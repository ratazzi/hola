const std = @import("std");
const mruby = @import("mruby.zig");
const c = @cImport({
    @cInclude("stdlib.h");
});

// C helper functions for mruby true/false values
extern fn zig_mrb_true_value() mruby.mrb_value;
extern fn zig_mrb_false_value() mruby.mrb_value;

var global_allocator: ?std.mem.Allocator = null;

pub fn setAllocator(allocator: std.mem.Allocator) void {
    global_allocator = allocator;
}

/// mruby binding: env_get(key) - get environment variable
pub fn zig_env_get(mrb: *mruby.mrb_state, _: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    const allocator = global_allocator orelse return mruby.mrb_nil_value();

    var key_ptr: [*c]const u8 = null;
    var key_len: mruby.mrb_int = 0;
    _ = mruby.mrb_get_args(mrb, "s", &key_ptr, &key_len);

    if (key_ptr == null or key_len < 0) {
        return mruby.mrb_nil_value();
    }

    const key = key_ptr[0..@intCast(key_len)];

    // Get environment variable
    const value = std.process.getEnvVarOwned(allocator, key) catch {
        return mruby.mrb_nil_value();
    };
    defer allocator.free(value);

    return mruby.mrb_str_new(mrb, value.ptr, @intCast(value.len));
}

/// mruby binding: env_set(key, value) - set environment variable
pub fn zig_env_set(mrb: *mruby.mrb_state, _: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    const allocator = global_allocator orelse return mruby.mrb_nil_value();

    var key_ptr: [*c]const u8 = null;
    var key_len: mruby.mrb_int = 0;
    var val_ptr: [*c]const u8 = null;
    var val_len: mruby.mrb_int = 0;

    _ = mruby.mrb_get_args(mrb, "ss", &key_ptr, &key_len, &val_ptr, &val_len);

    if (key_ptr == null or key_len < 0) {
        return mruby.mrb_nil_value();
    }

    const value = if (val_ptr != null and val_len >= 0)
        val_ptr[0..@intCast(val_len)]
    else
        "";

    // Need null-terminated strings for setenv
    const key_z = allocator.dupeZ(u8, key_ptr[0..@intCast(key_len)]) catch return mruby.mrb_nil_value();
    defer allocator.free(key_z);
    const val_z = allocator.dupeZ(u8, value) catch return mruby.mrb_nil_value();
    defer allocator.free(val_z);

    // Set environment variable using libc
    const result = c.setenv(key_z.ptr, val_z.ptr, 1);
    if (result != 0) {
        return mruby.mrb_nil_value();
    }

    return mruby.mrb_str_new(mrb, value.ptr, @intCast(value.len));
}

/// mruby binding: env_delete(key) - delete environment variable
pub fn zig_env_delete(mrb: *mruby.mrb_state, _: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    const allocator = global_allocator orelse return mruby.mrb_nil_value();

    var key_ptr: [*c]const u8 = null;
    var key_len: mruby.mrb_int = 0;

    _ = mruby.mrb_get_args(mrb, "s", &key_ptr, &key_len);

    if (key_ptr == null or key_len < 0) {
        return mruby.mrb_nil_value();
    }

    // Need null-terminated string for unsetenv
    const key_z = allocator.dupeZ(u8, key_ptr[0..@intCast(key_len)]) catch return mruby.mrb_nil_value();
    defer allocator.free(key_z);

    // Unset environment variable using libc
    _ = c.unsetenv(key_z.ptr);

    return mruby.mrb_nil_value();
}

/// mruby binding: env_has_key(key) - check if environment variable exists
pub fn zig_env_has_key(mrb: *mruby.mrb_state, _: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    const allocator = global_allocator orelse return zig_mrb_false_value();

    var key_ptr: [*c]const u8 = null;
    var key_len: mruby.mrb_int = 0;
    _ = mruby.mrb_get_args(mrb, "s", &key_ptr, &key_len);

    if (key_ptr == null or key_len < 0) {
        return zig_mrb_false_value();
    }

    const key = key_ptr[0..@intCast(key_len)];

    // Check if environment variable exists
    if (std.process.getEnvVarOwned(allocator, key)) |value| {
        allocator.free(value);
        return zig_mrb_true_value();
    } else |_| {
        return zig_mrb_false_value();
    }
}

/// Ruby prelude for ENV object
pub const ruby_prelude = @embedFile("ruby_prelude/env_access.rb");

// MRuby module registration interface
const mruby_module = @import("mruby_module.zig");

const env_access_functions = [_]mruby_module.ModuleFunction{
    .{ .name = "env_get", .func = zig_env_get, .args = mruby.MRB_ARGS_REQ(1) },
    .{ .name = "env_set", .func = zig_env_set, .args = mruby.MRB_ARGS_REQ(2) },
    .{ .name = "env_delete", .func = zig_env_delete, .args = mruby.MRB_ARGS_REQ(1) },
    .{ .name = "env_has_key", .func = zig_env_has_key, .args = mruby.MRB_ARGS_REQ(1) },
};

fn getFunctions() []const mruby_module.ModuleFunction {
    return &env_access_functions;
}

fn getPrelude() []const u8 {
    return ruby_prelude;
}

pub const mruby_module_def = mruby_module.MRubyModule{
    .name = "ENV",
    .initFn = setAllocator,
    .getFunctions = getFunctions,
    .getPrelude = getPrelude,
};
