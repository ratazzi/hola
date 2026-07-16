//! Homebrew wrapper implementation in Zig
//!
//! This module provides functionality to interact with Homebrew
//! using the brew command-line interface.

const std = @import("std");
const builtin = @import("builtin");
const global_io = @import("global_io.zig");

// Only compile on macOS
comptime {
    if (builtin.os.tag != .macos) {
        @compileError("brew module is only available on macOS");
    }
}

/// Error types for brew operations
pub const Error = error{
    BrewNotFound,
    OutOfMemory,
};

/// Find brew executable
pub fn findBrew(allocator: std.mem.Allocator) Error![]const u8 {
    // Check common locations
    const locations = [_][]const u8{
        "/opt/homebrew/bin/brew",
        "/usr/local/bin/brew",
        "/home/linuxbrew/.linuxbrew/bin/brew",
    };

    const io = global_io.io();
    for (locations) |path| {
        const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch continue;
        file.close(io);
        return try allocator.dupe(u8, path);
    }

    // Search PATH environment variable
    const path_env = global_io.getEnvOwned(allocator, "PATH") catch return Error.BrewNotFound;
    defer allocator.free(path_env);

    var it = std.mem.splitScalar(u8, path_env, std.fs.path.delimiter);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full_path = std.fs.path.join(allocator, &.{ dir, "brew" }) catch continue;
        defer allocator.free(full_path);

        if (std.Io.Dir.accessAbsolute(io, full_path, .{})) |_| {
            return allocator.dupe(u8, full_path) catch return Error.BrewNotFound;
        } else |_| {}
    }

    return Error.BrewNotFound;
}

test "find brew" {
    const gpa = std.testing.allocator;
    const brew_path = findBrew(gpa) catch return;
    defer gpa.free(brew_path);
    std.debug.print("Found brew at: {s}\n", .{brew_path});
}
