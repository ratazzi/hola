const std = @import("std");
const mruby = @import("mruby.zig");
pub const notification = @import("notification.zig");
const builtin = @import("builtin");

/// Result of applying a resource
pub const ApplyResult = struct {
    was_updated: bool,
    action: []const u8,
    skip_reason: ?[]const u8 = null, // null means "up to date", non-null means skipped with reason
};

/// Common properties shared by all resources
pub const CommonProps = struct {
    // Conditional execution (guards)
    only_if_block: ?mruby.mrb_value = null,
    not_if_block: ?mruby.mrb_value = null,

    // Notifications
    notifications: std.ArrayList(notification.Notification),

    // mruby state for calling blocks
    mrb_state: ?*mruby.mrb_state = null,

    pub fn init(allocator: std.mem.Allocator) CommonProps {
        return .{
            .notifications = std.ArrayList(notification.Notification).initCapacity(allocator, 0) catch std.ArrayList(notification.Notification).empty,
        };
    }

    pub fn deinit(self: *CommonProps, allocator: std.mem.Allocator) void {
        // Unregister blocks from GC
        if (self.mrb_state) |mrb| {
            if (self.only_if_block) |block| {
                mruby.mrb_gc_unregister(mrb, block);
            }
            if (self.not_if_block) |block| {
                mruby.mrb_gc_unregister(mrb, block);
            }
        }

        // Free notifications
        for (self.notifications.items) |notif| {
            notif.deinit(allocator);
        }
        self.notifications.deinit(allocator);
    }

    /// Evaluate guards (only_if/not_if) to determine if resource should run
    /// Returns the reason if skipped, null if should run
    pub fn shouldRun(self: CommonProps) !?[]const u8 {
        const mrb = self.mrb_state orelse return null;

        // Evaluate only_if (must be true to run)
        if (self.only_if_block) |block| {
            const result = mruby.mrb_yield(mrb, block, mruby.mrb_nil_value());
            if (!mruby.mrb_test(result)) {
                return "skipped due to only_if"; // only_if returned falsy
            }
        }

        // Evaluate not_if (must be false to run)
        if (self.not_if_block) |block| {
            const result = mruby.mrb_yield(mrb, block, mruby.mrb_nil_value());
            if (mruby.mrb_test(result)) {
                return "skipped due to not_if"; // not_if returned truthy
            }
        }

        return null; // Should run
    }

    /// Register blocks with GC to prevent collection
    pub fn protectBlocks(self: *CommonProps) void {
        const mrb = self.mrb_state orelse return;

        if (self.only_if_block) |block| {
            mruby.mrb_gc_register(mrb, block);
        }
        if (self.not_if_block) |block| {
            mruby.mrb_gc_register(mrb, block);
        }
    }
};

/// Helper for parsing common arguments from Ruby
pub const CommonArgs = struct {
    only_if_block: ?mruby.mrb_value = null,
    not_if_block: ?mruby.mrb_value = null,
    notifications_array: ?mruby.mrb_value = null,

    /// Parse common optional arguments from mruby
    /// Expected format after resource-specific args: |ooA
    /// - only_if: optional block
    /// - not_if: optional block
    /// - notifications: optional array
    pub fn parse(_: *mruby.mrb_state, _: i32) !CommonArgs {
        // Placeholder (kept for future use). Most callers now use fillCommonFromRuby.
        return CommonArgs{};
    }
};

/// Populate CommonProps from Ruby args (only_if/not_if/notifications) and protect blocks
pub fn fillCommonFromRuby(
    common: *CommonProps,
    mrb: *mruby.mrb_state,
    only_if_val: mruby.mrb_value,
    not_if_val: mruby.mrb_value,
    notifications_val: mruby.mrb_value,
    allocator: std.mem.Allocator,
) void {
    // Attach mruby state and optional guard blocks
    common.mrb_state = mrb;
    common.only_if_block = if (mruby.mrb_test(only_if_val)) only_if_val else null;
    common.not_if_block = if (mruby.mrb_test(not_if_val)) not_if_val else null;

    // Parse notifications array if provided: each item is [target, action, timing]
    if (mruby.mrb_test(notifications_val)) {
        const arr_len = mruby.mrb_ary_len(mrb, notifications_val);
        var i: mruby.mrb_int = 0;
        while (i < arr_len) : (i += 1) {
            const notif_arr = mruby.mrb_ary_ref(mrb, notifications_val, i);

            const target_val = mruby.mrb_ary_ref(mrb, notif_arr, 0);
            const action_val_n = mruby.mrb_ary_ref(mrb, notif_arr, 1);
            const timing_val = mruby.mrb_ary_ref(mrb, notif_arr, 2);

            const target_cstr = mruby.mrb_str_to_cstr(mrb, target_val);
            const action_cstr_n = mruby.mrb_str_to_cstr(mrb, action_val_n);
            const timing_cstr = mruby.mrb_str_to_cstr(mrb, timing_val);

            const target = allocator.dupe(u8, std.mem.span(target_cstr)) catch continue;
            const action_name = allocator.dupe(u8, std.mem.span(action_cstr_n)) catch continue;
            const timing_str = std.mem.span(timing_cstr);

            const timing: notification.Timing = if (std.mem.eql(u8, timing_str, "immediate"))
                .immediate
            else
                .delayed;

            const notif = notification.Notification{
                .target_resource_id = target,
                .action = .{ .action_name = action_name },
                .timing = timing,
            };

            common.notifications.append(allocator, notif) catch continue;
        }
    }

    // Prevent GC from collecting guard blocks
    common.protectBlocks();
}

/// Set file mode (permissions) for a given file path using POSIX fchmodat
/// Uses AT_FDCWD to work with the current working directory
/// Silently ignores errors to maintain backward compatibility
pub fn setFileMode(file_path: []const u8, mode: u32) void {
    std.posix.fchmodat(std.posix.AT.FDCWD, file_path, @as(std.posix.mode_t, @intCast(mode)), 0) catch {};
}

/// Create a backup copy of a file by appending backup_ext to the filename
/// Returns void and closes the backup file properly to prevent fd leaks
/// If the original file doesn't exist, returns error.FileNotFound
pub fn createBackup(allocator: std.mem.Allocator, file_path: []const u8, backup_ext: []const u8) !void {
    const backup_path = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ file_path, backup_ext });
    defer allocator.free(backup_path);

    // Open original file for reading
    const original = std.fs.cwd().openFile(file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound, // No file to backup
        else => return err,
    };
    defer original.close();

    // Create backup file (with parent directories if needed)
    const backup = blk: {
        if (std.fs.cwd().createFile(backup_path, .{ .truncate = true })) |file| {
            break :blk file;
        } else |err| {
            if (err == error.FileNotFound) {
                if (std.fs.path.dirname(backup_path)) |dir| {
                    try std.fs.cwd().makePath(dir);
                }
                break :blk try std.fs.cwd().createFile(backup_path, .{ .truncate = true });
            }
            return err;
        }
    };
    defer backup.close(); // Properly close to prevent fd leak

    // Copy file contents in chunks
    var buf: [4096]u8 = undefined;
    while (true) {
        const bytes_read = try original.read(&buf);
        if (bytes_read == 0) break;
        try backup.writeAll(buf[0..bytes_read]);
    }
}

/// Ensure the parent directory for `path` exists, handling absolute and relative paths.
pub fn ensureParentDir(path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        if (parent.len == 0) return;
        try ensurePath(parent);
    }
}

/// Ensure the provided path exists as a directory (creates parents as needed).
pub fn ensurePath(path: []const u8) !void {
    if (std.fs.path.isAbsolute(path)) {
        std.fs.makeDirAbsolute(path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            error.FileNotFound => {
                if (std.fs.path.dirname(path)) |parent| {
                    if (parent.len == 0) return err;
                    try ensurePath(parent);
                    try std.fs.makeDirAbsolute(path);
                } else {
                    return err;
                }
            },
            else => return err,
        };
    } else {
        try std.fs.cwd().makePath(path);
    }
}
