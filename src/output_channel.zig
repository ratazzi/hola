const std = @import("std");
const global_io = @import("global_io.zig");

pub const Stream = enum(u8) {
    stdout = 1,
    stderr = 2,
};

pub const Batch = struct {
    bytes: []u8,
    dropped: usize,
};

/// Bounded worker-to-main line queue used by live command output. Records are
/// encoded as one stream tag byte, the line bytes, and a trailing newline.
pub const LineChannel = struct {
    pub const MAX_PENDING_BYTES: usize = 1024 * 1024;

    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    pending: std.ArrayList(u8) = .empty,
    dropped: usize = 0,

    pub fn init(allocator: std.mem.Allocator) LineChannel {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *LineChannel) void {
        self.pending.deinit(self.allocator);
        self.pending = .empty;
    }

    pub fn push(self: *LineChannel, stream: Stream, line: []const u8) void {
        self.mutex.lockUncancelable(global_io.io());
        defer self.mutex.unlock(global_io.io());

        const record_len = 1 + line.len + 1;
        if (record_len > MAX_PENDING_BYTES or self.pending.items.len + record_len > MAX_PENDING_BYTES) {
            self.dropped += 1;
            return;
        }
        self.pending.append(self.allocator, @intFromEnum(stream)) catch {
            self.dropped += 1;
            return;
        };
        self.pending.appendSlice(self.allocator, line) catch {
            _ = self.pending.pop();
            self.dropped += 1;
            return;
        };
        self.pending.append(self.allocator, '\n') catch {
            self.pending.shrinkRetainingCapacity(self.pending.items.len - line.len - 1);
            self.dropped += 1;
        };
    }

    pub fn take(self: *LineChannel) !Batch {
        self.mutex.lockUncancelable(global_io.io());
        var pending = self.pending;
        self.pending = .empty;
        const dropped = self.dropped;
        self.dropped = 0;
        self.mutex.unlock(global_io.io());
        errdefer pending.deinit(self.allocator);

        return .{
            .bytes = try pending.toOwnedSlice(self.allocator),
            .dropped = dropped,
        };
    }
};

threadlocal var current: ?*LineChannel = null;

pub fn setCurrent(channel: ?*LineChannel) void {
    current = channel;
}

pub fn getCurrent() ?*LineChannel {
    return current;
}

test "LineChannel transfers tagged records and reports drops" {
    var channel = LineChannel.init(std.testing.allocator);
    defer channel.deinit();

    channel.push(.stdout, "hello");
    channel.push(.stderr, "oops");
    const batch = try channel.take();
    defer std.testing.allocator.free(batch.bytes);
    try std.testing.expectEqual(@as(usize, 0), batch.dropped);
    try std.testing.expectEqualSlices(u8, &.{ 1, 'h', 'e', 'l', 'l', 'o', '\n', 2, 'o', 'o', 'p', 's', '\n' }, batch.bytes);

    const oversized = try std.testing.allocator.alloc(u8, LineChannel.MAX_PENDING_BYTES);
    defer std.testing.allocator.free(oversized);
    channel.push(.stdout, oversized);
    const dropped_batch = try channel.take();
    defer std.testing.allocator.free(dropped_batch.bytes);
    try std.testing.expectEqual(@as(usize, 1), dropped_batch.dropped);
}
