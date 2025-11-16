const std = @import("std");

/// Send a macOS notification with title, subtitle, and body using AppleScript
/// Uses osascript command specifically for notifications
/// Note: NSAppleScript can execute scripts successfully (e.g., UI automation, opening apps)
/// but 'display notification' specifically requires permissions that only osascript has.
/// Other AppleScript operations work fine with NSAppleScript (see applescript.zig)
pub fn notify(allocator: std.mem.Allocator, title: []const u8, subtitle: ?[]const u8, body: []const u8) !void {
    // Escape quotes in strings for AppleScript
    const title_escaped = try escapeAppleScriptString(allocator, title);
    defer allocator.free(title_escaped);

    const body_escaped = try escapeAppleScriptString(allocator, body);
    defer allocator.free(body_escaped);

    var script: []const u8 = undefined;
    if (subtitle) |sub| {
        const subtitle_escaped = try escapeAppleScriptString(allocator, sub);
        defer allocator.free(subtitle_escaped);

        script = try std.fmt.allocPrint(
            allocator,
            "display notification \"{s}\" with title \"{s}\" subtitle \"{s}\"",
            .{ body_escaped, title_escaped, subtitle_escaped },
        );
    } else {
        script = try std.fmt.allocPrint(
            allocator,
            "display notification \"{s}\" with title \"{s}\"",
            .{ body_escaped, title_escaped },
        );
    }
    defer allocator.free(script);

    // Use osascript for notifications specifically (not because NSAppleScript doesn't work,
    // but because 'display notification' requires special permissions only osascript has)
    var proc = std.process.Child.init(&[_][]const u8{ "osascript", "-e", script }, allocator);
    proc.stdout_behavior = .Ignore;
    proc.stderr_behavior = .Ignore;

    _ = try proc.spawnAndWait();
}

/// Send a simple notification with just title and body
pub fn notifySimple(allocator: std.mem.Allocator, title: []const u8, body: []const u8) !void {
    try notify(allocator, title, null, body);
}

/// Escape special characters for AppleScript strings
fn escapeAppleScriptString(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).initCapacity(allocator, input.len) catch std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    for (input) |c| {
        switch (c) {
            '"' => try result.appendSlice(allocator, "\\\""),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            else => try result.append(allocator, c),
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Convenience function: notify when apply completes
pub fn notifyApplyComplete(allocator: std.mem.Allocator, duration_seconds: f64) !void {
    const body = try std.fmt.allocPrint(allocator, "System configuration completed in {d:.1}s", .{duration_seconds});
    defer allocator.free(body);

    try notifySimple(allocator, "Hola Apply Complete", body);
}

/// Convenience function: notify when provision completes
pub fn notifyProvisionComplete(allocator: std.mem.Allocator, updated: usize, skipped: usize) !void {
    const body = try std.fmt.allocPrint(allocator, "{d} updated, {d} skipped", .{ updated, skipped });
    defer allocator.free(body);

    try notify(allocator, "Hola Provision Complete", "✅ Configuration Applied", body);
}

/// Convenience function: notify on error
pub fn notifyError(allocator: std.mem.Allocator, error_message: []const u8) !void {
    try notify(allocator, "Hola Error", "❌ Operation Failed", error_message);
}
