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
        const skip_reason = try self.common.shouldRun();
        if (skip_reason) |reason| {
            const action_name = switch (self.action) {
                .create => "create",
                .delete => "delete",
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
        };

        switch (self.action) {
            .create => {
                const was_created = try applyCreate(self);
                return base.ApplyResult{
                    .was_updated = was_created,
                    .action = action_name,
                    .skip_reason = if (was_created) null else "up to date",
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
        }
    }

    fn applyCreate(self: Resource) !bool {
        try base.ensureParentDir(self.path);
        const is_abs = std.fs.path.isAbsolute(self.path);

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

        if (file_exists) {
            // Read existing file and compare content
            const existing_file = if (is_abs)
                try std.fs.openFileAbsolute(self.path, .{})
            else
                try std.fs.cwd().openFile(self.path, .{});
            defer existing_file.close();

            existing_content = try existing_file.readToEndAlloc(std.heap.c_allocator, std.math.maxInt(usize));

            if (std.mem.eql(u8, existing_content.?, self.content)) {
                // Content matches, check attributes if specified
                if (self.attrs.mode) |m| {
                    const stat = try existing_file.stat();
                    const current_mode = stat.mode & 0o777;
                    if (current_mode == m) {
                        return false; // File exists with same content and mode
                    }
                } else {
                    return false; // File exists with same content
                }
            }
        }

        // File doesn't exist or content differs, create/update it
        // Generate diff if file existed and log it
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
                defer std.heap.c_allocator.free(d);
                if (d.len > 0) {
                    logger.info("File diff for {s}:\n{s}", .{ self.path, d });
                }
            }
        }

        var file = if (is_abs)
            try std.fs.createFileAbsolute(self.path, .{ .truncate = true })
        else
            try std.fs.cwd().createFile(self.path, .{ .truncate = true });

        try file.writeAll(self.content);

        // Apply file mode if specified
        if (self.attrs.mode) |m| {
            std.posix.fchmod(file.handle, @as(std.posix.mode_t, @intCast(m))) catch {};
        }

        // Close file before changing ownership (needed for some systems)
        file.close();

        // Apply owner/group after file is closed
        if (self.attrs.owner != null or self.attrs.group != null) {
            base.applyFileAttributes(self.path, self.attrs) catch |err| {
                logger.warn("Failed to set owner/group for {s}: {}", .{ self.path, err });
            };
        }

        return true; // File was created or updated
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

    // Get 6 strings + 2 optional blocks + 1 optional boolean + 1 optional array
    _ = mruby.mrb_get_args(mrb, "SSSSSS|oooA", &path_val, &content_val, &action_val, &mode_val, &owner_val, &group_val, &only_if_val, &not_if_val, &ignore_failure_val, &notifications_val);

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
    base.fillCommonFromRuby(&common, mrb, only_if_val, not_if_val, ignore_failure_val, notifications_val, allocator);

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
