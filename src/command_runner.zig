const std = @import("std");
const global_io = @import("global_io.zig");
const logger = @import("logger.zig");

/// Execute a command with real-time output and log it via logger.logCommand.
///
/// - `args`: full argv vector (program + arguments)
/// - `cwd`: optional working directory
pub fn executeCommandWithLogging(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    cwd: ?[]const u8,
) !void {
    // Build a shell-style command string for display/logging.
    const cmd_str = try joinArgs(allocator, args);
    defer allocator.free(cmd_str);

    // Show command being executed.
    std.debug.print("\x1b[90m$ {s}\x1b[0m\n", .{cmd_str});

    const io = global_io.io();
    // Inherit stdout/stderr for real-time output.
    var proc = try std.process.spawn(io, .{
        .argv = args,
        .cwd = if (cwd) |dir| .{ .path = dir } else .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try proc.wait(io);

    const exit_code: ?i32 = switch (term) {
        .exited => |code| code,
        else => null,
    };

    logger.logCommand(cmd_str, "", "", exit_code);

    switch (term) {
        .exited => |code| {
            if (code != 0) return error.CommandFailed;
        },
        else => return error.CommandFailed,
    }
}

/// Join argv into a single space-separated string for display/logging.
fn joinArgs(allocator: std.mem.Allocator, args: []const []const u8) ![]u8 {
    var cmd_buf = try std.ArrayList(u8).initCapacity(allocator, 256);
    defer cmd_buf.deinit(allocator);

    for (args, 0..) |arg, i| {
        if (i > 0) try cmd_buf.append(allocator, ' ');
        try cmd_buf.appendSlice(allocator, arg);
    }

    return cmd_buf.toOwnedSlice(allocator);
}

test "joinArgs handles command strings longer than the initial capacity" {
    const allocator = std.testing.allocator;

    const long_arg = "x" ** 300;
    const result = try joinArgs(allocator, &.{ "sudo", "apt-get", "install", "-y", long_arg });
    defer allocator.free(result);

    try std.testing.expectEqual("sudo apt-get install -y ".len + long_arg.len, result.len);
    try std.testing.expect(std.mem.startsWith(u8, result, "sudo apt-get install -y x"));
    try std.testing.expect(std.mem.endsWith(u8, result, "xxx"));
}

test "joinArgs joins a short argv" {
    const allocator = std.testing.allocator;

    const result = try joinArgs(allocator, &.{ "echo", "hello" });
    defer allocator.free(result);

    try std.testing.expectEqualStrings("echo hello", result);
}
