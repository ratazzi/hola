const std = @import("std");
const builtin = @import("builtin");
const modern_display = @import("modern_provision_display.zig");
const logger = @import("logger.zig");
const command_runner = @import("command_runner.zig");

comptime {
    if (builtin.os.tag != .linux) {
        @compileError("apt_bootstrap is only available on Linux");
    }
}

/// Install apt packages from config_root/packages.apt.txt.
///
/// Format of packages.apt.txt:
///   - one package name per line
///   - lines starting with '#' are comments
///   - empty / whitespace-only lines are ignored
pub fn installPackages(
    allocator: std.mem.Allocator,
    config_root: []const u8,
    display: *modern_display.ModernProvisionDisplay,
    apt_path: []const u8,
) !void {
    try display.showSection("Installing Packages (apt)");

    const apt_list_path = try std.fs.path.join(allocator, &.{ config_root, "packages.apt.txt" });
    defer allocator.free(apt_list_path);

    const file = std.fs.openFileAbsolute(apt_list_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            const msg = try std.fmt.allocPrint(allocator, "No packages.apt.txt found in {s}, skipping apt install", .{config_root});
            defer allocator.free(msg);
            try display.showInfo(msg);
            return;
        },
        else => return err,
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(content);

    var packages = std.ArrayList([]const u8).init(allocator);
    defer {
        for (packages.items) |p| allocator.free(p);
        packages.deinit();
    }

    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#') continue;
        try packages.append(try allocator.dupe(u8, trimmed));
    }

    if (packages.items.len == 0) {
        try display.showInfo("packages.apt.txt is empty, skipping apt install");
        return;
    }

    // apt-get / apt update
    try display.showInfo("Running: sudo apt update");
    var update_args = [_][]const u8{ "sudo", apt_path, "update" };
    try command_runner.executeCommandWithLogging(allocator, &update_args, null);

    // apt-get / apt install -y <packages...>
    try display.showInfo("Installing apt packages...");
    var args_list = std.ArrayList([]const u8).init(allocator);

    try args_list.append(allocator, "sudo");
    try args_list.append(allocator, apt_path);
    try args_list.append(allocator, "install");
    try args_list.append(allocator, "-y");

    for (packages.items) |pkg| {
        try args_list.append(allocator, pkg);
    }

    command_runner.executeCommandWithLogging(allocator, args_list.items, null) catch |err| {
        const warning_msg = try std.fmt.allocPrint(
            allocator,
            "Warning: Some apt packages failed to install (error: {}). Continuing...",
            .{err},
        );
        defer allocator.free(warning_msg);
        try display.showInfo(warning_msg);
        logger.warn("apt-get install failed: {}\n", .{err});
    };
}
