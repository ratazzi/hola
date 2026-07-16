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
    var cmd_buf = std.ArrayList(u8).initCapacity(allocator, 256) catch std.ArrayList(u8).empty;
    defer cmd_buf.deinit(allocator);

    for (args, 0..) |arg, i| {
        if (i > 0) cmd_buf.appendAssumeCapacity(' ');
        cmd_buf.appendSliceAssumeCapacity(arg);
    }

    const cmd_str = try cmd_buf.toOwnedSlice(allocator);
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
