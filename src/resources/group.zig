const std = @import("std");
const mruby = @import("../mruby.zig");
const base = @import("../base_resource.zig");
const logger = @import("../logger.zig");

/// Group resource data structure
pub const Resource = struct {
    // Resource-specific properties
    group_name: []const u8, // Group name (defaults to name if not specified)
    gid: ?u32, // Group ID
    members: ?[]const u8, // Comma-separated list of members
    excluded_members: ?[]const u8, // Comma-separated list of excluded members
    append: bool, // Append members instead of replacing
    comment: ?[]const u8, // Group comment
    system: bool, // Create as system group
    non_unique: bool, // Allow non-unique GID
    action: Action,

    // Common properties (guards, notifications, etc.)
    common: base.CommonProps,

    pub const Action = enum {
        create,
        modify,
        remove,
    };

    pub fn deinit(self: Resource, allocator: std.mem.Allocator) void {
        allocator.free(self.group_name);
        if (self.members) |m| allocator.free(m);
        if (self.excluded_members) |e| allocator.free(e);
        if (self.comment) |c| allocator.free(c);

        // Deinit common props
        var common = self.common;
        common.deinit(allocator);
    }

    pub fn apply(self: Resource) !base.ApplyResult {
        const skip_reason = try self.common.shouldRun(null, null);
        if (skip_reason) |reason| {
            const action_name = switch (self.action) {
                .create => "create",
                .modify => "modify",
                .remove => "remove",
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
        };

        const was_updated = switch (self.action) {
            .create => try applyCreate(self),
            .modify => try applyModify(self),
            .remove => try applyRemove(self),
        };

        return base.ApplyResult{
            .was_updated = was_updated,
            .action = action_name,
            .skip_reason = if (was_updated) null else "up to date",
        };
    }

    fn groupExists(group_name: []const u8) !bool {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const args = [_][]const u8{ "getent", "group", group_name };
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &args,
        }) catch |err| {
            logger.debug("getent command failed for group '{s}': {}", .{ group_name, err });
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
        var buf = try std.ArrayList(u8).initCapacity(allocator, 128);
        errdefer buf.deinit(allocator);
        const writer = buf.writer(allocator);

        try writer.writeAll(cmd);

        if (std.mem.eql(u8, cmd, "groupadd")) {
            if (self.gid) |gid| {
                try writer.print(" -g {d}", .{gid});
            }
            if (self.system) {
                try writer.writeAll(" -r");
            }
            if (self.non_unique) {
                try writer.writeAll(" -o");
            }
        } else if (std.mem.eql(u8, cmd, "groupmod")) {
            if (self.gid) |gid| {
                try writer.print(" -g {d}", .{gid});
            }
            if (self.non_unique) {
                try writer.writeAll(" -o");
            }
        }

        try writer.print(" {s}", .{self.group_name});
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

    fn manageMembers(self: Resource, allocator: std.mem.Allocator) !void {
        // Handle members
        if (self.members) |members| {
            const flag = if (self.append) "-a" else "";
            var iter = std.mem.splitSequence(u8, members, ",");
            while (iter.next()) |member| {
                const trimmed = std.mem.trim(u8, member, &std.ascii.whitespace);
                if (trimmed.len > 0) {
                    const cmd = try std.fmt.allocPrint(
                        allocator,
                        "gpasswd {s} -a {s} {s}",
                        .{ flag, trimmed, self.group_name },
                    );
                    _ = try executeCommand(cmd, allocator);
                }
            }
        }

        // Handle excluded members
        if (self.excluded_members) |excluded| {
            var iter = std.mem.splitSequence(u8, excluded, ",");
            while (iter.next()) |member| {
                const trimmed = std.mem.trim(u8, member, &std.ascii.whitespace);
                if (trimmed.len > 0) {
                    const cmd = try std.fmt.allocPrint(
                        allocator,
                        "gpasswd -d {s} {s}",
                        .{ trimmed, self.group_name },
                    );
                    _ = try executeCommand(cmd, allocator);
                }
            }
        }
    }

    fn applyCreate(self: Resource) !bool {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        // Check if group already exists
        if (try groupExists(self.group_name)) {
            logger.debug("Group '{s}' already exists", .{self.group_name});
            return false;
        }

        const cmd = try self.buildCommand("groupadd", allocator);
        const result = try executeCommand(cmd, allocator);

        // Manage members after creating group
        if (result) {
            try self.manageMembers(allocator);
        }

        return result;
    }

    fn applyModify(self: Resource) !bool {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        // Group must exist to modify
        if (!try groupExists(self.group_name)) {
            logger.err("Group '{s}' does not exist, cannot modify", .{self.group_name});
            return error.GroupNotFound;
        }

        const cmd = try self.buildCommand("groupmod", allocator);
        const result = try executeCommand(cmd, allocator);

        // Manage members after modifying group
        try self.manageMembers(allocator);

        return result;
    }

    fn applyRemove(self: Resource) !bool {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        // Check if group exists
        if (!try groupExists(self.group_name)) {
            logger.debug("Group '{s}' does not exist", .{self.group_name});
            return false;
        }

        const cmd = try std.fmt.allocPrint(allocator, "groupdel {s}", .{self.group_name});
        return try executeCommand(cmd, allocator);
    }
};

/// Ruby prelude for group resource
pub const ruby_prelude = @embedFile("group_resource.rb");

/// Zig callback for adding group resource from Ruby
pub fn zigAddResource(
    mrb: *mruby.mrb_state,
    _: mruby.mrb_value,
    resources: *std.ArrayList(Resource),
    allocator: std.mem.Allocator,
) mruby.mrb_value {
    // Parse arguments: group_name, gid, members, excluded_members, append, comment, system, non_unique, action, guards, notifications
    var group_name_val: mruby.mrb_value = undefined;
    var gid_val: mruby.mrb_value = undefined;
    var members_val: mruby.mrb_value = undefined;
    var excluded_members_val: mruby.mrb_value = undefined;
    var append_val: mruby.mrb_value = undefined;
    var comment_val: mruby.mrb_value = undefined;
    var system_val: mruby.mrb_value = undefined;
    var non_unique_val: mruby.mrb_value = undefined;
    var action_val: mruby.mrb_value = undefined;
    var only_if_val: mruby.mrb_value = undefined;
    var not_if_val: mruby.mrb_value = undefined;
    var ignore_failure_val: mruby.mrb_value = undefined;
    var notifications_val: mruby.mrb_value = undefined;
    var subscriptions_val: mruby.mrb_value = undefined;

    // Format: SSSSoSooS|oooAA
    _ = mruby.mrb_get_args(
        mrb,
        "SSSSoSooS|oooAA",
        &group_name_val,
        &gid_val,
        &members_val,
        &excluded_members_val,
        &append_val,
        &comment_val,
        &system_val,
        &non_unique_val,
        &action_val,
        &only_if_val,
        &not_if_val,
        &ignore_failure_val,
        &notifications_val,
        &subscriptions_val,
    );

    // Extract group name
    const group_name_cstr = mruby.mrb_str_to_cstr(mrb, group_name_val);
    const group_name = allocator.dupe(u8, std.mem.span(group_name_cstr)) catch return mruby.mrb_nil_value();

    // Parse GID (optional)
    const gid_cstr = mruby.mrb_str_to_cstr(mrb, gid_val);
    const gid_str = std.mem.span(gid_cstr);
    const gid: ?u32 = if (gid_str.len > 0)
        std.fmt.parseInt(u32, gid_str, 10) catch null
    else
        null;

    // Parse members (optional)
    const members_cstr = mruby.mrb_str_to_cstr(mrb, members_val);
    const members_str = std.mem.span(members_cstr);
    const members: ?[]const u8 = if (members_str.len > 0)
        allocator.dupe(u8, members_str) catch return mruby.mrb_nil_value()
    else
        null;

    // Parse excluded_members (optional)
    const excluded_members_cstr = mruby.mrb_str_to_cstr(mrb, excluded_members_val);
    const excluded_members_str = std.mem.span(excluded_members_cstr);
    const excluded_members: ?[]const u8 = if (excluded_members_str.len > 0)
        allocator.dupe(u8, excluded_members_str) catch return mruby.mrb_nil_value()
    else
        null;

    // Parse append (boolean)
    const append = mruby.mrb_test(append_val);

    // Parse comment (optional)
    const comment_cstr = mruby.mrb_str_to_cstr(mrb, comment_val);
    const comment_str = std.mem.span(comment_cstr);
    const comment: ?[]const u8 = if (comment_str.len > 0)
        allocator.dupe(u8, comment_str) catch return mruby.mrb_nil_value()
    else
        null;

    // Parse boolean flags
    const system = mruby.mrb_test(system_val);
    const non_unique = mruby.mrb_test(non_unique_val);

    // Parse action
    const action_cstr = mruby.mrb_str_to_cstr(mrb, action_val);
    const action_str = std.mem.span(action_cstr);
    const action: Resource.Action = if (std.mem.eql(u8, action_str, "modify"))
        .modify
    else if (std.mem.eql(u8, action_str, "remove"))
        .remove
    else
        .create;

    // Build common properties (guards + notifications)
    var common = base.CommonProps.init(allocator);
    base.fillCommonFromRuby(&common, mrb, only_if_val, not_if_val, ignore_failure_val, notifications_val, subscriptions_val, allocator);

    resources.append(allocator, .{
        .group_name = group_name,
        .gid = gid,
        .members = members,
        .excluded_members = excluded_members,
        .append = append,
        .comment = comment,
        .system = system,
        .non_unique = non_unique,
        .action = action,
        .common = common,
    }) catch return mruby.mrb_nil_value();

    return mruby.mrb_nil_value();
}
