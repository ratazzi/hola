const std = @import("std");

/// Parse HTTP headers from JSON string
/// Returns a HashMap that caller must deinit
pub fn parseHeadersFromJson(allocator: std.mem.Allocator, json_str: []const u8) !std.StringHashMap([]const u8) {
    var headers = std.StringHashMap([]const u8).init(allocator);
    errdefer {
        var it = headers.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        headers.deinit();
    }

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(key);

        const value = try allocator.dupe(u8, entry.value_ptr.string);
        errdefer allocator.free(value);

        try headers.put(key, value);
    }

    return headers;
}

/// Format byte size using binary units (KiB, MiB, GiB, TiB)
pub fn formatSize(allocator: std.mem.Allocator, bytes: u64) ![]const u8 {
    var buf: [64]u8 = undefined;
    const formatted = formatSizeBuf(bytes, &buf, 1);
    return allocator.dupe(u8, formatted);
}

/// Format byte size using binary units into a provided buffer (no allocation)
pub fn formatSizeBuf(bytes: u64, buf: []u8, decimals: u8) []const u8 {
    if (bytes == 0) {
        return std.fmt.bufPrint(buf, "0B", .{}) catch buf[0..0];
    }

    const k: f64 = 1024.0;
    const sizes = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB", "PiB" };

    const i = @min(
        @as(usize, @intFromFloat(@floor(@log(@as(f64, @floatFromInt(bytes))) / @log(k)))),
        sizes.len - 1,
    );

    const value = @as(f64, @floatFromInt(bytes)) / std.math.pow(f64, k, @as(f64, @floatFromInt(i)));

    if (i == 0) {
        return std.fmt.bufPrint(buf, "{d}B", .{bytes}) catch buf[0..0];
    }

    return switch (decimals) {
        0 => std.fmt.bufPrint(buf, "{d:.0}{s}", .{ value, sizes[i] }) catch buf[0..0],
        1 => std.fmt.bufPrint(buf, "{d:.1}{s}", .{ value, sizes[i] }) catch buf[0..0],
        2 => std.fmt.bufPrint(buf, "{d:.2}{s}", .{ value, sizes[i] }) catch buf[0..0],
        else => std.fmt.bufPrint(buf, "{d:.1}{s}", .{ value, sizes[i] }) catch buf[0..0],
    };
}

/// Format a range of bytes (e.g., "1.5MiB/10.2MiB")
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

/// Generate slugified version of a file path for unique temp filename
/// Replaces / with _ and removes leading /
pub fn slugifyPath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var result = try allocator.alloc(u8, path.len);
    var write_idx: usize = 0;

    for (path) |c| {
        if (c == '/') {
            if (write_idx > 0) { // Skip leading /
                result[write_idx] = '_';
                write_idx += 1;
            }
        } else {
            result[write_idx] = c;
            write_idx += 1;
        }
    }

    return allocator.realloc(result, write_idx);
}

/// Calculate SHA256 checksum of a file
/// Returns hex-encoded string
pub fn calculateSha256(allocator: std.mem.Allocator, file_path: []const u8) ![]const u8 {
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

    // Convert to hex string
    const hex_str = std.fmt.bytesToHex(digest, .lower);
    return try allocator.dupe(u8, &hex_str);
}
