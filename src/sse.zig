const std = @import("std");

/// A parsed SSE event
pub const Event = struct {
    event_type: ?[]const u8 = null,
    data: ?[]const u8 = null,
    id: ?[]const u8 = null,

    pub fn deinit(self: *Event, allocator: std.mem.Allocator) void {
        if (self.event_type) |v| allocator.free(v);
        if (self.data) |v| allocator.free(v);
        if (self.id) |v| allocator.free(v);
    }
};

/// Incremental SSE line-protocol parser.
/// Feed raw bytes via `feed()`, poll complete events via `next()`.
pub const Parser = struct {
    allocator: std.mem.Allocator,
    line_buf: std.ArrayList(u8),
    // Accumulated fields for the current event
    data_buf: std.ArrayList(u8),
    event_type: ?[]const u8 = null,
    event_id: ?[]const u8 = null,
    has_data: bool = false,
    // Queue of complete events ready to be consumed
    events: std.ArrayList(Event),

    pub fn init(allocator: std.mem.Allocator) Parser {
        return .{
            .allocator = allocator,
            .line_buf = std.ArrayList(u8).empty,
            .data_buf = std.ArrayList(u8).empty,
            .events = std.ArrayList(Event).empty,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.line_buf.deinit(self.allocator);
        self.data_buf.deinit(self.allocator);
        if (self.event_type) |v| self.allocator.free(v);
        if (self.event_id) |v| self.allocator.free(v);
        for (self.events.items) |*ev| ev.deinit(self.allocator);
        self.events.deinit(self.allocator);
    }

    /// Feed a chunk of raw bytes from the HTTP stream.
    pub fn feed(self: *Parser, data: []const u8) !void {
        for (data) |byte| {
            if (byte == '\n') {
                try self.processLine();
                self.line_buf.clearRetainingCapacity();
            } else if (byte == '\r') {
                // ignore CR, we handle LF
            } else {
                try self.line_buf.append(self.allocator, byte);
            }
        }
    }

    /// Return the next complete event, or null.
    pub fn next(self: *Parser) ?Event {
        if (self.events.items.len == 0) return null;
        return self.events.orderedRemove(0);
    }

    fn processLine(self: *Parser) !void {
        const line = self.line_buf.items;

        // Empty line → dispatch event
        if (line.len == 0) {
            if (self.has_data) {
                const ev = Event{
                    .event_type = self.event_type,
                    .data = try self.allocator.dupe(u8, self.data_buf.items),
                    .id = self.event_id,
                };
                try self.events.append(self.allocator, ev);
                // Reset accumulators (ownership transferred)
                self.event_type = null;
                self.event_id = null;
                self.data_buf.clearRetainingCapacity();
                self.has_data = false;
            }
            return;
        }

        // Comment line
        if (line[0] == ':') return;

        // Parse "field: value" or "field:value"
        var field: []const u8 = line;
        var value: []const u8 = "";
        if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
            field = line[0..colon];
            const rest = line[colon + 1 ..];
            value = if (rest.len > 0 and rest[0] == ' ') rest[1..] else rest;
        }

        if (std.mem.eql(u8, field, "data")) {
            if (self.has_data) try self.data_buf.append(self.allocator, '\n');
            try self.data_buf.appendSlice(self.allocator, value);
            self.has_data = true;
        } else if (std.mem.eql(u8, field, "event")) {
            if (self.event_type) |old| self.allocator.free(old);
            self.event_type = try self.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, field, "id")) {
            if (self.event_id) |old| self.allocator.free(old);
            self.event_id = try self.allocator.dupe(u8, value);
        }
        // "retry" and unknown fields are ignored
    }
};

// Tests
test "parse single event" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator);
    defer parser.deinit();

    try parser.feed("event: provision\ndata: {\"url\":\"https://example.com/test.rb\"}\n\n");

    var ev = parser.next() orelse return error.ExpectedEvent;
    defer ev.deinit(allocator);

    try std.testing.expectEqualStrings("provision", ev.event_type.?);
    try std.testing.expectEqualStrings("{\"url\":\"https://example.com/test.rb\"}", ev.data.?);
}

test "parse multi-line data" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator);
    defer parser.deinit();

    try parser.feed("data: line1\ndata: line2\n\n");

    var ev = parser.next() orelse return error.ExpectedEvent;
    defer ev.deinit(allocator);

    try std.testing.expectEqualStrings("line1\nline2", ev.data.?);
}

test "ignore comments and empty chunks" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator);
    defer parser.deinit();

    try parser.feed(": this is a comment\n\n");
    try std.testing.expect(parser.next() == null);
}

test "incremental feed across chunks" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator);
    defer parser.deinit();

    try parser.feed("data: hel");
    try parser.feed("lo\n\n");

    var ev = parser.next() orelse return error.ExpectedEvent;
    defer ev.deinit(allocator);

    try std.testing.expectEqualStrings("hello", ev.data.?);
}
