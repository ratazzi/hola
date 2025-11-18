const std = @import("std");
const mruby = @import("mruby.zig");

// Global allocator for mruby callbacks
var global_allocator: ?std.mem.Allocator = null;

pub fn setAllocator(allocator: std.mem.Allocator) void {
    global_allocator = allocator;
}

/// mruby binding: JSON.encode(obj) - convert Ruby object to JSON string
pub fn zig_json_encode(mrb: *mruby.mrb_state, _: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    const allocator = global_allocator orelse return mruby.mrb_nil_value();

    var obj: mruby.mrb_value = undefined;
    _ = mruby.mrb_get_args(mrb, "o", &obj);

    var json_value = mrubyValueToJsonValue(mrb, allocator, obj) catch {
        return mruby.mrb_nil_value();
    };
    defer freeJsonValue(allocator, &json_value);

    const json_str = std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(json_value, .{})}) catch {
        return mruby.mrb_nil_value();
    };
    defer allocator.free(json_str);

    return mruby.mrb_str_new(mrb, json_str.ptr, @intCast(json_str.len));
}

/// mruby binding: JSON.decode(str) - parse JSON string to Ruby object
pub fn zig_json_decode(mrb: *mruby.mrb_state, _: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    const allocator = global_allocator orelse return mruby.mrb_nil_value();

    var str_ptr: [*c]const u8 = null;
    var str_len: mruby.mrb_int = 0;
    _ = mruby.mrb_get_args(mrb, "s", &str_ptr, &str_len);

    if (str_ptr == null or str_len <= 0) {
        return mruby.mrb_nil_value();
    }

    const json_str = str_ptr[0..@intCast(str_len)];

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
        return mruby.mrb_nil_value();
    };
    defer parsed.deinit();

    return jsonValueToMrubyValue(mrb, allocator, parsed.value) catch mruby.mrb_nil_value();
}

/// Free resources allocated for a JSON value
pub fn freeJsonValue(allocator: std.mem.Allocator, value: *std.json.Value) void {
    switch (value.*) {
        .string => |s| allocator.free(s),
        .array => |*arr| {
            for (arr.items) |*item| {
                freeJsonValue(allocator, item);
            }
            arr.deinit();
        },
        .object => |*obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeJsonValue(allocator, entry.value_ptr);
            }
            obj.deinit();
        },
        else => {},
    }
}

// Type checking helpers (C wrappers for mruby macros)
extern fn zig_mrb_nil_p(val: mruby.mrb_value) c_int;
extern fn zig_mrb_true_p(val: mruby.mrb_value) c_int;
extern fn zig_mrb_false_p(val: mruby.mrb_value) c_int;
extern fn zig_mrb_integer_p(val: mruby.mrb_value) c_int;
extern fn zig_mrb_float_p(val: mruby.mrb_value) c_int;
extern fn zig_mrb_string_p(val: mruby.mrb_value) c_int;
extern fn zig_mrb_array_p(val: mruby.mrb_value) c_int;
extern fn zig_mrb_hash_p(val: mruby.mrb_value) c_int;
extern fn zig_mrb_symbol_p(val: mruby.mrb_value) c_int;
extern fn mrb_obj_as_string(mrb: *mruby.mrb_state, obj: mruby.mrb_value) mruby.mrb_value;
extern fn mrb_hash_keys(mrb: *mruby.mrb_state, hash: mruby.mrb_value) mruby.mrb_value;
extern fn mrb_hash_get(mrb: *mruby.mrb_state, hash: mruby.mrb_value, key: mruby.mrb_value) mruby.mrb_value;
extern fn zig_mrb_float_value(mrb: *mruby.mrb_state, f: f64) mruby.mrb_value;

/// Convert mruby value to std.json.Value
pub fn mrubyValueToJsonValue(mrb: *mruby.mrb_state, allocator: std.mem.Allocator, val: mruby.mrb_value) !std.json.Value {
    if (zig_mrb_nil_p(val) != 0) {
        return .null;
    } else if (zig_mrb_false_p(val) != 0) {
        return .{ .bool = false };
    } else if (zig_mrb_true_p(val) != 0) {
        return .{ .bool = true };
    } else if (zig_mrb_integer_p(val) != 0) {
        return .{ .integer = mruby.mrb_fixnum(mrb, val) };
    } else if (zig_mrb_float_p(val) != 0) {
        return .{ .float = mruby.mrb_float(mrb, val) };
    } else if (zig_mrb_string_p(val) != 0) {
        const cstr = mruby.mrb_str_to_cstr(mrb, val);
        const str = try allocator.dupe(u8, std.mem.span(cstr));
        return .{ .string = str };
    } else if (zig_mrb_symbol_p(val) != 0) {
        const str_val = mrb_obj_as_string(mrb, val);
        const cstr = mruby.mrb_str_to_cstr(mrb, str_val);
        const str = try allocator.dupe(u8, std.mem.span(cstr));
        return .{ .string = str };
    } else if (zig_mrb_array_p(val) != 0) {
        const len = mruby.mrb_ary_len(mrb, val);
        var arr = std.json.Array.init(allocator);
        for (0..@intCast(len)) |i| {
            const elem = mruby.mrb_ary_ref(mrb, val, @intCast(i));
            const json_elem = try mrubyValueToJsonValue(mrb, allocator, elem);
            try arr.append(json_elem);
        }
        return .{ .array = arr };
    } else if (zig_mrb_hash_p(val) != 0) {
        const keys = mrb_hash_keys(mrb, val);
        const len = mruby.mrb_ary_len(mrb, keys);
        var obj = std.json.ObjectMap.init(allocator);

        for (0..@intCast(len)) |i| {
            const key = mruby.mrb_ary_ref(mrb, keys, @intCast(i));
            const value = mrb_hash_get(mrb, val, key);

            const key_str_val = mrb_obj_as_string(mrb, key);
            const key_cstr = mruby.mrb_str_to_cstr(mrb, key_str_val);
            const key_owned = try allocator.dupe(u8, std.mem.span(key_cstr));

            const json_value = try mrubyValueToJsonValue(mrb, allocator, value);
            try obj.put(key_owned, json_value);
        }
        return .{ .object = obj };
    }

    return .null;
}

/// Convert std.json.Value to mruby value
fn jsonValueToMrubyValue(mrb: *mruby.mrb_state, allocator: std.mem.Allocator, value: std.json.Value) !mruby.mrb_value {
    switch (value) {
        .null => return mruby.mrb_nil_value(),
        .bool => |b| {
            if (b) {
                return mruby.mrb_value{ .w = 12 }; // true
            } else {
                return mruby.mrb_value{ .w = 4 }; // false
            }
        },
        .integer => |i| return mruby.mrb_int_value(mrb, i),
        .float => |f| return zig_mrb_float_value(mrb, f),
        .number_string => |s| {
            // Try to parse as float
            const f = std.fmt.parseFloat(f64, s) catch 0.0;
            return zig_mrb_float_value(mrb, f);
        },
        .string => |s| return mruby.mrb_str_new(mrb, s.ptr, @intCast(s.len)),
        .array => |arr| {
            const mrb_arr = mruby.mrb_ary_new_capa(mrb, @intCast(arr.items.len));
            for (arr.items) |item| {
                const mrb_item = try jsonValueToMrubyValue(mrb, allocator, item);
                mruby.mrb_ary_push(mrb, mrb_arr, mrb_item);
            }
            return mrb_arr;
        },
        .object => |obj| {
            const hash = mruby.mrb_hash_new(mrb);
            var it = obj.iterator();
            while (it.next()) |entry| {
                const key = mruby.mrb_str_new(mrb, entry.key_ptr.*.ptr, @intCast(entry.key_ptr.*.len));
                const val = try jsonValueToMrubyValue(mrb, allocator, entry.value_ptr.*);
                mruby.mrb_hash_set(mrb, hash, key, val);
            }
            return hash;
        },
    }
}

pub const ruby_prelude = @embedFile("ruby_prelude/json.rb");
