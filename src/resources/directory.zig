const std = @import("std");
const mruby = @import("../mruby.zig");
const base = @import("../base_resource.zig");

/// Directory resource data structure
pub const Resource = struct {
    // Resource-specific properties
    path: []const u8,
    mode: ?u32,
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
            // Check if mode needs to be updated
            if (self.mode) |m| {
                var dir = if (is_abs)
                    try std.fs.openDirAbsolute(self.path, .{})
                else
                    try std.fs.cwd().openDir(self.path, .{});
                defer dir.close();

                const stat = try dir.stat();
                const current_mode = stat.mode & 0o777;
                if (current_mode == m) {
                    return false; // Directory exists with same mode
                } else {
                    // Update mode
                    std.posix.fchmod(dir.fd, @as(std.posix.mode_t, @intCast(m))) catch {
                        // Ignore permission errors on some systems
                    };
                    return true; // Mode was updated
                }
            }
            return false; // Directory exists
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
        if (self.mode) |m| {
            var dir = if (is_abs)
                try std.fs.openDirAbsolute(self.path, .{})
            else
                try std.fs.cwd().openDir(self.path, .{});
            defer dir.close();

            std.posix.fchmod(dir.fd, @as(std.posix.mode_t, @intCast(m))) catch {
                // Ignore permission errors on some systems
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
    // Parse arguments: path, mode, recursive, action, only_if_block, not_if_block, notifications
    var path_val: mruby.mrb_value = undefined;
    var mode_val: mruby.mrb_value = undefined;
    var recursive_val: mruby.mrb_value = undefined;
    var action_val: mruby.mrb_value = undefined;
    var only_if_val: mruby.mrb_value = undefined;
    var not_if_val: mruby.mrb_value = undefined;
    var notifications_val: mruby.mrb_value = undefined;

    // Format: S|obo|oooA
    // S: required string (path)
    // |: optional arguments start
    // o: optional object (mode - can be string or nil)
    // b: optional boolean (recursive)
    // o: optional object (action - can be string or nil)
    // |: optional arguments start
    // o: optional object (only_if)
    // o: optional object (not_if)
    // A: optional array (notifications)
    _ = mruby.mrb_get_args(mrb, "S|obo|ooA", &path_val, &mode_val, &recursive_val, &action_val, &only_if_val, &not_if_val, &notifications_val);

    // Extract path
    const path_cstr = mruby.mrb_str_to_cstr(mrb, path_val);
    const path = allocator.dupe(u8, std.mem.span(path_cstr)) catch return mruby.mrb_nil_value();

    // Parse mode (optional)
    // mode_val can be nil, empty string, or a mode string like "0755"
    var mode: ?u32 = null;
    if (mruby.mrb_test(mode_val)) {
        // Check if it's actually a string (not nil)
        // In mruby, nil has type 0, string has type 5
        // We can't use mrb_type directly (linker issue), so we rely on mrb_test
        // If mrb_test returns true, it's not nil/false, so safe to convert
        const mode_cstr = mruby.mrb_str_to_cstr(mrb, mode_val);
        const mode_str = std.mem.span(mode_cstr);
        if (mode_str.len > 0) {
            const parsed_mode = std.fmt.parseInt(u32, mode_str, 8) catch null;
            if (parsed_mode) |m| {
                mode = m;
            }
        }
    }

    // Parse recursive (optional, default false)
    const recursive = if (mruby.mrb_test(recursive_val)) mruby.mrb_test(recursive_val) else false;

    // Parse action (optional, default create)
    const action: Resource.Action = if (mruby.mrb_test(action_val)) blk: {
        // action_val can be nil or a string
        const action_cstr = mruby.mrb_str_to_cstr(mrb, action_val);
        const action_str = std.mem.span(action_cstr);
        if (std.mem.eql(u8, action_str, "delete")) {
            break :blk .delete;
        }
        break :blk .create;
    } else .create;

    // Build common properties (guards + notifications)
    var common = base.CommonProps.init(allocator);
    base.fillCommonFromRuby(&common, mrb, only_if_val, not_if_val, notifications_val, allocator);

    resources.append(allocator, .{
        .path = path,
        .mode = mode,
        .recursive = recursive,
        .action = action,
        .common = common,
    }) catch return mruby.mrb_nil_value();

    return mruby.mrb_nil_value();
}
