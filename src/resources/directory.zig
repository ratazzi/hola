const std = @import("std");
const mruby = @import("../mruby.zig");
const base = @import("../base_resource.zig");

/// Directory resource data structure
pub const Resource = struct {
    // Resource-specific properties
    path: []const u8,
    attrs: base.FileAttributes,
    recursive: bool,
    action: Action,

    // Common properties (guards, notifications, etc.)
    common: base.CommonProps,

    pub const Action = enum {
        create,
        delete,
    };

    pub fn deinit(self: Resource, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
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
        const is_abs = std.fs.path.isAbsolute(self.path);

        // Check if directory already exists
        const dir_exists = blk: {
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

        if (dir_exists) {
            // Check if attributes need to be updated
            var needs_update = false;

            // Check and update mode
            if (self.attrs.mode) |m| {
                var dir = if (is_abs)
                    try std.fs.openDirAbsolute(self.path, .{})
                else
                    try std.fs.cwd().openDir(self.path, .{});
                defer dir.close();

                const stat = try dir.stat();
                const current_mode = stat.mode & 0o777;
                if (current_mode != m) {
                    // Update mode using path-based chmod instead of fd-based fchmod
                    // This avoids BADF errors on some systems where dir.fd might not be valid
                    base.setFileMode(self.path, m);
                    needs_update = true;
                }
            }

            // Apply owner/group if specified (without mode, as we handled it above)
            if (self.attrs.owner != null or self.attrs.group != null) {
                base.setFileOwnerAndGroup(self.path, self.attrs.owner, self.attrs.group) catch |err| {
                    std.log.warn("Failed to set owner/group for {s}: {}", .{ self.path, err });
                };
                needs_update = true;
            }

            return needs_update;
        }

        // Create directory
        if (self.recursive) {
            try base.ensurePath(self.path);
        } else {
            try base.ensureParentDir(self.path);
            if (is_abs) {
                try std.fs.makeDirAbsolute(self.path);
            } else {
                try std.fs.cwd().makeDir(self.path);
            }
        }

        // Set mode if specified
        if (self.attrs.mode) |m| {
            // Use path-based chmod instead of fd-based fchmod
            // This avoids BADF errors on some systems
            base.setFileMode(self.path, m);
        }

        // Apply owner/group if specified
        if (self.attrs.owner != null or self.attrs.group != null) {
            base.applyFileAttributes(self.path, self.attrs) catch |err| {
                std.log.warn("Failed to set owner/group for {s}: {}", .{ self.path, err });
            };
        }

        return true; // Directory was created
    }

    fn applyDelete(self: Resource) !void {
        const is_abs = std.fs.path.isAbsolute(self.path);

        // Check if directory exists
        const dir_exists = blk: {
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

        if (!dir_exists) {
            return; // Already deleted
        }

        var resolved: ?[]u8 = null;
        defer if (resolved) |buf| std.heap.c_allocator.free(buf);

        const abs_path = if (is_abs) self.path else blk: {
            const buf = try std.fs.cwd().realpathAlloc(std.heap.c_allocator, self.path);
            resolved = buf;
            break :blk buf;
        };

        if (self.recursive) {
            try deleteDirRecursiveAbsolute(abs_path);
        } else {
            std.fs.deleteDirAbsolute(abs_path) catch |err| switch (err) {
                error.DirNotEmpty => return error.DirNotEmpty,
                else => return err,
            };
        }
    }

    fn deleteDirRecursiveAbsolute(path: []const u8) !void {
        var dir = try std.fs.openDirAbsolute(path, .{ .iterate = true });
        defer dir.close();
        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            const child_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ path, entry.name });
            defer std.heap.page_allocator.free(child_path);
            switch (entry.kind) {
                .directory => try deleteDirRecursiveAbsolute(child_path),
                else => try std.fs.deleteFileAbsolute(child_path),
            }
        }
        try std.fs.deleteDirAbsolute(path);
    }
};

/// Ruby prelude for directory resource
pub const ruby_prelude = @embedFile("directory_resource.rb");

/// Zig callback for adding directory resource from Ruby
pub fn zigAddResource(
    mrb: *mruby.mrb_state,
    _: mruby.mrb_value,
    resources: *std.ArrayList(Resource),
    allocator: std.mem.Allocator,
) mruby.mrb_value {
    // Parse arguments: path, mode, owner, group, recursive, action, only_if_block, not_if_block, ignore_failure, notifications
    var path_val: mruby.mrb_value = undefined;
    var mode_val: mruby.mrb_value = undefined;
    var owner_val: mruby.mrb_value = undefined;
    var group_val: mruby.mrb_value = undefined;
    var recursive_val: mruby.mrb_value = undefined;
    var action_val: mruby.mrb_value = undefined;
    var only_if_val: mruby.mrb_value = undefined;
    var not_if_val: mruby.mrb_value = undefined;
    var ignore_failure_val: mruby.mrb_value = undefined;
    var notifications_val: mruby.mrb_value = undefined;

    // Format: SSSSbS|oooA (path, mode, owner, group, recursive, action, optional blocks, optional boolean, optional array)
    _ = mruby.mrb_get_args(mrb, "SSSSbS|oooA", &path_val, &mode_val, &owner_val, &group_val, &recursive_val, &action_val, &only_if_val, &not_if_val, &ignore_failure_val, &notifications_val);

    // Extract path
    const path_cstr = mruby.mrb_str_to_cstr(mrb, path_val);
    const path = allocator.dupe(u8, std.mem.span(path_cstr)) catch return mruby.mrb_nil_value();

    // Parse mode (optional)
    const mode_cstr = mruby.mrb_str_to_cstr(mrb, mode_val);
    const mode_str = std.mem.span(mode_cstr);
    const mode: ?u32 = if (mode_str.len > 0)
        std.fmt.parseInt(u32, mode_str, 8) catch null
    else
        null;

    // Parse owner and group
    const owner_cstr = mruby.mrb_str_to_cstr(mrb, owner_val);
    const owner_str = std.mem.span(owner_cstr);
    const owner: ?[]const u8 = if (owner_str.len > 0)
        allocator.dupe(u8, owner_str) catch return mruby.mrb_nil_value()
    else
        null;

    const group_cstr = mruby.mrb_str_to_cstr(mrb, group_val);
    const group_str = std.mem.span(group_cstr);
    const group: ?[]const u8 = if (group_str.len > 0)
        allocator.dupe(u8, group_str) catch return mruby.mrb_nil_value()
    else
        null;

    // Parse recursive (boolean)
    const recursive = mruby.mrb_test(recursive_val);

    // Parse action (string)
    const action_cstr = mruby.mrb_str_to_cstr(mrb, action_val);
    const action_str = std.mem.span(action_cstr);
    const action: Resource.Action = if (std.mem.eql(u8, action_str, "delete"))
        .delete
    else
        .create;

    // Build common properties (guards + notifications)
    var common = base.CommonProps.init(allocator);
    base.fillCommonFromRuby(&common, mrb, only_if_val, not_if_val, ignore_failure_val, notifications_val, allocator);

    resources.append(allocator, .{
        .path = path,
        .attrs = .{
            .mode = mode,
            .owner = owner,
            .group = group,
        },
        .recursive = recursive,
        .action = action,
        .common = common,
    }) catch return mruby.mrb_nil_value();

    return mruby.mrb_nil_value();
}
