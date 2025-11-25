const std = @import("std");
const mruby = @import("mruby.zig");
const logger = @import("logger.zig");

/// mruby binding: Hola.debug(msg) - log debug message
pub fn zig_hola_debug(mrb: *mruby.mrb_state, _: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    var str_ptr: [*c]const u8 = null;
    var str_len: mruby.mrb_int = 0;
    _ = mruby.mrb_get_args(mrb, "s", &str_ptr, &str_len);

    if (str_ptr == null or str_len < 0) {
        return mruby.mrb_nil_value();
    }

    const msg = str_ptr[0..@intCast(str_len)];
    logger.debug("{s}", .{msg});

    return mruby.mrb_nil_value();
}

/// mruby binding: Hola.info(msg) - log info message
pub fn zig_hola_info(mrb: *mruby.mrb_state, _: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    var str_ptr: [*c]const u8 = null;
    var str_len: mruby.mrb_int = 0;
    _ = mruby.mrb_get_args(mrb, "s", &str_ptr, &str_len);

    if (str_ptr == null or str_len < 0) {
        return mruby.mrb_nil_value();
    }

    const msg = str_ptr[0..@intCast(str_len)];
    logger.info("{s}", .{msg});

    return mruby.mrb_nil_value();
}

/// mruby binding: Hola.warn(msg) - log warning message
pub fn zig_hola_warn(mrb: *mruby.mrb_state, _: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    var str_ptr: [*c]const u8 = null;
    var str_len: mruby.mrb_int = 0;
    _ = mruby.mrb_get_args(mrb, "s", &str_ptr, &str_len);

    if (str_ptr == null or str_len < 0) {
        return mruby.mrb_nil_value();
    }

    const msg = str_ptr[0..@intCast(str_len)];
    logger.warn("{s}", .{msg});

    return mruby.mrb_nil_value();
}

/// mruby binding: Hola.error(msg) - log error message
pub fn zig_hola_error(mrb: *mruby.mrb_state, _: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    var str_ptr: [*c]const u8 = null;
    var str_len: mruby.mrb_int = 0;
    _ = mruby.mrb_get_args(mrb, "s", &str_ptr, &str_len);

    if (str_ptr == null or str_len < 0) {
        return mruby.mrb_nil_value();
    }

    const msg = str_ptr[0..@intCast(str_len)];
    logger.err("{s}", .{msg});

    return mruby.mrb_nil_value();
}

/// Ruby prelude for Hola module
pub const ruby_prelude = @embedFile("ruby_prelude/hola_logger.rb");

// MRuby module registration interface
const mruby_module = @import("mruby_module.zig");

const hola_logger_functions = [_]mruby_module.ModuleFunction{
    .{ .name = "hola_debug", .func = zig_hola_debug, .args = mruby.MRB_ARGS_REQ(1) },
    .{ .name = "hola_info", .func = zig_hola_info, .args = mruby.MRB_ARGS_REQ(1) },
    .{ .name = "hola_warn", .func = zig_hola_warn, .args = mruby.MRB_ARGS_REQ(1) },
    .{ .name = "hola_error", .func = zig_hola_error, .args = mruby.MRB_ARGS_REQ(1) },
};

fn getFunctions() []const mruby_module.ModuleFunction {
    return &hola_logger_functions;
}

fn getPrelude() []const u8 {
    return ruby_prelude;
}

pub const mruby_module_def = mruby_module.MRubyModule{
    .name = "Logger",
    .getFunctions = getFunctions,
    .getPrelude = getPrelude,
};
