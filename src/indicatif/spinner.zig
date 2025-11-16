const std = @import("std");
const ProgressBar = @import("progress_bar.zig").ProgressBar;

/// Convenience wrapper for creating spinners
pub const Spinner = struct {
    const Self = @This();

    /// Create a new spinner with default settings
    pub fn new(allocator: std.mem.Allocator, message: []const u8) !*ProgressBar {
        const pb = try ProgressBar.newSpinner(allocator);
        pb.setMessage(message);
        return pb;
    }

    /// Create a spinner that ticks automatically
    pub fn newWithTick(allocator: std.mem.Allocator, message: []const u8, tick_interval_ms: u64) !*ProgressBar {
        const pb = try Self.new(allocator, message);
        try pb.enableSteadyTick(tick_interval_ms);
        return pb;
    }
};
