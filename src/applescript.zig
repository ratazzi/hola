//! macOS AppleScript execution using Foundation framework
//!
//! This module provides a Zig-friendly interface to execute AppleScript
//! directly through macOS system APIs, without using the command line.
//!
//! Example:
//! ```zig
//! const applescript = @import("applescript");
//!
//! // Execute AppleScript directly
//! try applescript.execute(allocator, "tell application \"Finder\" to display dialog \"Hello\"");
//!
//! // Execute with error handling
//! const result = applescript.execute(allocator, "1 + 1") catch |err| {
//!     std.debug.print("Error: {}\n", .{err});
//     return;
// };
//! std.debug.print("Result: {s}\n", .{result});
//! ```

const std = @import("std");
const builtin = @import("builtin");

// Only compile on macOS
comptime {
    if (builtin.os.tag != .macos) {
        @compileError("applescript module is only available on macOS");
    }
}

const c = @cImport({
    @cInclude("objc/runtime.h");
});

// C bridge functions - SEL is passed as pointer since it's opaque in Zig
extern fn objc_msgSend_wrapper(obj: ?*anyopaque, sel: ?*anyopaque) ?*anyopaque;
extern fn objc_msgSend1_wrapper(obj: ?*anyopaque, sel: ?*anyopaque, arg1: ?*anyopaque) ?*anyopaque;
extern fn objc_msgSend2_wrapper(obj: ?*anyopaque, sel: ?*anyopaque, arg1: ?*anyopaque, arg2: usize, arg3: u32) ?*anyopaque;
extern fn objc_msgSend_bool_wrapper(obj: ?*anyopaque, sel: ?*anyopaque, error_ptr: [*c]?*anyopaque) bool;
extern fn objc_msgSend_error_wrapper(obj: ?*anyopaque, sel: ?*anyopaque, error_ptr: [*c]?*anyopaque) ?*anyopaque;
extern fn nsstring_utf8string(ns_string: ?*anyopaque) [*c]const u8;
extern fn nsstring_with_utf8string(c_str: [*c]const u8) id;
extern fn cast_to_id(ptr: ?*anyopaque) ?*anyopaque;

// Type definitions
// SEL is opaque in Zig, so we use a pointer type instead
const ObjCObject = opaque {};
const id = ?*ObjCObject;
const SEL = ?*const c.objc_selector;

// Helper: cast result to specific type
fn castResult(comptime T: type, result: ?*anyopaque) T {
    // For bool, check if result is not null
    if (T == bool) {
        return result != null;
    }
    // For id type, directly cast result to id without using cast_to_id
    // This avoids ARC retain issues
    // We use @as with @ptrCast to convert pointer types directly
    // Note: Objective-C objects are always properly aligned (8 bytes on 64-bit),
    // but Zig's type system sees ?*anyopaque as having alignment 1.
    // We use @alignCast to assert the alignment, which is safe because
    // objc_msgSend always returns properly aligned pointers.
    // If alignment check fails at runtime, it means the pointer is truly misaligned,
    // which should never happen with Objective-C objects.
    if (T == id) {
        if (result) |ptr| {
            return @as(T, @ptrCast(ptr));
        }
        return null;
    }
    // For pointer types (including optional pointers), use C bridge function
    // to handle alignment properly - but only if result is not null
    if (result) |ptr| {
        // Use C bridge function to cast with proper alignment
        // This handles the alignment issue in C where it's easier
        const casted = cast_to_id(ptr);
        return @as(T, casted);
    } else {
        return null;
    }
}

// Simplified msgSend wrappers using C bridge
fn msgSend(comptime T: type, receiver: id, selector: SEL) T {
    const result = objc_msgSend_wrapper(@ptrCast(receiver), @ptrCast(@constCast(selector)));
    return castResult(T, result);
}

fn msgSend1(comptime T: type, receiver: id, selector: SEL, arg1: anytype) T {
    const result = objc_msgSend1_wrapper(@ptrCast(receiver), @ptrCast(@constCast(selector)), @ptrCast(arg1));
    return castResult(T, result);
}

fn msgSend2(comptime T: type, receiver: id, selector: SEL, arg1: ?*anyopaque, arg2: usize, arg3: u32) T {
    // arg1 might not be aligned, but Objective-C runtime can handle it
    const result = objc_msgSend2_wrapper(@ptrCast(receiver), @ptrCast(@constCast(selector)), arg1, arg2, arg3);
    return castResult(T, result);
}

fn msgSendError(comptime T: type, receiver: id, selector: SEL, error_ptr: *?*c.objc_object) T {
    if (T == bool) {
        return objc_msgSend_bool_wrapper(@ptrCast(receiver), @ptrCast(@constCast(selector)), @ptrCast(error_ptr));
    }
    const result = objc_msgSend_error_wrapper(@ptrCast(receiver), @ptrCast(@constCast(selector)), @ptrCast(error_ptr));
    return castResult(T, result);
}

fn msgSendVoid(receiver: id, selector: SEL) void {
    _ = objc_msgSend_wrapper(@ptrCast(receiver), @ptrCast(@constCast(selector)));
}

fn msgSendVoid1(receiver: id, selector: SEL, arg1: anytype) void {
    _ = objc_msgSend1_wrapper(@ptrCast(receiver), @ptrCast(@constCast(selector)), @ptrCast(arg1));
}

/// Error types for AppleScript execution
pub const Error = error{
    ScriptCompilationFailed,
    ScriptExecutionFailed,
    InvalidResult,
    OutOfMemory,
    Unknown,
};

/// Execute AppleScript and return the result as a string
pub fn execute(allocator: std.mem.Allocator, script_source: []const u8) Error![]const u8 {
    // Create autorelease pool
    const pool_class = c.objc_getClass("NSAutoreleasePool");
    if (pool_class == null) return Error.Unknown;

    const pool_alloc = msgSend(id, @ptrCast(@alignCast(pool_class)), c.sel_getUid("alloc"));
    if (pool_alloc == null) return Error.OutOfMemory;

    const pool = msgSend(id, pool_alloc, c.sel_getUid("init"));
    defer msgSendVoid(pool, c.sel_getUid("drain"));

    // Create NSString from Zig string using C bridge function
    // This avoids alignment issues
    var c_string_buf = try allocator.alloc(u8, script_source.len + 1);
    defer allocator.free(c_string_buf);
    @memcpy(c_string_buf[0..script_source.len], script_source);
    c_string_buf[script_source.len] = 0;

    // Use C bridge function to create NSString - returns id directly (properly aligned)
    const ns_string_id = nsstring_with_utf8string(c_string_buf.ptr);
    if (ns_string_id == null) {
        return Error.OutOfMemory;
    }
    defer msgSendVoid(ns_string_id, c.sel_getUid("release"));

    // Create NSAppleScript
    const ns_script_class = c.objc_getClass("NSAppleScript");
    if (ns_script_class == null) return Error.Unknown;

    const ns_script_alloc = msgSend(id, @ptrCast(@alignCast(ns_script_class)), c.sel_getUid("alloc"));
    if (ns_script_alloc == null) return Error.OutOfMemory;

    const ns_script = msgSend1(id, ns_script_alloc, c.sel_getUid("initWithSource:"), ns_string_id);
    if (ns_script == null) {
        msgSendVoid(ns_script_alloc, c.sel_getUid("release"));
        return Error.OutOfMemory;
    }
    defer msgSendVoid(ns_script, c.sel_getUid("release"));

    // Compile script
    var compile_error: ?*c.objc_object = null;
    const compiled = msgSendError(bool, ns_script, c.sel_getUid("compileAndReturnError:"), &compile_error);
    if (!compiled) {
        return Error.ScriptCompilationFailed;
    }

    // Execute script
    var error_dict: ?*c.objc_object = null;
    const result = msgSendError(id, ns_script, c.sel_getUid("executeAndReturnError:"), &error_dict);

    if (error_dict != null) {
        return Error.ScriptExecutionFailed;
    }

    if (result == null) {
        return Error.InvalidResult;
    }

    // Convert NSAppleEventDescriptor to NSString
    const string_value = msgSend(id, result, c.sel_getUid("stringValue"));
    if (string_value == null) {
        return Error.InvalidResult;
    }

    // Get C string from NSString using bridge function
    const c_string = nsstring_utf8string(@ptrCast(string_value));
    if (c_string == null) {
        return Error.InvalidResult;
    }

    // Copy to Zig string
    const result_str = std.mem.span(c_string);
    return try allocator.dupe(u8, result_str);
}

/// Execute AppleScript without returning a result
pub fn executeVoid(allocator: std.mem.Allocator, script_source: []const u8) Error!void {
    _ = try execute(allocator, script_source);
}

/// Execute AppleScript and return boolean result
pub fn executeBoolean(allocator: std.mem.Allocator, script_source: []const u8) Error!bool {
    const result_str = try execute(allocator, script_source);
    defer allocator.free(result_str);

    // AppleScript boolean returns "true" or "false"
    if (std.mem.eql(u8, result_str, "true")) {
        return true;
    } else if (std.mem.eql(u8, result_str, "false")) {
        return false;
    }

    return Error.InvalidResult;
}

/// Execute AppleScript and return integer result
pub fn executeInteger(allocator: std.mem.Allocator, script_source: []const u8) Error!i64 {
    const result_str = try execute(allocator, script_source);
    defer allocator.free(result_str);

    return std.fmt.parseInt(i64, result_str, 10) catch return Error.InvalidResult;
}

/// Open App Store app page (for installation)
pub fn openAppStoreApp(allocator: std.mem.Allocator, app_id: u64) Error!void {
    const script = try std.fmt.allocPrint(
        allocator,
        \\tell application "App Store"
        \\    activate
        \\    open location "macappstore://apps.apple.com/app/id{d}"
        \\end tell
    ,
        .{app_id},
    );
    defer allocator.free(script);

    try executeVoid(allocator, script);
}

/// Check if an application is running
pub fn isAppRunning(allocator: std.mem.Allocator, app_name: []const u8) Error!bool {
    const script = try std.fmt.allocPrint(
        allocator,
        \\tell application "System Events"
        \\    return (name of processes) contains "{s}"
        \\end tell
    ,
        .{app_name},
    );
    defer allocator.free(script);

    return try executeBoolean(allocator, script);
}

/// Get list of running applications
pub fn getRunningApps(allocator: std.mem.Allocator) Error![]const []const u8 {
    const script =
        \\tell application "System Events"
        \\    return name of every process
        \\end tell
    ;

    const result_str = try execute(allocator, script);
    defer allocator.free(result_str);

    // Parse AppleScript list format: {"app1", "app2", "app3"}
    var list = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (list.items) |item| {
            allocator.free(item);
        }
        list.deinit();
    }

    // Simple parsing: remove braces and split by comma
    const trimmed = std.mem.trim(u8, result_str, " {}");
    var items = std.mem.splitScalar(u8, trimmed, ',');

    while (items.next()) |item| {
        const cleaned = std.mem.trim(u8, item, " \"");
        if (cleaned.len > 0) {
            try list.append(try allocator.dupe(u8, cleaned));
        }
    }

    return try list.toOwnedSlice();
}

test "execute simple script" {
    const gpa = std.testing.allocator;
    const result = try execute(gpa, "1 + 1");
    defer gpa.free(result);
    try std.testing.expectEqualStrings("2", result);
}

test "execute boolean" {
    const gpa = std.testing.allocator;
    const result = try executeBoolean(gpa, "1 = 1");
    try std.testing.expectEqual(true, result);
}

test "open app store" {
    const gpa = std.testing.allocator;
    // Just test that it doesn't crash
    _ = openAppStoreApp(gpa, 497799835) catch {
        // Might fail if App Store is not available, that's OK
    };
}
