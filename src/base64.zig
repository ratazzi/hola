const std = @import("std");
const mruby = @import("mruby.zig");

// Global allocator for mruby callbacks
var global_allocator: ?std.mem.Allocator = null;

pub fn setAllocator(allocator: std.mem.Allocator) void {
    global_allocator = allocator;
}

/// mruby binding: Base64.encode(str) - encode string to Base64
pub fn zig_base64_encode(mrb: *mruby.mrb_state, _: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    const allocator = global_allocator orelse return mruby.mrb_nil_value();

    var str_ptr: [*c]const u8 = null;
    var str_len: mruby.mrb_int = 0;
    _ = mruby.mrb_get_args(mrb, "s", &str_ptr, &str_len);

    if (str_ptr == null or str_len < 0) {
        return mruby.mrb_nil_value();
    }

    const input = str_ptr[0..@intCast(str_len)];

    // Calculate output size
    const encoded_len = std.base64.standard.Encoder.calcSize(input.len);
    const encoded = allocator.alloc(u8, encoded_len) catch return mruby.mrb_nil_value();
    defer allocator.free(encoded);

    // Encode
    const result = std.base64.standard.Encoder.encode(encoded, input);

    return mruby.mrb_str_new(mrb, result.ptr, @intCast(result.len));
}

/// mruby binding: Base64.decode(str) - decode Base64 string
pub fn zig_base64_decode(mrb: *mruby.mrb_state, _: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    const allocator = global_allocator orelse return mruby.mrb_nil_value();

    var str_ptr: [*c]const u8 = null;
    var str_len: mruby.mrb_int = 0;
    _ = mruby.mrb_get_args(mrb, "s", &str_ptr, &str_len);

    if (str_ptr == null or str_len < 0) {
        return mruby.mrb_nil_value();
    }

    const input = str_ptr[0..@intCast(str_len)];

    // Calculate output size
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(input) catch return mruby.mrb_nil_value();
    const decoded = allocator.alloc(u8, decoded_len) catch return mruby.mrb_nil_value();
    defer allocator.free(decoded);

    // Decode
    std.base64.standard.Decoder.decode(decoded, input) catch return mruby.mrb_nil_value();

    return mruby.mrb_str_new(mrb, decoded.ptr, @intCast(decoded.len));
}

/// mruby binding: Base64.urlsafe_encode(str) - encode string to URL-safe Base64
pub fn zig_base64_urlsafe_encode(mrb: *mruby.mrb_state, _: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    const allocator = global_allocator orelse return mruby.mrb_nil_value();

    var str_ptr: [*c]const u8 = null;
    var str_len: mruby.mrb_int = 0;
    _ = mruby.mrb_get_args(mrb, "s", &str_ptr, &str_len);

    if (str_ptr == null or str_len < 0) {
        return mruby.mrb_nil_value();
    }

    const input = str_ptr[0..@intCast(str_len)];

    // Calculate output size
    const encoded_len = std.base64.url_safe_no_pad.Encoder.calcSize(input.len);
    const encoded = allocator.alloc(u8, encoded_len) catch return mruby.mrb_nil_value();
    defer allocator.free(encoded);

    // Encode
    const result = std.base64.url_safe_no_pad.Encoder.encode(encoded, input);

    return mruby.mrb_str_new(mrb, result.ptr, @intCast(result.len));
}

/// mruby binding: Base64.urlsafe_decode(str) - decode URL-safe Base64 string
pub fn zig_base64_urlsafe_decode(mrb: *mruby.mrb_state, _: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    const allocator = global_allocator orelse return mruby.mrb_nil_value();

    var str_ptr: [*c]const u8 = null;
    var str_len: mruby.mrb_int = 0;
    _ = mruby.mrb_get_args(mrb, "s", &str_ptr, &str_len);

    if (str_ptr == null or str_len < 0) {
        return mruby.mrb_nil_value();
    }

    const input = str_ptr[0..@intCast(str_len)];

    // Calculate output size
    const decoded_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(input) catch return mruby.mrb_nil_value();
    const decoded = allocator.alloc(u8, decoded_len) catch return mruby.mrb_nil_value();
    defer allocator.free(decoded);

    // Decode
    std.base64.url_safe_no_pad.Decoder.decode(decoded, input) catch return mruby.mrb_nil_value();

    return mruby.mrb_str_new(mrb, decoded.ptr, @intCast(decoded.len));
}

pub const ruby_prelude = @embedFile("ruby_prelude/base64.rb");

// MRuby module registration interface
const mruby_module = @import("mruby_module.zig");

const base64_functions = [_]mruby_module.ModuleFunction{
    .{ .name = "base64_encode", .func = zig_base64_encode, .args = mruby.MRB_ARGS_REQ(1) },
    .{ .name = "base64_decode", .func = zig_base64_decode, .args = mruby.MRB_ARGS_REQ(1) },
    .{ .name = "base64_urlsafe_encode", .func = zig_base64_urlsafe_encode, .args = mruby.MRB_ARGS_REQ(1) },
    .{ .name = "base64_urlsafe_decode", .func = zig_base64_urlsafe_decode, .args = mruby.MRB_ARGS_REQ(1) },
};

fn getFunctions() []const mruby_module.ModuleFunction {
    return &base64_functions;
}

fn getPrelude() []const u8 {
    return ruby_prelude;
}

pub const mruby_module_def = mruby_module.MRubyModule{
    .name = "Base64",
    .initFn = setAllocator,
    .getFunctions = getFunctions,
    .getPrelude = getPrelude,
};
