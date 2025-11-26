const std = @import("std");
const mruby = @import("../mruby.zig");
const base = @import("../base_resource.zig");
const plist = @import("../plist.zig");
const logger = @import("../logger.zig");
const builtin = @import("builtin");

comptime {
    if (builtin.os.tag != .macos) {
        @compileError("macos_dock resource is only available on macOS");
    }
}

/// macOS Dock resource data structure
pub const Resource = struct {
    // Dock configuration
    apps: std.ArrayList([]const u8), // Array of app paths/names
    tilesize: ?i64 = null, // Dock icon size
    orientation: ?[]const u8 = null, // "left", "bottom", "right"
    autohide: ?bool = null, // Auto-hide Dock
    magnification: ?bool = null, // Magnification enabled
    largesize: ?i64 = null, // Magnification size

    // Common properties (guards, notifications, etc.)
    common: base.CommonProps,

    pub fn deinit(self: Resource, allocator: std.mem.Allocator) void {
        var apps = self.apps;
        for (apps.items) |app| {
            allocator.free(app);
        }
        apps.deinit(allocator);
        if (self.orientation) |orient| {
            allocator.free(orient);
        }

        // Deinit common props
        var common = self.common;
        common.deinit(allocator);
    }

    pub fn apply(self: Resource) !base.ApplyResult {
        const skip_reason = try self.common.shouldRun();
        if (skip_reason) |reason| {
            return base.ApplyResult{
                .was_updated = false,
                .action = "configure",
                .skip_reason = reason,
            };
        }

        const was_updated = try applyConfigure(self);
        return base.ApplyResult{
            .was_updated = was_updated,
            .action = "configure",
            .skip_reason = if (was_updated) null else "up to date",
        };
    }

    fn applyConfigure(self: Resource) !bool {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        // Get Dock plist path - use actual Dock plist
        const home_dir = std.posix.getenv("HOME") orelse return error.HomeNotFound;
        const dock_plist_path = try std.fmt.allocPrint(allocator, "{s}/Library/Preferences/com.apple.dock.plist", .{home_dir});
        defer allocator.free(dock_plist_path);

        // Load existing Dock plist or create new one
        var dict = plist.Dictionary.loadFromFile(allocator, dock_plist_path) catch |err| switch (err) {
            error.FileNotFound => plist.Dictionary.init(allocator),
            else => return err,
        };
        defer dict.deinit();

        // We need to create a mutable copy to modify it
        // Since loadFromFile returns an immutable dictionary, we need to create a mutable one
        var mutable_dict = plist.Dictionary.init(allocator);
        defer mutable_dict.deinit();

        // Copy existing values to mutable dict
        const keys = try dict.keys(allocator);
        defer plist.Dictionary.freeKeys(allocator, keys);
        for (keys) |key| {
            if (dict.get(key)) |value| {
                // Copy the value before setting it, since set() will convert it to CF
                const copied_value = try copyValue(allocator, value);
                defer value.deinit(allocator); // Free the value returned by get()
                defer copied_value.deinit(allocator); // Free our copy after set() converts it to CF
                try mutable_dict.set(key, copied_value);
                // Note: set() will convert to CF and retain, so copied_value can be freed
            }
        }

        var needs_update = false;

        logger.debug("macos_dock: starting configuration check", .{});

        // Configure Dock properties using CFPreferences API
        // This ensures CFPreferences cache is updated correctly
        // Use CFPreferences to get actual current value (may not be in plist file)
        if (self.tilesize) |size| {
            const current_size_value = readDockPrefWithCFPreferences(allocator, "tilesize") catch null;
            const needs_change = if (current_size_value) |val| blk: {
                defer val.deinit(allocator);
                switch (val) {
                    .integer => |i| break :blk i != size,
                    else => break :blk true,
                }
            } else true;

            logger.debug("macos_dock: tilesize requested={d}, current={?}, needs_change={}", .{ size, current_size_value, needs_change });

            if (needs_change) {
                try updateDockPrefWithCFPreferences(allocator, "tilesize", .{ .integer = size });
                try mutable_dict.set("tilesize", .{ .integer = size });
                needs_update = true;
                logger.info("macos_dock: tilesize updated to {d}", .{size});
            }
        }

        if (self.orientation) |orient| {
            const current_orient_value = readDockPrefWithCFPreferences(allocator, "orientation") catch null;
            const needs_change = if (current_orient_value) |val| blk: {
                defer val.deinit(allocator);
                const current_orient = switch (val) {
                    .string => |s| s,
                    else => break :blk true,
                };
                break :blk !std.mem.eql(u8, current_orient, orient);
            } else true;

            logger.debug("macos_dock: orientation requested={s}, current={?}, needs_change={}", .{ orient, current_orient_value, needs_change });

            if (needs_change) {
                const orient_copy = try allocator.dupe(u8, orient);
                defer allocator.free(orient_copy);
                try updateDockPrefWithCFPreferences(allocator, "orientation", .{ .string = orient_copy });
                try mutable_dict.set("orientation", .{ .string = orient_copy });
                needs_update = true;
                logger.info("macos_dock: orientation updated to {s}", .{orient});
            }
        }

        if (self.autohide) |hide| {
            const current_autohide_value = readDockPrefWithCFPreferences(allocator, "autohide") catch null;
            const needs_change = if (current_autohide_value) |val| blk: {
                defer val.deinit(allocator);
                const current_autohide = switch (val) {
                    .boolean => |b| b,
                    else => break :blk true,
                };
                break :blk current_autohide != hide;
            } else true;

            logger.debug("macos_dock: autohide requested={}, current={?}, needs_change={}", .{ hide, current_autohide_value, needs_change });

            if (needs_change) {
                try updateDockPrefWithCFPreferences(allocator, "autohide", .{ .boolean = hide });
                try mutable_dict.set("autohide", .{ .boolean = hide });
                needs_update = true;
                logger.info("macos_dock: autohide updated to {}", .{hide});
            }
        }

        if (self.magnification) |mag| {
            const current_mag_value = readDockPrefWithCFPreferences(allocator, "magnification") catch null;
            const needs_change = if (current_mag_value) |val| blk: {
                defer val.deinit(allocator);
                const current_mag = switch (val) {
                    .boolean => |b| b,
                    else => break :blk true,
                };
                break :blk current_mag != mag;
            } else true;

            logger.debug("macos_dock: magnification requested={}, current={?}, needs_change={}", .{ mag, current_mag_value, needs_change });

            if (needs_change) {
                try updateDockPrefWithCFPreferences(allocator, "magnification", .{ .boolean = mag });
                try mutable_dict.set("magnification", .{ .boolean = mag });
                needs_update = true;
                logger.info("macos_dock: magnification updated to {}", .{mag});
            }
        }

        if (self.largesize) |size| {
            const current_size_value = readDockPrefWithCFPreferences(allocator, "largesize") catch null;
            const needs_change = if (current_size_value) |val| blk: {
                defer val.deinit(allocator);
                const current_size = switch (val) {
                    .integer => |i| i,
                    else => break :blk true,
                };
                break :blk current_size != size;
            } else true;

            logger.debug("macos_dock: largesize requested={d}, current={?}, needs_change={}", .{ size, current_size_value, needs_change });

            if (needs_change) {
                try updateDockPrefWithCFPreferences(allocator, "largesize", .{ .integer = size });
                try mutable_dict.set("largesize", .{ .integer = size });
                needs_update = true;
                logger.info("macos_dock: largesize updated to {d}", .{size});
            }
        }

        // Configure apps order
        var apps_changed = false;
        if (self.apps.items.len > 0) {
            const current_apps_value = mutable_dict.get("persistent-apps");
            var current_apps: []const plist.Value = &[_]plist.Value{};
            var current_apps_owned: ?[]plist.Value = null;
            defer if (current_apps_owned) |arr| {
                for (arr) |item| {
                    item.deinit(allocator);
                }
                allocator.free(arr);
            };
            if (current_apps_value) |val| {
                defer val.deinit(allocator);
                switch (val) {
                    .array => |arr| {
                        // Deep copy the array to avoid use-after-free
                        const copied_arr = try allocator.alloc(plist.Value, arr.len);
                        for (arr, 0..) |item, i| {
                            copied_arr[i] = try copyValue(allocator, item);
                        }
                        current_apps_owned = copied_arr;
                        current_apps = copied_arr;
                    },
                    else => {},
                }
            }

            // Build new apps array from provided app paths
            var new_apps = std.ArrayList(plist.Value).initCapacity(allocator, self.apps.items.len) catch std.ArrayList(plist.Value).empty;
            var apps_transferred = false;
            defer if (!apps_transferred) {
                for (new_apps.items) |app| {
                    app.deinit(allocator);
                }
                new_apps.deinit(allocator);
            };

            app_loop: for (self.apps.items) |app_path| {
                // Find existing app entry or create new one
                var app_entry: ?plist.Value = null;

                // Normalize the requested path for comparison (decode URL encoding)
                const normalized_requested_path = try urlDecode(allocator, app_path);
                defer allocator.free(normalized_requested_path);

                // Try to find existing app by path
                for (current_apps) |existing_app| {
                    // Create a mutable copy of the app value for comparison
                    const existing_path = extractAppPath(allocator, existing_app) catch null;
                    defer if (existing_path) |p| allocator.free(p);
                    if (existing_path) |p| {
                        // Compare normalized paths
                        if (std.mem.eql(u8, p, normalized_requested_path)) {
                            // Found existing app, create a copy since we'll use it in new array
                            app_entry = try copyAppValue(allocator, existing_app);
                            break;
                        }
                    }
                }

                // If not found, create new app entry
                if (app_entry == null) {
                    app_entry = createAppEntry(allocator, app_path) catch |err| switch (err) {
                        error.AppNotFound => {
                            logger.warn("macos_dock: app path does not exist, skipping: {s}", .{app_path});
                            continue :app_loop;
                        },
                        else => return err,
                    };
                }

                try new_apps.append(allocator, app_entry.?);
            }

            // Check if apps order changed, based on the effective (non-skipped) apps list.
            apps_changed = if (current_apps.len != new_apps.items.len) true else blk: {
                for (new_apps.items, 0..) |new_app, i| {
                    if (i >= current_apps.len) break :blk true;

                    const new_path = extractAppPath(allocator, new_app) catch break :blk true;
                    defer allocator.free(new_path);

                    const old_path = extractAppPath(allocator, current_apps[i]) catch break :blk true;
                    defer allocator.free(old_path);

                    if (!std.mem.eql(u8, new_path, old_path)) {
                        logger.debug(
                            "macos_dock: apps mismatch at index {d}: new={s}, old={s}\n",
                            .{ i, new_path, old_path },
                        );
                        break :blk true;
                    }
                }
                break :blk false;
            };

            logger.debug(
                "macos_dock: apps current_count={d}, effective_requested_count={d}, apps_changed={}\n",
                .{ current_apps.len, new_apps.items.len, apps_changed },
            );

            if (apps_changed) {
                // Transfer ownership of apps from new_apps to apps_array
                // Don't deinit new_apps items since they're being transferred
                const apps_array = try allocator.alloc(plist.Value, new_apps.items.len);
                for (new_apps.items, 0..) |app, i| {
                    apps_array[i] = app;
                }
                // Mark as transferred so defer won't free them
                apps_transferred = true;
                // Clear new_apps without deinit'ing items (they're now owned by apps_array)
                new_apps.clearRetainingCapacity();
                new_apps.deinit(allocator);
                // Create Value and set it
                const apps_value = plist.Value{ .array = apps_array };

                try mutable_dict.set("persistent-apps", apps_value);

                // IMPORTANT: After mutable_dict.set(), toCF() has been called which:
                // 1. Creates a CFArray and calls CFRetain on each dictionary
                // 2. CFArray takes ownership of the dictionaries (they're now managed by CF)
                // 3. The CFArray itself is retained by the mutable_dict
                //
                // However, the apps_array slice itself (the array container) is still allocated
                // by our allocator and needs to be freed. We can't call deinit() on the array
                // because that would try to deinit the dictionaries, which are now owned by CF.
                // So we just free the array slice memory without deinit'ing its elements.
                allocator.free(apps_array);

                needs_update = true;
            }
        }

        logger.debug("macos_dock: final check needs_update={}, apps_changed={}", .{ needs_update, apps_changed });

        // Save if changes were made
        if (needs_update) {
            logger.info("macos_dock: configuration changed, restarting Dock", .{});

            // Use CFPreferences API to set values (like dockutil does)
            // This is more reliable than directly modifying plist files
            const c = @cImport({
                @cInclude("CoreFoundation/CoreFoundation.h");
            });

            const domain = c.CFStringCreateWithCString(null, "com.apple.dock", c.kCFStringEncodingUTF8);
            if (domain == null) return error.OutOfMemory;
            defer c.CFRelease(domain);

            // Only write the values we explicitly modified
            // For persistent-apps, directly get the CFArray from mutable_dict's cf_dict
            // Only set persistent-apps if apps were actually changed
            if (apps_changed) {
                logger.debug("macos_dock: setting persistent-apps via CFPreferences", .{});
                const cf_key = c.CFStringCreateWithCString(null, "persistent-apps", c.kCFStringEncodingUTF8);
                if (cf_key != null) {
                    defer c.CFRelease(cf_key);

                    // Get the CFArray directly from the CFDictionary
                    const cf_value = c.CFDictionaryGetValue(@as(c.CFDictionaryRef, @ptrCast(mutable_dict.cf_dict)), cf_key);
                    if (cf_value != null) {
                        c.CFPreferencesSetAppValue(cf_key, cf_value, domain);
                    }
                }
            }

            // CRITICAL: Kill Dock BEFORE setting preferences!
            // If we set preferences while Dock is running, it will overwrite them when it exits
            logger.debug("macos_dock: killing Dock with SIGKILL", .{});
            try killDockWithSignal9();

            // Wait for Dock to fully exit
            std.Thread.sleep(500_000_000); // 0.5 seconds

            // NOW set the preferences (Dock is not running, so it can't overwrite)
            logger.debug("macos_dock: synchronizing preferences", .{});
            _ = c.CFPreferencesSynchronize(domain, c.kCFPreferencesCurrentUser, c.kCFPreferencesAnyHost);

            // Verify that the value was actually saved
            const verify_key = c.CFStringCreateWithCString(null, "persistent-apps", c.kCFStringEncodingUTF8);
            if (verify_key != null) {
                defer c.CFRelease(verify_key);
                const saved_value = c.CFPreferencesCopyAppValue(verify_key, domain);
                if (saved_value != null) {
                    c.CFRelease(saved_value);
                }
            }

            // Dock will automatically restart after being killed
            std.Thread.sleep(1_000_000_000); // 1 second

            logger.info("macos_dock: Dock restart completed", .{});
            return true;
        }

        // No changes needed, Dock doesn't need to be restarted
        logger.debug("macos_dock: no changes needed, skipping Dock restart", .{});
        return false;
    }

    fn copyAppValue(allocator: std.mem.Allocator, app_value: plist.Value) !plist.Value {
        // Deep copy the app value
        switch (app_value) {
            .dictionary => |app_dict| {
                var new_app_dict = plist.Dictionary.init(allocator);
                const keys = try app_dict.keys(allocator);
                defer plist.Dictionary.freeKeys(allocator, keys);
                for (keys) |key| {
                    if (app_dict.get(key)) |value| {
                        const copied_value = try copyValue(allocator, value);
                        defer value.deinit(allocator);
                        defer copied_value.deinit(allocator);
                        try new_app_dict.set(key, copied_value);
                        // Note: set() will convert to CF and retain, so copied_value can be freed
                    }
                }
                return plist.Value{ .dictionary = new_app_dict };
            },
            else => return error.InvalidFormat,
        }
    }

    fn copyValue(allocator: std.mem.Allocator, value: plist.Value) !plist.Value {
        switch (value) {
            .string => |s| {
                const s_copy = try allocator.dupe(u8, s);
                return plist.Value{ .string = s_copy };
            },
            .data => |d| {
                const d_copy = try allocator.dupe(u8, d);
                return plist.Value{ .data = d_copy };
            },
            .integer => |i| return plist.Value{ .integer = i },
            .float => |f| return plist.Value{ .float = f },
            .boolean => |b| return plist.Value{ .boolean = b },
            .dictionary => |dict| {
                var new_dict = plist.Dictionary.init(allocator);
                const keys = try dict.keys(allocator);
                defer plist.Dictionary.freeKeys(allocator, keys);
                for (keys) |key| {
                    if (dict.get(key)) |val| {
                        // Copy the value before setting it
                        const copied_val = try copyValue(allocator, val);
                        defer val.deinit(allocator); // Free the value returned by get()
                        defer copied_val.deinit(allocator); // Free our copy after set() converts it to CF
                        try new_dict.set(key, copied_val);
                        // Note: set() will convert to CF and retain, so copied_val can be freed
                        // But we still need to free val here since it was allocated by get()
                    }
                }
                return plist.Value{ .dictionary = new_dict };
            },
            .array => |arr| {
                const new_arr = try allocator.alloc(plist.Value, arr.len);
                errdefer {
                    // Only free items that were successfully copied
                    for (new_arr) |*item| {
                        item.deinit(allocator);
                    }
                    allocator.free(new_arr);
                }
                for (arr, 0..) |item, i| {
                    new_arr[i] = try copyValue(allocator, item);
                }
                return plist.Value{ .array = new_arr };
            },
            else => return value,
        }
    }

    fn extractAppPath(allocator: std.mem.Allocator, app_value: plist.Value) ![]const u8 {
        switch (app_value) {
            .dictionary => |app_dict| {
                const tile_data_value = app_dict.get("tile-data") orelse return error.InvalidFormat;
                defer tile_data_value.deinit(allocator);
                const tile_data = switch (tile_data_value) {
                    .dictionary => |td| td,
                    else => return error.InvalidFormat,
                };
                const file_data_value = tile_data.get("file-data") orelse return error.InvalidFormat;
                defer file_data_value.deinit(allocator);
                const file_data = switch (file_data_value) {
                    .dictionary => |fd| fd,
                    else => return error.InvalidFormat,
                };
                const url_value = file_data.get("_CFURLString") orelse return error.InvalidFormat;
                defer url_value.deinit(allocator);
                const url_str = switch (url_value) {
                    .string => |s| s,
                    else => return error.InvalidFormat,
                };
                // Extract path from file:// URL format
                // Format: file:///absolute/path -> /absolute/path
                var path: []const u8 = undefined;
                if (std.mem.startsWith(u8, url_str, "file://")) {
                    path = url_str["file://".len..];
                } else {
                    // Fallback: return as-is if not in file:// format (for backward compatibility)
                    path = url_str;
                }
                // Normalize path: remove trailing slash if present
                var normalized_path = path;
                if (normalized_path.len > 0 and normalized_path[normalized_path.len - 1] == '/') {
                    normalized_path = normalized_path[0 .. normalized_path.len - 1];
                }
                // Decode URL encoding (e.g., %20 -> space)
                const decoded_path = try urlDecode(allocator, normalized_path);
                return decoded_path;
            },
            else => return error.InvalidFormat,
        }
    }

    fn urlDecode(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
        var result = try std.ArrayList(u8).initCapacity(allocator, encoded.len);
        errdefer result.deinit(allocator);

        var i: usize = 0;
        while (i < encoded.len) : (i += 1) {
            if (encoded[i] == '%' and i + 2 < encoded.len) {
                // Parse hex digits
                const hex = encoded[i + 1 .. i + 3];
                const value = std.fmt.parseInt(u8, hex, 16) catch {
                    // Invalid hex, just append the %
                    try result.append(allocator, '%');
                    continue;
                };
                try result.append(allocator, value);
                i += 2; // Skip the two hex digits
            } else {
                try result.append(allocator, encoded[i]);
            }
        }

        return result.toOwnedSlice(allocator);
    }

    fn createAppEntry(allocator: std.mem.Allocator, app_path: []const u8) !plist.Value {
        const c = @cImport({
            @cInclude("CoreFoundation/CoreFoundation.h");
        });

        // Create app entry structure
        var app_dict = plist.Dictionary.init(allocator);
        // Don't defer deinit - ownership will be transferred to the returned Value

        var tile_data_dict = plist.Dictionary.init(allocator);
        // Don't defer deinit - ownership will be transferred

        var file_data_dict = plist.Dictionary.init(allocator);
        // Don't defer deinit - ownership will be transferred

        // Clean the app path: remove trailing slash if present
        var clean_path = app_path;
        if (app_path.len > 0 and app_path[app_path.len - 1] == '/') {
            clean_path = app_path[0 .. app_path.len - 1];
        }

        // URL decode the path (convert %20 to space, etc.)
        const decoded_path = try urlDecode(allocator, clean_path);
        defer allocator.free(decoded_path);

        // If the decoded path does not exist on disk, skip this app.
        std.fs.accessAbsolute(decoded_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return error.AppNotFound,
            else => return err,
        };

        // CFStringCreateWithCString requires a null-terminated string
        // Add null terminator
        const decoded_path_z = try allocator.dupeZ(u8, decoded_path);
        defer allocator.free(decoded_path_z);

        // Create security-scoped bookmark using NSURL
        const ns_path = c.CFStringCreateWithCString(null, decoded_path_z.ptr, c.kCFStringEncodingUTF8);
        if (ns_path == null) return error.OutOfMemory;
        defer c.CFRelease(ns_path);

        const file_url = c.CFURLCreateWithFileSystemPath(null, ns_path, c.kCFURLPOSIXPathStyle, 1); // 1 = directory
        if (file_url == null) return error.InvalidPath;
        defer c.CFRelease(file_url);

        // Create bookmark data
        var bookmark_error: c.CFErrorRef = null;
        const bookmark_data = c.CFURLCreateBookmarkData(
            null,
            file_url,
            c.kCFURLBookmarkCreationSuitableForBookmarkFile,
            null,
            null,
            &bookmark_error,
        );
        if (bookmark_data == null) {
            if (bookmark_error != null) c.CFRelease(bookmark_error);
            return error.BookmarkCreationFailed;
        }
        defer c.CFRelease(bookmark_data);

        // Convert bookmark data to plist.Value
        const data_length = c.CFDataGetLength(bookmark_data);
        if (data_length <= 0) {
            return error.InvalidBookmarkData;
        }

        const data_bytes = c.CFDataGetBytePtr(bookmark_data);
        if (data_bytes == null) {
            return error.InvalidBookmarkData;
        }

        const bookmark_copy = try allocator.alloc(u8, @intCast(data_length));
        @memcpy(bookmark_copy, data_bytes[0..@intCast(data_length)]);

        const bookmark_value = plist.Value{ .data = bookmark_copy };
        defer bookmark_value.deinit(allocator);
        try tile_data_dict.set("book", bookmark_value);

        // Set _CFURLString - must end with trailing slash for .app bundles
        const url_str = try std.fmt.allocPrint(allocator, "file://{s}/", .{decoded_path});
        const url_value = plist.Value{ .string = url_str };
        defer url_value.deinit(allocator); // Free after set() converts it to CF
        try file_data_dict.set("_CFURLString", url_value);

        // Set _CFURLStringType (15 for file URLs with bookmark)
        const url_type_value = plist.Value{ .integer = 15 };
        defer url_type_value.deinit(allocator);
        try file_data_dict.set("_CFURLStringType", url_type_value);

        // Set file-data
        // Mark file_data_dict as not owned since it will be retained by tile_data_dict
        var file_data_value = plist.Value{ .dictionary = file_data_dict };
        file_data_value.dictionary.owned = false;
        defer file_data_value.deinit(allocator); // Free after set() converts it to CF (won't release cf_dict since owned=false)
        try tile_data_dict.set("file-data", file_data_value);
        // file_data_dict is now owned by tile_data_dict (via CF), don't deinit

        // Set tile-data
        // Mark tile_data_dict as not owned since it will be retained by app_dict
        var tile_data_value = plist.Value{ .dictionary = tile_data_dict };
        tile_data_value.dictionary.owned = false;
        defer tile_data_value.deinit(allocator); // Free after set() converts it to CF (won't release cf_dict since owned=false)
        try app_dict.set("tile-data", tile_data_value);
        // tile_data_dict is now owned by app_dict (via CF), don't deinit

        // app_dict will be owned by the returned Value
        return plist.Value{ .dictionary = app_dict };
    }

    fn readDockPrefWithCFPreferences(allocator: std.mem.Allocator, key: []const u8) !?plist.Value {
        const c = @cImport({
            @cInclude("CoreFoundation/CoreFoundation.h");
        });

        // Convert key to CFString
        const key_cf = c.CFStringCreateWithCString(null, key.ptr, c.kCFStringEncodingUTF8);
        if (key_cf == null) return error.OutOfMemory;
        defer c.CFRelease(key_cf);

        // Read preference using CFPreferences
        const domain = c.CFStringCreateWithCString(null, "com.apple.dock", c.kCFStringEncodingUTF8);
        if (domain == null) return error.OutOfMemory;
        defer c.CFRelease(domain);

        const value_cf = c.CFPreferencesCopyValue(key_cf, domain, c.kCFPreferencesCurrentUser, c.kCFPreferencesCurrentHost);
        if (value_cf == null) {
            // Key doesn't exist
            return null;
        }
        defer c.CFRelease(value_cf);

        // Convert CFTypeRef to plist.Value
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
            var buf = try allocator.alloc(u8, @as(usize, @intCast(max_len)) + 1);
            if (c.CFStringGetCString(str, buf.ptr, @as(c_long, @intCast(buf.len)), c.kCFStringEncodingUTF8) == 0) {
                allocator.free(buf);
                return null;
            }
            // Trim to actual length (null-terminated)
            const len = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
            const str_slice = try allocator.dupe(u8, buf[0..len]);
            allocator.free(buf);
            return plist.Value{ .string = str_slice };
        }

        return null;
    }

    fn updateDockPrefWithCFPreferences(_: std.mem.Allocator, key: []const u8, value: plist.Value) !void {
        const c = @cImport({
            @cInclude("CoreFoundation/CoreFoundation.h");
        });

        // Convert key to CFString
        const key_cf = c.CFStringCreateWithCString(null, key.ptr, c.kCFStringEncodingUTF8);
        if (key_cf == null) return error.OutOfMemory;
        defer c.CFRelease(key_cf);

        // Convert value to CFTypeRef
        var value_cf: c.CFTypeRef = undefined;
        switch (value) {
            .integer => |i| {
                const num = c.CFNumberCreate(null, c.kCFNumberLongLongType, &i);
                if (num == null) return error.OutOfMemory;
                value_cf = num;
            },
            .boolean => |b| {
                value_cf = if (b) c.kCFBooleanTrue else c.kCFBooleanFalse;
                _ = c.CFRetain(value_cf); // Retain since we'll release it
            },
            .string => |s| {
                const str = c.CFStringCreateWithCString(null, s.ptr, c.kCFStringEncodingUTF8);
                if (str == null) return error.OutOfMemory;
                value_cf = str;
            },
            else => return error.UnsupportedType,
        }
        defer c.CFRelease(value_cf);

        // Set preference using CFPreferences
        const domain = c.CFStringCreateWithCString(null, "com.apple.dock", c.kCFStringEncodingUTF8);
        if (domain == null) return error.OutOfMemory;
        defer c.CFRelease(domain);

        c.CFPreferencesSetValue(key_cf, value_cf, domain, c.kCFPreferencesCurrentUser, c.kCFPreferencesCurrentHost);

        // Synchronize to ensure cache is updated and written to disk
        if (c.CFPreferencesSynchronize(domain, c.kCFPreferencesCurrentUser, c.kCFPreferencesCurrentHost) == 0) {
            return error.PreferencesSyncFailed;
        }
    }

    fn restartDockGracefully() !void {
        // Use killall without -9 to allow Dock to terminate gracefully
        // This lets Dock save its state properly before exiting
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var proc = std.process.Child.init(&[_][]const u8{ "killall", "Dock" }, allocator);
        proc.stdout_behavior = .Ignore;
        proc.stderr_behavior = .Ignore;
        _ = try proc.spawnAndWait();

        // Wait a moment for Dock to restart
        std.Thread.sleep(1_000_000_000); // 1 second
    }

    fn killDockWithSignal9() !void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        // Use kill -9 to force kill Dock without allowing it to save state
        // Find Dock process PID first
        var proc = std.process.Child.init(&[_][]const u8{ "pgrep", "-x", "Dock" }, allocator);
        proc.stdout_behavior = .Pipe;
        proc.stderr_behavior = .Ignore;
        try proc.spawn();

        const stdout = proc.stdout orelse {
            _ = proc.wait() catch {};
            return;
        };

        var buf: [32]u8 = undefined;
        const bytes_read = stdout.read(&buf) catch {
            _ = proc.wait() catch {};
            return;
        };
        _ = proc.wait() catch {};

        if (bytes_read > 0) {
            // Parse PID and kill with signal 9
            const pid_str = std.mem.trim(u8, buf[0..bytes_read], " \n\r");
            if (pid_str.len > 0) {
                var kill_proc = std.process.Child.init(&[_][]const u8{ "kill", "-9", pid_str }, allocator);
                kill_proc.stdout_behavior = .Ignore;
                kill_proc.stderr_behavior = .Ignore;
                _ = kill_proc.spawnAndWait() catch {};
            }
        }
    }
};

/// Ruby prelude for macos_dock resource
pub const ruby_prelude = @embedFile("macos_dock_resource.rb");

/// Zig callback: called from Ruby to add a macos_dock resource
pub fn zigAddResource(
    mrb: *mruby.mrb_state,
    self: mruby.mrb_value,
    resources: *std.ArrayList(Resource),
    allocator: std.mem.Allocator,
) mruby.mrb_value {
    _ = self;

    var apps_val: mruby.mrb_value = undefined;
    var tilesize_val: mruby.mrb_value = undefined;
    var orientation_val: mruby.mrb_value = undefined;
    var autohide_val: mruby.mrb_value = undefined;
    var magnification_val: mruby.mrb_value = undefined;
    var largesize_val: mruby.mrb_value = undefined;
    var only_if_val: mruby.mrb_value = undefined;
    var not_if_val: mruby.mrb_value = undefined;
    var ignore_failure_val: mruby.mrb_value = undefined;
    var notifications_val: mruby.mrb_value = undefined;
    var subscriptions_val: mruby.mrb_value = undefined;

    // Format: A|iSbbioooAA
    // A: required array (apps)
    // |: optional args start
    // i: optional integer (tilesize)
    // S: optional string (orientation)
    // b: optional boolean (autohide)
    // b: optional boolean (magnification)
    // i: optional integer (largesize)
    // o: optional object (only_if)
    // o: optional object (not_if)
    // o: optional object (ignore_failure)
    // A: optional array (notifications)
    // A: optional array (subscriptions)
    _ = mruby.mrb_get_args(mrb, "A|iSbbioooAA", &apps_val, &tilesize_val, &orientation_val, &autohide_val, &magnification_val, &largesize_val, &only_if_val, &not_if_val, &ignore_failure_val, &notifications_val, &subscriptions_val);

    // Parse apps array
    var apps = std.ArrayList([]const u8).initCapacity(allocator, 0) catch std.ArrayList([]const u8).empty;
    const apps_len = mruby.mrb_ary_len(mrb, apps_val);
    for (0..@intCast(apps_len)) |i| {
        const app_val = mruby.mrb_ary_ref(mrb, apps_val, @intCast(i));
        const app_cstr = mruby.mrb_str_to_cstr(mrb, app_val);
        const app_path = allocator.dupe(u8, std.mem.span(app_cstr)) catch return mruby.mrb_nil_value();
        apps.append(allocator, app_path) catch return mruby.mrb_nil_value();
    }

    // Parse optional parameters
    var tilesize: ?i64 = null;
    if (mruby.mrb_test(tilesize_val)) {
        tilesize = @as(i64, @intCast(@as(i32, @bitCast(@as(u32, @intCast(tilesize_val.w & 0xFFFFFFFF))))));
    }

    var orientation: ?[]const u8 = null;
    if (mruby.mrb_test(orientation_val)) {
        const orient_cstr = mruby.mrb_str_to_cstr(mrb, orientation_val);
        const orient_str = std.mem.span(orient_cstr);
        if (orient_str.len > 0) {
            orientation = allocator.dupe(u8, orient_str) catch return mruby.mrb_nil_value();
        }
    }

    // For boolean values in mruby word boxing:
    // - nil:   0xAAAAAAAAAAAAAAAA
    // - false: 0xAAAAAAAAAAAAAA00
    // - true:  0xAAAAAAAAAAAAAA01
    var autohide: ?bool = null;
    // Check if the upper bits match the boolean pattern
    if ((autohide_val.w & 0xFFFFFFFFFFFFFF00) == 0xAAAAAAAAAAAAAA00) {
        // It's a boolean, check the last byte
        autohide = (autohide_val.w & 0x01) != 0;
    }

    var magnification: ?bool = null;
    if ((magnification_val.w & 0xFFFFFFFFFFFFFF00) == 0xAAAAAAAAAAAAAA00) {
        magnification = (magnification_val.w & 0x01) != 0;
    }

    var largesize: ?i64 = null;
    if (mruby.mrb_test(largesize_val)) {
        largesize = @as(i64, @intCast(@as(i32, @bitCast(@as(u32, @intCast(largesize_val.w & 0xFFFFFFFF))))));
    }

    // Build common properties (guards + notifications)
    var common = base.CommonProps.init(allocator);
    base.fillCommonFromRuby(&common, mrb, only_if_val, not_if_val, ignore_failure_val, notifications_val, subscriptions_val, allocator);

    resources.append(allocator, Resource{
        .apps = apps,
        .tilesize = tilesize,
        .orientation = orientation,
        .autohide = autohide,
        .magnification = magnification,
        .largesize = largesize,
        .common = common,
    }) catch return mruby.mrb_nil_value();

    return mruby.mrb_nil_value();
}
