const std = @import("std");

/// Mask the password in a URL's `user:password@` userinfo for safe display or
/// logging. Writes `scheme://user:***@rest` into `buf` (no allocation) and
/// returns that slice. When the URL has no userinfo password, the original URL
/// is copied into `buf` unchanged. If `buf` is too small the masked form is
/// truncated — the raw password is never emitted.
pub fn maskUrlPassword(url: []const u8, buf: []u8) []const u8 {
    const ui = findUserinfoPassword(url) orelse return copyUrl(url, buf);
    // Build "<scheme>://<user>:***<@host/path...>" piece by piece. We never fall
    // back to copying the raw URL, which would leak the password when buf is
    // too small (truncating the masked form keeps the password out).
    var n: usize = 0;
    n += copyChunk(buf, n, url[0..ui.password_start]);
    n += copyChunk(buf, n, "***");
    n += copyChunk(buf, n, url[ui.at_pos..]);
    return buf[0..n];
}

/// Copy `text` into `buf`, replacing every occurrence of the password carried in
/// `url`'s `user:password@` userinfo with `***`. Use this to scrub credentials a
/// library error message may have echoed back. Returns `text` unchanged when
/// `url` carries no password.
pub fn redactPassword(url: []const u8, text: []const u8, buf: []u8) []const u8 {
    const ui = findUserinfoPassword(url) orelse return text;
    const password = url[ui.password_start..ui.at_pos];
    if (password.len == 0) return text;

    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len and n < buf.len) {
        if (std.mem.startsWith(u8, text[i..], password)) {
            n += copyChunk(buf, n, "***");
            i += password.len;
        } else {
            n += copyChunk(buf, n, text[i .. i + 1]);
            i += 1;
        }
    }
    return buf[0..n];
}

const UserinfoPassword = struct { password_start: usize, at_pos: usize };

fn findUserinfoPassword(url: []const u8) ?UserinfoPassword {
    const scheme_pos = std.mem.indexOf(u8, url, "://") orelse return null;
    const auth_start = scheme_pos + 3;
    const path_start = std.mem.indexOfScalarPos(u8, url, auth_start, '/') orelse url.len;
    const at_rel = std.mem.indexOfScalar(u8, url[auth_start..path_start], '@') orelse return null;
    const at_pos = auth_start + at_rel;
    const colon_rel = std.mem.indexOfScalar(u8, url[auth_start..at_pos], ':') orelse return null;
    return .{ .password_start = auth_start + colon_rel + 1, .at_pos = at_pos };
}

/// Copy `src` into `buf` at `offset`, truncating to fit. Returns bytes written.
fn copyChunk(buf: []u8, offset: usize, src: []const u8) usize {
    if (offset >= buf.len) return 0;
    const n = @min(src.len, buf.len - offset);
    @memcpy(buf[offset..][0..n], src[0..n]);
    return n;
}

fn copyUrl(value: []const u8, buf: []u8) []const u8 {
    const n = @min(value.len, buf.len);
    @memcpy(buf[0..n], value[0..n]);
    return buf[0..n];
}

test "maskUrlPassword masks password with ample buffer" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://user:***@example.com/path",
        maskUrlPassword("https://user:secret@example.com/path", &buf),
    );
}

test "maskUrlPassword leaves a URL without userinfo unchanged" {
    var buf: [128]u8 = undefined;
    const url = "https://example.com/path?token=abc";
    try std.testing.expectEqualStrings(url, maskUrlPassword(url, &buf));
}

test "maskUrlPassword never leaks the password when buffer is too small" {
    var buf: [24]u8 = undefined;
    const out = maskUrlPassword("https://user:supersecretpassword@example.com/very/long/path", &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "supersecretpassword") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "***") != null);
    try std.testing.expect(std.mem.startsWith(u8, out, "https://user:***"));
}

test "redactPassword scrubs the url password echoed in arbitrary text" {
    var buf: [128]u8 = undefined;
    const out = redactPassword(
        "https://user:tok3n@host/repo.git",
        "failed to connect to https://user:tok3n@host/repo.git",
        &buf,
    );
    try std.testing.expect(std.mem.indexOf(u8, out, "tok3n") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "***") != null);
}

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
