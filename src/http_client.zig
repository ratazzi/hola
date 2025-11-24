const std = @import("std");
const mruby = @import("mruby.zig");
const builtin = @import("builtin");
const build_options = @import("build_options");

/// Version string for User-Agent from build.zig.zon
const VERSION = build_options.version;

/// Generate User-Agent string: Hola/version (platform; arch; zig version)
fn getUserAgent(allocator: std.mem.Allocator) ![]const u8 {
    const platform = switch (builtin.os.tag) {
        .macos => "macOS",
        .linux => "Linux",
        .windows => "Windows",
        else => "Unknown",
    };

    const arch = switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "x86_64",
        else => "unknown",
    };

    const zig_version = builtin.zig_version_string;

    return std.fmt.allocPrint(allocator, "Hola/{s} ({s}; {s}; Zig {s})", .{
        VERSION,
        platform,
        arch,
        zig_version,
    });
}

/// HTTP Response structure
pub const Response = struct {
    status: u16,
    headers: std.StringHashMap([]const u8),
    body: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Response) void {
        var it = self.headers.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.headers.deinit();
        self.allocator.free(self.body);
    }
};

/// Perform HTTP GET request
pub fn get(allocator: std.mem.Allocator, url: []const u8) !Response {
    return request(allocator, .GET, url, null, null);
}

/// Perform HTTP POST request
pub fn post(allocator: std.mem.Allocator, url: []const u8, body: ?[]const u8, content_type: ?[]const u8) !Response {
    return request(allocator, .POST, url, body, content_type);
}

/// Perform HTTP PUT request
pub fn put(allocator: std.mem.Allocator, url: []const u8, body: ?[]const u8, content_type: ?[]const u8) !Response {
    return request(allocator, .PUT, url, body, content_type);
}

/// Perform HTTP DELETE request
pub fn delete(allocator: std.mem.Allocator, url: []const u8) !Response {
    return request(allocator, .DELETE, url, null, null);
}

/// Perform HTTP PATCH request
pub fn patch(allocator: std.mem.Allocator, url: []const u8, body: ?[]const u8, content_type: ?[]const u8) !Response {
    return request(allocator, .PATCH, url, body, content_type);
}

/// Perform HTTP request with method, URL, optional body and content type
pub fn request(
    allocator: std.mem.Allocator,
    method: std.http.Method,
    url: []const u8,
    body: ?[]const u8,
    content_type: ?[]const u8,
) !Response {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(url);

    var req = try client.request(method, uri, .{
        .redirect_behavior = @enumFromInt(10),
    });
    defer req.deinit();

    // Set User-Agent header
    const user_agent = try getUserAgent(allocator);
    defer allocator.free(user_agent);
    req.headers.user_agent = .{ .override = user_agent };

    // Set content-type header if provided
    if (content_type) |ct| {
        req.headers.content_type = .{ .override = ct };
    }

    // Send request with or without body
    if (body) |b| {
        req.transfer_encoding = .{ .content_length = b.len };
        // Use heap allocation for body buffer to avoid stack size issues
        const body_buf = try allocator.alloc(u8, @max(b.len, 8192));
        defer allocator.free(body_buf);
        @memcpy(body_buf[0..b.len], b);
        try req.sendBodyComplete(body_buf[0..b.len]);
    } else {
        // For methods that can have a body (PUT, POST, PATCH), send empty body
        // For methods that cannot have a body (GET, DELETE), use sendBodiless
        if (method == .PUT or method == .POST or method == .PATCH) {
            req.transfer_encoding = .{ .content_length = 0 };
            try req.sendBodyComplete(&[_]u8{});
        } else {
            try req.sendBodiless();
        }
    }

    // Receive response
    var redirect_buffer: [8192]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);

    // Parse response headers
    var response_headers = std.StringHashMap([]const u8).init(allocator);
    errdefer {
        var it = response_headers.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        response_headers.deinit();
    }

    // Extract common headers
    if (response.head.content_type) |ct| {
        const key = try allocator.dupe(u8, "content-type");
        const value = try allocator.dupe(u8, ct);
        try response_headers.put(key, value);
    }

    // Read body
    var body_list = std.ArrayList(u8).empty;
    defer body_list.deinit(allocator);

    var transfer_buffer: [64 * 1024]u8 = undefined;
    var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var body_reader = response.readerDecompressing(&transfer_buffer, &decompress, &decompress_buffer);

    var buffer: [64 * 1024]u8 = undefined;

    while (true) {
        const bytes_read = body_reader.readSliceShort(&buffer) catch |err| {
            std.log.warn("Error reading HTTP body: {}", .{err});
            break;
        };
        if (bytes_read == 0) break;
        body_list.appendSlice(allocator, buffer[0..bytes_read]) catch break;
        if (bytes_read < buffer.len) break;
    }

    const response_body = allocator.dupe(u8, body_list.items) catch &[_]u8{};

    return Response{
        .status = @intFromEnum(response.head.status),
        .headers = response_headers,
        .body = response_body,
        .allocator = allocator,
    };
}

// Global allocator for mruby callbacks
var global_allocator: ?std.mem.Allocator = null;

pub fn setAllocator(allocator: std.mem.Allocator) void {
    global_allocator = allocator;
}

/// mruby binding: HTTP GET request
/// Args: url, headers_array (optional) - array of [key, value] pairs
/// Returns array: [status_code, headers_hash, body_string]
pub fn zig_http_get(mrb: *mruby.mrb_state, _: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    const allocator = global_allocator orelse return mruby.mrb_nil_value();

    // Get URL argument and optional headers
    var url_ptr: [*c]const u8 = null;
    var url_len: mruby.mrb_int = 0;
    var headers_arr: mruby.mrb_value = mruby.mrb_nil_value();

    _ = mruby.mrb_get_args(mrb, "s|o", &url_ptr, &url_len, &headers_arr);

    if (url_ptr == null or url_len <= 0) {
        return mruby.mrb_nil_value();
    }

    const url = url_ptr[0..@intCast(url_len)];

    // Parse custom headers from mruby array
    var custom_headers = std.ArrayList([2][]const u8).empty;
    defer custom_headers.deinit(allocator);

    if (!isNil(headers_arr)) {
        parseHeadersArray(mrb, allocator, headers_arr, &custom_headers) catch {
            return mruby.mrb_nil_value();
        };
    }

    var response = requestWithHeaders(allocator, .GET, url, null, null, custom_headers.items) catch {
        return mruby.mrb_nil_value();
    };
    defer response.deinit();

    return createResponseArray(mrb, allocator, &response);
}

/// mruby binding: HTTP POST request
/// Args: url, body (optional), content_type (optional), headers_array (optional)
/// Returns array: [status_code, headers_hash, body_string]
pub fn zig_http_post(mrb: *mruby.mrb_state, _: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    const allocator = global_allocator orelse return mruby.mrb_nil_value();

    var url_ptr: [*c]const u8 = null;
    var url_len: mruby.mrb_int = 0;
    var body_ptr: [*c]const u8 = null;
    var body_len: mruby.mrb_int = 0;
    var ct_ptr: [*c]const u8 = null;
    var ct_len: mruby.mrb_int = 0;
    var headers_arr: mruby.mrb_value = mruby.mrb_nil_value();

    // Get arguments: url, body (optional), content_type (optional), headers (optional)
    _ = mruby.mrb_get_args(mrb, "s|sso", &url_ptr, &url_len, &body_ptr, &body_len, &ct_ptr, &ct_len, &headers_arr);

    if (url_ptr == null or url_len <= 0) {
        return mruby.mrb_nil_value();
    }

    const url = url_ptr[0..@intCast(url_len)];
    const body: ?[]const u8 = if (body_ptr != null and body_len > 0)
        body_ptr[0..@intCast(body_len)]
    else
        null;
    const content_type: ?[]const u8 = if (ct_ptr != null and ct_len > 0)
        ct_ptr[0..@intCast(ct_len)]
    else
        null;

    // Parse custom headers from mruby array
    var custom_headers = std.ArrayList([2][]const u8).empty;
    defer custom_headers.deinit(allocator);

    if (!isNil(headers_arr)) {
        parseHeadersArray(mrb, allocator, headers_arr, &custom_headers) catch {
            return mruby.mrb_nil_value();
        };
    }

    var response = requestWithHeaders(allocator, .POST, url, body, content_type, custom_headers.items) catch {
        return mruby.mrb_nil_value();
    };
    defer response.deinit();

    return createResponseArray(mrb, allocator, &response);
}

/// mruby binding: HTTP PUT request
/// Args: url, body (optional), content_type (optional), headers_array (optional)
/// Returns array: [status_code, headers_hash, body_string]
pub fn zig_http_put(mrb: *mruby.mrb_state, _: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    const allocator = global_allocator orelse return mruby.mrb_nil_value();

    var url_ptr: [*c]const u8 = null;
    var url_len: mruby.mrb_int = 0;
    var body_ptr: [*c]const u8 = null;
    var body_len: mruby.mrb_int = 0;
    var ct_ptr: [*c]const u8 = null;
    var ct_len: mruby.mrb_int = 0;
    var headers_arr: mruby.mrb_value = mruby.mrb_nil_value();

    _ = mruby.mrb_get_args(mrb, "s|sso", &url_ptr, &url_len, &body_ptr, &body_len, &ct_ptr, &ct_len, &headers_arr);

    if (url_ptr == null or url_len <= 0) {
        return mruby.mrb_nil_value();
    }

    const url = url_ptr[0..@intCast(url_len)];
    const body: ?[]const u8 = if (body_ptr != null and body_len > 0)
        body_ptr[0..@intCast(body_len)]
    else
        null;
    const content_type: ?[]const u8 = if (ct_ptr != null and ct_len > 0)
        ct_ptr[0..@intCast(ct_len)]
    else
        null;

    var custom_headers = std.ArrayList([2][]const u8).empty;
    defer custom_headers.deinit(allocator);

    if (!isNil(headers_arr)) {
        parseHeadersArray(mrb, allocator, headers_arr, &custom_headers) catch {
            return mruby.mrb_nil_value();
        };
    }

    var response = requestWithHeaders(allocator, .PUT, url, body, content_type, custom_headers.items) catch {
        return mruby.mrb_nil_value();
    };
    defer response.deinit();

    return createResponseArray(mrb, allocator, &response);
}

/// mruby binding: HTTP DELETE request
/// Args: url, headers_array (optional)
/// Returns array: [status_code, headers_hash, body_string]
pub fn zig_http_delete(mrb: *mruby.mrb_state, _: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    const allocator = global_allocator orelse return mruby.mrb_nil_value();

    var url_ptr: [*c]const u8 = null;
    var url_len: mruby.mrb_int = 0;
    var headers_arr: mruby.mrb_value = mruby.mrb_nil_value();

    _ = mruby.mrb_get_args(mrb, "s|o", &url_ptr, &url_len, &headers_arr);

    if (url_ptr == null or url_len <= 0) {
        return mruby.mrb_nil_value();
    }

    const url = url_ptr[0..@intCast(url_len)];

    var custom_headers = std.ArrayList([2][]const u8).empty;
    defer custom_headers.deinit(allocator);

    if (!isNil(headers_arr)) {
        parseHeadersArray(mrb, allocator, headers_arr, &custom_headers) catch {
            return mruby.mrb_nil_value();
        };
    }

    var response = requestWithHeaders(allocator, .DELETE, url, null, null, custom_headers.items) catch {
        return mruby.mrb_nil_value();
    };
    defer response.deinit();

    return createResponseArray(mrb, allocator, &response);
}

/// mruby binding: HTTP PATCH request
/// Args: url, body (optional), content_type (optional), headers_array (optional)
/// Returns array: [status_code, headers_hash, body_string]
pub fn zig_http_patch(mrb: *mruby.mrb_state, _: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    const allocator = global_allocator orelse return mruby.mrb_nil_value();

    var url_ptr: [*c]const u8 = null;
    var url_len: mruby.mrb_int = 0;
    var body_ptr: [*c]const u8 = null;
    var body_len: mruby.mrb_int = 0;
    var ct_ptr: [*c]const u8 = null;
    var ct_len: mruby.mrb_int = 0;
    var headers_arr: mruby.mrb_value = mruby.mrb_nil_value();

    _ = mruby.mrb_get_args(mrb, "s|sso", &url_ptr, &url_len, &body_ptr, &body_len, &ct_ptr, &ct_len, &headers_arr);

    if (url_ptr == null or url_len <= 0) {
        return mruby.mrb_nil_value();
    }

    const url = url_ptr[0..@intCast(url_len)];
    const body: ?[]const u8 = if (body_ptr != null and body_len > 0)
        body_ptr[0..@intCast(body_len)]
    else
        null;
    const content_type: ?[]const u8 = if (ct_ptr != null and ct_len > 0)
        ct_ptr[0..@intCast(ct_len)]
    else
        null;

    var custom_headers = std.ArrayList([2][]const u8).empty;
    defer custom_headers.deinit(allocator);

    if (!isNil(headers_arr)) {
        parseHeadersArray(mrb, allocator, headers_arr, &custom_headers) catch {
            return mruby.mrb_nil_value();
        };
    }

    var response = requestWithHeaders(allocator, .PATCH, url, body, content_type, custom_headers.items) catch {
        return mruby.mrb_nil_value();
    };
    defer response.deinit();

    return createResponseArray(mrb, allocator, &response);
}

fn isNil(val: mruby.mrb_value) bool {
    return val.w == 0;
}

fn parseHeadersArray(
    mrb: *mruby.mrb_state,
    allocator: std.mem.Allocator,
    headers_arr: mruby.mrb_value,
    custom_headers: *std.ArrayList([2][]const u8),
) !void {
    const arr_len = mruby.mrb_ary_len(mrb, headers_arr);
    for (0..@intCast(arr_len)) |i| {
        const pair = mruby.mrb_ary_ref(mrb, headers_arr, @intCast(i));
        if (mruby.mrb_ary_len(mrb, pair) >= 2) {
            const key_val = mruby.mrb_ary_ref(mrb, pair, 0);
            const val_val = mruby.mrb_ary_ref(mrb, pair, 1);

            const key_cstr = mruby.mrb_str_to_cstr(mrb, key_val);
            const val_cstr = mruby.mrb_str_to_cstr(mrb, val_val);

            if (key_cstr != null and val_cstr != null) {
                try custom_headers.append(allocator, .{
                    std.mem.span(key_cstr),
                    std.mem.span(val_cstr),
                });
            }
        }
    }
}

/// Perform HTTP request with custom headers
pub fn requestWithHeaders(
    allocator: std.mem.Allocator,
    method: std.http.Method,
    url: []const u8,
    body: ?[]const u8,
    content_type: ?[]const u8,
    custom_headers: [][2][]const u8,
) !Response {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(url);

    var req = try client.request(method, uri, .{
        .redirect_behavior = @enumFromInt(10),
    });
    defer req.deinit();

    // Set User-Agent header
    const user_agent = try getUserAgent(allocator);
    defer allocator.free(user_agent);
    req.headers.user_agent = .{ .override = user_agent };

    // Set content-type header if provided
    if (content_type) |ct| {
        req.headers.content_type = .{ .override = ct };
    }

    // Set custom headers using extra_headers
    // Note: must keep the allocation alive until after request is sent
    var extra: ?[]std.http.Header = null;
    defer if (extra) |e| allocator.free(e);

    if (custom_headers.len > 0) {
        extra = try allocator.alloc(std.http.Header, custom_headers.len);

        for (custom_headers, 0..) |header, i| {
            extra.?[i] = .{ .name = header[0], .value = header[1] };
        }
        req.extra_headers = extra.?;
    }

    // Send request with or without body
    if (body) |b| {
        req.transfer_encoding = .{ .content_length = b.len };
        // Use heap allocation for body buffer to avoid stack size issues
        const body_buf = try allocator.alloc(u8, @max(b.len, 8192));
        defer allocator.free(body_buf);
        @memcpy(body_buf[0..b.len], b);
        try req.sendBodyComplete(body_buf[0..b.len]);
    } else {
        // For methods that can have a body (PUT, POST, PATCH), send empty body
        // For methods that cannot have a body (GET, DELETE), use sendBodiless
        if (method == .PUT or method == .POST or method == .PATCH) {
            req.transfer_encoding = .{ .content_length = 0 };
            try req.sendBodyComplete(&[_]u8{});
        } else {
            try req.sendBodiless();
        }
    }

    // Receive response
    var redirect_buffer: [8192]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);

    // Parse response headers
    var response_headers = std.StringHashMap([]const u8).init(allocator);
    errdefer {
        var it = response_headers.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        response_headers.deinit();
    }

    // Extract common headers
    if (response.head.content_type) |ct| {
        const key = try allocator.dupe(u8, "content-type");
        const value = try allocator.dupe(u8, ct);
        try response_headers.put(key, value);
    }

    // Read body
    var body_list = std.ArrayList(u8).empty;
    defer body_list.deinit(allocator);

    var transfer_buffer: [64 * 1024]u8 = undefined;
    var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var body_reader = response.readerDecompressing(&transfer_buffer, &decompress, &decompress_buffer);

    var buffer: [64 * 1024]u8 = undefined;

    while (true) {
        const bytes_read = body_reader.readSliceShort(&buffer) catch |err| {
            std.log.warn("Error reading HTTP body: {}", .{err});
            break;
        };
        if (bytes_read == 0) break;
        body_list.appendSlice(allocator, buffer[0..bytes_read]) catch break;
        if (bytes_read < buffer.len) break;
    }

    const response_body = allocator.dupe(u8, body_list.items) catch &[_]u8{};

    return Response{
        .status = @intFromEnum(response.head.status),
        .headers = response_headers,
        .body = response_body,
        .allocator = allocator,
    };
}

fn createResponseArray(mrb: *mruby.mrb_state, _: std.mem.Allocator, response: *Response) mruby.mrb_value {
    // Create result array [status, headers, body]
    const result = mruby.mrb_ary_new_capa(mrb, 3);

    // Add status code
    mruby.mrb_ary_push(mrb, result, mruby.mrb_int_value(mrb, @intCast(response.status)));

    // Add headers as hash
    const headers_hash = mruby.mrb_hash_new(mrb);
    var it = response.headers.iterator();
    while (it.next()) |entry| {
        const key = mruby.mrb_str_new(mrb, entry.key_ptr.*.ptr, @intCast(entry.key_ptr.*.len));
        const value = mruby.mrb_str_new(mrb, entry.value_ptr.*.ptr, @intCast(entry.value_ptr.*.len));
        mruby.mrb_hash_set(mrb, headers_hash, key, value);
    }
    mruby.mrb_ary_push(mrb, result, headers_hash);

    // Add body
    const body_str = mruby.mrb_str_new(mrb, response.body.ptr, @intCast(response.body.len));
    mruby.mrb_ary_push(mrb, result, body_str);

    return result;
}

pub const ruby_prelude = @embedFile("ruby_prelude/http_client.rb");

// MRuby module registration interface
const mruby_module = @import("mruby_module.zig");

const http_functions = [_]mruby_module.ModuleFunction{
    .{ .name = "http_get", .func = zig_http_get, .args = mruby.MRB_ARGS_REQ(1) | mruby.MRB_ARGS_OPT(1) },
    .{ .name = "http_post", .func = zig_http_post, .args = mruby.MRB_ARGS_REQ(1) | mruby.MRB_ARGS_OPT(3) },
    .{ .name = "http_put", .func = zig_http_put, .args = mruby.MRB_ARGS_REQ(1) | mruby.MRB_ARGS_OPT(3) },
    .{ .name = "http_delete", .func = zig_http_delete, .args = mruby.MRB_ARGS_REQ(1) | mruby.MRB_ARGS_OPT(1) },
    .{ .name = "http_patch", .func = zig_http_patch, .args = mruby.MRB_ARGS_REQ(1) | mruby.MRB_ARGS_OPT(3) },
};

fn getFunctions() []const mruby_module.ModuleFunction {
    return &http_functions;
}

fn getPrelude() []const u8 {
    return ruby_prelude;
}

pub const mruby_module_def = mruby_module.MRubyModule{
    .name = "HTTP",
    .initFn = setAllocator,
    .getFunctions = getFunctions,
    .getPrelude = getPrelude,
};
