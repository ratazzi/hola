const std = @import("std");
const global_io = @import("global_io.zig");

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
    const io = global_io.io();
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.Io.Dir.cwd().realPath(io, &cwd_buf);
    const cwd = cwd_buf[0..cwd_len];
    return std.fs.path.join(allocator, &.{ cwd, path });
}

pub fn getDefaultDotfilesPath(allocator: std.mem.Allocator, home: []const u8) ![]const u8 {
    const io = global_io.io();
    const state_link = try std.fs.path.join(allocator, &.{ home, ".local/state/hola/dotfiles" });
    defer allocator.free(state_link);

    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.Io.Dir.readLinkAbsolute(io, state_link, &link_buf)) |link_len| {
        return allocator.dupe(u8, link_buf[0..link_len]);
    } else |_| {
        return std.fs.path.join(allocator, &.{ home, ".dotfiles" });
    }
}

/// Helper function to ignore specific errors
inline fn ignoreError(err: anyerror, comptime errors_to_ignore: []const anyerror) !void {
    inline for (errors_to_ignore) |ignored| {
        if (err == ignored) return;
    }
    return err;
}

pub fn saveDotfilesPreference(allocator: std.mem.Allocator, dotfiles_path: []const u8, home: []const u8) !void {
    const io = global_io.io();
    const state_dir = try std.fs.path.join(allocator, &.{ home, ".local/state/hola" });
    defer allocator.free(state_dir);

    const state_link = try std.fs.path.join(allocator, &.{ state_dir, "dotfiles" });
    defer allocator.free(state_link);

    std.Io.Dir.createDirAbsolute(io, state_dir, .default_dir) catch |err| try ignoreError(err, &.{error.PathAlreadyExists});
    std.Io.Dir.deleteFileAbsolute(io, state_link) catch |err| try ignoreError(err, &.{error.FileNotFound});

    try std.Io.Dir.symLinkAbsolute(io, dotfiles_path, state_link, .{});
}
