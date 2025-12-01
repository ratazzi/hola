const std = @import("std");

/// Download task status
pub const Status = enum(u8) {
    queued = 0,
    downloading = 1,
    completed = 2,
    failed = 3,
};

/// Download task for a remote file
pub const Task = struct {
    // Identity
    id: []const u8,
    url: []const u8,
    display_name: []const u8,

    // Paths
    temp_path: []const u8,
    final_path: []const u8,

    // Options
    mode: ?[]const u8 = null,
    checksum: ?[]const u8 = null,
    backup: ?[]const u8 = null,
    headers: ?std.StringHashMap([]const u8) = null,

    // State (atomic for thread-safety)
    status: std.atomic.Value(Status) = std.atomic.Value(Status).init(.queued),
    bytes_downloaded: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    total_bytes: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    error_message: std.atomic.Value(?[*:0]u8) = std.atomic.Value(?[*:0]u8).init(null),

    // UI tracking
    board_line_id: ?usize = null,

    pub fn init(
        allocator: std.mem.Allocator,
        id: []const u8,
        url: []const u8,
        display_name: []const u8,
        temp_path: []const u8,
        final_path: []const u8,
    ) !Task {
        return Task{
            .id = try allocator.dupe(u8, id),
            .url = try allocator.dupe(u8, url),
            .display_name = try allocator.dupe(u8, display_name),
            .temp_path = try allocator.dupe(u8, temp_path),
            .final_path = try allocator.dupe(u8, final_path),
        };
    }

    pub fn deinit(self: *Task, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.url);
        allocator.free(self.display_name);
        allocator.free(self.temp_path);
        allocator.free(self.final_path);

        if (self.mode) |mode| allocator.free(mode);
        if (self.checksum) |checksum| allocator.free(checksum);
        if (self.backup) |backup| allocator.free(backup);

        if (self.headers) |*headers| {
            var it = headers.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            headers.deinit();
        }

        if (self.error_message.load(.acquire)) |msg_ptr| {
            allocator.free(std.mem.span(msg_ptr));
        }
    }

    pub fn setError(self: *Task, allocator: std.mem.Allocator, err_msg: []const u8) !void {
        // Free old error if exists
        if (self.error_message.load(.acquire)) |old_msg| {
            allocator.free(std.mem.span(old_msg));
        }

        // Allocate new error message
        const msg_z = try allocator.dupeZ(u8, err_msg);
        self.error_message.store(msg_z.ptr, .release);
        self.status.store(.failed, .release);
    }

    pub fn getError(self: *const Task, allocator: std.mem.Allocator) ?[]const u8 {
        const msg_ptr = self.error_message.load(.acquire) orelse return null;
        const span = std.mem.span(msg_ptr);
        return allocator.dupe(u8, span) catch null;
    }

    pub fn updateProgress(self: *Task, downloaded: usize, total: usize) void {
        self.bytes_downloaded.store(downloaded, .release);
        self.total_bytes.store(total, .release);
    }

    pub fn getProgress(self: *const Task) struct { downloaded: usize, total: usize } {
        return .{
            .downloaded = self.bytes_downloaded.load(.acquire),
            .total = self.total_bytes.load(.acquire),
        };
    }
};

// Tests
const testing = @import("std").testing;

test "Task thread-safe state transitions" {
    const allocator = testing.allocator;

    var task = try Task.init(
        allocator,
        "test-1",
        "https://example.com/file.zip",
        "file.zip",
        "/tmp/file.zip.tmp",
        "/home/user/file.zip",
    );
    defer task.deinit(allocator);

    // Verify atomic state transitions
    try testing.expectEqual(Status.queued, task.status.load(.acquire));
    task.status.store(.downloading, .release);
    try testing.expectEqual(Status.downloading, task.status.load(.acquire));

    // Concurrent progress updates
    task.updateProgress(512, 1024);
    const progress = task.getProgress();
    try testing.expectEqual(@as(usize, 512), progress.downloaded);
    try testing.expectEqual(@as(usize, 1024), progress.total);
}

test "Task error message memory management" {
    const allocator = testing.allocator;

    var task = try Task.init(
        allocator,
        "test-2",
        "https://example.com/file.zip",
        "file.zip",
        "/tmp/file.zip.tmp",
        "/home/user/file.zip",
    );
    defer task.deinit(allocator);

    // Set and update error messages - verify memory is properly freed
    try task.setError(allocator, "First error");
    try task.setError(allocator, "Second error");

    const err_msg = task.getError(allocator);
    defer if (err_msg) |msg| allocator.free(msg);

    try testing.expectEqual(Status.failed, task.status.load(.acquire));
    try testing.expectEqualStrings("Second error", err_msg.?);
}
