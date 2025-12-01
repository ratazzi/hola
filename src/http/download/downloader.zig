const std = @import("std");
const http_client = @import("../client.zig");
const types = @import("../types.zig");
const Task = @import("task.zig").Task;
const logger = @import("../../logger.zig");

/// Options for single file download
pub const Options = struct {
    /// HTTP headers
    headers: ?std.StringHashMap([]const u8) = null,

    /// Resume from byte position
    resume_from: ?u64 = null,

    /// If-None-Match (ETag)
    if_none_match: ?[]const u8 = null,

    /// If-Modified-Since
    if_modified_since: ?[]const u8 = null,

    /// Progress callback
    progress_callback: ?types.ProgressCallback = null,
    progress_context: ?*anyopaque = null,
};

/// Result of download operation
pub const Result = struct {
    status: Status,
    etag: ?[]const u8 = null,
    last_modified: ?[]const u8 = null,

    pub const Status = enum {
        downloaded,
        not_modified,
    };

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        if (self.etag) |etag| allocator.free(etag);
        if (self.last_modified) |lm| allocator.free(lm);
    }
};

/// Context for download progress tracking
const DownloadContext = struct {
    file: std.fs.File,
};

/// Simple download file wrapper (for direct use without Manager)
pub fn downloadFile(
    allocator: std.mem.Allocator,
    url: []const u8,
    dest_path: []const u8,
    opts: Options,
) !Result {
    const cfg = @import("../config.zig").Config{};
    var client = try http_client.Client.init(allocator, cfg);
    defer client.deinit();

    return downloadFileWithClient(allocator, &client, url, dest_path, opts);
}

/// Download file to disk with existing client (for advanced use)
pub fn downloadFileWithClient(
    allocator: std.mem.Allocator,
    client: *http_client.Client,
    url: []const u8,
    dest_path: []const u8,
    opts: Options,
) !Result {
    // Build request
    var req = types.Request.init(.GET, url);
    defer req.deinit();

    // Add custom headers
    if (opts.headers) |custom_headers| {
        req.headers = std.StringHashMap([]const u8).init(allocator);
        req.headers_owned = true;
        var it = custom_headers.iterator();
        while (it.next()) |entry| {
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            const value = try allocator.dupe(u8, entry.value_ptr.*);
            try req.headers.?.put(key, value);
        }
    } else {
        req.headers = std.StringHashMap([]const u8).init(allocator);
        req.headers_owned = true;
    }

    // Add conditional headers
    if (opts.if_none_match) |etag| {
        const key = try allocator.dupe(u8, "If-None-Match");
        const value = try allocator.dupe(u8, etag);
        try req.headers.?.put(key, value);
    }

    if (opts.if_modified_since) |lm| {
        const key = try allocator.dupe(u8, "If-Modified-Since");
        const value = try allocator.dupe(u8, lm);
        try req.headers.?.put(key, value);
    }

    // Add range header for resume
    if (opts.resume_from) |offset| {
        const key = try allocator.dupe(u8, "Range");
        const value = try std.fmt.allocPrint(allocator, "bytes={d}-", .{offset});
        try req.headers.?.put(key, value);
    }

    // For all downloads (except resume), use a temporary file first, then atomically replace.
    // This prevents destroying existing files if:
    // - Server returns 4xx/5xx errors
    // - Network fails mid-download
    // - Conditional request returns 304 Not Modified
    // Only skip temp file for resume (need to append to existing file)
    const use_temp_file = opts.resume_from == null;

    const actual_dest_path = if (use_temp_file)
        try std.fmt.allocPrint(allocator, "{s}.tmp.{d}", .{ dest_path, std.time.timestamp() })
    else
        dest_path;
    defer if (use_temp_file) allocator.free(actual_dest_path);

    // Open file for writing
    const file = try std.fs.cwd().createFile(actual_dest_path, .{
        .truncate = opts.resume_from == null,
    });
    var file_closed = false;
    defer if (!file_closed) {
        file.close();
        // Clean up temp file if we used one and didn't move it
        if (use_temp_file) {
            std.fs.cwd().deleteFile(actual_dest_path) catch {};
        }
    };

    // Seek to resume position if needed
    if (opts.resume_from) |offset| {
        try file.seekTo(offset);
    }

    // Download context
    var ctx = DownloadContext{
        .file = file,
    };

    // Stream to file and get response status and headers
    var stream_result = try client.stream(req, streamToFile, &ctx, opts.progress_callback, opts.progress_context);
    var cleanup_headers = true;
    defer if (cleanup_headers) {
        var it = stream_result.headers.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        stream_result.headers.deinit();
    };

    // If the server ignored the Range request, drop the partial file and retry from scratch.
    if (opts.resume_from != null and stream_result.status != 206) {
        cleanup_headers = false;
        var it = stream_result.headers.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        stream_result.headers.deinit();

        // Remove the partially written file before retrying.
        std.fs.cwd().deleteFile(dest_path) catch {};
        file_closed = true;
        file.close();

        var fresh_opts = opts;
        fresh_opts.resume_from = null;
        return downloadFileWithClient(allocator, client, url, dest_path, fresh_opts);
    }

    // Check HTTP status code
    if (stream_result.status == 304) {
        // Not Modified - cached file is still valid, temp file can be discarded
        // The original dest_path file is untouched
        return Result{
            .status = .not_modified,
            .etag = null,
            .last_modified = null,
        };
    }

    // Check HTTP status code (only accept 2xx)
    if (stream_result.status < 200 or stream_result.status >= 300) {
        // Error or unexpected status code
        // Temp file will be cleaned up by defer automatically
        // For resume mode, explicitly delete the corrupted file
        if (!use_temp_file) {
            std.fs.cwd().deleteFile(dest_path) catch {};
        }
        return error.InvalidResponse;
    }

    // Close file before moving (required on Windows)
    file_closed = true;
    file.close();

    // If we used a temp file for conditional request, atomically replace the original
    if (use_temp_file) {
        // Delete old file first, then rename temp to dest
        std.fs.cwd().deleteFile(dest_path) catch {};
        try std.fs.cwd().rename(actual_dest_path, dest_path);
    }

    // Extract ETag and Last-Modified from response headers
    const etag = if (stream_result.headers.get("etag")) |val|
        try allocator.dupe(u8, val)
    else if (stream_result.headers.get("ETag")) |val|
        try allocator.dupe(u8, val)
    else
        null;

    const last_modified = if (stream_result.headers.get("last-modified")) |val|
        try allocator.dupe(u8, val)
    else if (stream_result.headers.get("Last-Modified")) |val|
        try allocator.dupe(u8, val)
    else
        null;

    return Result{
        .status = .downloaded,
        .etag = etag,
        .last_modified = last_modified,
    };
}

/// Download file for a task
pub fn downloadTask(
    allocator: std.mem.Allocator,
    client: *http_client.Client,
    task: *Task,
) !Result {
    task.status.store(.downloading, .release);

    const opts = Options{
        .headers = task.headers,
        .progress_callback = taskProgressCallback,
        .progress_context = task,
    };

    const result = downloadFileWithClient(
        allocator,
        client,
        task.url,
        task.temp_path,
        opts,
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(allocator, "Download failed: {}", .{err});
        defer allocator.free(err_msg);
        try task.setError(allocator, err_msg);
        return err;
    };

    // Verify checksum if provided
    if (task.checksum) |expected_checksum| {
        try verifyChecksum(allocator, task.temp_path, expected_checksum);
    }

    // Move to final location
    try std.fs.cwd().rename(task.temp_path, task.final_path);

    // Set file mode if provided
    if (task.mode) |mode_str| {
        const mode = try std.fmt.parseInt(u16, mode_str, 8);
        const final_file = try std.fs.cwd().openFile(task.final_path, .{});
        defer final_file.close();
        try final_file.chmod(mode);
    }

    task.status.store(.completed, .release);
    return result;
}

/// Stream callback that writes to file
fn streamToFile(data: []const u8, context: *anyopaque) !usize {
    const ctx: *DownloadContext = @ptrCast(@alignCast(context));

    // Write to file
    try ctx.file.writeAll(data);

    return data.len;
}

/// Progress callback for tasks
fn taskProgressCallback(downloaded: usize, total: usize, context: *anyopaque) void {
    const task: *Task = @ptrCast(@alignCast(context));
    task.updateProgress(downloaded, total);
}

/// Verify file checksum (SHA256)
pub fn verifyChecksum(_: std.mem.Allocator, file_path: []const u8, expected: []const u8) !void {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [8192]u8 = undefined;

    while (true) {
        const n = try file.read(&buf);
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }

    var digest: [32]u8 = undefined;
    hasher.final(&digest);

    // Convert to hex
    const hex = std.fmt.bytesToHex(digest, .lower);

    // Compare
    if (!std.mem.eql(u8, &hex, expected)) {
        logger.err("Checksum mismatch: expected {s}, got {s}", .{ expected, hex });
        return error.ChecksumMismatch;
    }
}
