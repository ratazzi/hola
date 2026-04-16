const std = @import("std");
const plist = @import("../plist.zig");

const c_cf = @cImport({
    @cInclude("CoreFoundation/CoreFoundation.h");
});

/// Read a dock preference from a specific host domain (AnyHost or CurrentHost).
fn readDockPrefFromHost(alloc: std.mem.Allocator, key: []const u8, host: c_cf.CFStringRef) !?plist.Value {
    const key_cf = c_cf.CFStringCreateWithCString(null, key.ptr, c_cf.kCFStringEncodingUTF8);
    if (key_cf == null) return error.OutOfMemory;
    defer c_cf.CFRelease(key_cf);

    const domain = c_cf.CFStringCreateWithCString(null, "com.apple.dock", c_cf.kCFStringEncodingUTF8);
    if (domain == null) return error.OutOfMemory;
    defer c_cf.CFRelease(domain);

    const value_cf = c_cf.CFPreferencesCopyValue(key_cf, domain, c_cf.kCFPreferencesCurrentUser, host);
    if (value_cf == null) return null;
    defer c_cf.CFRelease(value_cf);

    const type_id = c_cf.CFGetTypeID(value_cf);

    if (type_id == c_cf.CFNumberGetTypeID()) {
        const num = @as(c_cf.CFNumberRef, @ptrCast(value_cf));
        var int_val: c_longlong = undefined;
        if (c_cf.CFNumberGetValue(num, c_cf.kCFNumberLongLongType, &int_val) != 0) {
            return plist.Value{ .integer = @as(i64, @intCast(int_val)) };
        }
        return null;
    } else if (type_id == c_cf.CFBooleanGetTypeID()) {
        const bool_val = c_cf.CFBooleanGetValue(@as(c_cf.CFBooleanRef, @ptrCast(value_cf)));
        return plist.Value{ .boolean = bool_val != 0 };
    } else if (type_id == c_cf.CFStringGetTypeID()) {
        const str = @as(c_cf.CFStringRef, @ptrCast(value_cf));
        const max_len = c_cf.CFStringGetMaximumSizeForEncoding(c_cf.CFStringGetLength(str), c_cf.kCFStringEncodingUTF8);
        var buf = try alloc.alloc(u8, @as(usize, @intCast(max_len)) + 1);
        if (c_cf.CFStringGetCString(str, buf.ptr, @as(c_long, @intCast(buf.len)), c_cf.kCFStringEncodingUTF8) == 0) {
            alloc.free(buf);
            return null;
        }
        const len = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
        const str_slice = try alloc.dupe(u8, buf[0..len]);
        alloc.free(buf);
        return plist.Value{ .string = str_slice };
    } else if (type_id == c_cf.CFArrayGetTypeID()) {
        return plist.Value{ .array = undefined };
    }

    return null;
}

/// Compare two scalar plist values for equality. Treats bool and integer 0/1
/// as equivalent because CFPreferences sometimes stores booleans as CFNumbers.
fn scalarValuesEqual(a: plist.Value, b: plist.Value) bool {
    return switch (a) {
        .boolean => |x| switch (b) {
            .boolean => |y| x == y,
            .integer => |y| (if (x) @as(i64, 1) else 0) == y,
            else => false,
        },
        .integer => |x| switch (b) {
            .integer => |y| x == y,
            .boolean => |y| x == (if (y) @as(i64, 1) else 0),
            else => false,
        },
        .float => |x| switch (b) {
            .float => |y| x == y,
            else => false,
        },
        .string => |x| switch (b) {
            .string => |y| std.mem.eql(u8, x, y),
            else => false,
        },
        else => false,
    };
}

fn fmtScalarValue(val: plist.Value, buf: *[32]u8) []const u8 {
    return switch (val) {
        .boolean => |b| if (b) "true" else "false",
        .integer => |i| std.fmt.bufPrint(buf, "{d}", .{i}) catch "<int>",
        .string => |s| s,
        else => "<complex>",
    };
}

/// Return the `defaults` type flag for the scalar so the migration hint
/// writes the value back into AnyHost with the correct type.
fn defaultsTypeFlag(val: plist.Value) []const u8 {
    return switch (val) {
        .boolean => "-bool",
        .integer => "-int",
        .float => "-float",
        .string => "-string",
        else => "",
    };
}

/// Read a dock preference from AnyHost (matches defaults(1) default behavior),
/// falling back to CurrentHost when AnyHost is unset so that legacy installs
/// with only ByHost values still export their real configuration. Warn to
/// stderr when the two domains disagree or when CurrentHost is shadowing an
/// expected AnyHost value. Callers own the returned value and must deinit it.
fn readDockPref(alloc: std.mem.Allocator, key: []const u8) !?plist.Value {
    const any = try readDockPrefFromHost(alloc, key, c_cf.kCFPreferencesAnyHost);
    var cur = try readDockPrefFromHost(alloc, key, c_cf.kCFPreferencesCurrentHost);
    var return_cur = false;
    defer if (!return_cur) {
        if (cur) |*v| v.deinit(alloc);
    };

    var fmt_buf1: [32]u8 = undefined;
    var fmt_buf2: [32]u8 = undefined;

    if (any) |any_val| {
        if (cur) |cur_val| {
            if (!scalarValuesEqual(any_val, cur_val)) {
                std.debug.print("warning: com.apple.dock/{s}: AnyHost={s}, CurrentHost={s} (stale); using AnyHost\n", .{
                    key, fmtScalarValue(any_val, &fmt_buf1), fmtScalarValue(cur_val, &fmt_buf2),
                });
                std.debug.print("  hint: defaults -currentHost delete com.apple.dock {s}\n", .{key});
            }
        }
        return any;
    } else if (cur) |cur_val| {
        std.debug.print("warning: com.apple.dock/{s}: only CurrentHost={s} is set; using it for compatibility\n", .{
            key, fmtScalarValue(cur_val, &fmt_buf1),
        });
        std.debug.print("  hint: migrate with: defaults write com.apple.dock {s} {s} {s} && defaults -currentHost delete com.apple.dock {s}\n", .{
            key, defaultsTypeFlag(cur_val), fmtScalarValue(cur_val, &fmt_buf2), key,
        });
        return_cur = true;
        return cur;
    }

    return null;
}

pub fn run(allocator: std.mem.Allocator, iter: *std.process.ArgIterator) !void {
    _ = iter;

    const home_dir = std.process.getEnvVarOwned(allocator, "HOME") catch {
        std.debug.print("Error: HOME environment variable not set\n", .{});
        return;
    };
    defer allocator.free(home_dir);

    const dock_plist_path = try std.fmt.allocPrint(allocator, "{s}/Library/Preferences/com.apple.dock.plist", .{home_dir});
    defer allocator.free(dock_plist_path);

    var dict = plist.Dictionary.loadFromFile(allocator, dock_plist_path) catch |err| {
        std.debug.print("Error loading Dock plist: {}\n", .{err});
        return;
    };
    defer dict.deinit();

    var app_paths = std.ArrayList([]const u8).empty;
    defer {
        for (app_paths.items) |path| {
            allocator.free(path);
        }
        app_paths.deinit(allocator);
    }

    var persistent_apps_value = dict.get("persistent-apps") orelse {
        std.debug.print("No 'persistent-apps' key found in Dock plist\n", .{});
        return;
    };
    defer persistent_apps_value.deinit(allocator);

    const apps_array = switch (persistent_apps_value) {
        .array => |arr| arr,
        else => {
            std.debug.print("Error: 'persistent-apps' is not an array\n", .{});
            return;
        },
    };

    for (apps_array) |app_item| {
        const app_dict = switch (app_item) {
            .dictionary => |d| d,
            else => continue,
        };

        var tile_data_value = app_dict.get("tile-data") orelse continue;
        defer tile_data_value.deinit(allocator);

        const tile_data = switch (tile_data_value) {
            .dictionary => |d| d,
            else => continue,
        };

        const file_data_value = tile_data.get("file-data") orelse continue;
        const file_data_dict = switch (file_data_value) {
            .dictionary => |d| d,
            else => continue,
        };
        defer file_data_value.deinit(allocator);

        const url_string_value = file_data_dict.get("_CFURLString") orelse continue;
        defer url_string_value.deinit(allocator);

        const app_path = switch (url_string_value) {
            .string => |s| s,
            else => continue,
        };

        try app_paths.append(allocator, try allocator.dupe(u8, app_path));
    }

    var orientation_owned: ?[]u8 = null;
    defer if (orientation_owned) |s| allocator.free(s);

    const orientation = blk: {
        if (try readDockPref(allocator, "orientation")) |val| {
            defer val.deinit(allocator);
            break :blk switch (val) {
                .string => |s| blk2: {
                    orientation_owned = try allocator.dupe(u8, s);
                    break :blk2 orientation_owned.?;
                },
                else => "bottom",
            };
        }
        break :blk "bottom";
    };

    const autohide = blk: {
        if (try readDockPref(allocator, "autohide")) |val| {
            defer val.deinit(allocator);
            break :blk switch (val) {
                .boolean => |b| b,
                .integer => |i| i != 0,
                else => false,
            };
        }
        break :blk false;
    };

    const magnification = blk: {
        if (try readDockPref(allocator, "magnification")) |val| {
            defer val.deinit(allocator);
            break :blk switch (val) {
                .boolean => |b| b,
                .integer => |i| i != 0,
                else => false,
            };
        }
        break :blk false;
    };

    const tilesize = blk: {
        if (try readDockPref(allocator, "tilesize")) |val| {
            defer val.deinit(allocator);
            break :blk switch (val) {
                .integer => |i| i,
                .float => |f| @as(i64, @intFromFloat(f)),
                else => 50,
            };
        }
        break :blk 50;
    };

    const largesize = blk: {
        if (try readDockPref(allocator, "largesize")) |val| {
            defer val.deinit(allocator);
            break :blk switch (val) {
                .integer => |i| i,
                .float => |f| @as(i64, @intFromFloat(f)),
                else => 64,
            };
        }
        break :blk 64;
    };

    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    try output.appendSlice(allocator, "macos_dock do\n");
    try output.appendSlice(allocator, "  apps [\n");

    for (app_paths.items) |path| {
        const clean_path = if (std.mem.startsWith(u8, path, "file://"))
            path[7..]
        else
            path;

        const decoded_buf = try allocator.alloc(u8, clean_path.len);
        defer allocator.free(decoded_buf);
        const decoded = std.Uri.percentDecodeBackwards(decoded_buf, clean_path);

        try output.appendSlice(allocator, "    '");
        try output.appendSlice(allocator, decoded);
        try output.appendSlice(allocator, "',\n");
    }

    try output.appendSlice(allocator, "  ]\n");
    try std.fmt.format(output.writer(allocator), "  orientation :{s}\n", .{orientation});
    try std.fmt.format(output.writer(allocator), "  autohide {s}\n", .{if (autohide) "true" else "false"});
    try std.fmt.format(output.writer(allocator), "  magnification {s}\n", .{if (magnification) "true" else "false"});
    try std.fmt.format(output.writer(allocator), "  tilesize {d}\n", .{tilesize});
    try std.fmt.format(output.writer(allocator), "  largesize {d}\n", .{largesize});
    try output.appendSlice(allocator, "end\n");

    const stdout = std.fs.File.stdout();
    try stdout.writeAll(output.items);
}
