const std = @import("std");
const fmt = std.fmt;
const table = @import("table.zig");
const glob = @import("glob.zig");

const log = std.log.scoped(.dotfiles);
const Ansi = table.Ansi;
const CellStyle = table.CellStyle;

const DisplayPrefix = struct {
    text: []const u8,
    owned: bool = false,
};
const default_display_prefix: []const u8 = "~/";

pub const Options = struct {
    root_override: ?[]const u8 = null,
    dry_run: bool = false, // Default: actually create links
    home_override: ?[]const u8 = null,
    ignore_patterns: ?[]const []const u8 = null,
    output_writer: ?std.fs.File.Writer = null, // Optional writer for output (for progress display integration)
};

pub fn run(allocator: std.mem.Allocator, opts: Options) !void {
    const home_dir = try resolveHome(allocator, opts.home_override);
    defer allocator.free(home_dir);

    const base_root = opts.root_override orelse "~/.dotfiles";
    const resolved_root = try resolvePath(allocator, base_root, home_dir);
    defer allocator.free(resolved_root);

    var display_prefix = try buildDisplayPrefix(allocator, home_dir, opts.home_override == null);
    errdefer if (display_prefix.owned) allocator.free(display_prefix.text);

    var planner = try Planner.init(allocator, resolved_root, home_dir, display_prefix, opts.ignore_patterns);
    display_prefix.owned = false;
    defer planner.deinit();

    try planner.build();
    if (opts.dry_run) {
        try planner.renderReport();
    } else {
        try planner.apply();
    }
}

pub const runDryRun = run;

fn resolveHome(allocator: std.mem.Allocator, override: ?[]const u8) ![]const u8 {
    if (override) |value| return allocator.dupe(u8, value);
    return std.process.getEnvVarOwned(allocator, "HOME");
}

fn resolvePath(allocator: std.mem.Allocator, path: []const u8, home: []const u8) ![]const u8 {
    if (path.len == 0) return error.InvalidPath;
    if (path[0] == '~') {
        if (path.len == 1) return allocator.dupe(u8, home);
        if (path[1] != '/')
            return error.UnsupportedTildeUser;
        return std.fs.path.join(allocator, &.{ home, path[2..] });
    }
    if (std.fs.path.isAbsolute(path)) {
        return allocator.dupe(u8, path);
    }
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, path });
}

fn buildDisplayPrefix(allocator: std.mem.Allocator, target_dir: []const u8, use_home_symbol: bool) !DisplayPrefix {
    if (use_home_symbol) {
        return .{ .text = default_display_prefix };
    }

    const needs_trailing = target_dir.len == 0 or target_dir[target_dir.len - 1] != '/';
    if (!needs_trailing) {
        const duped = try allocator.dupe(u8, target_dir);
        return .{ .text = duped, .owned = true };
    }
    const text = try std.fmt.allocPrint(allocator, "{s}/", .{target_dir});
    return .{ .text = text, .owned = true };
}

const Planner = struct {
    allocator: std.mem.Allocator,
    root: []const u8,
    home: []const u8,
    display_prefix: []const u8,
    owns_display_prefix: bool,
    entries: std.ArrayListUnmanaged(PlanEntry) = .{},
    builder: std.ArrayListUnmanaged(u8) = .{},
    ignore_patterns: std.ArrayListUnmanaged([]const u8) = .{},

    const PlanEntry = struct {
        rel_path: []const u8,
        status: Status,
        existing_target: ?[]const u8 = null,
    };
    fn entryRelPath(entry: PlanEntry) []const u8 {
        return entry.rel_path;
    }

    const Status = enum {
        create_link,
        already_linked,
        different_link,
        existing_file,
        existing_directory,
    };
    const ApplyOutcome = enum { success, skipped };

    const default_ignore_components = [_][]const u8{
        ".git",
        ".github",
        ".gitmodules",
        ".gitignore",
        ".DS_Store",
        "README.md",
        "README",
        "LICENSE",
        "LICENSE.md",
    };

    fn init(allocator: std.mem.Allocator, root: []const u8, home: []const u8, prefix: DisplayPrefix, ignore_patterns: ?[]const []const u8) !Planner {
        try ensureRootExists(root);
        var planner = Planner{
            .allocator = allocator,
            .root = root,
            .home = home,
            .display_prefix = prefix.text,
            .owns_display_prefix = prefix.owned,
        };

        // Load ignore patterns from provided list
        if (ignore_patterns) |patterns| {
            for (patterns) |pattern| {
                const pattern_copy = try allocator.dupe(u8, pattern);
                try planner.ignore_patterns.append(allocator, pattern_copy);
            }
        }

        return planner;
    }

    fn deinit(self: *Planner) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.rel_path);
            if (entry.existing_target) |t| self.allocator.free(t);
        }
        self.entries.deinit(self.allocator);
        self.builder.deinit(self.allocator);
        for (self.ignore_patterns.items) |pattern| {
            self.allocator.free(pattern);
        }
        self.ignore_patterns.deinit(self.allocator);
        if (self.owns_display_prefix) self.allocator.free(self.display_prefix);
    }

    fn build(self: *Planner) !void {
        try self.scan(self.root);
        sortEntries(self.entries.items);
    }

    fn scan(self: *Planner, abs_path: []const u8) !void {
        var dir = try std.fs.openDirAbsolute(abs_path, .{ .iterate = true });
        defer dir.close();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            const prev_len = self.builder.items.len;
            if (prev_len != 0) try self.builder.append(self.allocator, '/');
            try self.builder.appendSlice(self.allocator, entry.name);

            const rel = self.builder.items[0..self.builder.items.len];
            const skip = shouldSkip(self, rel, entry.kind);

            switch (entry.kind) {
                .file, .sym_link, .directory => {
                    if (!skip) try self.recordEntry(rel);
                },
                else => {},
            }

            self.builder.items.len = prev_len;
        }
    }

    const Classification = struct {
        status: Status,
        existing_target: ?[]const u8 = null,
    };

    fn recordEntry(self: *Planner, rel: []const u8) !void {
        const rel_copy = try self.allocator.dupe(u8, rel);
        const source_abs = try std.fs.path.join(self.allocator, &.{ self.root, rel });
        defer self.allocator.free(source_abs);

        const status_info = try self.classify(source_abs, rel);
        try self.entries.append(self.allocator, .{
            .rel_path = rel_copy,
            .status = status_info.status,
            .existing_target = status_info.existing_target,
        });
    }

    fn classify(self: *Planner, source_abs: []const u8, rel_path: []const u8) !Classification {
        const target_abs = try std.fs.path.join(self.allocator, &.{ self.home, rel_path });
        defer self.allocator.free(target_abs);

        var link_buf: [std.fs.max_path_bytes]u8 = undefined;
        const link_result = std.fs.readLinkAbsolute(target_abs, &link_buf) catch |err| switch (err) {
            error.FileNotFound => return .{ .status = .create_link },
            error.NotLink => {
                const kind = try statKind(target_abs);
                return .{ .status = switch (kind) {
                    .directory => .existing_directory,
                    else => .existing_file,
                } };
            },
            else => return err,
        };

        if (std.mem.eql(u8, link_result, source_abs)) {
            return .{ .status = .already_linked };
        }

        const existing = try self.allocator.dupe(u8, link_result);
        return .{ .status = .different_link, .existing_target = existing };
    }

    fn statKind(path: []const u8) !std.fs.File.Kind {
        const parent = std.fs.path.dirname(path) orelse "/";
        const base = std.fs.path.basename(path);
        var dir = try std.fs.openDirAbsolute(parent, .{});
        defer dir.close();
        const stat = try dir.statFile(base);
        return stat.kind;
    }

    fn renderReport(self: *Planner) !void {
        const out = std.fs.File.stdout();
        const simple = table.SimpleTable.init(self.allocator, out);

        if (self.entries.items.len == 0) {
            var buf: [256]u8 = undefined;
            const detail = try fmt.bufPrint(&buf, "dry-run (root: {s})", .{self.root});
            try simple.printHeader("[dotfiles]", detail);
            try simple.printDimmed("No linkable entries were found.\n");
            return;
        }

        var create_count: usize = 0;
        var ok_count: usize = 0;
        var conflict_count: usize = 0;

        var buf: [256]u8 = undefined;
        const detail = try fmt.bufPrint(&buf, "dry-run (root: {s})", .{self.root});
        try simple.printHeader("[dotfiles]", detail);

        var tbl = try table.Table.init(self.allocator, out, &.{
            .{ .width = 3, .padding = 2 },
            .{ .padding = 2 },
            .{ .padding = 2 },
            .{ .padding = 0 },
        });
        defer tbl.deinit();

        var cells_buf: std.ArrayListUnmanaged([]const u8) = .{};
        defer {
            for (cells_buf.items) |cell| {
                self.allocator.free(cell);
            }
            cells_buf.deinit(self.allocator);
        }

        for (self.entries.items) |entry| {
            const source_abs = try std.fs.path.join(self.allocator, &.{ self.root, entry.rel_path });
            defer self.allocator.free(source_abs);

            const path_str = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.display_prefix, entry.rel_path });
            try cells_buf.append(self.allocator, path_str);

            const status_info = try self.getStatusInfo(entry, source_abs, path_str);
            try cells_buf.append(self.allocator, status_info.reason_text);

            try tbl.addRow(&.{
                status_info.status_cell,
                status_info.path_style,
                CellStyle.plain("->"),
                status_info.target_style,
            });

            switch (entry.status) {
                .create_link => create_count += 1,
                .already_linked => ok_count += 1,
                .different_link, .existing_file, .existing_directory => conflict_count += 1,
            }
        }

        try tbl.render();

        try out.writeAll("\n");
        try simple.printSummary(&.{
            .{ .label = "plan", .value = create_count, .color = Ansi.green },
            .{ .label = "ok", .value = ok_count, .color = Ansi.cyan },
            .{ .label = "conflicts", .value = conflict_count, .color = Ansi.red },
        });
        try simple.printDimmed("Dry-run only: nothing was modified.\n");
    }

    const StatusInfo = struct {
        status_cell: CellStyle,
        path_style: CellStyle,
        target_style: CellStyle,
        reason_text: []const u8,
    };

    fn getStatusInfo(self: *Planner, entry: PlanEntry, source_abs: []const u8, path_str: []const u8) !StatusInfo {
        return switch (entry.status) {
            .create_link => blk: {
                // Format source_abs to avoid encoding issues
                const formatted_target = try std.fmt.allocPrint(self.allocator, "{s}", .{source_abs});
                break :blk StatusInfo{
                    .status_cell = CellStyle.label("[+]", Ansi.green),
                    .path_style = CellStyle.colored(path_str, Ansi.green),
                    .target_style = CellStyle.colored(formatted_target, Ansi.green),
                    .reason_text = formatted_target,
                };
            },
            .already_linked => blk: {
                const reason = try std.fmt.allocPrint(self.allocator, "{s} (already linked)", .{source_abs});
                break :blk StatusInfo{
                    .status_cell = CellStyle.label("[✓]", Ansi.green),
                    .path_style = CellStyle.dimmed(path_str),
                    .target_style = CellStyle.dimmed(reason),
                    .reason_text = reason,
                };
            },
            .different_link => blk: {
                const target = entry.existing_target orelse "unknown";
                const reason = try std.fmt.allocPrint(self.allocator, "{s} (points to {s})", .{ source_abs, target });
                break :blk StatusInfo{
                    .status_cell = CellStyle.label("[→]", Ansi.yellow),
                    .path_style = CellStyle.dimmed(path_str),
                    .target_style = CellStyle.colored(reason, Ansi.yellow),
                    .reason_text = reason,
                };
            },
            .existing_file => blk: {
                const reason = try std.fmt.allocPrint(self.allocator, "{s} (file exists)", .{source_abs});
                break :blk StatusInfo{
                    .status_cell = CellStyle.label("[!]", Ansi.red),
                    .path_style = CellStyle.dimmed(path_str),
                    .target_style = CellStyle.colored(reason, Ansi.red),
                    .reason_text = reason,
                };
            },
            .existing_directory => blk: {
                const reason = try std.fmt.allocPrint(self.allocator, "{s} (directory exists)", .{source_abs});
                break :blk StatusInfo{
                    .status_cell = CellStyle.label("[!]", Ansi.red),
                    .path_style = CellStyle.dimmed(path_str),
                    .target_style = CellStyle.colored(reason, Ansi.red),
                    .reason_text = reason,
                };
            },
        };
    }

    fn apply(self: *Planner) !void {
        const out = std.fs.File.stdout();
        const simple = table.SimpleTable.init(self.allocator, out);

        var buf: [256]u8 = undefined;
        const detail = try fmt.bufPrint(&buf, "linking {s} -> {s}", .{ self.root, self.home });
        try simple.printHeader("[apply]", detail);

        var tbl = try table.Table.init(self.allocator, out, &.{
            .{ .width = 3, .padding = 2 },
            .{ .padding = 2 },
            .{ .padding = 2 },
            .{ .padding = 0 },
        });
        defer tbl.deinit();

        var cells_buf: std.ArrayListUnmanaged([]const u8) = .{};
        defer {
            for (cells_buf.items) |cell| {
                self.allocator.free(cell);
            }
            cells_buf.deinit(self.allocator);
        }

        var linked_count: usize = 0;
        var skipped_count: usize = 0;

        for (self.entries.items) |entry| {
            const source_abs = try std.fs.path.join(self.allocator, &.{ self.root, entry.rel_path });
            defer self.allocator.free(source_abs);

            const path_str = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.display_prefix, entry.rel_path });
            try cells_buf.append(self.allocator, path_str);

            switch (entry.status) {
                .create_link => {
                    const outcome = try self.applyLink(entry);
                    const status_info = if (outcome == .success) blk: {
                        // After successful link creation, keep [+] icon and green color
                        const reason = try std.fmt.allocPrint(self.allocator, "{s} (already linked)", .{source_abs});
                        break :blk StatusInfo{
                            .status_cell = CellStyle.label("[+]", Ansi.green),
                            .path_style = CellStyle.colored(path_str, Ansi.green),
                            .target_style = CellStyle.colored(reason, Ansi.green),
                            .reason_text = reason,
                        };
                    } else
                        StatusInfo{
                            .status_cell = CellStyle.label("[!]", Ansi.red),
                            .path_style = CellStyle.dimmed(path_str),
                            .target_style = CellStyle.colored(source_abs, Ansi.red),
                            .reason_text = try self.allocator.dupe(u8, source_abs),
                        };

                    try cells_buf.append(self.allocator, status_info.reason_text);

                    try tbl.addRow(&.{
                        status_info.status_cell,
                        status_info.path_style,
                        CellStyle.plain("->"),
                        status_info.target_style,
                    });

                    switch (outcome) {
                        .success => linked_count += 1,
                        .skipped => skipped_count += 1,
                    }
                },
                else => {
                    skipped_count += 1;
                    const status_info = try self.getStatusInfo(entry, source_abs, path_str);
                    try cells_buf.append(self.allocator, status_info.reason_text);

                    try tbl.addRow(&.{
                        status_info.status_cell,
                        status_info.path_style,
                        CellStyle.plain("->"),
                        status_info.target_style,
                    });
                },
            }
        }

        try tbl.render();

        try out.writeAll("\n");
        try simple.printSummary(&.{
            .{ .label = "linked", .value = linked_count, .color = Ansi.green },
            .{ .label = "skipped", .value = skipped_count, .color = Ansi.yellow },
        });
    }

    fn applyLink(self: *Planner, entry: PlanEntry) !ApplyOutcome {
        const source_abs = try std.fs.path.join(self.allocator, &.{ self.root, entry.rel_path });
        defer self.allocator.free(source_abs);
        const target_abs = try std.fs.path.join(self.allocator, &.{ self.home, entry.rel_path });
        defer self.allocator.free(target_abs);

        if (std.fs.path.dirname(target_abs)) |dir| {
            std.fs.cwd().makePath(dir) catch |err| {
                log.err("Failed to create parent directories for {s}: {s}", .{ target_abs, @errorName(err) });
                return .skipped;
            };
        }

        std.fs.symLinkAbsolute(source_abs, target_abs, .{}) catch |err| {
            log.err("Failed to create symlink {s}: {s}", .{ target_abs, @errorName(err) });
            return .skipped;
        };

        return .success;
    }
};

fn ensureRootExists(path: []const u8) !void {
    var dir = try std.fs.openDirAbsolute(path, .{});
    defer dir.close();
}

fn shouldSkip(planner: *Planner, rel_path: []const u8, kind: std.fs.Dir.Entry.Kind) bool {
    // Check default ignore components (first component only)
    const component_end = std.mem.indexOfScalar(u8, rel_path, '/') orelse rel_path.len;
    const first_component = rel_path[0..component_end];
    inline for (Planner.default_ignore_components) |pattern| {
        if (std.mem.eql(u8, first_component, pattern)) return true;
    }

    // Check glob patterns from config
    for (planner.ignore_patterns.items) |pattern| {
        if (glob.match(pattern, rel_path)) {
            return true;
        }
    }

    // Ignore backup files (ending with ~)
    if (kind == .file and rel_path.len != 0 and rel_path[rel_path.len - 1] == '~') return true;

    return false;
}

fn sortEntries(entries: []Planner.PlanEntry) void {
    const Cmp = struct {
        fn lessThan(_: void, lhs: Planner.PlanEntry, rhs: Planner.PlanEntry) bool {
            return std.mem.lessThan(u8, lhs.rel_path, rhs.rel_path);
        }
    };
    std.mem.sort(Planner.PlanEntry, entries, {}, Cmp.lessThan);
}

test "classify statuses" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_path = try std.fs.path.join(alloc, &.{ tmp.path, "dotfiles" });
    defer alloc.free(root_path);
    try std.fs.makeDirAbsolute(root_path);

    const home_path = try std.fs.path.join(alloc, &.{ tmp.path, "home" });
    defer alloc.free(home_path);
    try std.fs.makeDirAbsolute(home_path);

    const source_abs = try std.fs.path.join(alloc, &.{ root_path, ".zshrc" });
    defer alloc.free(source_abs);
    try std.fs.writeFileAbsolute(source_abs, "echo hi\n");

    var planner = try Planner.init(alloc, root_path, home_path);
    defer planner.deinit();

    const rel = ".zshrc";

    var classification = try planner.classify(source_abs, rel);
    try std.testing.expectEqual(Planner.Status.create_link, classification.status);

    const target_abs = try std.fs.path.join(alloc, &.{ home_path, rel });
    defer alloc.free(target_abs);
    try std.fs.symLinkAbsolute(source_abs, target_abs, .{});

    classification = try planner.classify(source_abs, rel);
    try std.testing.expectEqual(Planner.Status.already_linked, classification.status);

    try std.fs.deleteFileAbsolute(target_abs);
    const other = try std.fs.path.join(alloc, &.{ tmp.path, "other" });
    defer alloc.free(other);
    try std.fs.writeFileAbsolute(other, "alt\n");
    try std.fs.symLinkAbsolute(other, target_abs, .{});

    classification = try planner.classify(source_abs, rel);
    try std.testing.expectEqual(Planner.Status.different_link, classification.status);
    try std.testing.expect(classification.existing_target != null);

    try std.fs.deleteFileAbsolute(target_abs);
    try std.fs.writeFileAbsolute(target_abs, "plain file\n");
    classification = try planner.classify(source_abs, rel);
    try std.testing.expectEqual(Planner.Status.existing_file, classification.status);
}
