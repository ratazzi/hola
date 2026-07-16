const std = @import("std");
const global_io = @import("../global_io.zig");

/// ProgressState holds the current state of a progress bar
pub const ProgressState = struct {
    pos: u64 = 0,
    len: ?u64 = null,
    tick: u64 = 0,
    started: i64 = 0, // Unix timestamp in nanoseconds
    message: []const u8 = "",
    prefix: []const u8 = "",
    finished: bool = false,
    mutex: std.Io.Mutex = .init,

    // WARNING: message and prefix are just pointers!
    // The caller must ensure they remain valid for the lifetime of this state.
    // Do NOT use setMessage/setPrefix with temporary strings!

    const Self = @This();

    pub fn init(len: ?u64) Self {
        return .{
            .len = len,
            .started = @as(i64, @intCast(std.Io.Timestamp.now(global_io.io(), .real).toNanoseconds())),
        };
    }

    pub fn setPosition(self: *Self, pos: u64) void {
        self.mutex.lockUncancelable(global_io.io());
        defer self.mutex.unlock(global_io.io());
        self.pos = pos;
    }

    pub fn inc(self: *Self, delta: u64) void {
        self.mutex.lockUncancelable(global_io.io());
        defer self.mutex.unlock(global_io.io());
        self.pos += delta;
    }

    pub fn setLength(self: *Self, len: u64) void {
        self.mutex.lockUncancelable(global_io.io());
        defer self.mutex.unlock(global_io.io());
        self.len = len;
    }

    pub fn setMessage(self: *Self, msg: []const u8) void {
        self.mutex.lockUncancelable(global_io.io());
        defer self.mutex.unlock(global_io.io());
        self.message = msg;
    }

    pub fn setPrefix(self: *Self, prefix: []const u8) void {
        self.mutex.lockUncancelable(global_io.io());
        defer self.mutex.unlock(global_io.io());
        self.prefix = prefix;
    }

    pub fn finish(self: *Self) void {
        self.mutex.lockUncancelable(global_io.io());
        defer self.mutex.unlock(global_io.io());
        self.finished = true;
    }

    pub fn isFinished(self: *Self) bool {
        self.mutex.lockUncancelable(global_io.io());
        defer self.mutex.unlock(global_io.io());
        return self.finished;
    }

    pub fn percentComplete(self: *Self) f64 {
        self.mutex.lockUncancelable(global_io.io());
        defer self.mutex.unlock(global_io.io());

        if (self.len) |len| {
            if (len == 0) return 100.0;
            return @as(f64, @floatFromInt(self.pos)) / @as(f64, @floatFromInt(len)) * 100.0;
        }
        return 0.0;
    }

    pub fn elapsed(self: *Self) i64 {
        self.mutex.lockUncancelable(global_io.io());
        defer self.mutex.unlock(global_io.io());
        return @as(i64, @intCast(std.Io.Timestamp.now(global_io.io(), .real).toNanoseconds())) - self.started;
    }

    pub fn eta(self: *Self) i64 {
        self.mutex.lockUncancelable(global_io.io());
        defer self.mutex.unlock(global_io.io());

        if (self.len) |len| {
            if (self.pos == 0) return 0;
            const elapsed_ns = @as(i64, @intCast(std.Io.Timestamp.now(global_io.io(), .real).toNanoseconds())) - self.started;
            const rate = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(self.pos));
            const remaining = len -| self.pos;
            return @as(i64, @intFromFloat(rate * @as(f64, @floatFromInt(remaining))));
        }
        return 0;
    }

    pub fn perSec(self: *Self) f64 {
        self.mutex.lockUncancelable(global_io.io());
        defer self.mutex.unlock(global_io.io());

        const elapsed_ns = @as(i64, @intCast(std.Io.Timestamp.now(global_io.io(), .real).toNanoseconds())) - self.started;
        if (elapsed_ns == 0) return 0.0;
        const elapsed_sec = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
        return @as(f64, @floatFromInt(self.pos)) / elapsed_sec;
    }
};
