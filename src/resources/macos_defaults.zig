const std = @import("std");
const mruby = @import("../mruby.zig");
const base = @import("../base_resource.zig");
const logger = @import("../logger.zig");
const builtin = @import("builtin");

comptime {
    if (builtin.os.tag != .macos) {
        @compileError("macos_defaults resource is only available on macOS");
    }
}

// IMPORTANT: Use global CoreFoundation bindings to ensure consistent constant addresses across all modules
const cf = @import("../cf.zig");
const c = cf.c;

// ============================================================================
// C wrapper functions for CFPreferences operations
// These functions bypass Zig's @cImport issues with CFPreferences API
// ============================================================================

// Write operations
extern "c" fn cfpreferences_write_boolean(domain: [*:0]const u8, key: [*:0]const u8, value: c_int) c_int;
extern "c" fn cfpreferences_write_integer(domain: [*:0]const u8, key: [*:0]const u8, value: c_longlong) c_int;
extern "c" fn cfpreferences_write_float(domain: [*:0]const u8, key: [*:0]const u8, value: f64) c_int;
extern "c" fn cfpreferences_write_string(domain: [*:0]const u8, key: [*:0]const u8, value: [*:0]const u8) c_int;

// Read operations
extern "c" fn cfpreferences_read_boolean(domain: [*:0]const u8, key: [*:0]const u8, out_value: *c_int) c_int;
extern "c" fn cfpreferences_read_integer(domain: [*:0]const u8, key: [*:0]const u8, out_value: *c_longlong) c_int;
extern "c" fn cfpreferences_read_float(domain: [*:0]const u8, key: [*:0]const u8, out_value: *f64) c_int;
extern "c" fn cfpreferences_read_string(domain: [*:0]const u8, key: [*:0]const u8, buffer: [*]u8, buffer_size: c_int) c_int;

// Utility operations
extern "c" fn cfpreferences_key_exists(domain: [*:0]const u8, key: [*:0]const u8) c_int;
extern "c" fn cfpreferences_delete_key(domain: [*:0]const u8, key: [*:0]const u8) c_int;

/// macOS defaults resource data structure
pub const Resource = struct {
    domain: []const u8,
    key: []const u8,
    value: Value,
    action: Action,

    // Common properties (guards, notifications, etc.)
    common: base.CommonProps,

    pub const Action = enum {
        write,
        delete,
    };

    pub const Value = union(enum) {
        string: []const u8,
        integer: i64,
        boolean: bool,
        float: f64,
        array: std.ArrayList(Value),
        dict: std.StringHashMap(Value),

        pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .string => |s| allocator.free(s),
                .array => |*arr| {
                    for (arr.items) |*item| {
                        item.deinit(allocator);
                    }
                    arr.deinit(allocator);
                },
                .dict => |*dict_map| {
                    var it = dict_map.iterator();
                    while (it.next()) |entry| {
                        allocator.free(entry.key_ptr.*);
                        entry.value_ptr.*.deinit(allocator);
                    }
                    dict_map.deinit();
                },
                else => {},
            }
        }
    };

    pub fn deinit(self: Resource, allocator: std.mem.Allocator) void {
        allocator.free(self.domain);
        allocator.free(self.key);
        var value = self.value;
        value.deinit(allocator);

        // Deinit common props
        var common = self.common;
        common.deinit(allocator);
    }

    pub fn apply(self: Resource) !base.ApplyResult {
        logger.debug("macos_defaults apply: domain={s}, key={s}, action={}\n", .{ self.domain, self.key, self.action });

        // Log the desired value stored in the resource
        switch (self.value) {
            .boolean => |b| logger.debug("macos_defaults desired value = boolean: {}\n", .{b}),
            .integer => |i| logger.debug("macos_defaults desired value = integer: {}\n", .{i}),
            .float => |f| logger.debug("macos_defaults desired value = float: {d}\n", .{f}),
            .string => |s| logger.debug("macos_defaults desired value = string: {s}\n", .{s}),
            else => logger.debug("macos_defaults desired value = other type\n", .{}),
        }

        const skip_reason = try self.common.shouldRun();
        if (skip_reason) |reason| {
            const action_name = switch (self.action) {
                .write => "write",
                .delete => "delete",
            };
            return base.ApplyResult{
                .was_updated = false,
                .action = action_name,
                .skip_reason = reason,
            };
        }

        const action_name = switch (self.action) {
            .write => "write",
            .delete => "delete",
        };

        switch (self.action) {
            .write => {
                logger.debug("macos_defaults calling applyWrite...\n", .{});
                const was_updated = try applyWrite(self);
                logger.debug("macos_defaults applyWrite returned: {}\n", .{was_updated});
                return base.ApplyResult{
                    .was_updated = was_updated,
                    .action = action_name,
                    .skip_reason = if (was_updated) null else "up to date",
                };
            },
            .delete => {
                try applyDelete(self);
                return base.ApplyResult{
                    .was_updated = false,
                    .action = action_name,
                    .skip_reason = "up to date",
                };
            },
        }
    }

    fn applyWrite(self: Resource) !bool {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        // Step 1: Read current value
        const value_type = std.meta.activeTag(self.value);
        const current_value = try readDefaultWithCWrapper(allocator, self.domain, self.key, value_type);
        defer if (current_value) |val| {
            if (val == .string) allocator.free(val.string);
        };

        // Step 2: Compare with desired value
        if (current_value) |current| {
            const values_match = switch (self.value) {
                .boolean => |b| current == .boolean and current.boolean == b,
                .integer => |i| current == .integer and current.integer == i,
                .float => |f| current == .float and current.float == f,
                .string => |s| current == .string and std.mem.eql(u8, current.string, s),
                else => false,
            };

            if (values_match) {
                // Values already match, no need to write
                return false;
            }
        }

        // Step 3: Write new value
        try writeDefault(allocator, self.domain, self.key, self.value);

        // Step 4: Restart application if needed
        try restartApplicationIfNeeded(allocator, self.domain);

        return true; // Value was updated
    }

    fn restartApplicationIfNeeded(allocator: std.mem.Allocator, domain: []const u8) !void {
        // Map domains to their application names
        if (std.mem.eql(u8, domain, "com.apple.finder")) {
            try restartFinder(allocator);
        } else if (std.mem.eql(u8, domain, "com.apple.dock")) {
            // Dock is handled separately by macos_dock resource
            // But we can still restart it here if needed
            try restartDock(allocator);
        } else if (std.mem.eql(u8, domain, "com.apple.systemuiserver")) {
            try restartSystemUIServer(allocator);
        }
        // Add more domains as needed
    }

    fn restartFinder(_: std.mem.Allocator) !void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        // Kill Finder
        var kill_proc = std.process.Child.init(&[_][]const u8{ "killall", "Finder" }, arena_allocator);
        kill_proc.stdout_behavior = .Ignore;
        kill_proc.stderr_behavior = .Ignore;
        _ = kill_proc.spawnAndWait() catch {};

        // Finder will automatically restart
        std.Thread.sleep(500_000_000); // 0.5 seconds
    }

    fn restartDock(_: std.mem.Allocator) !void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        // Kill Dock
        var kill_proc = std.process.Child.init(&[_][]const u8{ "killall", "Dock" }, arena_allocator);
        kill_proc.stdout_behavior = .Ignore;
        kill_proc.stderr_behavior = .Ignore;
        _ = kill_proc.spawnAndWait() catch {};

        // Dock will automatically restart
        std.Thread.sleep(500_000_000); // 0.5 seconds
    }

    fn restartSystemUIServer(_: std.mem.Allocator) !void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        // Kill SystemUIServer
        var kill_proc = std.process.Child.init(&[_][]const u8{ "killall", "SystemUIServer" }, arena_allocator);
        kill_proc.stdout_behavior = .Ignore;
        kill_proc.stderr_behavior = .Ignore;
        _ = kill_proc.spawnAndWait() catch {};

        // SystemUIServer will automatically restart
        std.Thread.sleep(500_000_000); // 0.5 seconds
    }

    fn applyDelete(self: Resource) !void {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        // Check if key exists
        var current_value = readDefault(allocator, self.domain, self.key) catch null;
        defer if (current_value) |*val| val.deinit(allocator);

        if (current_value == null) {
            return; // Already deleted
        }

        // Delete the key
        try deleteDefault(allocator, self.domain, self.key);
    }

    fn valuesEqual(allocator: std.mem.Allocator, a: *const Value, b: Value) bool {
        switch (a.*) {
            .string => |a_str| {
                switch (b) {
                    .string => |b_str| return std.mem.eql(u8, a_str, b_str),
                    else => return false,
                }
            },
            .integer => |a_int| {
                switch (b) {
                    .integer => |b_int| return a_int == b_int,
                    else => return false,
                }
            },
            .boolean => |a_bool| {
                switch (b) {
                    .boolean => |b_bool| return a_bool == b_bool,
                    else => return false,
                }
            },
            .float => |a_float| {
                switch (b) {
                    .float => |b_float| return a_float == b_float,
                    else => return false,
                }
            },
            .array => |a_arr| {
                switch (b) {
                    .array => |b_arr| {
                        if (a_arr.items.len != b_arr.items.len) return false;
                        for (a_arr.items, b_arr.items) |*a_item, b_item| {
                            if (!valuesEqual(allocator, a_item, b_item)) return false;
                        }
                        return true;
                    },
                    else => return false,
                }
            },
            .dict => |*a_dict| {
                switch (b) {
                    .dict => |b_dict| {
                        if (a_dict.count() != b_dict.count()) return false;
                        var it = a_dict.iterator();
                        while (it.next()) |entry| {
                            const b_val = b_dict.get(entry.key_ptr.*) orelse return false;
                            if (!valuesEqual(allocator, &entry.value_ptr.*, b_val)) return false;
                        }
                        return true;
                    },
                    else => return false,
                }
            },
        }
    }

    /// Read default using `defaults` command to avoid CFPreferences caching issues
    fn readDefaultWithCommand(allocator: std.mem.Allocator, domain: []const u8, key: []const u8) !?Value {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const cmd = try std.fmt.allocPrint(arena_alloc, "defaults read {s} {s}", .{ domain, key });
        var proc = std.process.Child.init(&[_][]const u8{ "/bin/sh", "-c", cmd }, arena_alloc);
        proc.stdout_behavior = .Pipe;
        proc.stderr_behavior = .Ignore;
        try proc.spawn();
        const stdout = try proc.stdout.?.readToEndAlloc(arena_alloc, 1024);
        const result = try proc.wait();

        // If the key doesn't exist, `defaults read` will exit with non-zero status
        if (result.Exited != 0) {
            return null; // Key doesn't exist
        }

        // Parse the output
        const trimmed = std.mem.trim(u8, stdout, &std.ascii.whitespace);

        // Try to parse as boolean first
        if (std.mem.eql(u8, trimmed, "1")) {
            return Value{ .boolean = true };
        } else if (std.mem.eql(u8, trimmed, "0")) {
            return Value{ .boolean = false };
        }

        // Try to parse as integer
        if (std.fmt.parseInt(i64, trimmed, 10)) |num| {
            return Value{ .integer = num };
        } else |_| {}

        // Try to parse as float
        if (std.fmt.parseFloat(f64, trimmed)) |num| {
            return Value{ .float = num };
        } else |_| {}

        // Default to string
        return Value{ .string = try allocator.dupe(u8, trimmed) };
    }

    fn readDefault(allocator: std.mem.Allocator, domain: []const u8, key: []const u8) !?Value {
        logger.debug("macos_defaults readDefault: domain={s}, key={s}\n", .{ domain, key });

        // Convert domain and key to CFString
        const domain_cf = c.CFStringCreateWithCString(null, domain.ptr, c.kCFStringEncodingUTF8);
        if (domain_cf == null) return error.OutOfMemory;
        defer c.CFRelease(domain_cf);

        const key_cf = c.CFStringCreateWithCString(null, key.ptr, c.kCFStringEncodingUTF8);
        if (key_cf == null) return error.OutOfMemory;
        defer c.CFRelease(key_cf);

        // CRITICAL FIX: Force invalidation of CFPreferences cache before reading!
        // According to Apple docs, we need to synchronize with kCFPreferencesAnyApplication
        // to force a reload from disk, ignoring any in-memory cache
        _ = c.CFPreferencesSynchronize(c.kCFPreferencesAnyApplication, c.kCFPreferencesCurrentUser, c.kCFPreferencesAnyHost);

        // Also synchronize the specific domain to ensure we get fresh data
        _ = c.CFPreferencesSynchronize(domain_cf, c.kCFPreferencesCurrentUser, c.kCFPreferencesAnyHost);

        logger.debug("macos_defaults after synchronization, calling CFPreferencesCopyValue...\n", .{});

        const value_cf = c.CFPreferencesCopyValue(key_cf, domain_cf, c.kCFPreferencesCurrentUser, c.kCFPreferencesAnyHost);
        const from_anyhost = true;

        // Don't fallback to CurrentHost - if AnyHost doesn't have it, the key doesn't exist
        // CurrentHost is for host-specific cache, not the actual plist file

        if (value_cf) |val| {
            logger.debug("macos_defaults value_cf found: {*}\n", .{val});
        } else {
            logger.debug("macos_defaults value_cf is NULL (key doesn't exist)\n", .{});
        }

        if (value_cf == null) {
            return null; // Key doesn't exist
        }
        defer c.CFRelease(value_cf);

        // Log the type and value for debugging
        const type_id = c.CFGetTypeID(value_cf);
        if (type_id == c.CFBooleanGetTypeID()) {
            const bool_val = c.CFBooleanGetValue(@as(c.CFBooleanRef, @ptrCast(value_cf)));
            logger.writeFmt("[macos_defaults] readDefault: CFBoolean value={} (from AnyHost={})\n", .{ bool_val, from_anyhost });
        }

        // Convert CFTypeRef to Value
        return try cfValueToValue(allocator, value_cf);
    }

    /// Read a preference value using C wrapper (bypasses Zig @cImport issues)
    fn readDefaultWithCWrapper(allocator: std.mem.Allocator, domain: []const u8, key: []const u8, expected_type: std.meta.Tag(Value)) !?Value {
        // Create null-terminated strings for C
        var domain_buf: [256]u8 = undefined;
        var key_buf: [256]u8 = undefined;
        const domain_z = try std.fmt.bufPrintZ(&domain_buf, "{s}", .{domain});
        const key_z = try std.fmt.bufPrintZ(&key_buf, "{s}", .{key});

        // Try to read based on expected type
        switch (expected_type) {
            .boolean => {
                var out_value: c_int = 0;
                const result = cfpreferences_read_boolean(domain_z.ptr, key_z.ptr, &out_value);
                if (result == 0) return null; // Key doesn't exist or wrong type
                return Value{ .boolean = out_value != 0 };
            },
            .integer => {
                var out_value: c_longlong = 0;
                const result = cfpreferences_read_integer(domain_z.ptr, key_z.ptr, &out_value);
                if (result == 0) return null;
                return Value{ .integer = @intCast(out_value) };
            },
            .float => {
                var out_value: f64 = 0;
                const result = cfpreferences_read_float(domain_z.ptr, key_z.ptr, &out_value);
                if (result == 0) return null;
                return Value{ .float = out_value };
            },
            .string => {
                var buffer: [1024]u8 = undefined;
                const result = cfpreferences_read_string(domain_z.ptr, key_z.ptr, &buffer, buffer.len);
                if (result == 0) return null;
                const len = std.mem.indexOfScalar(u8, &buffer, 0) orelse buffer.len;
                const str = try allocator.dupe(u8, buffer[0..len]);
                return Value{ .string = str };
            },
            else => return error.UnsupportedValueType,
        }
    }

    fn writeDefault(_: std.mem.Allocator, domain: []const u8, key: []const u8, value: Value) !void {
        // Create null-terminated strings for C
        var domain_buf: [256]u8 = undefined;
        var key_buf: [256]u8 = undefined;
        const domain_z = try std.fmt.bufPrintZ(&domain_buf, "{s}", .{domain});
        const key_z = try std.fmt.bufPrintZ(&key_buf, "{s}", .{key});

        // Call appropriate C wrapper based on value type
        const result = switch (value) {
            .boolean => |b| cfpreferences_write_boolean(domain_z.ptr, key_z.ptr, if (b) 1 else 0),
            .integer => |i| cfpreferences_write_integer(domain_z.ptr, key_z.ptr, @intCast(i)),
            .float => |f| cfpreferences_write_float(domain_z.ptr, key_z.ptr, f),
            .string => |s| blk: {
                var value_buf: [1024]u8 = undefined;
                const value_z = try std.fmt.bufPrintZ(&value_buf, "{s}", .{s});
                break :blk cfpreferences_write_string(domain_z.ptr, key_z.ptr, value_z.ptr);
            },
            else => return error.UnsupportedValueType,
        };

        if (result == 0) {
            return error.WriteFailed;
        }
    }

    fn deleteDefault(_: std.mem.Allocator, domain: []const u8, key: []const u8) !void {
        // Convert domain and key to CFString
        const domain_cf = c.CFStringCreateWithCString(null, domain.ptr, c.kCFStringEncodingUTF8);
        if (domain_cf == null) return error.OutOfMemory;
        defer c.CFRelease(domain_cf);

        const key_cf = c.CFStringCreateWithCString(null, key.ptr, c.kCFStringEncodingUTF8);
        if (key_cf == null) return error.OutOfMemory;
        defer c.CFRelease(key_cf);

        // Delete preference using CFPreferences (set to NULL)
        // Use CFPreferencesSetValue with NULL to delete
        c.CFPreferencesSetValue(key_cf, null, domain_cf, c.kCFPreferencesCurrentUser, c.kCFPreferencesCurrentHost);

        // Synchronize to ensure cache is updated and written to disk
        if (c.CFPreferencesSynchronize(domain_cf, c.kCFPreferencesCurrentUser, c.kCFPreferencesCurrentHost) == 0) {
            return error.PreferencesSyncFailed;
        }
    }

    fn cfValueToValue(allocator: std.mem.Allocator, cf_value: anytype) !Value {
        const type_id = c.CFGetTypeID(cf_value);

        logger.debug("macos_defaults cfValueToValue: cf_value ptr={*}\n", .{cf_value});

        if (type_id == c.CFNumberGetTypeID()) {
            const num = @as(c.CFNumberRef, @ptrCast(cf_value));
            var int_val: c_longlong = undefined;
            if (c.CFNumberGetValue(num, c.kCFNumberLongLongType, &int_val) != 0) {
                return Value{ .integer = @as(i64, @intCast(int_val)) };
            }
            var float_val: f64 = undefined;
            if (c.CFNumberGetValue(num, c.kCFNumberDoubleType, &float_val) != 0) {
                return Value{ .float = float_val };
            }
            return error.UnsupportedNumberType;
        } else if (type_id == c.CFBooleanGetTypeID()) {
            const bool_val = c.CFBooleanGetValue(@as(c.CFBooleanRef, @ptrCast(cf_value)));
            logger.debug("macos_defaults CFBoolean raw value: {}, converted: {}\n", .{ bool_val, bool_val != 0 });
            const result_bool = bool_val != 0;
            return Value{ .boolean = result_bool };
        } else if (type_id == c.CFStringGetTypeID()) {
            const str = @as(c.CFStringRef, @ptrCast(cf_value));
            const max_len = c.CFStringGetMaximumSizeForEncoding(c.CFStringGetLength(str), c.kCFStringEncodingUTF8);
            var buf = try allocator.alloc(u8, @as(usize, @intCast(max_len)) + 1);
            if (c.CFStringGetCString(str, buf.ptr, @as(c_long, @intCast(buf.len)), c.kCFStringEncodingUTF8) == 0) {
                allocator.free(buf);
                return error.StringConversionFailed;
            }
            const len = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
            const str_slice = try allocator.dupe(u8, buf[0..len]);
            allocator.free(buf);
            return Value{ .string = str_slice };
        } else if (type_id == c.CFArrayGetTypeID()) {
            const arr = @as(c.CFArrayRef, @ptrCast(cf_value));
            const count = c.CFArrayGetCount(arr);
            var values = std.ArrayList(Value).initCapacity(allocator, @as(usize, @intCast(count))) catch return error.OutOfMemory;
            errdefer {
                for (values.items) |*item| {
                    item.deinit(allocator);
                }
                values.deinit(allocator);
            }

            var i: c_long = 0;
            while (i < count) : (i += 1) {
                const item_cf = c.CFArrayGetValueAtIndex(arr, i);
                const item_value = try cfValueToValue(allocator, item_cf);
                values.append(allocator, item_value) catch return error.OutOfMemory;
            }

            return Value{ .array = values };
        } else if (type_id == c.CFDictionaryGetTypeID()) {
            const dict = @as(c.CFDictionaryRef, @ptrCast(cf_value));
            const count = c.CFDictionaryGetCount(dict);
            var map = std.StringHashMap(Value).init(allocator);
            errdefer {
                var it = map.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.*.deinit(allocator);
                }
                map.deinit();
            }

            var keys: [256]c.CFTypeRef = undefined;
            var values: [256]c.CFTypeRef = undefined;
            const actual_count = @as(usize, @intCast(count));
            if (actual_count > keys.len) return error.DictionaryTooLarge;

            c.CFDictionaryGetKeysAndValues(dict, &keys, &values);

            for (keys[0..actual_count], values[0..actual_count]) |key_cf, val_cf| {
                // Convert key to string
                const key_str = @as(c.CFStringRef, @ptrCast(key_cf));
                const max_len = c.CFStringGetMaximumSizeForEncoding(c.CFStringGetLength(key_str), c.kCFStringEncodingUTF8);
                var key_buf = try allocator.alloc(u8, @as(usize, @intCast(max_len)) + 1);
                if (c.CFStringGetCString(key_str, key_buf.ptr, @as(c_long, @intCast(key_buf.len)), c.kCFStringEncodingUTF8) == 0) {
                    allocator.free(key_buf);
                    return error.StringConversionFailed;
                }
                const key_len = std.mem.indexOfScalar(u8, key_buf, 0) orelse key_buf.len;
                const key_slice = try allocator.dupe(u8, key_buf[0..key_len]);
                allocator.free(key_buf);

                // Convert value
                const val = try cfValueToValue(allocator, val_cf);
                try map.put(key_slice, val);
            }

            return Value{ .dict = map };
        }

        return error.UnsupportedType;
    }

    fn valueToCFValue(allocator: std.mem.Allocator, value: Value) !*anyopaque {
        switch (value) {
            .integer => |i| {
                const num = c.CFNumberCreate(null, c.kCFNumberLongLongType, &i);
                if (num == null) return error.OutOfMemory;
                return @ptrCast(@constCast(num));
            },
            .boolean => |b| {
                logger.debug("macos_defaults valueToCFValue: converting boolean {} to CFBoolean\n", .{b});
                const bool_val = if (b) c.kCFBooleanTrue else c.kCFBooleanFalse;
                _ = c.CFRetain(bool_val);
                const result: *anyopaque = @ptrCast(@constCast(bool_val));
                const check_val = c.CFBooleanGetValue(@as(c.CFBooleanRef, @ptrCast(result)));
                logger.debug("macos_defaults valueToCFValue: CFBoolean result value: {}\n", .{check_val});
                return result;
            },
            .float => |f| {
                const num = c.CFNumberCreate(null, c.kCFNumberDoubleType, &f);
                if (num == null) return error.OutOfMemory;
                return @ptrCast(@constCast(num));
            },
            .string => |s| {
                const str = c.CFStringCreateWithCString(null, s.ptr, c.kCFStringEncodingUTF8);
                if (str == null) return error.OutOfMemory;
                return @ptrCast(@constCast(str));
            },
            .array => |arr| {
                var cf_values = try std.heap.c_allocator.alloc(?*const anyopaque, arr.items.len);
                defer std.heap.c_allocator.free(cf_values);
                errdefer {
                    for (cf_values) |cf_val| {
                        if (cf_val) |val| c.CFRelease(@constCast(val));
                    }
                }

                for (arr.items, 0..) |item, i| {
                    const cf_val = try valueToCFValue(allocator, item);
                    cf_values[i] = @ptrCast(cf_val);
                }

                const cf_array = c.CFArrayCreate(null, cf_values.ptr, @as(c_long, @intCast(arr.items.len)), null);
                if (cf_array == null) {
                    for (cf_values) |cf_val| {
                        if (cf_val) |val| c.CFRelease(@constCast(val));
                    }
                    return error.OutOfMemory;
                }

                // Release individual items (array retains them)
                for (cf_values) |cf_val| {
                    if (cf_val) |val| c.CFRelease(@constCast(val));
                }

                return @ptrCast(@constCast(cf_array));
            },
            .dict => |dict_map| {
                var cf_keys = try std.heap.c_allocator.alloc(?*const anyopaque, dict_map.count());
                defer std.heap.c_allocator.free(cf_keys);
                var cf_values = try std.heap.c_allocator.alloc(?*const anyopaque, dict_map.count());
                defer std.heap.c_allocator.free(cf_values);
                errdefer {
                    for (cf_keys) |cf_key| {
                        if (cf_key) |key| c.CFRelease(@constCast(key));
                    }
                    for (cf_values) |cf_val| {
                        if (cf_val) |val| c.CFRelease(@constCast(val));
                    }
                }

                var i: usize = 0;
                var it = dict_map.iterator();
                while (it.next()) |entry| {
                    const key_str = c.CFStringCreateWithCString(null, entry.key_ptr.*.ptr, c.kCFStringEncodingUTF8);
                    if (key_str == null) {
                        for (cf_keys[0..i]) |cf_key| {
                            if (cf_key) |key| c.CFRelease(@constCast(key));
                        }
                        for (cf_values[0..i]) |cf_val| {
                            if (cf_val) |val| c.CFRelease(@constCast(val));
                        }
                        return error.OutOfMemory;
                    }
                    cf_keys[i] = @ptrCast(key_str);

                    const cf_val = try valueToCFValue(allocator, entry.value_ptr.*);
                    cf_values[i] = @ptrCast(cf_val);
                    i += 1;
                }

                const cf_dict = c.CFDictionaryCreate(null, cf_keys.ptr, cf_values.ptr, @as(c_long, @intCast(dict_map.count())), null, null);
                if (cf_dict == null) {
                    for (cf_keys) |cf_key| {
                        if (cf_key) |key| c.CFRelease(@constCast(key));
                    }
                    for (cf_values) |cf_val| {
                        if (cf_val) |val| c.CFRelease(@constCast(val));
                    }
                    return error.OutOfMemory;
                }

                // Release individual keys and values (dictionary retains them)
                for (cf_keys) |cf_key| {
                    if (cf_key) |key| c.CFRelease(@constCast(key));
                }
                for (cf_values) |cf_val| {
                    if (cf_val) |val| c.CFRelease(@constCast(val));
                }

                return @ptrCast(@constCast(cf_dict));
            },
        }
    }
};

/// Ruby prelude for macos_defaults resource
pub const ruby_prelude = @embedFile("macos_defaults_resource.rb");

/// Zig callback: called from Ruby to add a macos_defaults resource
pub fn zigAddResource(
    mrb: *mruby.mrb_state,
    self: mruby.mrb_value,
    resources: *std.ArrayList(Resource),
    allocator: std.mem.Allocator,
) mruby.mrb_value {
    _ = self;

    // DEBUG: COMMENTING OUT CFPreferencesCopyValue - it may interfere with writes!
    // {
    //     const domain = "com.apple.finder";
    //     const key = "AppleShowAllFiles";
    //     const domain_cf = c.CFStringCreateWithCString(null, domain.ptr, c.kCFStringEncodingUTF8);
    //     const key_cf = c.CFStringCreateWithCString(null, key.ptr, c.kCFStringEncodingUTF8);
    //     const value = c.CFPreferencesCopyValue(key_cf, domain_cf, c.kCFPreferencesCurrentUser, c.kCFPreferencesAnyHost);
    //     std.debug.print("[DEBUG zigAddResource START] CFPreferencesCopyValue returned: {*}\n", .{value orelse @as(*const anyopaque, @ptrFromInt(1))});
    //     if (value) |v| {
    //         if (c.CFGetTypeID(v) == c.CFBooleanGetTypeID()) {
    //             std.debug.print("[DEBUG zigAddResource START] Boolean value: {}\n", .{c.CFBooleanGetValue(@as(c.CFBooleanRef, @ptrCast(v)))});
    //         }
    //         c.CFRelease(v);
    //     }
    //     c.CFRelease(key_cf);
    //     c.CFRelease(domain_cf);
    // }

    var domain_val: mruby.mrb_value = undefined;
    var key_val: mruby.mrb_value = undefined;
    var value_val: mruby.mrb_value = undefined;
    var action_val: mruby.mrb_value = undefined;
    var only_if_val: mruby.mrb_value = undefined;
    var not_if_val: mruby.mrb_value = undefined;
    var notifications_val: mruby.mrb_value = undefined;

    // Format: SS|Aoo|ooA
    // S: required string (domain)
    // S: required string (key)
    // |: optional args start
    // A: optional array (value: [type, value])
    // o: optional object (action)
    // |: optional args start
    // o: optional object (only_if)
    // o: optional object (not_if)
    // A: optional array (notifications)
    _ = mruby.mrb_get_args(mrb, "SS|Aoo|ooA", &domain_val, &key_val, &value_val, &action_val, &only_if_val, &not_if_val, &notifications_val);

    // Extract domain and key
    const domain_cstr = mruby.mrb_str_to_cstr(mrb, domain_val);
    const domain = allocator.dupe(u8, std.mem.span(domain_cstr)) catch return mruby.mrb_nil_value();

    const key_cstr = mruby.mrb_str_to_cstr(mrb, key_val);
    const key = allocator.dupe(u8, std.mem.span(key_cstr)) catch return mruby.mrb_nil_value();

    // Parse action (optional, default write)
    const action: Resource.Action = if (mruby.mrb_test(action_val)) blk: {
        const action_cstr = mruby.mrb_str_to_cstr(mrb, action_val);
        const action_str = std.mem.span(action_cstr);
        if (std.mem.eql(u8, action_str, "delete")) {
            break :blk .delete;
        }
        break :blk .write;
    } else .write;

    // Parse value (optional, required for write action)
    var value: Resource.Value = undefined;
    if (mruby.mrb_test(value_val)) {
        // value_val is an array: [type, value]
        const arr_len = mruby.mrb_ary_len(mrb, value_val);
        if (arr_len < 2) {
            allocator.free(domain);
            allocator.free(key);
            return mruby.mrb_nil_value();
        }

        const type_val = mruby.mrb_ary_ref(mrb, value_val, 0);
        const val_val = mruby.mrb_ary_ref(mrb, value_val, 1);

        const type_cstr = mruby.mrb_str_to_cstr(mrb, type_val);
        const type_str = std.mem.span(type_cstr);

        value = parseValueFromRuby(mrb, allocator, type_str, val_val) catch {
            allocator.free(domain);
            allocator.free(key);
            return mruby.mrb_nil_value();
        };
    } else {
        // No value provided - use empty string as placeholder (will be ignored for delete action)
        value = Resource.Value{ .string = allocator.dupe(u8, "") catch {
            allocator.free(domain);
            allocator.free(key);
            return mruby.mrb_nil_value();
        } };
    }

    // Build common properties (guards + notifications)
    var common = base.CommonProps.init(allocator);
    base.fillCommonFromRuby(&common, mrb, only_if_val, not_if_val, notifications_val, allocator);

    resources.append(allocator, .{
        .domain = domain,
        .key = key,
        .value = value,
        .action = action,
        .common = common,
    }) catch {
        allocator.free(domain);
        allocator.free(key);
        var value_to_free = value;
        value_to_free.deinit(allocator);
        return mruby.mrb_nil_value();
    };

    // DEBUG: COMMENTING OUT CFPreferencesCopyValue - it may interfere with writes!
    // {
    //     const domain_test = "com.apple.finder";
    //     const key_test = "AppleShowAllFiles";
    //     const domain_cf_test = c.CFStringCreateWithCString(null, domain_test.ptr, c.kCFStringEncodingUTF8);
    //     const key_cf_test = c.CFStringCreateWithCString(null, key_test.ptr, c.kCFStringEncodingUTF8);
    //     const value_test = c.CFPreferencesCopyValue(key_cf_test, domain_cf_test, c.kCFPreferencesCurrentUser, c.kCFPreferencesAnyHost);
    //     std.debug.print("[DEBUG zigAddResource END] CFPreferencesCopyValue returned: {*}\n", .{value_test orelse @as(*const anyopaque, @ptrFromInt(1))});
    //     if (value_test) |v| {
    //         if (c.CFGetTypeID(v) == c.CFBooleanGetTypeID()) {
    //             std.debug.print("[DEBUG zigAddResource END] Boolean value: {}\n", .{c.CFBooleanGetValue(@as(c.CFBooleanRef, @ptrCast(v)))});
    //         }
    //         c.CFRelease(v);
    //     }
    //     c.CFRelease(key_cf_test);
    //     c.CFRelease(domain_cf_test);
    // }

    return mruby.mrb_nil_value();
}

fn parseValueFromRuby(mrb: *mruby.mrb_state, allocator: std.mem.Allocator, type_str: []const u8, val_val: mruby.mrb_value) !Resource.Value {
    if (std.mem.eql(u8, type_str, "string")) {
        const val_cstr = mruby.mrb_str_to_cstr(mrb, val_val);
        const val_str = std.mem.span(val_cstr);
        return Resource.Value{ .string = try allocator.dupe(u8, val_str) };
    } else if (std.mem.eql(u8, type_str, "integer")) {
        const int_val = mruby.mrb_fixnum(mrb, val_val);
        return Resource.Value{ .integer = int_val };
    } else if (std.mem.eql(u8, type_str, "boolean")) {
        // In mruby: false = 4, true = 12, nil = 0
        // Check the raw value to determine boolean
        const bool_val = if (val_val.w == 4) false // false
            else if (val_val.w == 12) true // true
            else mruby.mrb_test(val_val); // fallback to truthy check
        return Resource.Value{ .boolean = bool_val };
    } else if (std.mem.eql(u8, type_str, "float")) {
        // mruby supports floats via mrb_float
        const float_val = mruby.mrb_float(mrb, val_val);
        return Resource.Value{ .float = float_val };
    } else if (std.mem.eql(u8, type_str, "array")) {
        const arr_len = mruby.mrb_ary_len(mrb, val_val);
        var values = std.ArrayList(Resource.Value).initCapacity(allocator, @as(usize, @intCast(arr_len))) catch return error.OutOfMemory;
        errdefer {
            for (values.items) |*item| {
                item.deinit(allocator);
            }
            values.deinit(allocator);
        }

        // For arrays, we need to know the type of each element
        // For simplicity, assume all elements are strings unless we can detect otherwise
        var i: mruby.mrb_int = 0;
        while (i < arr_len) : (i += 1) {
            const item_val = mruby.mrb_ary_ref(mrb, val_val, i);
            // Try to detect type by checking value representation
            // In mruby: fixnum has tag 0x01, false=4, nil=0, true=12
            // Try to convert to integer first (will work for fixnums)
            const int_val = mruby.mrb_fixnum(mrb, item_val);
            // Check if it's actually a fixnum by checking if conversion succeeded
            // For now, treat all numeric values as integers, boolean as boolean, rest as string
            if (mruby.mrb_test(item_val) == false and item_val.w == 0) {
                // nil or false
                const bool_val = mruby.mrb_test(item_val);
                try values.append(allocator, Resource.Value{ .boolean = bool_val });
            } else if (item_val.w == 4) {
                // false
                try values.append(allocator, Resource.Value{ .boolean = false });
            } else if (item_val.w == 12) {
                // true
                try values.append(allocator, Resource.Value{ .boolean = true });
            } else if ((item_val.w & 0x03) == 0x01) {
                // Fixnum (tag 0x01)
                try values.append(allocator, Resource.Value{ .integer = int_val });
            } else {
                // String (default)
                const item_cstr = mruby.mrb_str_to_cstr(mrb, item_val);
                const item_str = std.mem.span(item_cstr);
                try values.append(allocator, Resource.Value{ .string = try allocator.dupe(u8, item_str) });
            }
        }

        return Resource.Value{ .array = values };
    } else if (std.mem.eql(u8, type_str, "dict")) {
        // For hash/dict, we need to iterate over keys and values
        // mruby hash iteration is complex, so we'll use a simpler approach
        // For now, return an empty dict - full hash support can be added later
        const map = std.StringHashMap(Resource.Value).init(allocator);
        return Resource.Value{ .dict = map };
    } else {
        // Default to string
        const val_cstr = mruby.mrb_str_to_cstr(mrb, val_val);
        const val_str = std.mem.span(val_cstr);
        return Resource.Value{ .string = try allocator.dupe(u8, val_str) };
    }
}
