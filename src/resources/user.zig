const std = @import("std");
const mruby = @import("../mruby.zig");
const base = @import("../base_resource.zig");
const logger = @import("../logger.zig");
const builtin = @import("builtin");

/// User resource data structure
pub const Resource = struct {
    // Resource-specific properties
    username: []const u8, // Username (defaults to name if not specified)
    uid: ?u32, // User ID
    gid: ?u32, // Group ID
    comment: ?[]const u8, // GECOS field
    home: ?[]const u8, // Home directory
    shell: ?[]const u8, // Login shell
    password: ?[]const u8, // Encrypted password
    system: bool, // Create as system user
    manage_home: bool, // Create/manage home directory
    non_unique: bool, // Allow non-unique UID
    action: Action,

    // Common properties (guards, notifications, etc.)
    common: base.CommonProps,

    pub const Action = enum {
        create,
        modify,
        remove,
        lock,
        unlock,
    };

    pub fn deinit(self: Resource, allocator: std.mem.Allocator) void {
        allocator.free(self.username);
        if (self.comment) |c| allocator.free(c);
        if (self.home) |h| allocator.free(h);
        if (self.shell) |s| allocator.free(s);
        if (self.password) |p| allocator.free(p);

        // Deinit common props
        var common = self.common;
        common.deinit(allocator);
    }

    pub fn apply(self: Resource) !base.ApplyResult {
        const skip_reason = try self.common.shouldRun();
        if (skip_reason) |reason| {
            const action_name = switch (self.action) {
                .create => "create",
                .modify => "modify",
                .remove => "remove",
                .lock => "lock",
                .unlock => "unlock",
            };
            return base.ApplyResult{
                .was_updated = false,
                .action = action_name,
                .skip_reason = reason,
            };
        }

        const action_name = switch (self.action) {
            .create => "create",
            .modify => "modify",
            .remove => "remove",
            .lock => "lock",
            .unlock => "unlock",
        };

        const was_updated = switch (self.action) {
            .create => try applyCreate(self),
            .modify => try applyModify(self),
            .remove => try applyRemove(self),
            .lock => try applyLock(self),
            .unlock => try applyUnlock(self),
        };

        return base.ApplyResult{
            .was_updated = was_updated,
            .action = action_name,
            .skip_reason = if (was_updated) null else "up to date",
        };
    }

    fn userExists(username: []const u8) !bool {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const args = [_][]const u8{ "id", "-u", username };
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &args,
        }) catch |err| {
            logger.debug("id command failed for user '{s}': {}", .{ username, err });
            return false;
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        switch (result.term) {
            .Exited => |code| return code == 0,
            else => return false,
        }
    }

    fn buildCommand(
        self: Resource,
        comptime cmd: []const u8,
        allocator: std.mem.Allocator,
    ) ![]const u8 {
        _ = builtin; // Suppress unused import warning

        // Simpler approach: build command string directly
        var buf = try std.ArrayList(u8).initCapacity(allocator, 256);
        errdefer buf.deinit(allocator);
        const writer = buf.writer(allocator);

        try writer.writeAll(cmd);

        if (std.mem.eql(u8, cmd, "useradd")) {
            if (self.uid) |uid| {
                try writer.print(" -u {d}", .{uid});
            }
            if (self.gid) |gid| {
                try writer.print(" -g {d}", .{gid});
            }
            if (self.comment) |comment| {
                try writer.print(" -c '{s}'", .{comment});
            }
            if (self.home) |home| {
                try writer.print(" -d '{s}'", .{home});
            }
            if (self.shell) |shell| {
                try writer.print(" -s '{s}'", .{shell});
            }
            if (self.password) |password| {
                try writer.print(" -p '{s}'", .{password});
            }
            if (self.system) {
                try writer.writeAll(" -r");
            }
            if (self.manage_home) {
                try writer.writeAll(" -m");
            } else {
                try writer.writeAll(" -M");
            }
            if (self.non_unique) {
                try writer.writeAll(" -o");
            }
        } else if (std.mem.eql(u8, cmd, "usermod")) {
            if (self.uid) |uid| {
                try writer.print(" -u {d}", .{uid});
            }
            if (self.gid) |gid| {
                try writer.print(" -g {d}", .{gid});
            }
            if (self.comment) |comment| {
                try writer.print(" -c '{s}'", .{comment});
            }
            if (self.home) |home| {
                try writer.print(" -d '{s}'", .{home});
            }
            if (self.shell) |shell| {
                try writer.print(" -s '{s}'", .{shell});
            }
            if (self.password) |password| {
                try writer.print(" -p '{s}'", .{password});
            }
            if (self.non_unique) {
                try writer.writeAll(" -o");
            }
        } else if (std.mem.eql(u8, cmd, "userdel")) {
            if (self.manage_home) {
                try writer.writeAll(" -r");
            }
        }

        try writer.print(" {s}", .{self.username});
        return try buf.toOwnedSlice(allocator);
    }

    fn executeCommand(cmd: []const u8, allocator: std.mem.Allocator) !bool {
        logger.debug("Executing: {s}", .{cmd});

        const args = [_][]const u8{ "/bin/sh", "-c", cmd };
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &args,
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        if (result.stdout.len > 0) {
            logger.debug("stdout: {s}", .{result.stdout});
        }
        if (result.stderr.len > 0) {
            logger.warn("stderr: {s}", .{result.stderr});
        }

        switch (result.term) {
            .Exited => |code| {
                if (code != 0) {
                    logger.err("Command exited with code {d}: {s}", .{ code, cmd });
                    // Print error details
                    if (result.stderr.len > 0) {
                        logger.err("stderr: {s}", .{result.stderr});
                    }
                    return error.CommandFailed;
                }
                return true;
            },
            else => return error.CommandFailed,
        }
    }

    fn applyCreate(self: Resource) !bool {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        // Check if user already exists
        if (try userExists(self.username)) {
            logger.debug("User '{s}' already exists", .{self.username});
            return false;
        }

        const cmd = try self.buildCommand("useradd", allocator);
        return try executeCommand(cmd, allocator);
    }

    fn applyModify(self: Resource) !bool {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        // User must exist to modify
        if (!try userExists(self.username)) {
            logger.err("User '{s}' does not exist, cannot modify", .{self.username});
            return error.UserNotFound;
        }

        const cmd = try self.buildCommand("usermod", allocator);
        return try executeCommand(cmd, allocator);
    }

    fn applyRemove(self: Resource) !bool {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        // Check if user exists
        if (!try userExists(self.username)) {
            logger.debug("User '{s}' does not exist", .{self.username});
            return false;
        }

        const cmd = try self.buildCommand("userdel", allocator);
        return try executeCommand(cmd, allocator);
    }

    fn applyLock(self: Resource) !bool {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const cmd = try std.fmt.allocPrint(allocator, "passwd -l {s}", .{self.username});
        return try executeCommand(cmd, allocator);
    }

    fn applyUnlock(self: Resource) !bool {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const cmd = try std.fmt.allocPrint(allocator, "passwd -u {s}", .{self.username});
        return try executeCommand(cmd, allocator);
    }
};

/// Ruby prelude for user resource
pub const ruby_prelude = @embedFile("user_resource.rb");

/// Zig callback for adding user resource from Ruby
pub fn zigAddResource(
    mrb: *mruby.mrb_state,
    _: mruby.mrb_value,
    resources: *std.ArrayList(Resource),
    allocator: std.mem.Allocator,
) mruby.mrb_value {
    // Parse arguments: username, uid, gid, comment, home, shell, password, system, manage_home, non_unique, action, guards, notifications
    var username_val: mruby.mrb_value = undefined;
    var uid_val: mruby.mrb_value = undefined;
    var gid_val: mruby.mrb_value = undefined;
    var comment_val: mruby.mrb_value = undefined;
    var home_val: mruby.mrb_value = undefined;
    var shell_val: mruby.mrb_value = undefined;
    var password_val: mruby.mrb_value = undefined;
    var system_val: mruby.mrb_value = undefined;
    var manage_home_val: mruby.mrb_value = undefined;
    var non_unique_val: mruby.mrb_value = undefined;
    var action_val: mruby.mrb_value = undefined;
    var only_if_val: mruby.mrb_value = undefined;
    var not_if_val: mruby.mrb_value = undefined;
    var ignore_failure_val: mruby.mrb_value = undefined;
    var notifications_val: mruby.mrb_value = undefined;
    var subscriptions_val: mruby.mrb_value = undefined;

    // Format: SSSSSSSoooS|oooAA
    _ = mruby.mrb_get_args(
        mrb,
        "SSSSSSSoooS|oooAA",
        &username_val,
        &uid_val,
        &gid_val,
        &comment_val,
        &home_val,
        &shell_val,
        &password_val,
        &system_val,
        &manage_home_val,
        &non_unique_val,
        &action_val,
        &only_if_val,
        &not_if_val,
        &ignore_failure_val,
        &notifications_val,
        &subscriptions_val,
    );

    // Extract username
    const username_cstr = mruby.mrb_str_to_cstr(mrb, username_val);
    const username = allocator.dupe(u8, std.mem.span(username_cstr)) catch return mruby.mrb_nil_value();

    // Parse UID (optional)
    const uid_cstr = mruby.mrb_str_to_cstr(mrb, uid_val);
    const uid_str = std.mem.span(uid_cstr);
    const uid: ?u32 = if (uid_str.len > 0)
        std.fmt.parseInt(u32, uid_str, 10) catch null
    else
        null;

    // Parse GID (optional)
    const gid_cstr = mruby.mrb_str_to_cstr(mrb, gid_val);
    const gid_str = std.mem.span(gid_cstr);
    const gid: ?u32 = if (gid_str.len > 0)
        std.fmt.parseInt(u32, gid_str, 10) catch null
    else
        null;

    // Parse comment (optional)
    const comment_cstr = mruby.mrb_str_to_cstr(mrb, comment_val);
    const comment_str = std.mem.span(comment_cstr);
    const comment: ?[]const u8 = if (comment_str.len > 0)
        allocator.dupe(u8, comment_str) catch return mruby.mrb_nil_value()
    else
        null;

    // Parse home (optional)
    const home_cstr = mruby.mrb_str_to_cstr(mrb, home_val);
    const home_str = std.mem.span(home_cstr);
    const home: ?[]const u8 = if (home_str.len > 0)
        allocator.dupe(u8, home_str) catch return mruby.mrb_nil_value()
    else
        null;

    // Parse shell (optional)
    const shell_cstr = mruby.mrb_str_to_cstr(mrb, shell_val);
    const shell_str = std.mem.span(shell_cstr);
    const shell: ?[]const u8 = if (shell_str.len > 0)
        allocator.dupe(u8, shell_str) catch return mruby.mrb_nil_value()
    else
        null;

    // Parse password (optional)
    const password_cstr = mruby.mrb_str_to_cstr(mrb, password_val);
    const password_str = std.mem.span(password_cstr);
    const password: ?[]const u8 = if (password_str.len > 0)
        allocator.dupe(u8, password_str) catch return mruby.mrb_nil_value()
    else
        null;

    // Parse boolean flags
    const system = mruby.mrb_test(system_val);
    const manage_home = mruby.mrb_test(manage_home_val);
    const non_unique = mruby.mrb_test(non_unique_val);

    // Parse action
    const action_cstr = mruby.mrb_str_to_cstr(mrb, action_val);
    const action_str = std.mem.span(action_cstr);
    const action: Resource.Action = if (std.mem.eql(u8, action_str, "modify"))
        .modify
    else if (std.mem.eql(u8, action_str, "remove"))
        .remove
    else if (std.mem.eql(u8, action_str, "lock"))
        .lock
    else if (std.mem.eql(u8, action_str, "unlock"))
        .unlock
    else
        .create;

    // Build common properties (guards + notifications)
    var common = base.CommonProps.init(allocator);
    base.fillCommonFromRuby(&common, mrb, only_if_val, not_if_val, ignore_failure_val, notifications_val, subscriptions_val, allocator);

    resources.append(allocator, .{
        .username = username,
        .uid = uid,
        .gid = gid,
        .comment = comment,
        .home = home,
        .shell = shell,
        .password = password,
        .system = system,
        .manage_home = manage_home,
        .non_unique = non_unique,
        .action = action,
        .common = common,
    }) catch return mruby.mrb_nil_value();

    return mruby.mrb_nil_value();
}
