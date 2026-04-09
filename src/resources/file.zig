const std = @import("std");
const mruby = @import("../mruby.zig");
const base = @import("../base_resource.zig");
const git = @import("../git.zig");
const logger = @import("../logger.zig");

/// File resource data structure
pub const Resource = struct {
    // Resource-specific properties
    path: []const u8,
    content: []const u8,
    attrs: base.FileAttributes,
    action: Action,

    // Common properties (guards, notifications, etc.)
    common: base.CommonProps,

    pub const Action = enum {
        create,
        delete,
        touch,
    };

    pub fn deinit(self: Resource, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.content);
        self.attrs.deinit(allocator);

        // Deinit common props (handles GC, notifications, etc.)
        var common = self.common;
        common.deinit(allocator);
    }

    pub fn apply(self: Resource) !base.ApplyResult {
        const skip_reason = try self.common.shouldRun(self.attrs.owner, self.attrs.group);
        if (skip_reason) |reason| {
            const action_name = switch (self.action) {
                .create => "create",
                .delete => "delete",
                .touch => "touch",
            };
            return base.ApplyResult{
                .was_updated = false,
                .action = action_name,
                .skip_reason = reason,
            };
        }

        const action_name = switch (self.action) {
            .create => "create",
            .delete => "delete",
            .touch => "touch",
        };

        switch (self.action) {
            .create => {
                const create_result = try applyCreate(self);
                return base.ApplyResult{
                    .was_updated = create_result.was_updated,
                    .action = action_name,
                    .skip_reason = if (create_result.was_updated) null else "up to date",
                    .output = create_result.output,
                };
            },
            .delete => {
                try applyDelete(self);
                return base.ApplyResult{
                    .was_updated = false,
                    .action = action_name,
                    .skip_reason = "up to date",
                };
            },
            .touch => {
                const was_updated = try applyTouch(self);
                return base.ApplyResult{
                    .was_updated = was_updated,
                    .action = action_name,
                    .skip_reason = if (was_updated) null else "up to date",
                };
            },
        }
    }

    const CreateResult = struct { was_updated: bool, output: ?[]const u8 };

    fn applyCreate(self: Resource) !CreateResult {
        try base.ensureParentDir(self.path);
        const is_abs = std.fs.path.isAbsolute(self.path);

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        // Check if file exists and content matches
        const file_exists = blk: {
            if (is_abs) {
                std.fs.accessAbsolute(self.path, .{}) catch |err| switch (err) {
                    error.FileNotFound => break :blk false,
                    else => return err,
                };
            } else {
                std.fs.cwd().access(self.path, .{}) catch |err| switch (err) {
                    error.FileNotFound => break :blk false,
                    else => return err,
                };
            }
            break :blk true;
        };

        var existing_content: ?[]u8 = null;
        defer if (existing_content) |c| std.heap.c_allocator.free(c);

        var current_mode: ?u32 = null;
        if (file_exists) {
            // Read existing file and compare content
            const existing_file = if (is_abs)
                try std.fs.openFileAbsolute(self.path, .{})
            else
                try std.fs.cwd().openFile(self.path, .{});
            defer existing_file.close();

            existing_content = try existing_file.readToEndAlloc(std.heap.c_allocator, std.math.maxInt(usize));

            if (self.attrs.mode) |_| {
                const stat = try existing_file.stat();
                current_mode = @intCast(stat.mode & 0o777);
            }

            if (std.mem.eql(u8, existing_content.?, self.content)) {
                // Content matches, check attributes if specified
                const mode_matches = if (self.attrs.mode) |m|
                    current_mode != null and current_mode.? == m
                else
                    true;

                if (mode_matches) {
                    return .{ .was_updated = false, .output = null };
                }

                // Only mode differs; fix attributes without rewriting
                base.applyFileAttributes(self.path, self.attrs) catch |err| {
                    logger.warn("Failed to apply file attributes for {s}: {}", .{ self.path, err });
                };
                return .{ .was_updated = true, .output = null };
            }
        }

        // File doesn't exist or content differs, create/update it
        // Generate diff if file existed and log it
        var diff_output: ?[]const u8 = null;
        errdefer if (diff_output) |d| std.heap.c_allocator.free(d);
        if (existing_content) |old_content| {
            const diff = git.diffStrings(
                std.heap.c_allocator,
                old_content,
                self.content,
                self.path,
                self.path,
            ) catch |err| blk: {
                logger.warn("Failed to generate diff for {s}: {}", .{ self.path, err });
                break :blk null;
            };

            if (diff) |d| {
                if (d.len > 0) {
                    logger.info("File diff for {s}:\n{s}", .{ self.path, d });
                    diff_output = d;
                } else {
                    std.heap.c_allocator.free(d);
                }
            }
        }

        const dir_path = std.fs.path.dirname(self.path);
        const timestamp = std.time.nanoTimestamp();
        const pid = std.c.getpid();
        const temp_name = try std.fmt.allocPrint(allocator, ".hola-tmp-{d}-{d}", .{ timestamp, pid });
        const temp_path = if (dir_path) |d|
            try std.fs.path.join(allocator, &.{ d, temp_name })
        else
            temp_name;

        var temp_file = if (is_abs)
            try std.fs.createFileAbsolute(temp_path, .{ .truncate = true, .exclusive = true })
        else
            try std.fs.cwd().createFile(temp_path, .{ .truncate = true, .exclusive = true });

        var temp_cleanup = true;
        var temp_file_closed = false;
        defer if (temp_cleanup) {
            if (!temp_file_closed) temp_file.close();
            if (is_abs) {
                std.fs.deleteFileAbsolute(temp_path) catch {};
            } else {
                std.fs.cwd().deleteFile(temp_path) catch {};
            }
        };

        try temp_file.writeAll(self.content);
        try temp_file.sync();
        temp_file.close();
        temp_file_closed = true;

        if (is_abs) {
            try std.fs.renameAbsolute(temp_path, self.path);
        } else {
            try std.fs.cwd().rename(temp_path, self.path);
        }

        // Temp file has been moved; avoid double cleanup
        temp_cleanup = false;

        // Apply file attributes after atomic rename
        base.applyFileAttributes(self.path, self.attrs) catch |err| {
            logger.warn("Failed to apply file attributes for {s}: {}", .{ self.path, err });
        };

        return .{ .was_updated = true, .output = diff_output };
    }

    /// Chef :touch semantics — ensure the file exists and bump atime/mtime
    /// without ever rewriting the content. If the file is missing, an empty
    /// file is created; otherwise its bytes are left untouched. The `content`
    /// property is intentionally ignored for touch.
    fn applyTouch(self: Resource) !bool {
        try base.ensureParentDir(self.path);
        const is_abs = std.fs.path.isAbsolute(self.path);

        // Separate "create if missing" from "update timestamps": createFile
        // opens with O_WRONLY which fails on a 0444 file even for its owner,
        // yet standard touch / Chef :touch must succeed for the owner via
        // utimensat (checks inode ownership, not write permission).
        const exists = blk: {
            if (is_abs) {
                std.fs.accessAbsolute(self.path, .{}) catch |err| switch (err) {
                    error.FileNotFound => break :blk false,
                    else => return err,
                };
            } else {
                std.fs.cwd().access(self.path, .{}) catch |err| switch (err) {
                    error.FileNotFound => break :blk false,
                    else => return err,
                };
            }
            break :blk true;
        };

        if (!exists) {
            const new_file = if (is_abs)
                try std.fs.createFileAbsolute(self.path, .{})
            else
                try std.fs.cwd().createFile(self.path, .{});
            new_file.close();
        }

        // Path-based utimensat with times=null sets both atime and mtime
        // to the current time.  Unlike fd-based futimens, this does not
        // require opening the file at all, so it works regardless of the
        // file's read/write permission bits (only inode ownership or
        // CAP_FOWNER is checked).
        const path_z = try std.posix.toPosixPath(self.path);
        switch (std.posix.errno(std.c.utimensat(std.posix.AT.FDCWD, &path_z, null, 0))) {
            .SUCCESS => {},
            .ACCES => return error.AccessDenied,
            .PERM => return error.AccessDenied,
            .ROFS => return error.ReadOnlyFileSystem,
            else => |err| return std.posix.unexpectedErrno(err),
        }

        // Apply file attributes (mode/owner/group) if requested.
        base.applyFileAttributes(self.path, self.attrs) catch |err| {
            logger.warn("Failed to apply file attributes for {s}: {}", .{ self.path, err });
        };

        return true;
    }

    fn applyDelete(self: Resource) !void {
        const is_abs = std.fs.path.isAbsolute(self.path);
        if (is_abs) {
            std.fs.deleteFileAbsolute(self.path) catch |err| switch (err) {
                error.FileNotFound => return,
                else => return err,
            };
        } else {
            std.fs.cwd().deleteFile(self.path) catch |err| switch (err) {
                error.FileNotFound => return,
                else => return err,
            };
        }
    }
};

/// Ruby prelude for file resource
pub const ruby_prelude = @embedFile("file_resource.rb");

/// Zig callback: called from Ruby to add a file resource
/// Format: add_file(path, content, action, mode, owner, group, only_if_block, not_if_block, ignore_failure, notifications_array)
pub fn zigAddResource(
    mrb: *mruby.mrb_state,
    self: mruby.mrb_value,
    resources: *std.ArrayList(Resource),
    allocator: std.mem.Allocator,
) mruby.mrb_value {
    _ = self;

    var path_val: mruby.mrb_value = undefined;
    var content_val: mruby.mrb_value = undefined;
    var action_val: mruby.mrb_value = undefined;
    var mode_val: mruby.mrb_value = undefined;
    var owner_val: mruby.mrb_value = undefined;
    var group_val: mruby.mrb_value = undefined;
    var only_if_val: mruby.mrb_value = undefined;
    var not_if_val: mruby.mrb_value = undefined;
    var ignore_failure_val: mruby.mrb_value = undefined;
    var notifications_val: mruby.mrb_value = undefined;
    var subscriptions_val: mruby.mrb_value = undefined;

    // Get 6 strings + 2 optional blocks + 1 optional boolean + 2 optional arrays
    _ = mruby.mrb_get_args(mrb, "SSSSSS|oooAA", &path_val, &content_val, &action_val, &mode_val, &owner_val, &group_val, &only_if_val, &not_if_val, &ignore_failure_val, &notifications_val, &subscriptions_val);

    const path_cstr = mruby.mrb_str_to_cstr(mrb, path_val);
    const content_cstr = mruby.mrb_str_to_cstr(mrb, content_val);
    const action_cstr = mruby.mrb_str_to_cstr(mrb, action_val);
    const mode_cstr = mruby.mrb_str_to_cstr(mrb, mode_val);
    const owner_cstr = mruby.mrb_str_to_cstr(mrb, owner_val);
    const group_cstr = mruby.mrb_str_to_cstr(mrb, group_val);

    const path = allocator.dupe(u8, std.mem.span(path_cstr)) catch return mruby.mrb_nil_value();
    const content = allocator.dupe(u8, std.mem.span(content_cstr)) catch return mruby.mrb_nil_value();

    const action_str = std.mem.span(action_cstr);
    const action: Resource.Action = if (std.mem.eql(u8, action_str, "delete"))
        .delete
    else if (std.mem.eql(u8, action_str, "touch"))
        .touch
    else
        .create;

    const mode_str = std.mem.span(mode_cstr);
    const mode: ?u32 = if (mode_str.len > 0)
        std.fmt.parseInt(u32, mode_str, 8) catch null
    else
        null;

    const owner_str = std.mem.span(owner_cstr);
    const owner: ?[]const u8 = if (owner_str.len > 0)
        allocator.dupe(u8, owner_str) catch return mruby.mrb_nil_value()
    else
        null;

    const group_str = std.mem.span(group_cstr);
    const group: ?[]const u8 = if (group_str.len > 0)
        allocator.dupe(u8, group_str) catch return mruby.mrb_nil_value()
    else
        null;

    // Build common properties (guards + notifications)
    var common = base.CommonProps.init(allocator);
    base.fillCommonFromRuby(&common, mrb, only_if_val, not_if_val, ignore_failure_val, notifications_val, subscriptions_val, allocator);

    resources.append(allocator, .{
        .path = path,
        .content = content,
        .attrs = .{
            .mode = mode,
            .owner = owner,
            .group = group,
        },
        .action = action,
        .common = common,
    }) catch return mruby.mrb_nil_value();

    return mruby.mrb_nil_value();
}
