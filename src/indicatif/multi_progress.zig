const std = @import("std");
const ProgressBar = @import("progress_bar.zig").ProgressBar;

/// MultiProgress manages multiple progress bars
pub const MultiProgress = struct {
    allocator: std.mem.Allocator,
    bars: std.ArrayList(*ProgressBar) = .{},
    mutex: std.Thread.Mutex = .{},
    draw_enabled: bool = true,
    last_total_lines: usize = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.clear() catch {};
        for (self.bars.items) |bar| {
            bar.deinit();
        }
        self.bars.deinit(self.allocator);
    }

    /// Add a progress bar to the multi-progress
    pub fn add(self: *Self, bar: *ProgressBar) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Disable individual drawing for bars managed by MultiProgress
        bar.draw_enabled = false;
        try self.bars.append(self.allocator, bar);
    }

    /// Remove a progress bar
    pub fn remove(self: *Self, bar: *ProgressBar) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.bars.items, 0..) |b, i| {
            if (b == bar) {
                _ = self.bars.orderedRemove(i);
                bar.draw_enabled = true;
                break;
            }
        }
    }

    /// Move a progress bar to the end of the list
    pub fn moveToEnd(self: *Self, bar: *ProgressBar) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Find and remove the bar from its current position
        for (self.bars.items, 0..) |b, i| {
            if (b == bar) {
                _ = self.bars.orderedRemove(i);
                // Add it back at the end
                self.bars.append(self.allocator, bar) catch return;
                break;
            }
        }
    }

    /// Draw all progress bars (internal, no lock)
    fn drawInternal(self: *Self) !void {
        if (!self.draw_enabled) return;

        // Move cursor up to the start of our drawing area
        if (self.last_total_lines > 0) {
            std.debug.print("\x1b[{d}F", .{self.last_total_lines});
        }

        // Pre-allocate buffer with enough capacity
        var buffer: std.ArrayList(u8) = .{};
        defer buffer.deinit(self.allocator);
        try buffer.ensureTotalCapacity(self.allocator, 512);  // Pre-allocate to avoid reallocation

        // Draw each progress bar
        var total_lines: usize = 0;
        for (self.bars.items) |bar| {
            buffer.clearRetainingCapacity();

            try bar.style.format(bar.state, bar.width, buffer.writer(self.allocator));
            std.debug.print("\x1b[K{s}\n", .{buffer.items});

            total_lines += 1;
        }

        // If we drew fewer lines than before, clear the remaining lines
        while (total_lines < self.last_total_lines) {
            std.debug.print("\x1b[K\n", .{});
            total_lines += 1;
        }

        self.last_total_lines = self.bars.items.len;
    }

    /// Draw all progress bars
    pub fn draw(self: *Self) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.drawInternal();
    }

    /// Clear all progress bars from the terminal (internal, no lock)
    fn clearInternal(self: *Self) !void {
        if (!self.draw_enabled) return;

        if (self.last_total_lines > 0) {
            // Move cursor up
            std.debug.print("\x1b[{d}F", .{self.last_total_lines});

            // Clear each line
            var i: usize = 0;
            while (i < self.last_total_lines) : (i += 1) {
                std.debug.print("\x1b[K\n", .{});
            }

            // Move cursor back up
            std.debug.print("\x1b[{d}F", .{self.last_total_lines});
        }

        self.last_total_lines = 0;
    }

    /// Clear all progress bars from the terminal
    pub fn clear(self: *Self) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.clearInternal();
    }

    /// Print a message above all progress bars
    pub fn println(self: *Self, msg: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.clearInternal();
        std.debug.print("{s}\n", .{msg});
        try self.drawInternal();
    }

    /// Join all bars (wait for them to finish)
    pub fn join(self: *Self) void {
        while (true) {
            var all_finished = true;

            self.mutex.lock();
            for (self.bars.items) |bar| {
                if (!bar.isFinished()) {
                    all_finished = false;
                    break;
                }
            }
            self.mutex.unlock();

            if (all_finished) break;

            std.time.sleep(50 * std.time.ns_per_ms);
            self.draw() catch {};
        }
    }

    /// Create and add a new progress bar
    pub fn addBar(self: *Self, len: u64) !*ProgressBar {
        const bar = try ProgressBar.new(self.allocator, len);
        try self.add(bar);
        return bar;
    }

    /// Create and add a new spinner
    pub fn addSpinner(self: *Self) !*ProgressBar {
        const bar = try ProgressBar.newSpinner(self.allocator);
        try self.add(bar);
        return bar;
    }
};
