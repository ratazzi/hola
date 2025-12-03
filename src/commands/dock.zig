const std = @import("std");
const plist = @import("../plist.zig");

pub fn run(allocator: std.mem.Allocator, iter: *std.process.ArgIterator) !void {
    _ = iter;

    const readDockPref = struct {
        fn call(alloc: std.mem.Allocator, key: []const u8) !?plist.Value {
            const c = @cImport({
                @cInclude("CoreFoundation/CoreFoundation.h");
            });

            const key_cf = c.CFStringCreateWithCString(null, key.ptr, c.kCFStringEncodingUTF8);
            if (key_cf == null) return error.OutOfMemory;
            defer c.CFRelease(key_cf);

            const domain = c.CFStringCreateWithCString(null, "com.apple.dock", c.kCFStringEncodingUTF8);
            if (domain == null) return error.OutOfMemory;
            defer c.CFRelease(domain);

            const value_cf = c.CFPreferencesCopyValue(key_cf, domain, c.kCFPreferencesCurrentUser, c.kCFPreferencesCurrentHost);
            if (value_cf == null) {
                return null;
            }
            defer c.CFRelease(value_cf);

            const type_id = c.CFGetTypeID(value_cf);

            if (type_id == c.CFNumberGetTypeID()) {
                const num = @as(c.CFNumberRef, @ptrCast(value_cf));
                var int_val: c_longlong = undefined;
                if (c.CFNumberGetValue(num, c.kCFNumberLongLongType, &int_val) != 0) {
                    return plist.Value{ .integer = @as(i64, @intCast(int_val)) };
                }
                return null;
            } else if (type_id == c.CFBooleanGetTypeID()) {
                const bool_val = c.CFBooleanGetValue(@as(c.CFBooleanRef, @ptrCast(value_cf)));
                return plist.Value{ .boolean = bool_val != 0 };
            } else if (type_id == c.CFStringGetTypeID()) {
                const str = @as(c.CFStringRef, @ptrCast(value_cf));
                const max_len = c.CFStringGetMaximumSizeForEncoding(c.CFStringGetLength(str), c.kCFStringEncodingUTF8);
                var buf = try alloc.alloc(u8, @as(usize, @intCast(max_len)) + 1);
                if (c.CFStringGetCString(str, buf.ptr, @as(c_long, @intCast(buf.len)), c.kCFStringEncodingUTF8) == 0) {
                    alloc.free(buf);
                    return null;
                }
                const len = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
                const str_slice = try alloc.dupe(u8, buf[0..len]);
                alloc.free(buf);
                return plist.Value{ .string = str_slice };
            } else if (type_id == c.CFArrayGetTypeID()) {
                return plist.Value{ .array = undefined };
            }

            return null;
        }
    }.call;

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

    std.debug.print("{s}", .{output.items});
}
