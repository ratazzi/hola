const std = @import("std");
const mruby = @import("mruby.zig");
const mruby_module = @import("mruby_module.zig");
const logger = @import("logger.zig");

// Extend Ruby's File class with stat and mtime methods

fn file_stat(mrb: ?*mruby.mrb_state, _: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    const state = mrb.?;
    var path_ptr: [*c]const u8 = null;
    var path_len: mruby.mrb_int = 0;

    _ = mruby.mrb_get_args(state, "s", &path_ptr, &path_len);

    if (path_ptr == null or path_len <= 0) {
        const err_msg = mruby.mrb_str_new(state, "invalid file path", 17);
        const exc_class = mruby.mrb_class_get(state, "ArgumentError");
        mruby.mrb_raise(state, exc_class, mruby.mrb_str_to_cstr(state, err_msg));
    }

    const path = path_ptr[0..@intCast(path_len)];

    // Get file stats using std.fs
    // For absolute paths use openFileAbsolute, for relative use cwd
    const file = if (std.fs.path.isAbsolute(path))
        std.fs.openFileAbsolute(path, .{}) catch {
            const allocator = std.heap.c_allocator;
            const err_msg = std.fmt.allocPrint(allocator, "No such file or directory - {s}\x00", .{path}) catch {
                const fallback_msg = mruby.mrb_str_new(state, "file not found", 14);
                const exc_class = mruby.mrb_class_get(state, "RuntimeError");
                mruby.mrb_raise(state, exc_class, mruby.mrb_str_to_cstr(state, fallback_msg));
            };
            defer allocator.free(err_msg);

            const msg_val = mruby.mrb_str_new(state, err_msg.ptr, @intCast(err_msg.len - 1));
            const exc_class = mruby.mrb_class_get(state, "RuntimeError");
            mruby.mrb_raise(state, exc_class, mruby.mrb_str_to_cstr(state, msg_val));
        }
    else
        std.fs.cwd().openFile(path, .{}) catch {
            const allocator = std.heap.c_allocator;
            const err_msg = std.fmt.allocPrint(allocator, "No such file or directory - {s}\x00", .{path}) catch {
                const fallback_msg = mruby.mrb_str_new(state, "file not found", 14);
                const exc_class = mruby.mrb_class_get(state, "RuntimeError");
                mruby.mrb_raise(state, exc_class, mruby.mrb_str_to_cstr(state, fallback_msg));
            };
            defer allocator.free(err_msg);

            const msg_val = mruby.mrb_str_new(state, err_msg.ptr, @intCast(err_msg.len - 1));
            const exc_class = mruby.mrb_class_get(state, "RuntimeError");
            mruby.mrb_raise(state, exc_class, mruby.mrb_str_to_cstr(state, msg_val));
        };
    defer file.close();

    const stat_result = file.stat() catch {
        const err_msg = mruby.mrb_str_new(state, "failed to get file stats", 24);
        const exc_class = mruby.mrb_class_get(state, "RuntimeError");
        mruby.mrb_raise(state, exc_class, mruby.mrb_str_to_cstr(state, err_msg));
    };

    // Create a FileStat object (Ruby hash with stat info)
    const hash = mruby.mrb_hash_new(state);

    // Add mtime (modification time) - convert nanoseconds to seconds
    const mtime_sec: i64 = @intCast(@divTrunc(stat_result.mtime, std.time.ns_per_s));
    const mtime_val = mruby.zig_mrb_int_value(state, mtime_sec);
    const mtime_key = mruby.mrb_str_new(state, "mtime", 5);
    mruby.mrb_hash_set(state, hash, mtime_key, mtime_val);

    // Add atime (access time) - convert nanoseconds to seconds
    const atime_sec: i64 = @intCast(@divTrunc(stat_result.atime, std.time.ns_per_s));
    const atime_val = mruby.zig_mrb_int_value(state, atime_sec);
    const atime_key = mruby.mrb_str_new(state, "atime", 5);
    mruby.mrb_hash_set(state, hash, atime_key, atime_val);

    // Add size
    const size: i64 = @intCast(stat_result.size);
    const size_val = mruby.zig_mrb_int_value(state, size);
    const size_key = mruby.mrb_str_new(state, "size", 4);
    mruby.mrb_hash_set(state, hash, size_key, size_val);

    // Add mode
    const mode: i64 = @intCast(stat_result.mode);
    const mode_val = mruby.zig_mrb_int_value(state, mode);
    const mode_key = mruby.mrb_str_new(state, "mode", 4);
    mruby.mrb_hash_set(state, hash, mode_key, mode_val);

    // Wrap hash in File::Stat object
    const file_class = mruby.mrb_class_get(state, "File");
    const stat_class = mruby.mrb_class_get_under(state, file_class, "Stat");
    const new_sym = mruby.mrb_intern_cstr(state, "new");

    return mruby.mrb_funcall_argv(state, mruby.mrb_obj_value(stat_class), new_sym, 1, &hash);
}

fn file_mtime(mrb: ?*mruby.mrb_state, _: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    const state = mrb.?;
    var path_ptr: [*c]const u8 = null;
    var path_len: mruby.mrb_int = 0;

    _ = mruby.mrb_get_args(state, "s", &path_ptr, &path_len);

    if (path_ptr == null or path_len <= 0) {
        // Raise an error instead of returning nil
        const err_msg = mruby.mrb_str_new(state, "invalid file path", 17);
        const exc_class = mruby.mrb_class_get(state, "ArgumentError");
        mruby.mrb_raise(state, exc_class, mruby.mrb_str_to_cstr(state, err_msg));
        return mruby.mrb_nil_value(); // Unreachable but required for type
    }

    const path = path_ptr[0..@intCast(path_len)];

    // Get file stats using std.fs
    // For absolute paths use openFileAbsolute, for relative use cwd
    const file = if (std.fs.path.isAbsolute(path))
        std.fs.openFileAbsolute(path, .{}) catch {
            // Raise Errno::ENOENT instead of returning nil
            const allocator = std.heap.c_allocator;
            const err_msg = std.fmt.allocPrint(allocator, "No such file or directory - {s}\x00", .{path}) catch {
                const fallback_msg = mruby.mrb_str_new(state, "file not found", 14);
                const exc_class = mruby.mrb_class_get(state, "RuntimeError");
                mruby.mrb_raise(state, exc_class, mruby.mrb_str_to_cstr(state, fallback_msg));
            };
            defer allocator.free(err_msg);

            const msg_val = mruby.mrb_str_new(state, err_msg.ptr, @intCast(err_msg.len - 1));
            const exc_class = mruby.mrb_class_get(state, "RuntimeError");
            mruby.mrb_raise(state, exc_class, mruby.mrb_str_to_cstr(state, msg_val));
        }
    else
        std.fs.cwd().openFile(path, .{}) catch {
            // Raise error for file not found
            const allocator = std.heap.c_allocator;
            const err_msg = std.fmt.allocPrint(allocator, "No such file or directory - {s}\x00", .{path}) catch {
                const fallback_msg = mruby.mrb_str_new(state, "file not found", 14);
                const exc_class = mruby.mrb_class_get(state, "RuntimeError");
                mruby.mrb_raise(state, exc_class, mruby.mrb_str_to_cstr(state, fallback_msg));
            };
            defer allocator.free(err_msg);

            const msg_val = mruby.mrb_str_new(state, err_msg.ptr, @intCast(err_msg.len - 1));
            const exc_class = mruby.mrb_class_get(state, "RuntimeError");
            mruby.mrb_raise(state, exc_class, mruby.mrb_str_to_cstr(state, msg_val));
        };
    defer file.close();

    const stat_result = file.stat() catch {
        const err_msg = mruby.mrb_str_new(state, "failed to get file stats", 24);
        const exc_class = mruby.mrb_class_get(state, "RuntimeError");
        mruby.mrb_raise(state, exc_class, mruby.mrb_str_to_cstr(state, err_msg));
        return mruby.mrb_nil_value();
    };

    const mtime_sec: i64 = @intCast(@divTrunc(stat_result.mtime, std.time.ns_per_s));

    // Create a Time object from the timestamp using Time.at(timestamp)
    const time_class = mruby.mrb_class_get(state, "Time");
    const at_sym = mruby.mrb_intern_cstr(state, "at");
    const timestamp_val = mruby.zig_mrb_int_value(state, mtime_sec);

    return mruby.mrb_funcall_argv(state, mruby.mrb_obj_value(time_class), at_sym, 1, &timestamp_val);
}

// Ruby prelude for File::Stat wrapper
pub const ruby_prelude = @embedFile("ruby_prelude/file_ext.rb");

// Module-level state to store mrb pointer for class method registration
var g_mrb: ?*mruby.mrb_state = null;

fn initModule(_: std.mem.Allocator) void {
    // Initialization will be done in setupFileExtensions
}

// Store mrb pointer and register File class methods
pub fn setupFileExtensions(mrb: *mruby.mrb_state) void {
    g_mrb = mrb;
    const file_class = mruby.mrb_class_get(mrb, "File");
    mruby.mrb_define_class_method(mrb, file_class, "stat", file_stat, mruby.MRB_ARGS_REQ(1));
    mruby.mrb_define_class_method(mrb, file_class, "mtime", file_mtime, mruby.MRB_ARGS_REQ(1));
}

fn getFunctions() []const mruby_module.ModuleFunction {
    // File class methods are registered via setupFileExtensions, not as module functions
    return &[_]mruby_module.ModuleFunction{};
}

fn getPrelude() []const u8 {
    return ruby_prelude;
}

pub const mruby_module_def = mruby_module.MRubyModule{
    .name = "File",
    .initFn = initModule,
    .getFunctions = getFunctions,
    .getPrelude = getPrelude,
    .platformCheck = null,
};
