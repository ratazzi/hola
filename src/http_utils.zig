const std = @import("std");
const math = std.math;
const http_client = @import("http_client.zig");
const logger = @import("logger.zig");

/// Format byte size using binary units (KiB, MiB, GiB, TiB) with configurable decimals
/// Uses logarithmic calculation to elegantly determine the appropriate unit
/// Returns a formatted string that must be freed by the caller
pub fn formatSize(allocator: std.mem.Allocator, bytes: u64) ![]const u8 {
    var buf: [64]u8 = undefined;
    const formatted = formatSizeBuf(bytes, &buf, 1);
    return allocator.dupe(u8, formatted);
}

/// Format byte size using binary units into a provided buffer (no allocation)
/// Uses logarithmic calculation to determine unit level automatically
/// Returns a slice of the buffer containing the formatted string
pub fn formatSizeBuf(bytes: u64, buf: []u8, decimals: u8) []const u8 {
    if (bytes == 0) {
        return std.fmt.bufPrint(buf, "0B", .{}) catch buf[0..0];
    }

    const k: f64 = 1024.0;
    const sizes = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB", "PiB" };

    // Calculate unit level using logarithm
    const i = @min(
        @as(usize, @intFromFloat(@floor(@log(@as(f64, @floatFromInt(bytes))) / @log(k)))),
        sizes.len - 1,
    );

    const value = @as(f64, @floatFromInt(bytes)) / math.pow(f64, k, @as(f64, @floatFromInt(i)));

    // For bytes, don't show decimals
    if (i == 0) {
        return std.fmt.bufPrint(buf, "{d}B", .{bytes}) catch buf[0..0];
    }

    // Format with specified decimals
    return switch (decimals) {
        0 => std.fmt.bufPrint(buf, "{d:.0}{s}", .{ value, sizes[i] }) catch buf[0..0],
        1 => std.fmt.bufPrint(buf, "{d:.1}{s}", .{ value, sizes[i] }) catch buf[0..0],
        2 => std.fmt.bufPrint(buf, "{d:.2}{s}", .{ value, sizes[i] }) catch buf[0..0],
        else => std.fmt.bufPrint(buf, "{d:.1}{s}", .{ value, sizes[i] }) catch buf[0..0],
    };
}

/// Format a range of bytes (e.g., "1.5MiB/10.2MiB") into a provided buffer
pub fn formatSizeRange(bytes_downloaded: u64, total_bytes: u64, buf: []u8) []const u8 {
    var current_buf: [32]u8 = undefined;
    const current = formatSizeBuf(bytes_downloaded, &current_buf, 1);

    if (total_bytes == 0) {
        return std.fmt.bufPrint(buf, "{s}", .{current}) catch buf[0..0];
    }

    var total_buf: [32]u8 = undefined;
    const total = formatSizeBuf(total_bytes, &total_buf, 1);
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ current, total }) catch buf[0..0];
}

pub const DownloadStatus = enum {
    downloaded,
    not_modified,
};

pub const DownloadOptions = struct {
    headers: ?[]const u8 = null, // JSON encoded headers
    if_none_match: ?[]const u8 = null,
    if_modified_since: ?[]const u8 = null,
};

pub const DownloadResult = struct {
    status: DownloadStatus,
    etag: ?[]const u8 = null,
    last_modified: ?[]const u8 = null,
};

/// Simple HTTP download utility - similar to Python requests.get()
/// Downloads a file from URL to destination path with streaming
/// Returns status (downloaded / not_modified) and the ETag/Last-Modified (if present)
pub fn downloadFile(allocator: std.mem.Allocator, url: []const u8, dest_path: []const u8, options: DownloadOptions) !DownloadResult {
    // Create HTTP client
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // Parse URI
    const uri = try std.Uri.parse(url);

    // Parse headers if provided
    var headers_list = std.ArrayList(std.http.Header).empty;
    defer {
        for (headers_list.items) |*header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }
        headers_list.deinit(allocator);
    }

    if (options.headers) |headers_json| {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, headers_json, .{}) catch |err| {
            logger.warn("Failed to parse headers JSON: {}", .{err});
            return err;
        };
        defer parsed.deinit();

        if (parsed.value == .object) {
            var it = parsed.value.object.iterator();
            while (it.next()) |entry| {
                const name_copy = try allocator.dupe(u8, entry.key_ptr.*);
                const value_str = if (entry.value_ptr.* == .string) entry.value_ptr.*.string else "";
                const value_copy = try allocator.dupe(u8, value_str);

                const header = std.http.Header{
                    .name = name_copy,
                    .value = value_copy,
                };
                try headers_list.append(allocator, header);
            }
        }
    }

    if (options.if_none_match) |etag| {
        const name_copy = try allocator.dupe(u8, "If-None-Match");
        const value_copy = try allocator.dupe(u8, etag);
        try headers_list.append(allocator, .{
            .name = name_copy,
            .value = value_copy,
        });
    }

    if (options.if_modified_since) |lm| {
        const name_copy = try allocator.dupe(u8, "If-Modified-Since");
        const value_copy = try allocator.dupe(u8, lm);
        try headers_list.append(allocator, .{
            .name = name_copy,
            .value = value_copy,
        });
    }

    // Add Connection: close header only when using conditional requests
    // to avoid connection pooling issues with 304 responses
    if (options.if_none_match != null or options.if_modified_since != null) {
        const connection_name = try allocator.dupe(u8, "Connection");
        const connection_value = try allocator.dupe(u8, "close");
        try headers_list.append(allocator, .{
            .name = connection_name,
            .value = connection_value,
        });
    }

    // Create request
    var req = try client.request(.GET, uri, .{
        .redirect_behavior = @enumFromInt(5), // allow up to 5 redirects
        .extra_headers = headers_list.items,
    });
    errdefer req.deinit();

    // Set User-Agent header
    const user_agent = try http_client.getUserAgent(allocator);
    defer allocator.free(user_agent);
    req.headers.user_agent = .{ .override = user_agent };

    // Send request
    try req.sendBodiless();

    // Receive response headers
    var redirect_buffer: [8192]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);

    defer req.deinit();

    // Handle conditional requests
    // Per HTTP spec, 304 Not Modified MUST NOT contain a message body
    if (response.head.status == .not_modified) {
        const etag_header = getHeaderValue(allocator, response, "etag");
        const last_modified_header = getHeaderValue(allocator, response, "last-modified");

        // With Connection: close header, the server should close the connection immediately
        // after sending 304 response, allowing req.deinit() to complete cleanly
        return DownloadResult{ .status = .not_modified, .etag = etag_header, .last_modified = last_modified_header };
    }

    // Check response status
    if (response.head.status.class() != .success) {
        return error.HttpError;
    }

    const etag_header = getHeaderValue(allocator, response, "etag");
    const last_modified_header = getHeaderValue(allocator, response, "last-modified");

    // Create output file
    const dest_file = try std.fs.cwd().createFile(dest_path, .{ .truncate = true });
    defer dest_file.close();

    // Use readerDecompressing to automatically handle gzip/deflate
    var transfer_buffer: [64 * 1024]u8 = undefined;
    var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var body_reader = response.readerDecompressing(&transfer_buffer, &decompress, &decompress_buffer);

    var buffer: [64 * 1024]u8 = undefined; // 64KB buffer for efficient I/O

    while (true) {
        const bytes_read = try body_reader.readSliceShort(&buffer);
        if (bytes_read == 0) break;

        // Write to file
        try dest_file.writeAll(buffer[0..bytes_read]);

        // `readSliceShort` only returns fewer bytes when reaching EOF, so it's
        // safe to exit the loop to avoid invoking the reader again.
        if (bytes_read < buffer.len) break;
    }

    return DownloadResult{ .status = .downloaded, .etag = etag_header, .last_modified = last_modified_header };
}

fn getHeaderValue(allocator: std.mem.Allocator, response: std.http.Client.Response, name: []const u8) ?[]const u8 {
    var it = response.head.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) {
            return allocator.dupe(u8, header.value) catch return null;
        }
    }
    return null;
}

/// Slugify a file path for use in temporary filenames
/// Converts /tmp/foo/bar.txt -> tmp_foo_bar_txt
pub fn slugifyPath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var slug = try allocator.alloc(u8, path.len);
    defer allocator.free(slug);

    var i: usize = 0;
    for (path) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            slug[i] = c;
            i += 1;
        } else if (c == '/' or c == '\\' or c == '.' or c == '-' or c == '_') {
            // Replace path separators and special chars with underscore
            slug[i] = '_';
            i += 1;
        }
        // Skip other non-alphanumeric characters
    }

    // Trim trailing underscores
    while (i > 0 and slug[i - 1] == '_') {
        i -= 1;
    }

    // Strip leading underscores
    var start: usize = 0;
    while (start < i and slug[start] == '_') {
        start += 1;
    }

    return allocator.dupe(u8, slug[start..i]);
}

/// Calculate SHA256 checksum of a file using native Zig crypto
/// Returns hex string (lowercase) that must be freed by caller
pub fn calculateSha256(allocator: std.mem.Allocator, file_path: []const u8) ![]const u8 {
    // Open file for reading
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    // Initialize SHA-256 hasher
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    // Read file in chunks and update hash
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const bytes_read = try file.read(&buffer);
        if (bytes_read == 0) break;
        hasher.update(buffer[0..bytes_read]);
    }

    // Finalize hash
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);

    // Convert to hex string (lowercase)
    const hex_digest = std.fmt.bytesToHex(digest, .lower);

    return allocator.dupe(u8, &hex_digest);
}
