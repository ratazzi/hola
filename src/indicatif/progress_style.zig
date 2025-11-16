const std = @import("std");
const ProgressState = @import("progress_state.zig").ProgressState;
const format_utils = @import("format.zig");

/// ProgressStyle defines how a progress bar should be rendered
pub const ProgressStyle = struct {
    template: []const u8,
    progress_chars: []const u8 = "█░",
    tick_chars: []const u8 = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏",
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, template: []const u8) !Self {
        const owned_template = try allocator.dupe(u8, template);
        return .{
            .allocator = allocator,
            .template = owned_template,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.template);
    }

    /// Default style for progress bars
    pub fn defaultBar(allocator: std.mem.Allocator) !Self {
        return try init(allocator, "{wide_bar} {pos}/{len}");
    }

    /// Default style for spinners
    pub fn defaultSpinner(allocator: std.mem.Allocator) !Self {
        return try init(allocator, "{spinner} {msg}");
    }

    /// Create a style with a custom template
    /// Template variables:
    /// - {bar} or {wide_bar}: the progress bar
    /// - {spinner}: spinning animation
    /// - {pos}: current position
    /// - {len}: total length
    /// - {percent}: percentage complete
    /// - {msg}: custom message
    /// - {prefix}: custom prefix
    /// - {elapsed}: elapsed time
    /// - {eta}: estimated time remaining
    /// - {bytes}: position as bytes
    /// - {total_bytes}: total as bytes
    /// - {bytes_per_sec}: speed in bytes/sec
    pub fn withTemplate(allocator: std.mem.Allocator, template: []const u8) !Self {
        return try init(allocator, template);
    }

    /// Set the characters to use for the progress bar
    pub fn progressChars(self: *Self, chars: []const u8) Self {
        self.progress_chars = chars;
        return self.*;
    }

    /// Set the characters to use for the spinner
    pub fn tickChars(self: *Self, chars: []const u8) Self {
        self.tick_chars = chars;
        return self.*;
    }

    /// Format the progress bar according to the template
    pub fn format(self: *Self, state: *ProgressState, width: usize, writer: anytype) !void {
        var template_iter = std.mem.splitScalar(u8, self.template, '{');

        // First part before any placeholders
        if (template_iter.next()) |before| {
            try writer.writeAll(before);
        }

        while (template_iter.next()) |part| {
            // Find the closing brace
            if (std.mem.indexOfScalar(u8, part, '}')) |close_idx| {
                const placeholder = part[0..close_idx];
                const after = part[close_idx + 1 ..];

                try self.formatPlaceholder(placeholder, state, width, writer);
                try writer.writeAll(after);
            } else {
                // No closing brace, write as-is
                try writer.writeByte('{');
                try writer.writeAll(part);
            }
        }
    }

    fn formatPlaceholder(self: *Self, placeholder: []const u8, state: *ProgressState, width: usize, writer: anytype) !void {
        if (std.mem.eql(u8, placeholder, "bar") or std.mem.eql(u8, placeholder, "wide_bar")) {
            try self.formatBar(state, width, writer);
        } else if (std.mem.eql(u8, placeholder, "spinner")) {
            try self.formatSpinner(state, writer);
        } else if (std.mem.eql(u8, placeholder, "pos")) {
            try writer.print("{d}", .{state.pos});
        } else if (std.mem.eql(u8, placeholder, "len")) {
            if (state.len) |len| {
                try writer.print("{d}", .{len});
            } else {
                try writer.writeAll("??");
            }
        } else if (std.mem.eql(u8, placeholder, "percent")) {
            const pct = state.percentComplete();
            try writer.print("{d}%", .{@as(u64, @intFromFloat(pct))});
        } else if (std.mem.eql(u8, placeholder, "msg")) {
            try writer.writeAll(state.message);
        } else if (std.mem.eql(u8, placeholder, "prefix")) {
            try writer.writeAll(state.prefix);
        } else if (std.mem.eql(u8, placeholder, "elapsed")) {
            const elapsed_ns = state.elapsed();
            const human = format_utils.HumanDuration.init(elapsed_ns);
            try human.format(writer);
        } else if (std.mem.eql(u8, placeholder, "elapsed_precise")) {
            const elapsed_ns = state.elapsed();
            const secs = @divFloor(elapsed_ns, 1_000_000_000);
            const mins = @divFloor(secs, 60);
            const hours = @divFloor(mins, 60);
            try writer.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ hours, @rem(mins, 60), @rem(secs, 60) });
        } else if (std.mem.eql(u8, placeholder, "eta")) {
            const eta_ns = state.eta();
            const human = format_utils.HumanDuration.init(eta_ns);
            try human.format(writer);
        } else if (std.mem.eql(u8, placeholder, "bytes")) {
            const human = format_utils.HumanBytes.init(state.pos);
            try human.format(writer);
        } else if (std.mem.eql(u8, placeholder, "total_bytes")) {
            if (state.len) |len| {
                const human = format_utils.HumanBytes.init(len);
                try human.format(writer);
            } else {
                try writer.writeAll("??");
            }
        } else if (std.mem.eql(u8, placeholder, "bytes_per_sec")) {
            const rate = state.perSec();
            const human = format_utils.HumanBytes.init(@as(u64, @intFromFloat(rate)));
            try human.format(writer);
            try writer.writeAll("/s");
        } else if (std.mem.eql(u8, placeholder, "per_sec")) {
            const rate = state.perSec();
            try writer.print("{d:.2}", .{rate});
        }
    }

    fn formatBar(self: *Self, state: *ProgressState, width: usize, writer: anytype) !void {
        const bar_width = if (width > 20) width - 20 else 20;

        if (state.len) |len| {
            const filled_width = if (len > 0)
                @as(usize, @intFromFloat(@as(f64, @floatFromInt(bar_width)) * @as(f64, @floatFromInt(state.pos)) / @as(f64, @floatFromInt(len))))
            else
                bar_width;

            const filled_str = if (self.progress_chars.len > 0) "█" else "█";
            const empty_str = if (self.progress_chars.len > 1) "░" else "░";

            var i: usize = 0;
            while (i < bar_width) : (i += 1) {
                if (i < filled_width) {
                    try writer.writeAll(filled_str);
                } else {
                    try writer.writeAll(empty_str);
                }
            }
        } else {
            // Indeterminate progress
            const filled_str = if (self.progress_chars.len > 0) "█" else "█";
            const empty_str = if (self.progress_chars.len > 1) "░" else "░";

            const pulse_pos = @as(usize, @intCast(state.tick % bar_width));
            var i: usize = 0;
            while (i < bar_width) : (i += 1) {
                if (i == pulse_pos) {
                    try writer.writeAll(filled_str);
                } else {
                    try writer.writeAll(empty_str);
                }
            }
        }
    }

    fn formatSpinner(self: *Self, state: *ProgressState, writer: anytype) !void {
        // Count the number of Unicode codepoints
        var count_iter = std.unicode.Utf8Iterator{ .bytes = self.tick_chars, .i = 0 };
        var char_count: usize = 0;
        while (count_iter.nextCodepoint()) |_| {
            char_count += 1;
        }

        if (char_count == 0) {
            try writer.writeAll("?");
            return;
        }

        const tick_idx = @as(usize, @intCast(state.tick % @as(u64, @intCast(char_count))));

        // Handle multi-byte UTF-8 characters
        var iter = std.unicode.Utf8Iterator{ .bytes = self.tick_chars, .i = 0 };
        var current_idx: usize = 0;

        while (iter.nextCodepoint()) |codepoint| {
            if (current_idx == tick_idx) {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(codepoint, &buf) catch break;
                try writer.writeAll(buf[0..len]);
                return;
            }
            current_idx += 1;
        }

        // Fallback
        try writer.writeAll("?");
    }
};
