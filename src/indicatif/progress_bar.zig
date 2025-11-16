const std = @import("std");
const ProgressState = @import("progress_state.zig").ProgressState;
const ProgressStyle = @import("progress_style.zig").ProgressStyle;

/// ProgressBar represents a single progress bar or spinner
pub const ProgressBar = struct {
    state: *ProgressState,
    style: *ProgressStyle,
    allocator: std.mem.Allocator,
    draw_enabled: bool = true,
    steady_tick_thread: ?std.Thread = null,
    steady_tick_running: bool = false,
    width: usize = 80,
    buffer: std.ArrayList(u8) = .{},
    last_draw_len: usize = 0,

    const Self = @This();

    /// Create a new progress bar with a known length
    pub fn new(allocator: std.mem.Allocator, len: u64) !*Self {
        return try newWithLength(allocator, len);
    }

    /// Create a new progress bar with an optional length
    pub fn newWithLength(allocator: std.mem.Allocator, len: ?u64) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        const state = try allocator.create(ProgressState);
        errdefer allocator.destroy(state);
        state.* = ProgressState.init(len);

        const style = try allocator.create(ProgressStyle);
        errdefer allocator.destroy(style);
        style.* = try ProgressStyle.defaultBar(allocator);

        self.* = .{
            .state = state,
            .style = style,
            .allocator = allocator,
        };

        return self;
    }

    /// Create a new spinner (indeterminate progress)
    pub fn newSpinner(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        const state = try allocator.create(ProgressState);
        errdefer allocator.destroy(state);
        state.* = ProgressState.init(null);

        const style = try allocator.create(ProgressStyle);
        errdefer allocator.destroy(style);
        style.* = try ProgressStyle.defaultSpinner(allocator);

        self.* = .{
            .state = state,
            .style = style,
            .allocator = allocator,
        };

        return self;
    }

    /// Clean up resources
    pub fn deinit(self: *Self) void {
        self.disableSteadyTick();
        self.style.deinit();
        self.allocator.destroy(self.style);
        self.allocator.destroy(self.state);
        self.buffer.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Set a custom style
    pub fn setStyle(self: *Self, style: ProgressStyle) void {
        self.style.deinit();
        self.style.* = style;
    }

    /// Set the message to display
    pub fn setMessage(self: *Self, msg: []const u8) void {
        self.state.setMessage(msg);
        self.tick();
    }

    /// Set the prefix to display
    pub fn setPrefix(self: *Self, prefix: []const u8) void {
        self.state.setPrefix(prefix);
        self.tick();
    }

    /// Set the current position
    pub fn setPosition(self: *Self, pos: u64) void {
        self.state.setPosition(pos);
        self.tick();
    }

    /// Increment the position by delta
    pub fn inc(self: *Self, delta: u64) void {
        self.state.inc(delta);
        self.tick();
    }

    /// Set the total length
    pub fn setLength(self: *Self, len: u64) void {
        self.state.setLength(len);
        self.tick();
    }

    /// Manually tick the progress bar/spinner
    pub fn tick(self: *Self) void {
        self.state.tick += 1;
        self.draw() catch {};
    }

    /// Tick without drawing (for use with MultiProgress)
    pub fn tickNoDraw(self: *Self) void {
        self.state.tick += 1;
    }

    /// Enable automatic ticking in a background thread
    pub fn enableSteadyTick(self: *Self, interval_ms: u64) !void {
        if (self.steady_tick_running) return;

        self.steady_tick_running = true;
        self.steady_tick_thread = try std.Thread.spawn(.{}, steadyTickWorker, .{ self, interval_ms });
    }

    /// Disable automatic ticking
    pub fn disableSteadyTick(self: *Self) void {
        if (self.steady_tick_thread) |thread| {
            self.steady_tick_running = false;
            thread.join();
            self.steady_tick_thread = null;
        }
    }

    fn steadyTickWorker(self: *Self, interval_ms: u64) void {
        while (self.steady_tick_running) {
            std.Thread.sleep(interval_ms * std.time.ns_per_ms);
            if (!self.steady_tick_running) break;
            // Use tickNoDraw when managed by MultiProgress
            if (self.draw_enabled) {
                self.tick();
            } else {
                self.tickNoDraw();
            }
        }
    }

    /// Finish the progress bar
    pub fn finish(self: *Self) void {
        self.disableSteadyTick();
        self.state.finish();
        self.draw() catch {};
        self.println() catch {};
    }

    /// Finish with a custom message
    pub fn finishWithMessage(self: *Self, msg: []const u8) void {
        self.disableSteadyTick();
        self.state.setMessage(msg);
        self.state.finish();
        self.draw() catch {};
        self.println() catch {};
    }

    /// Finish and clear the progress bar
    pub fn finishAndClear(self: *Self) void {
        self.disableSteadyTick();
        self.state.finish();
        self.clear() catch {};
    }

    /// Clear the progress bar from the terminal
    pub fn clear(self: *Self) !void {
        if (!self.draw_enabled) return;

        // Move cursor to beginning of line and clear
        std.debug.print("\r\x1b[K", .{});
        self.last_draw_len = 0;
    }

    /// Move to next line (used after finishing)
    fn println(self: *Self) !void {
        if (!self.draw_enabled) return;
        std.debug.print("\n", .{});
    }

    /// Draw the progress bar
    fn draw(self: *Self) !void {
        if (!self.draw_enabled) return;
        if (self.state.isFinished() and self.last_draw_len == 0) return;

        self.buffer.clearRetainingCapacity();
        const writer = self.buffer.writer(self.allocator);

        // Format using the style template
        try self.style.format(self.state, self.width, writer);

        // Move cursor to beginning of line and clear, then write
        std.debug.print("\r\x1b[K{s}", .{self.buffer.items});

        self.last_draw_len = self.buffer.items.len;
    }

    /// Print a message above the progress bar
    pub fn printLine(self: *Self, msg: []const u8) !void {
        try self.clear();
        std.debug.print("{s}\n", .{msg});
        try self.draw();
    }

    /// Set the terminal width for rendering
    pub fn setWidth(self: *Self, width: usize) void {
        self.width = width;
    }

    /// Check if the progress bar is finished
    pub fn isFinished(self: *Self) bool {
        return self.state.isFinished();
    }

    /// Get current position
    pub fn position(self: *Self) u64 {
        return self.state.pos;
    }

    /// Get total length
    pub fn length(self: *Self) ?u64 {
        return self.state.len;
    }
};
