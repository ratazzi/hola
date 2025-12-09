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
    // Conditional execution (guards) - can be either Ruby block or shell command string
    only_if_block: ?mruby.mrb_value = null,
    only_if_command: ?[]const u8 = null, // Shell command string
    not_if_block: ?mruby.mrb_value = null,
    not_if_command: ?[]const u8 = null, // Shell command string

    // Error handling
    ignore_failure: bool = false,

    // Notifications
    notifications: std.ArrayList(notification.Notification),

    // Subscriptions (will be converted to notifications during processing)
    subscriptions: std.ArrayList(notification.Notification),

    // mruby state for calling blocks
    mrb_state: ?*mruby.mrb_state = null,

    pub fn init(allocator: std.mem.Allocator) CommonProps {
        return .{
            .notifications = std.ArrayList(notification.Notification).initCapacity(allocator, 0) catch std.ArrayList(notification.Notification).empty,
            .subscriptions = std.ArrayList(notification.Notification).initCapacity(allocator, 0) catch std.ArrayList(notification.Notification).empty,
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

        // Free string commands
        if (self.only_if_command) |cmd| allocator.free(cmd);
        if (self.not_if_command) |cmd| allocator.free(cmd);

        // Free notifications
        for (self.notifications.items) |notif| {
            notif.deinit(allocator);
        }
        self.notifications.deinit(allocator);

        // Free subscriptions
        for (self.subscriptions.items) |sub| {
            sub.deinit(allocator);
        }
        self.subscriptions.deinit(allocator);
    }

    /// Evaluate guards (only_if/not_if) to determine if resource should run
    /// Returns the reason if skipped, null if should run
    /// Optionally runs guard commands as specified user/group
    pub fn shouldRun(self: CommonProps, user: ?[]const u8, group: ?[]const u8) !?[]const u8 {
        const mrb = self.mrb_state orelse return null;

        // Evaluate only_if (must be true to run)
        // Check command string first (higher priority)
        if (self.only_if_command) |cmd| {
            // Execute shell command - exit code 0 means true
            const success = try executeShellCommand(cmd, user, group);
            if (!success) {
                return "skipped due to only_if"; // command failed (non-zero exit)
            }
        } else if (self.only_if_block) |block| {
            // Use funcall instead of yield to properly handle exceptions
            const call_sym = mruby.mrb_intern_cstr(mrb, "call");
            const result = mruby.mrb_funcall_argv(mrb, block, call_sym, 0, null);

            // Check for exceptions during call
            const exc = mruby.mrb_get_exception(mrb);
            if (mruby.mrb_test(exc)) {
                mruby.mrb_print_error(mrb);
                return error.MRubyException;
            }

            if (!mruby.mrb_test(result)) {
                return "skipped due to only_if"; // only_if returned falsy
            }
        }

        // Evaluate not_if (must be false to run)
        // Check command string first (higher priority)
        if (self.not_if_command) |cmd| {
            // Execute shell command - exit code 0 means true
            const success = try executeShellCommand(cmd, user, group);
            if (success) {
                return "skipped due to not_if"; // command succeeded (exit 0)
            }
        } else if (self.not_if_block) |block| {
            // Use funcall instead of yield to properly handle exceptions
            const call_sym = mruby.mrb_intern_cstr(mrb, "call");
            const result = mruby.mrb_funcall_argv(mrb, block, call_sym, 0, null);

            // Check for exceptions during call
            const exc = mruby.mrb_get_exception(mrb);
            if (mruby.mrb_test(exc)) {
                mruby.mrb_print_error(mrb);
                return error.MRubyException;
            }

            if (mruby.mrb_test(result)) {
                return "skipped due to not_if"; // not_if returned truthy
            }
        }

        return null; // Should run
    }

    /// Execute a shell command and return true if exit code is 0
    /// Optionally runs as specified user/group
    fn executeShellCommand(command: []const u8, user: ?[]const u8, group: ?[]const u8) !bool {
        // Use ArenaAllocator for temporary allocations (matches pattern in execute.zig)
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const temp_allocator = arena.allocator();

        var child = std.process.Child.init(&[_][]const u8{ "/bin/sh", "-c", command }, temp_allocator);
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        // Set user and/or group if specified (same logic as execute resource)
        if (user != null or group != null) {
            const c = @cImport({
                @cInclude("pwd.h");
                @cInclude("grp.h");
            });

            // Get user info if user is specified
            if (user) |username| {
                const username_z = std.posix.toPosixPath(username) catch |err| {
                    const logger = @import("logger.zig");
                    logger.warn("guard: failed to convert username '{s}': {}", .{ username, err });
                    return error.UserInfoFailed;
                };

                const pwd = c.getpwnam(&username_z);
                if (pwd == null) {
                    const logger = @import("logger.zig");
                    logger.warn("guard: user '{s}' not found", .{username});
                    return error.UserNotFound;
                }

                child.uid = @intCast(pwd.*.pw_uid);
                child.gid = @intCast(pwd.*.pw_gid);
            }

            // Override with group if specified
            if (group) |groupname| {
                const groupname_z = std.posix.toPosixPath(groupname) catch |err| {
                    const logger = @import("logger.zig");
                    logger.warn("guard: failed to convert groupname '{s}': {}", .{ groupname, err });
                    return error.GroupInfoFailed;
                };

                const grp = c.getgrnam(&groupname_z);
                if (grp == null) {
                    const logger = @import("logger.zig");
                    logger.warn("guard: group '{s}' not found", .{groupname});
                    return error.GroupNotFound;
                }

                child.gid = @intCast(grp.*.gr_gid);
            }
        }

        const term = try child.spawnAndWait();

        return switch (term) {
            .Exited => |code| code == 0,
            else => false,
        };
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

/// Populate CommonProps from Ruby args (only_if/not_if/ignore_failure/notifications/subscriptions) and protect blocks
pub fn fillCommonFromRuby(
    common: *CommonProps,
    mrb: *mruby.mrb_state,
    only_if_val: mruby.mrb_value,
    not_if_val: mruby.mrb_value,
    ignore_failure_val: mruby.mrb_value,
    notifications_val: mruby.mrb_value,
    subscriptions_val: mruby.mrb_value,
    allocator: std.mem.Allocator,
) void {
    const logger = @import("logger.zig");
    logger.debug("fillCommonFromRuby called", .{});
    logger.debug("only_if_val test: {}", .{mruby.mrb_test(only_if_val)});

    // Attach mruby state
    common.mrb_state = mrb;
    common.ignore_failure = mruby.mrb_test(ignore_failure_val);

    // Parse only_if - can be string (shell command) or proc (Ruby block)
    if (mruby.mrb_test(only_if_val)) {
        const is_string = mruby.zig_mrb_string_p(only_if_val) != 0;

        if (is_string) {
            // String guard - execute as shell command
            const cmd_cstr = mruby.mrb_str_to_cstr(mrb, only_if_val);
            const cmd_str = std.mem.span(cmd_cstr);
            logger.debug("only_if command: {s}", .{cmd_str});
            common.only_if_command = allocator.dupe(u8, cmd_str) catch |err| blk: {
                logger.warn("Failed to allocate memory for only_if command: {}", .{err});
                logger.warn("Guard 'only_if' will be ignored - this may cause unexpected resource execution!", .{});
                break :blk null;
            };
        } else {
            // Proc or other callable - store for later evaluation
            logger.debug("only_if is block/proc", .{});
            common.only_if_block = only_if_val;
        }
    }

    // Parse not_if - can be string (shell command) or proc (Ruby block)
    if (mruby.mrb_test(not_if_val)) {
        const is_string = mruby.zig_mrb_string_p(not_if_val) != 0;

        if (is_string) {
            // String guard - execute as shell command
            const cmd_cstr = mruby.mrb_str_to_cstr(mrb, not_if_val);
            const cmd_str = std.mem.span(cmd_cstr);
            common.not_if_command = allocator.dupe(u8, cmd_str) catch |err| blk: {
                logger.warn("Failed to allocate memory for not_if command: {}", .{err});
                logger.warn("Guard 'not_if' will be ignored - this may cause unexpected resource execution!", .{});
                break :blk null;
            };
        } else {
            // Proc or other callable - store for later evaluation
            common.not_if_block = not_if_val;
        }
    }

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

            const target = allocator.dupe(u8, std.mem.span(target_cstr)) catch |err| {
                logger.warn("Failed to allocate notification target: {}", .{err});
                continue;
            };
            const action_name = allocator.dupe(u8, std.mem.span(action_cstr_n)) catch |err| {
                allocator.free(target);
                logger.warn("Failed to allocate notification action: {}", .{err});
                continue;
            };
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

            common.notifications.append(allocator, notif) catch |err| {
                logger.warn("Failed to append notification: {}", .{err});
                allocator.free(target);
                allocator.free(action_name);
                continue;
            };
        }
    }

    // Parse subscriptions array if provided: each item is [target, action, timing]
    if (mruby.mrb_test(subscriptions_val)) {
        const arr_len = mruby.mrb_ary_len(mrb, subscriptions_val);
        var i: mruby.mrb_int = 0;
        while (i < arr_len) : (i += 1) {
            const sub_arr = mruby.mrb_ary_ref(mrb, subscriptions_val, i);

            const target_val = mruby.mrb_ary_ref(mrb, sub_arr, 0);
            const action_val_s = mruby.mrb_ary_ref(mrb, sub_arr, 1);
            const timing_val = mruby.mrb_ary_ref(mrb, sub_arr, 2);

            const target_cstr = mruby.mrb_str_to_cstr(mrb, target_val);
            const action_cstr_s = mruby.mrb_str_to_cstr(mrb, action_val_s);
            const timing_cstr = mruby.mrb_str_to_cstr(mrb, timing_val);

            const target = allocator.dupe(u8, std.mem.span(target_cstr)) catch |err| {
                logger.warn("Failed to allocate subscription target: {}", .{err});
                continue;
            };
            const action_name = allocator.dupe(u8, std.mem.span(action_cstr_s)) catch |err| {
                allocator.free(target);
                logger.warn("Failed to allocate subscription action: {}", .{err});
                continue;
            };
            const timing_str = std.mem.span(timing_cstr);

            const timing: notification.Timing = if (std.mem.eql(u8, timing_str, "immediate"))
                .immediate
            else
                .delayed;

            const sub = notification.Notification{
                .target_resource_id = target,
                .action = .{ .action_name = action_name },
                .timing = timing,
            };

            common.subscriptions.append(allocator, sub) catch |err| {
                logger.warn("Failed to append subscription: {}", .{err});
                allocator.free(target);
                allocator.free(action_name);
                continue;
            };
        }
    }

    // Prevent GC from collecting guard blocks
    common.protectBlocks();
}

/// File system attributes that can be managed
pub const FileAttributes = struct {
    mode: ?u32 = null,
    owner: ?[]const u8 = null,
    group: ?[]const u8 = null,

    pub fn deinit(self: FileAttributes, allocator: std.mem.Allocator) void {
        if (self.owner) |o| allocator.free(o);
        if (self.group) |g| allocator.free(g);
    }
};

/// Set file mode (permissions) for a given file path using POSIX fchmodat
/// Uses AT_FDCWD to work with the current working directory
/// Silently ignores errors to maintain backward compatibility
pub fn setFileMode(file_path: []const u8, mode: u32) void {
    std.posix.fchmodat(std.posix.AT.FDCWD, file_path, @as(std.posix.mode_t, @intCast(mode)), 0) catch {};
}

/// Set file owner (user) for a given file path
/// On non-macOS systems, uses chown system call
/// On macOS, uses chown system call (requires root or matching uid)
pub fn setFileOwner(file_path: []const u8, owner: []const u8) !void {
    const c = @cImport({
        @cInclude("sys/stat.h");
        @cInclude("unistd.h");
    });

    // Get UID from username
    const uid = try getUserId(owner);

    // Get current GID (we're not changing group) using stat
    const path_z = try std.posix.toPosixPath(file_path);
    var stat_buf: c.struct_stat = undefined;
    if (c.stat(&path_z, &stat_buf) != 0) {
        return error.StatFailed;
    }
    const gid = stat_buf.st_gid;

    // Change ownership
    if (c.chown(&path_z, uid, gid) != 0) {
        return error.ChownFailed;
    }
}

/// Set file group for a given file path
pub fn setFileGroup(file_path: []const u8, group: []const u8) !void {
    const c = @cImport({
        @cInclude("sys/stat.h");
        @cInclude("unistd.h");
    });

    // Get GID from group name
    const gid = try getGroupId(group);

    // Get current UID (we're not changing owner) using stat
    const path_z = try std.posix.toPosixPath(file_path);
    var stat_buf: c.struct_stat = undefined;
    if (c.stat(&path_z, &stat_buf) != 0) {
        return error.StatFailed;
    }
    const uid = stat_buf.st_uid;

    // Change ownership
    if (c.chown(&path_z, uid, gid) != 0) {
        return error.ChownFailed;
    }
}

/// Set file owner and group together
pub fn setFileOwnerAndGroup(file_path: []const u8, owner: ?[]const u8, group: ?[]const u8) !void {
    const c = @cImport({
        @cInclude("sys/stat.h");
        @cInclude("unistd.h");
    });

    const path_z = try std.posix.toPosixPath(file_path);
    var stat_buf: c.struct_stat = undefined;
    if (c.stat(&path_z, &stat_buf) != 0) {
        return error.StatFailed;
    }

    const uid = if (owner) |o| try getUserId(o) else stat_buf.st_uid;
    const gid = if (group) |g| try getGroupId(g) else stat_buf.st_gid;

    if (c.chown(&path_z, uid, gid) != 0) {
        return error.ChownFailed;
    }
}

/// Apply file attributes (mode, owner, group) to a file
pub fn applyFileAttributes(file_path: []const u8, attrs: FileAttributes) !void {
    // Set mode if specified
    if (attrs.mode) |m| {
        setFileMode(file_path, m);
    }

    // Set owner and/or group if specified
    if (attrs.owner != null or attrs.group != null) {
        try setFileOwnerAndGroup(file_path, attrs.owner, attrs.group);
    }
}

/// Get UID from username using getpwnam
pub fn getUserId(username: []const u8) !std.posix.uid_t {
    const c = @cImport({
        @cInclude("pwd.h");
        @cInclude("string.h");
    });

    const username_z = try std.posix.toPosixPath(username);
    const pwd = c.getpwnam(&username_z);
    if (pwd == null) {
        return error.UserNotFound;
    }

    return @intCast(pwd.*.pw_uid);
}

/// Get GID from group name using getgrnam
pub fn getGroupId(groupname: []const u8) !std.posix.gid_t {
    const c = @cImport({
        @cInclude("grp.h");
        @cInclude("string.h");
    });

    const groupname_z = try std.posix.toPosixPath(groupname);
    const grp = c.getgrnam(&groupname_z);
    if (grp == null) {
        return error.GroupNotFound;
    }

    return @intCast(grp.*.gr_gid);
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
