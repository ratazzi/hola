const std = @import("std");

/// Notification timing
pub const Timing = enum {
    immediate, // Execute right away
    delayed, // Execute at the end (Chef default)
};

/// Notification action to trigger
pub const Action = struct {
    action_name: []const u8, // e.g., "restart", "reload", "stop"
};

/// A notification from one resource to another
pub const Notification = struct {
    target_resource_id: []const u8, // e.g., "service[nginx]"
    action: Action,
    timing: Timing,

    pub fn deinit(self: Notification, allocator: std.mem.Allocator) void {
        allocator.free(self.target_resource_id);
        allocator.free(self.action.action_name);
    }
};

/// Resource identifier (e.g., "file[/etc/nginx.conf]", "service[nginx]")
pub const ResourceId = struct {
    type_name: []const u8, // "file", "service", "package", etc.
    name: []const u8, // "/etc/nginx.conf", "nginx", etc.

    /// Format: "type[name]"
    pub fn format(
        self: ResourceId,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{s}[{s}]", .{ self.type_name, self.name });
    }

    pub fn toString(self: ResourceId, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{s}[{s}]", .{ self.type_name, self.name });
    }

    /// Parse "type[name]" string
    pub fn parse(allocator: std.mem.Allocator, id_str: []const u8) !ResourceId {
        const bracket_pos = std.mem.indexOf(u8, id_str, "[") orelse return error.InvalidResourceId;
        if (!std.mem.endsWith(u8, id_str, "]")) return error.InvalidResourceId;

        const type_name = try allocator.dupe(u8, id_str[0..bracket_pos]);
        const name = try allocator.dupe(u8, id_str[bracket_pos + 1 .. id_str.len - 1]);

        return ResourceId{
            .type_name = type_name,
            .name = name,
        };
    }

    pub fn deinit(self: ResourceId, allocator: std.mem.Allocator) void {
        allocator.free(self.type_name);
        allocator.free(self.name);
    }
};
