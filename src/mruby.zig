const std = @import("std");

// Mirror the minimal mruby API surface we rely on.
pub const mrb_state = opaque {};
pub const mrb_value = extern struct {
    w: u64,
};
pub const RClass = opaque {};
pub const mrb_sym = u32;
pub const mrb_int = i64;
pub const mrb_aspec = u32;
pub const mrb_bool = u8;

// Function pointer type for mruby methods
pub const mrb_func_t = *const fn (mrb: *mrb_state, self: mrb_value) callconv(.c) mrb_value;

// Compiler context for file loading
pub const mrb_ccontext = opaque {};

extern fn mrb_open() ?*mrb_state;
extern fn mrb_close(mrb: *mrb_state) void;
pub extern fn mrb_load_string(mrb: *mrb_state, code: [*c]const u8) mrb_value;
pub extern fn mrb_load_file(mrb: *mrb_state, file: *std.c.FILE) mrb_value;
pub extern fn mrb_load_file_cxt(mrb: *mrb_state, file: *std.c.FILE, cxt: ?*mrb_ccontext) mrb_value;
pub extern fn mrb_ccontext_new(mrb: *mrb_state) ?*mrb_ccontext;
pub extern fn mrb_ccontext_free(mrb: *mrb_state, cxt: *mrb_ccontext) void;
pub extern fn mrb_ccontext_filename(mrb: *mrb_state, cxt: *mrb_ccontext, filename: [*:0]const u8) [*:0]const u8;
pub extern fn mrb_print_error(mrb: *mrb_state) void;

// Class and method definition
pub extern fn mrb_define_module(mrb: *mrb_state, name: [*c]const u8) *RClass;
pub extern fn mrb_define_module_function(mrb: *mrb_state, module: *RClass, name: [*c]const u8, func: mrb_func_t, aspec: mrb_aspec) void;
pub extern fn mrb_class_get(mrb: *mrb_state, name: [*c]const u8) *RClass;
pub extern fn mrb_class_get_under(mrb: *mrb_state, outer: *RClass, name: [*c]const u8) *RClass;
pub extern fn mrb_define_class_method(mrb: *mrb_state, class: *RClass, name: [*c]const u8, func: mrb_func_t, aspec: mrb_aspec) void;
extern fn zig_mrb_obj_value(obj: *const anyopaque) mrb_value;
pub const mrb_obj_value = zig_mrb_obj_value;

// Argument parsing
pub extern fn mrb_get_args(mrb: *mrb_state, format: [*c]const u8, ...) mrb_int;

// String handling
pub extern fn mrb_str_to_cstr(mrb: *mrb_state, str: mrb_value) [*c]const u8;
pub extern fn mrb_inspect(mrb: *mrb_state, obj: mrb_value) mrb_value;

// Exception handling (via C helper since mrb->exc is accessed directly)
extern fn zig_mrb_get_exception(mrb: *mrb_state) mrb_value;
pub const mrb_get_exception = zig_mrb_get_exception;
pub extern fn mrb_raise(mrb: *mrb_state, class: *RClass, msg: [*c]const u8) noreturn;

// Block/Proc handling
pub extern fn mrb_yield(mrb: *mrb_state, b: mrb_value, arg: mrb_value) mrb_value;
pub extern fn mrb_yield_argv(mrb: *mrb_state, b: mrb_value, argc: mrb_int, argv: [*c]const mrb_value) mrb_value;

// Function call
pub extern fn mrb_funcall_argv(mrb: *mrb_state, val: mrb_value, name: mrb_sym, argc: mrb_int, argv: [*c]const mrb_value) mrb_value;

// GC protection
pub extern fn mrb_gc_register(mrb: *mrb_state, obj: mrb_value) void;
pub extern fn mrb_gc_unregister(mrb: *mrb_state, obj: mrb_value) void;
pub extern fn mrb_gc_protect(mrb: *mrb_state, obj: mrb_value) void;

// Global variables
pub extern fn mrb_gv_get(mrb: *mrb_state, sym: mrb_sym) mrb_value;
pub extern fn mrb_gv_set(mrb: *mrb_state, sym: mrb_sym, val: mrb_value) void;
pub extern fn mrb_intern_cstr(mrb: *mrb_state, str: [*c]const u8) mrb_sym;

// Value type checking (via C helper since mrb_type is a macro)
pub extern fn zig_mrb_type(val: mrb_value) u32;
pub const mrb_type = zig_mrb_type;

// Array handling (using C helpers)
pub extern fn zig_mrb_ary_len(mrb: *mrb_state, arr: mrb_value) mrb_int;
pub extern fn zig_mrb_ary_ref(mrb: *mrb_state, arr: mrb_value, idx: mrb_int) mrb_value;
pub extern fn zig_mrb_fixnum(mrb: *mrb_state, val: mrb_value) mrb_int;
pub extern fn zig_mrb_float(mrb: *mrb_state, val: mrb_value) f64;

// Value constructors
pub extern fn zig_mrb_int_value(mrb: *mrb_state, i: mrb_int) mrb_value;

// Array creation and manipulation
pub extern fn mrb_ary_new_capa(mrb: *mrb_state, capa: mrb_int) mrb_value;
pub extern fn mrb_ary_push(mrb: *mrb_state, arr: mrb_value, val: mrb_value) void;

// Hash creation and manipulation
pub extern fn mrb_hash_new(mrb: *mrb_state) mrb_value;
pub extern fn mrb_hash_set(mrb: *mrb_state, hash: mrb_value, key: mrb_value, val: mrb_value) void;

// String creation
pub extern fn mrb_str_new(mrb: *mrb_state, ptr: [*c]const u8, len: mrb_int) mrb_value;

// Convenient aliases
pub const mrb_ary_len = zig_mrb_ary_len;
pub const mrb_ary_ref = zig_mrb_ary_ref;
pub const mrb_int_value = zig_mrb_int_value;
pub const mrb_fixnum = zig_mrb_fixnum;
pub const mrb_float = zig_mrb_float;

// Return values
// mrb_nil_value is typically a macro/inline - create our own
pub fn mrb_nil_value() mrb_value {
    return mrb_value{ .w = 0 }; // nil is typically represented as 0
}

// Check if value is truthy (anything except false/nil)
pub fn mrb_test(val: mrb_value) bool {
    // In mruby: false=4, nil=0, everything else is truthy
    // The mrb_bool macro: ((o).w & ~4) != 0
    // false & ~4 = 0 & ~4 = 0  → false
    // nil & ~4 = 0 & ~4 = 0    → false
    // true & ~4 = 12 & ~4 = 8  → true
    return (val.w & ~@as(u64, 4)) != 0;
}

// Argument spec helpers
pub fn MRB_ARGS_REQ(n: u32) mrb_aspec {
    return (n & 0x1f) << 18;
}

pub fn MRB_ARGS_OPT(n: u32) mrb_aspec {
    return (n & 0x1f) << 13;
}

pub fn MRB_ARGS_NONE() mrb_aspec {
    return 0;
}

// Lightweight RAII wrapper around the mruby state
pub const State = struct {
    mrb: ?*mrb_state,

    pub fn init() !State {
        const mrb = mrb_open();
        if (mrb == null) {
            return error.MRubyInitFailed;
        }
        return State{ .mrb = mrb };
    }

    pub fn deinit(self: *State) void {
        if (self.mrb) |mrb| {
            mrb_close(mrb);
            self.mrb = null;
        }
    }

    pub fn evalString(self: *State, code: []const u8) !void {
        const mrb = self.mrb orelse return error.MRubyNotInitialized;
        if (code.len < 4096) {
            var buf: [4096:0]u8 = undefined;
            @memcpy(buf[0..code.len], code);
            buf[code.len] = 0;
            _ = mrb_load_string(mrb, &buf);

            // Check if there was an exception
            const exc = mrb_get_exception(mrb);
            if (mrb_test(exc)) {
                mrb_print_error(mrb);
                return error.MRubyException;
            }
            return;
        }

        const heap = std.heap.c_allocator;
        const mem = try heap.alloc(u8, code.len + 1);
        defer heap.free(mem);
        @memcpy(mem[0..code.len], code);
        mem[code.len] = 0;
        _ = mrb_load_string(mrb, mem.ptr);

        // Check if there was an exception
        const exc = mrb_get_exception(mrb);
        if (mrb_test(exc)) {
            mrb_print_error(mrb);
            return error.MRubyException;
        }
    }

    pub fn evalFile(self: *State, file_path: []const u8) !void {
        const mrb = self.mrb orelse return error.MRubyNotInitialized;

        // Convert Zig string to C string with sentinel
        const heap = std.heap.c_allocator;
        const path_cstr = try heap.dupeZ(u8, file_path);
        defer heap.free(path_cstr);

        // Create a context and set the filename for proper error reporting
        const cxt = mrb_ccontext_new(mrb) orelse return error.ContextCreationFailed;
        defer mrb_ccontext_free(mrb, cxt);
        _ = mrb_ccontext_filename(mrb, cxt, path_cstr.ptr);

        // Open file using C fopen
        const file = std.c.fopen(path_cstr.ptr, "r") orelse return error.FileNotFound;
        defer _ = std.c.fclose(file);

        // Load and execute the file with context
        _ = mrb_load_file_cxt(mrb, file, cxt);

        // Check if there was an exception
        const exc = mrb_get_exception(mrb);
        if (mrb_test(exc)) {
            mrb_print_error(mrb);
            return error.MRubyException;
        }
    }
};
