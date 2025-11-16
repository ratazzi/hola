const std = @import("std");

/// Format bytes in human-readable format (e.g., "1.5 MiB")
pub const HumanBytes = struct {
    bytes: u64,

    const Self = @This();

    pub fn init(bytes: u64) Self {
        return .{ .bytes = bytes };
    }

    pub fn format(self: Self, writer: anytype) !void {
        const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB", "PiB" };

        if (self.bytes == 0) {
            try writer.writeAll("0 B");
            return;
        }

        var value = @as(f64, @floatFromInt(self.bytes));
        var unit_idx: usize = 0;

        while (value >= 1024.0 and unit_idx < units.len - 1) {
            value /= 1024.0;
            unit_idx += 1;
        }

        if (unit_idx == 0) {
            try writer.print("{d} {s}", .{ self.bytes, units[unit_idx] });
        } else {
            try writer.print("{d:.2} {s}", .{ value, units[unit_idx] });
        }
    }

    pub fn toString(self: Self, allocator: std.mem.Allocator) ![]const u8 {
        var list: std.ArrayList(u8) = .{};
        defer list.deinit(allocator);
        try self.format(list.writer(allocator));
        return try list.toOwnedSlice(allocator);
    }
};

/// Format duration in human-readable format (e.g., "1m 30s")
pub const HumanDuration = struct {
    nanoseconds: i64,

    const Self = @This();

    pub fn init(nanoseconds: i64) Self {
        return .{ .nanoseconds = nanoseconds };
    }

    pub fn format(self: Self, writer: anytype) !void {
        const ns = if (self.nanoseconds < 0) 0 else self.nanoseconds;
        const secs = @divFloor(ns, 1_000_000_000);

        if (secs == 0) {
            try writer.writeAll("0s");
            return;
        }

        const mins = @divFloor(secs, 60);
        const hours = @divFloor(mins, 60);
        const days = @divFloor(hours, 24);

        var wrote_something = false;

        if (days > 0) {
            try writer.print("{d}d", .{days});
            wrote_something = true;
        }

        const rem_hours = @rem(hours, 24);
        if (rem_hours > 0) {
            if (wrote_something) try writer.writeAll(" ");
            try writer.print("{d}h", .{rem_hours});
            wrote_something = true;
        }

        const rem_mins = @rem(mins, 60);
        if (rem_mins > 0) {
            if (wrote_something) try writer.writeAll(" ");
            try writer.print("{d}m", .{rem_mins});
            wrote_something = true;
        }

        const rem_secs = @rem(secs, 60);
        if (rem_secs > 0 or !wrote_something) {
            if (wrote_something) try writer.writeAll(" ");
            try writer.print("{d}s", .{rem_secs});
        }
    }

    pub fn toString(self: Self, allocator: std.mem.Allocator) ![]const u8 {
        var list: std.ArrayList(u8) = .{};
        defer list.deinit(allocator);
        try self.format(list.writer(allocator));
        return try list.toOwnedSlice(allocator);
    }
};

/// Format large counts with commas (e.g., "1,234,567")
pub const HumanCount = struct {
    count: u64,

    const Self = @This();

    pub fn init(count: u64) Self {
        return .{ .count = count };
    }

    pub fn format(self: Self, writer: anytype) !void {
        var buf: [32]u8 = undefined;
        const num_str = std.fmt.bufPrint(&buf, "{d}", .{self.count}) catch return;

        const len = num_str.len;
        var i: usize = 0;

        while (i < len) : (i += 1) {
            if (i > 0 and (len - i) % 3 == 0) {
                try writer.writeByte(',');
            }
            try writer.writeByte(num_str[i]);
        }
    }

    pub fn toString(self: Self, allocator: std.mem.Allocator) ![]const u8 {
        var list: std.ArrayList(u8) = .{};
        defer list.deinit(allocator);
        try self.format(list.writer(allocator));
        return try list.toOwnedSlice(allocator);
    }
};

test "HumanBytes formatting" {
    const testing = std.testing;
    const allocator = testing.allocator;

    {
        const hb = HumanBytes.init(0);
        const str = try hb.toString(allocator);
        defer allocator.free(str);
        try testing.expectEqualStrings("0 B", str);
    }

    {
        const hb = HumanBytes.init(1024);
        const str = try hb.toString(allocator);
        defer allocator.free(str);
        try testing.expectEqualStrings("1.00 KiB", str);
    }

    {
        const hb = HumanBytes.init(1536);
        const str = try hb.toString(allocator);
        defer allocator.free(str);
        try testing.expectEqualStrings("1.50 KiB", str);
    }

    {
        const hb = HumanBytes.init(3 * 1024 * 1024);
        const str = try hb.toString(allocator);
        defer allocator.free(str);
        try testing.expectEqualStrings("3.00 MiB", str);
    }
}

test "HumanDuration formatting" {
    const testing = std.testing;
    const allocator = testing.allocator;

    {
        const hd = HumanDuration.init(0);
        const str = try hd.toString(allocator);
        defer allocator.free(str);
        try testing.expectEqualStrings("0s", str);
    }

    {
        const hd = HumanDuration.init(30 * std.time.ns_per_s);
        const str = try hd.toString(allocator);
        defer allocator.free(str);
        try testing.expectEqualStrings("30s", str);
    }

    {
        const hd = HumanDuration.init(90 * std.time.ns_per_s);
        const str = try hd.toString(allocator);
        defer allocator.free(str);
        try testing.expectEqualStrings("1m 30s", str);
    }

    {
        const hd = HumanDuration.init(3661 * std.time.ns_per_s);
        const str = try hd.toString(allocator);
        defer allocator.free(str);
        try testing.expectEqualStrings("1h 1m 1s", str);
    }
}

test "HumanCount formatting" {
    const testing = std.testing;
    const allocator = testing.allocator;

    {
        const hc = HumanCount.init(0);
        const str = try hc.toString(allocator);
        defer allocator.free(str);
        try testing.expectEqualStrings("0", str);
    }

    {
        const hc = HumanCount.init(1234567);
        const str = try hc.toString(allocator);
        defer allocator.free(str);
        try testing.expectEqualStrings("1,234,567", str);
    }
}
