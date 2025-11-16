//! macOS Property List (plist) handling using Core Foundation
//!
//! This module provides a Zig-friendly interface to macOS Core Foundation's
//! CFPropertyList API for reading, writing, and manipulating plist files.
//!
//! Example:
//! ```zig
//! const plist = @import("plist");
//!
//! // Read a plist file
//! var dict = try plist.Dictionary.loadFromFile(allocator, "/path/to/file.plist");
//! defer dict.deinit();
//!
//! // Get a value
//! if (dict.get("key")) |value| {
//!     std.debug.print("Value: {s}\n", .{value.asString()});
//! }
//!
//! // Set a value
//! try dict.set("new_key", .{ .string = "value" });
//!
//! // Save back to file
//! try dict.saveToFile("/path/to/file.plist");
//! ```

const std = @import("std");
const builtin = @import("builtin");

// Only compile on macOS
comptime {
    if (builtin.os.tag != .macos) {
        @compileError("plist module is only available on macOS");
    }
}

const c = @cImport({
    @cInclude("CoreFoundation/CoreFoundation.h");
});

/// Error types for plist operations
pub const Error = error{
    FileNotFound,
    InvalidFormat,
    InvalidType,
    KeyNotFound,
    WriteFailed,
    OutOfMemory,
    Unknown,
};

/// Property list value types
pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    data: []const u8,
    date: f64, // CFTimeInterval (seconds since 2001-01-01)
    array: []const Value,
    dictionary: Dictionary,

    /// Convert a CFPropertyListRef to a Zig Value
    pub fn fromCF(allocator: std.mem.Allocator, cf_value: c.CFPropertyListRef) Error!Value {
        const type_id = c.CFGetTypeID(cf_value);

        if (type_id == c.CFStringGetTypeID()) {
            const cf_str = @as(c.CFStringRef, @ptrCast(cf_value));
            const length = c.CFStringGetLength(cf_str);
            const max_size = c.CFStringGetMaximumSizeForEncoding(length, c.kCFStringEncodingUTF8);
            const buffer = try allocator.alloc(u8, @intCast(max_size));
            defer allocator.free(buffer);
            const result = c.CFStringGetCString(cf_str, buffer.ptr, max_size, c.kCFStringEncodingUTF8);
            if (result == 0) {
                return Error.InvalidFormat;
            }
            // Find null terminator
            var actual_length: usize = 0;
            while (actual_length < buffer.len and buffer[actual_length] != 0) {
                actual_length += 1;
            }
            return Value{ .string = try allocator.dupe(u8, buffer[0..actual_length]) };
        } else if (type_id == c.CFNumberGetTypeID()) {
            const cf_num = @as(c.CFNumberRef, @ptrCast(cf_value));
            var int_value: i64 = undefined;
            var float_value: f64 = undefined;

            if (c.CFNumberGetValue(cf_num, c.kCFNumberSInt64Type, &int_value) != 0) {
                return Value{ .integer = int_value };
            } else if (c.CFNumberGetValue(cf_num, c.kCFNumberDoubleType, &float_value) != 0) {
                return Value{ .float = float_value };
            }
            return Error.InvalidType;
        } else if (type_id == c.CFBooleanGetTypeID()) {
            const bool_value = c.CFBooleanGetValue(@as(c.CFBooleanRef, @ptrCast(cf_value)));
            return Value{ .boolean = bool_value != 0 };
        } else if (type_id == c.CFDataGetTypeID()) {
            const cf_data = @as(c.CFDataRef, @ptrCast(cf_value));
            const length = c.CFDataGetLength(cf_data);
            const bytes = c.CFDataGetBytePtr(cf_data);
            const data = try allocator.dupe(u8, bytes[0..@intCast(length)]);
            return Value{ .data = data };
        } else if (type_id == c.CFDateGetTypeID()) {
            const cf_date = @as(c.CFDateRef, @ptrCast(cf_value));
            const interval = c.CFDateGetAbsoluteTime(cf_date);
            return Value{ .date = interval };
        } else if (type_id == c.CFArrayGetTypeID()) {
            const cf_array = @as(c.CFArrayRef, @ptrCast(cf_value));
            const count = c.CFArrayGetCount(cf_array);
            const array = try allocator.alloc(Value, @intCast(count));
            for (0..@intCast(count)) |i| {
                const item = c.CFArrayGetValueAtIndex(cf_array, @intCast(i));
                array[i] = try fromCF(allocator, item);
            }
            return Value{ .array = array };
        } else if (type_id == c.CFDictionaryGetTypeID()) {
            const cf_dict = @as(c.CFDictionaryRef, @ptrCast(cf_value));
            const dict = Dictionary{
                .allocator = allocator,
                .cf_dict = cf_dict,
                .owned = false,
            };
            _ = c.CFRetain(cf_dict); // Retain since we're keeping a reference
            return Value{ .dictionary = dict };
        }

        return Error.InvalidType;
    }

    /// Convert a Zig Value to CFPropertyListRef
    pub fn toCF(self: Value, allocator: std.mem.Allocator) Error!c.CFPropertyListRef {
        switch (self) {
            .string => |s| {
                const cf_str = c.CFStringCreateWithCString(
                    null,
                    s.ptr,
                    c.kCFStringEncodingUTF8,
                );
                if (cf_str == null) return Error.OutOfMemory;
                return @as(c.CFPropertyListRef, @ptrCast(cf_str));
            },
            .integer => |i| {
                const cf_num = c.CFNumberCreate(null, c.kCFNumberSInt64Type, &i);
                if (cf_num == null) return Error.OutOfMemory;
                return @as(c.CFPropertyListRef, @ptrCast(cf_num));
            },
            .float => |f| {
                const cf_num = c.CFNumberCreate(null, c.kCFNumberDoubleType, &f);
                if (cf_num == null) return Error.OutOfMemory;
                return @as(c.CFPropertyListRef, @ptrCast(cf_num));
            },
            .boolean => |b| {
                const cf_bool: c.CFBooleanRef = if (b) c.kCFBooleanTrue else c.kCFBooleanFalse;
                return @as(c.CFPropertyListRef, @ptrCast(cf_bool));
            },
            .data => |d| {
                const cf_data = c.CFDataCreate(null, d.ptr, @intCast(d.len));
                if (cf_data == null) return Error.OutOfMemory;
                return @as(c.CFPropertyListRef, @ptrCast(cf_data));
            },
            .date => |interval| {
                const cf_date = c.CFDateCreate(null, interval);
                if (cf_date == null) return Error.OutOfMemory;
                return @as(c.CFPropertyListRef, @ptrCast(cf_date));
            },
            .array => |arr| {
                const cf_array = c.CFArrayCreateMutable(null, 0, &c.kCFTypeArrayCallBacks);
                if (cf_array == null) return Error.OutOfMemory;
                for (arr) |item| {
                    const cf_item = try item.toCF(allocator);
                    c.CFArrayAppendValue(cf_array, cf_item);
                    c.CFRelease(cf_item); // Array retains it
                }
                return @as(c.CFPropertyListRef, @ptrCast(cf_array));
            },
            .dictionary => |dict| {
                // For dictionaries, we need to retain since CFDictionarySetValue will retain it
                // and we'll release our reference after setting
                _ = c.CFRetain(dict.cf_dict);
                return @as(c.CFPropertyListRef, @ptrCast(dict.cf_dict));
            },
        }
    }

    /// Get string value (panics if not a string)
    pub fn asString(self: Value) []const u8 {
        return switch (self) {
            .string => |s| s,
            else => @panic("Value is not a string"),
        };
    }

    /// Get integer value (panics if not an integer)
    pub fn asInteger(self: Value) i64 {
        return switch (self) {
            .integer => |i| i,
            else => @panic("Value is not an integer"),
        };
    }

    /// Get boolean value (panics if not a boolean)
    pub fn asBoolean(self: Value) bool {
        return switch (self) {
            .boolean => |b| b,
            else => @panic("Value is not a boolean"),
        };
    }

    /// Free memory allocated for this value
    pub fn deinit(self: *const Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s),
            .data => |d| allocator.free(d),
            .array => |arr| {
                for (arr) |*item| {
                    item.deinit(allocator);
                }
                allocator.free(arr);
            },
            .dictionary => |*dict| {
                dict.deinit();
            },
            else => {},
        }
    }
};

/// Dictionary wrapper for plist dictionaries
pub const Dictionary = struct {
    allocator: std.mem.Allocator,
    cf_dict: c.CFDictionaryRef,
    owned: bool = true,

    const Self = @This();

    /// Create a new empty dictionary
    pub fn init(allocator: std.mem.Allocator) Self {
        const cf_dict = c.CFDictionaryCreateMutable(null, 0, &c.kCFTypeDictionaryKeyCallBacks, &c.kCFTypeDictionaryValueCallBacks);
        return Self{
            .allocator = allocator,
            .cf_dict = cf_dict,
            .owned = true,
        };
    }

    /// Load a dictionary from a plist file
    pub fn loadFromFile(allocator: std.mem.Allocator, file_path: []const u8) Error!Self {
        const cf_path = c.CFStringCreateWithCString(null, file_path.ptr, c.kCFStringEncodingUTF8);
        if (cf_path == null) return Error.OutOfMemory;
        defer c.CFRelease(cf_path);

        const url = c.CFURLCreateWithFileSystemPath(null, cf_path, c.kCFURLPOSIXPathStyle, 0);
        if (url == null) return Error.OutOfMemory;
        defer c.CFRelease(url);

        var data_ref: c.CFDataRef = undefined;
        const result = c.CFURLCreateDataAndPropertiesFromResource(null, url, &data_ref, null, null, null);
        if (result == 0) {
            return Error.FileNotFound;
        }
        defer c.CFRelease(data_ref);

        var format: c.CFPropertyListFormat = undefined;
        var error_ref: c.CFErrorRef = null;
        const plist = c.CFPropertyListCreateWithData(
            null,
            data_ref,
            c.kCFPropertyListImmutable,
            &format,
            &error_ref,
        );

        if (plist == null) {
            if (error_ref != null) {
                c.CFRelease(error_ref);
            }
            return Error.InvalidFormat;
        }

        const type_id = c.CFGetTypeID(plist);
        if (type_id != c.CFDictionaryGetTypeID()) {
            c.CFRelease(plist);
            return Error.InvalidType;
        }

        const dict = @as(c.CFDictionaryRef, @ptrCast(plist));
        _ = c.CFRetain(dict); // Retain since we're keeping it

        return Self{
            .allocator = allocator,
            .cf_dict = dict,
            .owned = true,
        };
    }

    /// Get a value by key
    pub fn get(self: Self, key: []const u8) ?Value {
        const cf_key = c.CFStringCreateWithCString(null, key.ptr, c.kCFStringEncodingUTF8);
        if (cf_key == null) return null;
        defer c.CFRelease(cf_key);

        const value = c.CFDictionaryGetValue(self.cf_dict, cf_key);
        if (value == null) return null;

        return Value.fromCF(self.allocator, value) catch null;
    }

    /// Set a value for a key
    /// Note: This only works on mutable dictionaries created with Dictionary.init()
    pub fn set(self: Self, key: []const u8, value: Value) Error!void {
        // Check if it's a mutable dictionary
        const type_id = c.CFGetTypeID(self.cf_dict);
        if (type_id != c.CFDictionaryGetTypeID()) {
            return Error.InvalidType;
        }

        // Try to cast to mutable - this is safe if the dict was created mutable
        const mutable_dict = @as(c.CFMutableDictionaryRef, @constCast(self.cf_dict));

        const cf_key = c.CFStringCreateWithCString(null, key.ptr, c.kCFStringEncodingUTF8);
        if (cf_key == null) return Error.OutOfMemory;
        defer c.CFRelease(cf_key);

        const cf_value = try value.toCF(self.allocator);
        // CFDictionarySetValue will retain the value, so we release our reference
        // Note: For dictionaries, toCF returns the dict.cf_dict directly without creating a new reference
        // So we need to be careful - CFDictionarySetValue will retain it, and we should release our reference
        c.CFDictionarySetValue(mutable_dict, cf_key, cf_value);
        c.CFRelease(cf_value); // Release our reference after setting
    }

    /// Remove a key from the dictionary
    /// Note: This only works on mutable dictionaries created with Dictionary.init()
    pub fn remove(self: Self, key: []const u8) void {
        const type_id = c.CFGetTypeID(self.cf_dict);
        if (type_id != c.CFDictionaryGetTypeID()) {
            return;
        }

        const mutable_dict = @as(c.CFMutableDictionaryRef, @ptrCast(self.cf_dict));

        const cf_key = c.CFStringCreateWithCString(null, key.ptr, c.kCFStringEncodingUTF8);
        if (cf_key == null) return;
        defer c.CFRelease(cf_key);

        c.CFDictionaryRemoveValue(mutable_dict, cf_key);
    }

    /// Save dictionary to a plist file
    pub fn saveToFile(self: Self, file_path: []const u8) Error!void {
        const cf_path = c.CFStringCreateWithCString(null, file_path.ptr, c.kCFStringEncodingUTF8);
        if (cf_path == null) return Error.OutOfMemory;
        defer c.CFRelease(cf_path);

        const url = c.CFURLCreateWithFileSystemPath(null, cf_path, c.kCFURLPOSIXPathStyle, 0);
        if (url == null) return Error.OutOfMemory;
        defer c.CFRelease(url);

        const data = c.CFPropertyListCreateData(
            null,
            @as(c.CFPropertyListRef, @ptrCast(self.cf_dict)),
            c.kCFPropertyListXMLFormat_v1_0,
            0,
            null,
        );
        if (data == null) return Error.OutOfMemory;
        defer c.CFRelease(data);

        const result = c.CFURLWriteDataAndPropertiesToResource(url, data, null, null);
        if (result == 0) {
            return Error.WriteFailed;
        }
    }

    /// Get all keys in the dictionary
    /// Caller owns the returned memory and must free it with allocator.free()
    pub fn keys(self: Self, allocator: std.mem.Allocator) Error![]const []const u8 {
        const count = c.CFDictionaryGetCount(self.cf_dict);
        const keys_array = try allocator.alloc([]const u8, @intCast(count));
        errdefer allocator.free(keys_array);

        const cf_keys = try allocator.alloc(c.CFStringRef, @intCast(count));
        defer allocator.free(cf_keys);

        c.CFDictionaryGetKeysAndValues(self.cf_dict, cf_keys.ptr, null);

        for (0..@intCast(count)) |i| {
            const cf_key = cf_keys[i];
            const c_str = c.CFStringGetCStringPtr(cf_key, c.kCFStringEncodingUTF8);
            if (c_str != null) {
                // CFStringGetCStringPtr returns a pointer that's valid as long as the CFString exists
                // Since we're reading from the dictionary, we need to copy it
                keys_array[i] = try allocator.dupe(u8, std.mem.span(c_str));
            } else {
                // Fallback: copy the string
                const length = c.CFStringGetLength(cf_key);
                const max_size = c.CFStringGetMaximumSizeForEncoding(length, c.kCFStringEncodingUTF8);
                const buffer_size_usize = @as(usize, @intCast(max_size + 1));
                const buffer_size_c_long = @as(c_long, @intCast(max_size + 1));
                const buffer = try allocator.alloc(u8, buffer_size_usize);
                defer allocator.free(buffer);
                // Initialize buffer with zeros to ensure null termination
                @memset(buffer, 0);
                _ = c.CFStringGetCString(cf_key, buffer.ptr, buffer_size_c_long, c.kCFStringEncodingUTF8);
                // Find null terminator safely
                var actual_length: usize = 0;
                while (actual_length < buffer_size_usize and buffer[actual_length] != 0) {
                    actual_length += 1;
                }
                keys_array[i] = try allocator.dupe(u8, buffer[0..actual_length]);
            }
        }

        return keys_array;
    }

    /// Free resources
    pub fn deinit(self: *const Self) void {
        if (self.owned) {
            c.CFRelease(self.cf_dict);
        }
    }

    /// Free keys array returned by keys()
    pub fn freeKeys(allocator: std.mem.Allocator, keys_array: []const []const u8) void {
        for (keys_array) |key| {
            allocator.free(key);
        }
        allocator.free(keys_array);
    }
};

/// Read a plist file and return its root value
pub fn readFile(allocator: std.mem.Allocator, file_path: []const u8) Error!Value {
    const cf_path = c.CFStringCreateWithCString(null, file_path.ptr, c.kCFStringEncodingUTF8);
    if (cf_path == null) return Error.OutOfMemory;
    defer c.CFRelease(cf_path);

    const url = c.CFURLCreateWithFileSystemPath(null, cf_path, c.kCFURLPOSIXPathStyle, 0);
    if (url == null) return Error.OutOfMemory;
    defer c.CFRelease(url);

    var data_ref: c.CFDataRef = undefined;
    const result = c.CFURLCreateDataAndPropertiesFromResource(null, url, &data_ref, null, null, null);
    if (result == 0) {
        return Error.FileNotFound;
    }
    defer c.CFRelease(data_ref);

    var format: c.CFPropertyListFormat = undefined;
    var error_string: c.CFStringRef = undefined;
    const plist = c.CFPropertyListCreateWithData(
        null,
        data_ref,
        c.kCFPropertyListImmutable,
        &format,
        &error_string,
    );

    if (plist == null) {
        if (error_string != null) {
            c.CFRelease(error_string);
        }
        return Error.InvalidFormat;
    }
    defer c.CFRelease(plist);

    return Value.fromCF(allocator, plist);
}

/// Write a value to a plist file
pub fn writeFile(allocator: std.mem.Allocator, file_path: []const u8, value: Value) Error!void {
    const cf_value = try value.toCF(allocator);
    defer c.CFRelease(cf_value);

    const cf_path = c.CFStringCreateWithCString(null, file_path.ptr, c.kCFStringEncodingUTF8);
    if (cf_path == null) return Error.OutOfMemory;
    defer c.CFRelease(cf_path);

    const url = c.CFURLCreateWithFileSystemPath(null, cf_path, c.kCFURLPOSIXPathStyle, 0);
    if (url == null) return Error.OutOfMemory;
    defer c.CFRelease(url);

    const data = c.CFPropertyListCreateData(
        null,
        cf_value,
        c.kCFPropertyListXMLFormat_v1_0,
        0,
        null,
    );
    if (data == null) return Error.OutOfMemory;
    defer c.CFRelease(data);

    const result = c.CFURLWriteDataAndPropertiesToResource(url, data, null, null);
    if (result == 0) {
        return Error.WriteFailed;
    }
}

test "create and manipulate dictionary" {
    const gpa = std.testing.allocator;
    var dict = Dictionary.init(gpa);
    defer dict.deinit();

    try dict.set("string_key", .{ .string = "hello" });
    try dict.set("int_key", .{ .integer = 42 });
    try dict.set("bool_key", .{ .boolean = true });

    const str_val = dict.get("string_key").?;
    try std.testing.expectEqualStrings("hello", str_val.asString());
    str_val.deinit(gpa);

    const int_val = dict.get("int_key").?;
    try std.testing.expectEqual(@as(i64, 42), int_val.asInteger());
    int_val.deinit(gpa);

    const bool_val = dict.get("bool_key").?;
    try std.testing.expectEqual(true, bool_val.asBoolean());
    bool_val.deinit(gpa);
}

test "read and write plist file" {
    const gpa = std.testing.allocator;
    const tmp_dir = std.fs.cwd();
    const test_file = "/tmp/test_hola.plist";

    // Create a test dictionary
    var dict = Dictionary.init(gpa);
    defer dict.deinit();

    try dict.set("test_string", .{ .string = "test_value" });
    try dict.set("test_int", .{ .integer = 123 });

    // Write to file
    try dict.saveToFile(test_file);

    // Read back
    var loaded_dict = try Dictionary.loadFromFile(gpa, test_file);
    defer loaded_dict.deinit();

    const str_val = loaded_dict.get("test_string").?;
    try std.testing.expectEqualStrings("test_value", str_val.asString());
    str_val.deinit(gpa);

    const int_val = loaded_dict.get("test_int").?;
    try std.testing.expectEqual(@as(i64, 123), int_val.asInteger());
    int_val.deinit(gpa);

    // Cleanup
    _ = tmp_dir.deleteFile(test_file) catch {};
}
