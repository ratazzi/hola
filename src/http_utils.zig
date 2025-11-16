const std = @import("std");
const math = std.math;

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

/// Simple HTTP download utility - similar to Python requests.get()
/// Downloads a file from URL to destination path with streaming
pub fn downloadFile(allocator: std.mem.Allocator, url: []const u8, dest_path: []const u8) !void {
    // Create HTTP client
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // Parse URI
    const uri = try std.Uri.parse(url);

    // Create request
    var req = try client.request(.GET, uri, .{
        .redirect_behavior = @enumFromInt(5), // allow up to 5 redirects
    });
    defer req.deinit();

    // Send request
    try req.sendBodiless();

    // Receive response headers
    var redirect_buffer: [8192]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);

    // Check response status
    if (response.head.status.class() != .success) {
        return error.HttpError;
    }

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
