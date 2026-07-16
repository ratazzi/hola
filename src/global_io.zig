//! Process-wide `std.Io` instance.
//!
//! Zig 0.16 requires an explicit `Io` for filesystem, time, and process
//! APIs. `main` stores the instance provided by `std.process.Init` here so
//! the rest of the codebase (including mruby C callbacks, which cannot
//! thread an `Io` parameter through) can access it. When unset (unit tests,
//! standalone tools), falls back to the blocking single-threaded
//! implementation from std.
const std = @import("std");

var override: ?std.Io = null;

pub fn set(new_io: std.Io) void {
    override = new_io;
}

pub fn io() std.Io {
    return override orelse std.Io.Threaded.global_single_threaded.io();
}

var environ_map: ?*std.process.Environ.Map = null;

pub fn setEnviron(map: *std.process.Environ.Map) void {
    environ_map = map;
}

/// Access the process environment map (set by main). Null in unit tests.
pub fn environMap() ?*std.process.Environ.Map {
    return environ_map;
}

/// Replacement for the removed `std.posix.getenv`. Returns a slice that
/// borrows from the process environment; do not free.
pub fn getEnv(key: []const u8) ?[]const u8 {
    if (environ_map) |m| return m.get(key);
    // Fallback for contexts where main hasn't run (unit tests): libc getenv,
    // available because hola always links libc.
    var buf: [256]u8 = undefined;
    if (key.len >= buf.len) return null;
    @memcpy(buf[0..key.len], key);
    buf[key.len] = 0;
    const value = std.c.getenv(buf[0..key.len :0]) orelse return null;
    return std.mem.span(value);
}

/// Drop-in replacement for the removed `std.process.getEnvVarOwned`.
pub fn getEnvOwned(
    gpa: std.mem.Allocator,
    key: []const u8,
) error{ OutOfMemory, EnvironmentVariableNotFound }![]u8 {
    const value = getEnv(key) orelse return error.EnvironmentVariableNotFound;
    return gpa.dupe(u8, value);
}
