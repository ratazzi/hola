const std = @import("std");

pub fn resolvePathForLink(allocator: std.mem.Allocator, path: []const u8, home: []const u8) ![]const u8 {
    if (path.len == 0) return error.InvalidPath;
    if (path[0] == '~') {
        if (path.len == 1) return allocator.dupe(u8, home);
        if (path[1] != '/')
            return error.UnsupportedTildeUser;
        return std.fs.path.join(allocator, &.{ home, path[2..] });
    }
    if (std.fs.path.isAbsolute(path)) {
        return allocator.dupe(u8, path);
    }
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, path });
}

pub fn getDefaultDotfilesPath(allocator: std.mem.Allocator, home: []const u8) ![]const u8 {
    const state_link = try std.fs.path.join(allocator, &.{ home, ".local/state/hola/dotfiles" });
    defer allocator.free(state_link);

    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.fs.readLinkAbsolute(state_link, &link_buf)) |target| {
        return allocator.dupe(u8, target);
    } else |_| {
        return std.fs.path.join(allocator, &.{ home, ".dotfiles" });
    }
}

pub fn saveDotfilesPreference(allocator: std.mem.Allocator, dotfiles_path: []const u8, home: []const u8) !void {
    const state_dir = try std.fs.path.join(allocator, &.{ home, ".local/state/hola" });
    defer allocator.free(state_dir);

    const state_link = try std.fs.path.join(allocator, &.{ state_dir, "dotfiles" });
    defer allocator.free(state_link);

    std.fs.makeDirAbsolute(state_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    std.fs.deleteFileAbsolute(state_link) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    try std.fs.symLinkAbsolute(dotfiles_path, state_link, .{});
}
