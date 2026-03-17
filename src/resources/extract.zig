/// extract resource - Extract files from archives using native Zig std.tar + std.compress
/// Supported formats: .tar.gz/.tgz, .tar.xz/.txz, .tar (uncompressed)
const std = @import("std");
const mruby = @import("../mruby.zig");
const base = @import("../base_resource.zig");
const logger = @import("../logger.zig");

pub const FileMapping = struct {
    pattern: []const u8, // glob pattern, e.g. "*/s5cmd"
    target: []const u8, // destination filename, e.g. "s5cmd"
};

pub const ArchiveType = enum {
    tar_gz,
    tar_xz,
    tar,
    unknown,
};

pub const Resource = struct {
    path: []const u8,
    destination: []const u8,
    file_mappings: []const FileMapping,
    strip_components: u32,
    attrs: base.FileAttributes,
    action: Action,
    common: base.CommonProps,

    pub const Action = enum {
        extract, // extract all, rename matched files
        extract_files, // only extract matched files
    };

    pub fn deinit(self: Resource, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.destination);
        for (self.file_mappings) |m| {
            allocator.free(m.pattern);
            allocator.free(m.target);
        }
        allocator.free(self.file_mappings);
        self.attrs.deinit(allocator);
        var common = self.common;
        common.deinit(allocator);
    }

    pub fn apply(self: Resource) !base.ApplyResult {
        const action_name: []const u8 = switch (self.action) {
            .extract => "extract",
            .extract_files => "extract_files",
        };

        const skip_reason = try self.common.shouldRun(self.attrs.owner, self.attrs.group);
        if (skip_reason) |reason| {
            return base.ApplyResult{
                .was_updated = false,
                .action = action_name,
                .skip_reason = reason,
            };
        }

        // Idempotency: marker records fingerprint + file list.
        // Skip only if fingerprint matches AND all recorded files still exist.
        if (checkMarker(self.destination, self.path)) {
            return base.ApplyResult{
                .was_updated = false,
                .action = action_name,
                .skip_reason = "up to date",
            };
        }

        // Ensure destination directory exists (recursive)
        try makeDirRecursive(self.destination);

        const archive_type = detectArchiveType(self.path);
        if (archive_type == .unknown) {
            logger.err("[extract] unsupported archive type for {s}", .{self.path});
            return error.UnsupportedArchiveType;
        }

        const alloc = std.heap.c_allocator;

        var output_buf = std.ArrayList(u8).empty;
        defer output_buf.deinit(alloc);

        // extracted_paths: tracks files created by this run (for targeted attrs)
        var extracted_paths: std.ArrayListUnmanaged([]const u8) = .{};
        defer {
            for (extracted_paths.items) |p| alloc.free(p);
            extracted_paths.deinit(alloc);
        }

        if (self.file_mappings.len == 0) {
            try self.extractAll(archive_type, &output_buf, &extracted_paths);
        } else {
            try self.extractWithMappings(archive_type, &output_buf, &extracted_paths);
        }

        // Apply file attributes only to regular files created by this extraction.
        // Skip symlinks to avoid modifying link targets outside our management scope.
        if (self.attrs.mode != null or self.attrs.owner != null or self.attrs.group != null) {
            for (extracted_paths.items) |rel| {
                const full = std.fs.path.join(alloc, &.{ self.destination, rel }) catch continue;
                defer alloc.free(full);
                // Skip symlinks — applyFileAttributes follows links and would modify the target
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                if (std.fs.readLinkAbsolute(full, &buf)) |_| continue else |_| {}
                base.applyFileAttributes(full, self.attrs) catch |err| {
                    logger.warn("[extract] failed to apply attributes to {s}: {}", .{ full, err });
                };
            }
        }

        // Write marker file for idempotency (fingerprint + file list)
        writeMarker(self.destination, self.path, extracted_paths.items);

        const output = if (output_buf.items.len > 0)
            alloc.dupe(u8, output_buf.items) catch null
        else
            null;

        return base.ApplyResult{
            .was_updated = true,
            .action = action_name,
            .output = output,
        };
    }

    /// Full extraction: extract to temp dir first, collect file list,
    /// then copy to destination. This avoids including pre-existing files
    /// in the extracted_paths / marker.
    fn extractAll(self: Resource, archive_type: ArchiveType, output_buf: *std.ArrayList(u8), extracted_paths: *std.ArrayListUnmanaged([]const u8)) !void {
        const alloc = std.heap.c_allocator;

        // Extract to temp dir first to get clean file list
        const tmp_dir_path = std.fmt.allocPrint(alloc, "/tmp/hola-extract-all-{d}", .{std.time.nanoTimestamp()}) catch return error.OutOfMemory;
        defer alloc.free(tmp_dir_path);
        try makeDirRecursive(tmp_dir_path);
        defer std.fs.deleteTreeAbsolute(tmp_dir_path) catch {};

        const file = std.fs.openFileAbsolute(self.path, .{}) catch |err| {
            logger.err("[extract] failed to open archive {s}: {}", .{ self.path, err });
            return err;
        };
        defer file.close();

        var tmp_dir = try std.fs.openDirAbsolute(tmp_dir_path, .{});
        defer tmp_dir.close();

        try pipeArchiveToFileSystem(file, archive_type, tmp_dir, .{
            .strip_components = self.strip_components,
        }, alloc);

        // Collect file list from temp dir (these are exactly our extracted files)
        var walker = try walkDirRecursive(alloc, tmp_dir_path);
        defer walker.deinit(alloc);

        // Copy each file to destination and record in extracted_paths.
        // Errors propagate up to prevent marker from being written on partial failure.
        for (walker.items) |rel| {
            const src_path = try std.fs.path.join(alloc, &.{ tmp_dir_path, rel });
            defer alloc.free(src_path);
            const dest_path = try std.fs.path.join(alloc, &.{ self.destination, rel });
            defer alloc.free(dest_path);

            try ensureParentDirRecursive(dest_path);
            try copyFile(src_path, dest_path);
            try extracted_paths.append(alloc, rel); // transfer ownership
        }

        try output_buf.appendSlice(alloc, "extracted all files to ");
        try output_buf.appendSlice(alloc, self.destination);
    }

    /// Extract with file_mappings: supports both `all` and `files_only` modes.
    /// - all: extract all files and symlinks, matched entries get renamed,
    ///   unmatched entries keep their original paths (with strip_components applied).
    ///   Empty directories are not preserved.
    /// - files_only: only extract files/symlinks that match a pattern
    fn extractWithMappings(self: Resource, archive_type: ArchiveType, output_buf: *std.ArrayList(u8), extracted_paths: *std.ArrayListUnmanaged([]const u8)) !void {
        const alloc = std.heap.c_allocator;

        // Create temp directory
        const tmp_dir_path = std.fmt.allocPrint(alloc, "/tmp/hola-extract-{d}", .{std.time.nanoTimestamp()}) catch return error.OutOfMemory;
        defer alloc.free(tmp_dir_path);

        std.fs.makeDirAbsolute(tmp_dir_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        defer std.fs.deleteTreeAbsolute(tmp_dir_path) catch {};

        // Extract all to temp dir (raw, no strip)
        const file = std.fs.openFileAbsolute(self.path, .{}) catch |err| {
            logger.err("[extract] failed to open archive {s}: {}", .{ self.path, err });
            return err;
        };
        defer file.close();

        var tmp_dir = try std.fs.openDirAbsolute(tmp_dir_path, .{});
        defer tmp_dir.close();

        try pipeArchiveToFileSystem(file, archive_type, tmp_dir, .{}, alloc);

        // Walk temp dir
        var walker = try walkDirRecursive(alloc, tmp_dir_path);
        defer {
            for (walker.items) |entry| alloc.free(entry);
            walker.deinit(alloc);
        }

        // Track which files were matched (for `all` mode to know which are unmatched)
        var matched = try alloc.alloc(bool, walker.items.len);
        defer alloc.free(matched);
        @memset(matched, false);

        // Phase 1a: match patterns against archive entries (no writes yet)
        // match_idx[i] = index into walker.items that mapping[i] matched, or null
        var match_idx = try alloc.alloc(?usize, self.file_mappings.len);
        defer alloc.free(match_idx);
        @memset(match_idx, null);

        for (self.file_mappings, 0..) |mapping, mi| {
            for (walker.items, 0..) |relative_path, idx| {
                if (globMatch(mapping.pattern, relative_path)) {
                    match_idx[mi] = idx;
                    matched[idx] = true;
                    break;
                }
            }
        }

        // Phase 1b: in extract_files mode, validate all mappings hit before writing
        if (self.action == .extract_files) {
            for (self.file_mappings, 0..) |mapping, mi| {
                if (match_idx[mi] == null) {
                    logger.err("[extract] pattern '{s}' did not match any file in archive {s}", .{ mapping.pattern, self.path });
                    return error.PatternNotMatched;
                }
            }
        }

        // Phase 1c: write matched files (all validated)
        for (self.file_mappings, 0..) |mapping, mi| {
            if (match_idx[mi]) |idx| {
                const relative_path = walker.items[idx];
                const src_path = try std.fs.path.join(alloc, &.{ tmp_dir_path, relative_path });
                defer alloc.free(src_path);
                const dest_path = try std.fs.path.join(alloc, &.{ self.destination, mapping.target });
                defer alloc.free(dest_path);

                try ensureParentDirRecursive(dest_path);
                try copyFile(src_path, dest_path);
                try extracted_paths.append(alloc, try alloc.dupe(u8, mapping.target));

                try output_buf.appendSlice(alloc, relative_path);
                try output_buf.appendSlice(alloc, " -> ");
                try output_buf.appendSlice(alloc, mapping.target);
                try output_buf.appendSlice(alloc, "\n");
            }
        }

        // Phase 2: in `all` mode, copy unmatched files with strip_components
        if (self.action == .extract) {
            for (walker.items, 0..) |relative_path, idx| {
                if (matched[idx]) continue;

                const stripped = stripComponents(relative_path, self.strip_components);
                if (stripped.len == 0) continue; // fully stripped away

                const src_path = try std.fs.path.join(alloc, &.{ tmp_dir_path, relative_path });
                defer alloc.free(src_path);
                const dest_path = try std.fs.path.join(alloc, &.{ self.destination, stripped });
                defer alloc.free(dest_path);

                try ensureParentDirRecursive(dest_path);
                try copyFile(src_path, dest_path);
                try extracted_paths.append(alloc, try alloc.dupe(u8, stripped));

                try output_buf.appendSlice(alloc, relative_path);
                try output_buf.appendSlice(alloc, " -> ");
                try output_buf.appendSlice(alloc, stripped);
                try output_buf.appendSlice(alloc, "\n");
            }
        }
    }
};

/// Decompress and pipe tar archive to filesystem
fn pipeArchiveToFileSystem(file: std.fs.File, archive_type: ArchiveType, dir: std.fs.Dir, pipe_opts: std.tar.PipeOptions, allocator: std.mem.Allocator) !void {
    // Use diagnostics to collect non-fatal errors (e.g. stripped directory entries)
    // instead of failing the whole extraction
    var diagnostics: std.tar.Diagnostics = .{ .allocator = allocator };
    defer diagnostics.deinit();

    const opts: std.tar.PipeOptions = .{
        .strip_components = pipe_opts.strip_components,
        .mode_mode = pipe_opts.mode_mode,
        .exclude_empty_directories = pipe_opts.exclude_empty_directories,
        .diagnostics = &diagnostics,
    };

    var file_read_buf: [4096]u8 = undefined;
    var file_reader = std.fs.File.Reader.init(file, &file_read_buf);

    switch (archive_type) {
        .tar_gz => {
            var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
            var decompress = std.compress.flate.Decompress.init(&file_reader.interface, .gzip, &decompress_buf);
            try std.tar.pipeToFileSystem(dir, &decompress.reader, opts);
        },
        .tar_xz => {
            const old_reader = file_reader.interface.adaptToOldInterface();
            var xz_decomp = try std.compress.xz.decompress(allocator, old_reader);
            defer xz_decomp.deinit();
            var xz_reader_buf: [4096]u8 = undefined;
            var adapter = xz_decomp.reader().adaptToNewApi(&xz_reader_buf);
            try std.tar.pipeToFileSystem(dir, &adapter.new_interface, opts);
        },
        .tar => {
            try std.tar.pipeToFileSystem(dir, &file_reader.interface, opts);
        },
        .unknown => unreachable,
    }

    // Log real errors (not stripped-prefix warnings)
    for (diagnostics.errors.items) |err| {
        switch (err) {
            .unable_to_create_file => |info| {
                logger.warn("[extract] unable to create file: {s}", .{info.file_name});
            },
            .unable_to_create_sym_link => |info| {
                logger.warn("[extract] unable to create symlink: {s} -> {s}", .{ info.file_name, info.link_name });
            },
            .components_outside_stripped_prefix => {},
            .unsupported_file_type => {},
        }
    }
}

/// Check if a path exists without following symlinks.
/// Returns true for regular files, directories, and symlinks (even dangling ones).
fn pathExistsNoFollow(path: []const u8) bool {
    // First try readLinkAbsolute — succeeds for any symlink (dangling or not)
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.fs.readLinkAbsolute(path, &buf)) |_| return true else |_| {}
    // Not a symlink — check as regular file/dir
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn makeDirRecursive(path: []const u8) !void {
    std.fs.makeDirAbsolute(path) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        error.FileNotFound => {
            // Parent doesn't exist — recurse
            if (std.fs.path.dirname(path)) |parent| {
                try makeDirRecursive(parent);
                std.fs.makeDirAbsolute(path) catch |e| switch (e) {
                    error.PathAlreadyExists => {},
                    else => return e,
                };
            } else {
                return err;
            }
        },
        else => return err,
    };
}

fn ensureParentDirRecursive(path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try makeDirRecursive(parent);
    }
}

fn copyFile(src: []const u8, dst: []const u8) !void {
    try ensureParentDirRecursive(dst);

    // Try to read as symlink first
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.fs.readLinkAbsolute(src, &target_buf)) |target| {
        // Source is a symlink — recreate at destination
        std.fs.deleteFileAbsolute(dst) catch {};
        std.posix.symlinkat(target, std.posix.AT.FDCWD, dst) catch |err| {
            logger.warn("[extract] symlink creation failed {s}: {}", .{ dst, err });
            return err;
        };
    } else |_| {
        // Not a symlink — regular file copy
        try copyRegularFile(src, dst);
    }
}

fn copyRegularFile(src: []const u8, dst: []const u8) !void {
    const in_file = try std.fs.openFileAbsolute(src, .{});
    defer in_file.close();

    try ensureParentDirRecursive(dst);

    const out_file = try std.fs.createFileAbsolute(dst, .{ .truncate = true });
    defer out_file.close();

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try in_file.read(&buf);
        if (n == 0) break;
        try out_file.writeAll(buf[0..n]);
    }

    // Preserve source file mode (especially executable bit)
    const stat = try in_file.stat();
    out_file.chmod(stat.mode) catch {};
}

/// Strip N leading path components from a relative path.
/// e.g. stripComponents("a/b/c", 1) => "b/c"
fn stripComponents(path: []const u8, count: u32) []const u8 {
    var remaining = path;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (std.mem.indexOfScalar(u8, remaining, '/')) |sep| {
            remaining = remaining[sep + 1 ..];
        } else {
            return ""; // fully consumed
        }
    }
    return remaining;
}

/// Walk a directory recursively and return all file relative paths
fn walkDirRecursive(allocator: std.mem.Allocator, root: []const u8) !std.ArrayListUnmanaged([]const u8) {
    var results: std.ArrayListUnmanaged([]const u8) = .{};
    try walkDirRecursiveInner(allocator, root, "", &results);
    return results;
}

fn walkDirRecursiveInner(allocator: std.mem.Allocator, root: []const u8, prefix: []const u8, results: *std.ArrayListUnmanaged([]const u8)) !void {
    const full_path = if (prefix.len > 0)
        try std.fs.path.join(allocator, &.{ root, prefix })
    else
        try allocator.dupe(u8, root);
    defer allocator.free(full_path);

    var dir = std.fs.openDirAbsolute(full_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const relative = if (prefix.len > 0)
            try std.fs.path.join(allocator, &.{ prefix, entry.name })
        else
            try allocator.dupe(u8, entry.name);

        switch (entry.kind) {
            .directory => {
                try walkDirRecursiveInner(allocator, root, relative, results);
                allocator.free(relative);
            },
            .file, .sym_link => {
                try results.append(allocator, relative);
            },
            else => allocator.free(relative),
        }
    }
}

const MARKER_NAME = ".hola-extracted";

/// Build a fingerprint line: "path\tsize\tmtime_ns"
fn buildFingerprint(alloc: std.mem.Allocator, archive_path: []const u8) ?[]const u8 {
    const archive_file = std.fs.openFileAbsolute(archive_path, .{}) catch return null;
    defer archive_file.close();
    const stat = archive_file.stat() catch return null;
    return std.fmt.allocPrint(alloc, "{s}\t{d}\t{d}", .{ archive_path, stat.size, stat.mtime }) catch null;
}

/// Check marker: fingerprint must match AND all recorded files must still exist.
/// Marker format: first line = fingerprint, remaining lines = extracted file paths (relative to destination).
fn checkMarker(destination: []const u8, archive_path: []const u8) bool {
    const alloc = std.heap.c_allocator;
    const marker_path = std.fs.path.join(alloc, &.{ destination, MARKER_NAME }) catch return false;
    defer alloc.free(marker_path);
    const content = std.fs.cwd().readFileAlloc(alloc, marker_path, 1024 * 1024) catch return false;
    defer alloc.free(content);

    // First line is fingerprint
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    const first_line = line_iter.next() orelse return false;

    const fingerprint = buildFingerprint(alloc, archive_path) orelse return false;
    defer alloc.free(fingerprint);
    if (!std.mem.eql(u8, first_line, fingerprint)) return false;

    // Remaining lines are file paths — verify each exists (without following symlinks)
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        const file_path = std.fs.path.join(alloc, &.{ destination, line }) catch return false;
        defer alloc.free(file_path);
        if (!pathExistsNoFollow(file_path)) return false;
    }

    return true;
}

/// Write marker: fingerprint + file list.
fn writeMarker(destination: []const u8, archive_path: []const u8, files: []const []const u8) void {
    const alloc = std.heap.c_allocator;
    const marker_path = std.fs.path.join(alloc, &.{ destination, MARKER_NAME }) catch return;
    defer alloc.free(marker_path);
    const fingerprint = buildFingerprint(alloc, archive_path) orelse return;
    defer alloc.free(fingerprint);
    const file = std.fs.createFileAbsolute(marker_path, .{ .truncate = true }) catch return;
    defer file.close();
    file.writeAll(fingerprint) catch {};
    file.writeAll("\n") catch {};
    for (files) |rel| {
        file.writeAll(rel) catch {};
        file.writeAll("\n") catch {};
    }
}

pub fn detectArchiveType(path: []const u8) ArchiveType {
    if (std.mem.endsWith(u8, path, ".tar.gz") or std.mem.endsWith(u8, path, ".tgz")) {
        return .tar_gz;
    } else if (std.mem.endsWith(u8, path, ".tar.xz") or std.mem.endsWith(u8, path, ".txz")) {
        return .tar_xz;
    } else if (std.mem.endsWith(u8, path, ".tar")) {
        return .tar;
    }
    return .unknown;
}

/// Simple glob matching: `*` matches one path segment (no `/`), other chars match literally.
pub fn globMatch(pattern: []const u8, path: []const u8) bool {
    var pat_iter = std.mem.splitScalar(u8, pattern, '/');
    var path_iter = std.mem.splitScalar(u8, path, '/');

    while (true) {
        const pat_seg = pat_iter.next();
        const path_seg = path_iter.next();

        if (pat_seg == null and path_seg == null) return true;
        if (pat_seg == null or path_seg == null) return false;

        if (!segmentMatch(pat_seg.?, path_seg.?)) return false;
    }
}

fn segmentMatch(pattern: []const u8, text: []const u8) bool {
    if (std.mem.eql(u8, pattern, "*")) return true;

    var pi: usize = 0;
    var ti: usize = 0;
    var star_pi: ?usize = null;
    var star_ti: ?usize = null;

    while (ti < text.len) {
        if (pi < pattern.len and (pattern[pi] == text[ti] or pattern[pi] == '?')) {
            pi += 1;
            ti += 1;
        } else if (pi < pattern.len and pattern[pi] == '*') {
            star_pi = pi;
            star_ti = ti;
            pi += 1;
        } else if (star_pi) |sp| {
            pi = sp + 1;
            star_ti = star_ti.? + 1;
            ti = star_ti.?;
        } else {
            return false;
        }
    }

    while (pi < pattern.len and pattern[pi] == '*') pi += 1;
    return pi == pattern.len;
}

pub const ruby_prelude = @embedFile("extract_resource.rb");

pub fn zigAddResource(
    mrb: *mruby.mrb_state,
    self_val: mruby.mrb_value,
    resource_list: *std.ArrayList(Resource),
    allocator: std.mem.Allocator,
) mruby.mrb_value {
    _ = self_val;

    var path_val: mruby.mrb_value = undefined;
    var destination_val: mruby.mrb_value = undefined;
    var files_val: mruby.mrb_value = undefined;
    var mode_val: mruby.mrb_value = undefined;
    var owner_val: mruby.mrb_value = undefined;
    var group_val: mruby.mrb_value = undefined;
    var action_val: mruby.mrb_value = undefined;
    var strip_val: mruby.mrb_value = undefined;
    var only_if_val: mruby.mrb_value = undefined;
    var not_if_val: mruby.mrb_value = undefined;
    var ignore_failure_val: mruby.mrb_value = undefined;
    var notifications_val: mruby.mrb_value = undefined;
    var subscriptions_val: mruby.mrb_value = undefined;

    _ = mruby.mrb_get_args(mrb, "SSASSSSS|oooAA", &path_val, &destination_val, &files_val, &mode_val, &owner_val, &group_val, &action_val, &strip_val, &only_if_val, &not_if_val, &ignore_failure_val, &notifications_val, &subscriptions_val);

    const path = allocator.dupe(u8, std.mem.span(mruby.mrb_str_to_cstr(mrb, path_val))) catch return mruby.mrb_nil_value();
    const destination = allocator.dupe(u8, std.mem.span(mruby.mrb_str_to_cstr(mrb, destination_val))) catch return mruby.mrb_nil_value();

    // Parse files array: [[pattern, target], ...]
    var mappings_list = std.ArrayList(FileMapping).initCapacity(allocator, 4) catch std.ArrayList(FileMapping).empty;

    const files_len = mruby.mrb_ary_len(mrb, files_val);
    for (0..@intCast(files_len)) |i| {
        const pair = mruby.mrb_ary_ref(mrb, files_val, @intCast(i));
        const pair_len = mruby.mrb_ary_len(mrb, pair);
        if (pair_len >= 2) {
            const pattern_val = mruby.mrb_ary_ref(mrb, pair, 0);
            const target_val = mruby.mrb_ary_ref(mrb, pair, 1);

            const pat = allocator.dupe(u8, std.mem.span(mruby.mrb_str_to_cstr(mrb, pattern_val))) catch continue;
            const tgt = allocator.dupe(u8, std.mem.span(mruby.mrb_str_to_cstr(mrb, target_val))) catch {
                allocator.free(pat);
                continue;
            };

            mappings_list.append(allocator, .{
                .pattern = pat,
                .target = tgt,
            }) catch continue;
        }
    }

    const file_mappings = mappings_list.toOwnedSlice(allocator) catch return mruby.mrb_nil_value();

    // Parse action
    const action_str = std.mem.span(mruby.mrb_str_to_cstr(mrb, action_val));
    const action: Resource.Action = if (std.mem.eql(u8, action_str, "extract_files"))
        .extract_files
    else
        .extract;

    // Parse strip_components
    const strip_str = std.mem.span(mruby.mrb_str_to_cstr(mrb, strip_val));
    const strip_components: u32 = if (strip_str.len > 0)
        std.fmt.parseInt(u32, strip_str, 10) catch 0
    else
        0;

    // Parse mode
    const mode_str = std.mem.span(mruby.mrb_str_to_cstr(mrb, mode_val));
    const mode: ?u32 = if (mode_str.len > 0)
        std.fmt.parseInt(u32, mode_str, 8) catch null
    else
        null;

    // Parse owner
    const owner_str = std.mem.span(mruby.mrb_str_to_cstr(mrb, owner_val));
    const owner: ?[]const u8 = if (owner_str.len > 0)
        allocator.dupe(u8, owner_str) catch null
    else
        null;

    // Parse group
    const group_str = std.mem.span(mruby.mrb_str_to_cstr(mrb, group_val));
    const group_opt: ?[]const u8 = if (group_str.len > 0)
        allocator.dupe(u8, group_str) catch null
    else
        null;

    var common = base.CommonProps.init(allocator);
    base.fillCommonFromRuby(&common, mrb, only_if_val, not_if_val, ignore_failure_val, notifications_val, subscriptions_val, allocator);

    resource_list.append(allocator, .{
        .path = path,
        .destination = destination,
        .file_mappings = file_mappings,
        .strip_components = strip_components,
        .attrs = .{
            .mode = mode,
            .owner = owner,
            .group = group_opt,
        },
        .action = action,
        .common = common,
    }) catch return mruby.mrb_nil_value();

    return mruby.mrb_nil_value();
}

test "detectArchiveType" {
    const testing = std.testing;
    try testing.expectEqual(ArchiveType.tar_gz, detectArchiveType("/tmp/foo.tar.gz"));
    try testing.expectEqual(ArchiveType.tar_gz, detectArchiveType("/tmp/foo.tgz"));
    try testing.expectEqual(ArchiveType.tar_xz, detectArchiveType("/tmp/foo.tar.xz"));
    try testing.expectEqual(ArchiveType.tar_xz, detectArchiveType("/tmp/foo.txz"));
    try testing.expectEqual(ArchiveType.tar, detectArchiveType("/tmp/foo.tar"));
    try testing.expectEqual(ArchiveType.unknown, detectArchiveType("/tmp/foo.zip"));
    try testing.expectEqual(ArchiveType.unknown, detectArchiveType("/tmp/foo.rar"));
    try testing.expectEqual(ArchiveType.unknown, detectArchiveType("/tmp/foo"));
}

test "globMatch basic patterns" {
    const testing = std.testing;
    try testing.expect(globMatch("foo/bar", "foo/bar"));
    try testing.expect(!globMatch("foo/bar", "foo/baz"));

    try testing.expect(globMatch("*/s5cmd", "s5cmd_2.3.0_Linux-64bit/s5cmd"));
    try testing.expect(globMatch("*/LICENSE", "some_dir/LICENSE"));
    try testing.expect(!globMatch("*/s5cmd", "a/b/s5cmd"));

    try testing.expect(globMatch("s5cmd_*/s5cmd", "s5cmd_2.3.0/s5cmd"));
    try testing.expect(!globMatch("s5cmd_*/s5cmd", "other/s5cmd"));

    try testing.expect(globMatch("bin/tool", "bin/tool"));
    try testing.expect(!globMatch("bin/tool", "bin/other"));
}

test "stripComponents" {
    const testing = std.testing;
    try testing.expectEqualStrings("b/c", stripComponents("a/b/c", 1));
    try testing.expectEqualStrings("c", stripComponents("a/b/c", 2));
    try testing.expectEqualStrings("", stripComponents("a/b/c", 3));
    try testing.expectEqualStrings("a/b/c", stripComponents("a/b/c", 0));
    try testing.expectEqualStrings("", stripComponents("a", 1));
}

test "globMatch edge cases" {
    const testing = std.testing;
    try testing.expect(globMatch("README", "README"));
    try testing.expect(!globMatch("README", "LICENSE"));
    try testing.expect(globMatch("*", "anything"));
    try testing.expect(!globMatch("*", "a/b"));
}
