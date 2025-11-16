const std = @import("std");
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

    var proc = std.process.Child.init(args, allocator);
    if (cwd) |dir| {
        proc.cwd = dir;
    }
    // Inherit stdout/stderr for real-time output.
    proc.stdout_behavior = .Inherit;
    proc.stderr_behavior = .Inherit;

    try proc.spawn();
    const term = try proc.wait();

    const exit_code: ?i32 = switch (term) {
        .Exited => |code| code,
        else => null,
    };

    logger.logCommand(cmd_str, "", "", exit_code);

    switch (term) {
        .Exited => |code| {
            if (code != 0) return error.CommandFailed;
        },
        else => return error.CommandFailed,
    }
}
