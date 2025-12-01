const std = @import("std");
const mruby = @import("../mruby.zig");
const mruby_module = @import("../mruby_module.zig");
const http = @import("../http.zig");

// Global allocator for mruby callbacks
var global_allocator: ?std.mem.Allocator = null;

pub fn setAllocator(allocator: std.mem.Allocator) void {
    global_allocator = allocator;
}

// Helper to check if value is nil
fn isNil(val: mruby.mrb_value) bool {
    return val.w == 0;
}

/// Parse headers from mruby array of [key, value] pairs into StringHashMap
fn parseHeadersArray(
    mrb: *mruby.mrb_state,
    allocator: std.mem.Allocator,
    headers_arr: mruby.mrb_value,
) !std.StringHashMap([]const u8) {
    var headers = std.StringHashMap([]const u8).init(allocator);

    if (isNil(headers_arr)) {
        return headers;
    }

    const len = mruby.zig_mrb_ary_len(mrb, headers_arr);
    var i: i32 = 0;
    while (i < len) : (i += 1) {
        const pair = mruby.zig_mrb_ary_ref(mrb, headers_arr, i);
        if (mruby.zig_mrb_ary_len(mrb, pair) != 2) continue;

        const key_val = mruby.zig_mrb_ary_ref(mrb, pair, 0);
        const val_val = mruby.zig_mrb_ary_ref(mrb, pair, 1);

        const key_ptr = mruby.mrb_str_to_cstr(mrb, key_val);
        const val_ptr = mruby.mrb_str_to_cstr(mrb, val_val);

        const key_str = std.mem.span(key_ptr);
        const val_str = std.mem.span(val_ptr);

        const key = try allocator.dupe(u8, key_str);
        const val = try allocator.dupe(u8, val_str);

        try headers.put(key, val);
    }

    return headers;
}

/// Create mruby response array: [status_code, headers_hash, body_string]
fn createResponseArray(
    mrb: *mruby.mrb_state,
    allocator: std.mem.Allocator,
    response: *http.Response,
) mruby.mrb_value {
    _ = allocator;

    // Create array to return
    const result = mruby.mrb_ary_new_capa(mrb, 3);

    // Add status code
    mruby.mrb_ary_push(mrb, result, mruby.mrb_int_value(mrb, @intCast(response.status)));

    // Add headers hash
    const headers_hash = mruby.mrb_hash_new(mrb);
    var it = response.headers.iterator();
    while (it.next()) |entry| {
        const key = mruby.mrb_str_new(mrb, entry.key_ptr.*.ptr, @intCast(entry.key_ptr.*.len));
        const val = mruby.mrb_str_new(mrb, entry.value_ptr.*.ptr, @intCast(entry.value_ptr.*.len));
        mruby.mrb_hash_set(mrb, headers_hash, key, val);
    }
    mruby.mrb_ary_push(mrb, result, headers_hash);

    // Add body
    const body = mruby.mrb_str_new(mrb, response.body.ptr, @intCast(response.body.len));
    mruby.mrb_ary_push(mrb, result, body);

    return result;
}

/// Common request execution logic
/// Handles headers cleanup, client creation, request execution, and response creation
fn executeHttpRequest(
    mrb: *mruby.mrb_state,
    allocator: std.mem.Allocator,
    method: http.Method,
    url: []const u8,
    body: ?[]const u8,
    headers_opt: ?std.StringHashMap([]const u8),
) mruby.mrb_value {
    var headers = headers_opt;
    defer if (headers) |*h| {
        var it = h.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        h.deinit();
    };

    // Create client and execute request
    const cfg = http.Config{};
    var client = http.Client.init(allocator, cfg) catch {
        return mruby.mrb_nil_value();
    };
    defer client.deinit();

    // Build request
    var req = http.Request.init(method, url);
    req.body = body;
    req.headers = headers;

    var response = client.request(req) catch {
        return mruby.mrb_nil_value();
    };
    defer response.deinit();

    return createResponseArray(mrb, allocator, &response);
}

/// Parse optional Content-Type and add to headers
fn addContentTypeHeader(
    allocator: std.mem.Allocator,
    headers: *?std.StringHashMap([]const u8),
    content_type: ?[]const u8,
) !void {
    if (content_type) |ct| {
        if (headers.* == null) {
            headers.* = std.StringHashMap([]const u8).init(allocator);
        }
        const key = try allocator.dupe(u8, "Content-Type");
        const val = try allocator.dupe(u8, ct);
        try headers.*.?.put(key, val);
    }
}

/// mruby binding: HTTP GET request
/// Args: url, headers_array (optional) - array of [key, value] pairs
/// Returns array: [status_code, headers_hash, body_string]
pub fn zig_http_get(mrb: *mruby.mrb_state, _: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    const allocator = global_allocator orelse return mruby.mrb_nil_value();

    var url_ptr: [*c]const u8 = null;
    var url_len: mruby.mrb_int = 0;
    var headers_arr: mruby.mrb_value = mruby.mrb_nil_value();

    _ = mruby.mrb_get_args(mrb, "s|o", &url_ptr, &url_len, &headers_arr);

    if (url_ptr == null or url_len <= 0) {
        return mruby.mrb_nil_value();
    }

    const url = url_ptr[0..@intCast(url_len)];

    // Parse custom headers if provided
    const headers = if (!isNil(headers_arr))
        parseHeadersArray(mrb, allocator, headers_arr) catch return mruby.mrb_nil_value()
    else
        null;

    return executeHttpRequest(mrb, allocator, .GET, url, null, headers);
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

    // Parse custom headers and add Content-Type if provided
    var headers = if (!isNil(headers_arr))
        parseHeadersArray(mrb, allocator, headers_arr) catch return mruby.mrb_nil_value()
    else
        null;

    addContentTypeHeader(allocator, &headers, content_type) catch return mruby.mrb_nil_value();

    return executeHttpRequest(mrb, allocator, .POST, url, body, headers);
}

/// mruby binding: HTTP PUT request
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

    // Parse custom headers and add Content-Type if provided
    var headers = if (!isNil(headers_arr))
        parseHeadersArray(mrb, allocator, headers_arr) catch return mruby.mrb_nil_value()
    else
        null;

    addContentTypeHeader(allocator, &headers, content_type) catch return mruby.mrb_nil_value();

    return executeHttpRequest(mrb, allocator, .PUT, url, body, headers);
}

/// mruby binding: HTTP DELETE request
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

    // Parse custom headers if provided
    const headers = if (!isNil(headers_arr))
        parseHeadersArray(mrb, allocator, headers_arr) catch return mruby.mrb_nil_value()
    else
        null;

    return executeHttpRequest(mrb, allocator, .DELETE, url, null, headers);
}

/// mruby binding: HTTP PATCH request
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

    // Parse custom headers and add Content-Type if provided
    var headers = if (!isNil(headers_arr))
        parseHeadersArray(mrb, allocator, headers_arr) catch return mruby.mrb_nil_value()
    else
        null;

    addContentTypeHeader(allocator, &headers, content_type) catch return mruby.mrb_nil_value();

    return executeHttpRequest(mrb, allocator, .PATCH, url, body, headers);
}

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

const ruby_prelude = @embedFile("../ruby_prelude/http_client.rb");

fn getPrelude() []const u8 {
    return ruby_prelude;
}

pub const mruby_module_def = mruby_module.MRubyModule{
    .name = "HTTP",
    .initFn = setAllocator,
    .getFunctions = getFunctions,
    .getPrelude = getPrelude,
};
