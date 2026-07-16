const std = @import("std");
const mruby = @import("../mruby.zig");
const base = @import("../base_resource.zig");
const logger = @import("../logger.zig");
const builtin = @import("builtin");
const AsyncExecutor = @import("../async_executor.zig").AsyncExecutor;
const common = @import("package_common.zig");
const global_io = @import("../global_io.zig");

// Only compile on Linux
comptime {
    if (builtin.os.tag != .linux) {
        @compileError("apt_package resource is only available on Linux");
    }
}

/// Context for async package operations
const PackageApplyContext = struct {
    resource: *const Resource,
    action: common.Action,
};

/// APT package resource data structure
pub const Resource = struct {
    // Resource-specific properties
    names: std.ArrayList([]const u8), // Package names (supports multiple)
    display_name: []const u8, // Pre-formatted display name (e.g., "pkg1, pkg2, pkg3")
    version: ?[]const u8, // Optional version constraint (only for single package)
    options: ?[]const u8, // Additional APT options
    action: common.Action,

    // Common properties (guards, notifications, etc.)
    common_props: base.CommonProps,

    pub fn deinit(self: Resource, allocator: std.mem.Allocator) void {
        for (self.names.items) |name| {
            allocator.free(name);
        }
        var names_copy = self.names;
        names_copy.deinit(allocator);
        allocator.free(self.display_name);
        if (self.version) |v| allocator.free(v);
        if (self.options) |o| allocator.free(o);

        var common_copy = self.common_props;
        common_copy.deinit(allocator);
    }

    /// Get display name for resource (comma-separated list of all packages)
    pub fn displayName(self: Resource) []const u8 {
        return self.display_name;
    }

    pub fn apply(self: Resource) !base.ApplyResult {
        const skip_reason = try self.common_props.shouldRun(null, null);
        if (skip_reason) |reason| {
            return base.ApplyResult{
                .was_updated = false,
                .action = self.action.toString(),
                .skip_reason = reason,
            };
        }

        // Execute the entire apply operation asynchronously
        const ctx = PackageApplyContext{
            .resource = &self,
            .action = self.action,
        };

        return try AsyncExecutor.executeWithContext(
            PackageApplyContext,
            base.ApplyResult,
            ctx,
            applyAsync,
        );
    }

    /// Async apply implementation - runs in separate thread
    fn applyAsync(ctx: PackageApplyContext) !base.ApplyResult {
        switch (ctx.action) {
            .install => return try ctx.resource.applyInstallSync(),
            .remove => return try ctx.resource.applyRemoveSync(),
            .upgrade => return try ctx.resource.applyUpgradeSync(),
            .nothing => {
                return base.ApplyResult{
                    .was_updated = false,
                    .action = "nothing",
                    .skip_reason = "skipped due to action :nothing",
                };
            },
        }
    }

    fn applyInstallSync(self: Resource) !base.ApplyResult {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        // Build list of packages that need to be installed
        var to_install = std.ArrayList([]const u8).empty;
        defer to_install.deinit(allocator);

        for (self.names.items) |name| {
            if (!try isInstalled(allocator, name)) {
                try to_install.append(allocator, name);
            }
        }

        if (to_install.items.len == 0) {
            const names_str = try common.formatPackageList(allocator, self.names.items);
            defer allocator.free(names_str);
            logger.info("apt_package[{s}]: already installed", .{names_str});
            return base.ApplyResult{
                .was_updated = false,
                .action = "install",
                .skip_reason = "up to date",
            };
        }

        // Install only the missing packages
        try self.runInstallPackages(allocator, to_install.items);

        return base.ApplyResult{
            .was_updated = true,
            .action = "install",
            .skip_reason = null,
        };
    }

    fn applyRemoveSync(self: Resource) !base.ApplyResult {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        // Build list of packages that are installed and need to be removed
        var to_remove = std.ArrayList([]const u8).empty;
        defer to_remove.deinit(allocator);

        for (self.names.items) |name| {
            if (try isInstalled(allocator, name)) {
                try to_remove.append(allocator, name);
            }
        }

        if (to_remove.items.len == 0) {
            const names_str = try common.formatPackageList(allocator, self.names.items);
            defer allocator.free(names_str);
            logger.info("apt_package[{s}]: not installed", .{names_str});
            return base.ApplyResult{
                .was_updated = false,
                .action = "remove",
                .skip_reason = "up to date",
            };
        }

        // Remove only the installed packages
        try self.runRemovePackages(allocator, to_remove.items);

        return base.ApplyResult{
            .was_updated = true,
            .action = "remove",
            .skip_reason = null,
        };
    }

    fn applyUpgradeSync(self: Resource) !base.ApplyResult {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        // Upgrade all packages
        try self.runUpgradePackages(allocator, self.names.items);

        return base.ApplyResult{
            .was_updated = true,
            .action = "upgrade",
            .skip_reason = null,
        };
    }

    fn runInstallPackages(self: Resource, allocator: std.mem.Allocator, packages: []const []const u8) !void {
        const cmd = try self.buildInstallCmd(allocator, packages);
        defer allocator.free(cmd);

        const pkg_list = try std.mem.join(allocator, " ", packages);
        defer allocator.free(pkg_list);
        logger.info("apt_package[{s}]: installing", .{pkg_list});
        try runCommand(allocator, cmd, .install, packages);
    }

    fn runRemovePackages(self: Resource, allocator: std.mem.Allocator, packages: []const []const u8) !void {
        const cmd = try self.buildRemoveCmd(allocator, packages);
        defer allocator.free(cmd);

        const pkg_list = try std.mem.join(allocator, " ", packages);
        defer allocator.free(pkg_list);
        logger.info("apt_package[{s}]: removing", .{pkg_list});
        try runCommand(allocator, cmd, .remove, packages);
    }

    fn runUpgradePackages(self: Resource, allocator: std.mem.Allocator, packages: []const []const u8) !void {
        const cmd = try self.buildUpgradeCmd(allocator, packages);
        defer allocator.free(cmd);

        const pkg_list = try std.mem.join(allocator, " ", packages);
        defer allocator.free(pkg_list);
        logger.info("apt_package[{s}]: upgrading", .{pkg_list});
        try runCommand(allocator, cmd, .upgrade, packages);
    }

    fn buildInstallCmd(self: Resource, allocator: std.mem.Allocator, packages: []const []const u8) ![]const u8 {
        const pkg_list = try std.mem.join(allocator, " ", packages);
        defer allocator.free(pkg_list);

        // Use -qq to suppress output, -o Dpkg::Use-Pty=0 to prevent /dev/tty usage
        const base_opts = "-y -qq -o Dpkg::Use-Pty=0 -o Dpkg::Progress-Fancy=0";

        if (self.options) |opts| {
            return try std.fmt.allocPrint(allocator, "apt-get install {s} {s} {s}", .{ base_opts, opts, pkg_list });
        } else {
            return try std.fmt.allocPrint(allocator, "apt-get install {s} {s}", .{ base_opts, pkg_list });
        }
    }

    fn buildRemoveCmd(self: Resource, allocator: std.mem.Allocator, packages: []const []const u8) ![]const u8 {
        const pkg_list = try std.mem.join(allocator, " ", packages);
        defer allocator.free(pkg_list);

        const base_opts = "-y -qq -o Dpkg::Use-Pty=0";

        if (self.options) |opts| {
            return try std.fmt.allocPrint(allocator, "apt-get remove {s} {s} {s}", .{ base_opts, opts, pkg_list });
        } else {
            return try std.fmt.allocPrint(allocator, "apt-get remove {s} {s}", .{ base_opts, pkg_list });
        }
    }

    fn buildUpgradeCmd(self: Resource, allocator: std.mem.Allocator, packages: []const []const u8) ![]const u8 {
        const pkg_list = try std.mem.join(allocator, " ", packages);
        defer allocator.free(pkg_list);

        const base_opts = "-y -qq -o Dpkg::Use-Pty=0 -o Dpkg::Progress-Fancy=0 --only-upgrade";

        if (self.options) |opts| {
            return try std.fmt.allocPrint(allocator, "apt-get install {s} {s} {s}", .{ base_opts, opts, pkg_list });
        } else {
            return try std.fmt.allocPrint(allocator, "apt-get install {s} {s}", .{ base_opts, pkg_list });
        }
    }
};

/// Check if an APT package is installed
fn isInstalled(allocator: std.mem.Allocator, name: []const u8) !bool {
    // Check if package is installed via: dpkg-query -W -f='${Status}' <package>
    const cmd = try std.fmt.allocPrint(allocator, "dpkg-query -W -f='${{Status}}' {s} 2>/dev/null | grep -q 'install ok installed'", .{name});
    defer allocator.free(cmd);

    const result = try std.process.run(allocator, global_io.io(), .{
        .argv = &[_][]const u8{ "/bin/sh", "-c", cmd },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

/// Execute an APT command with appropriate error mapping based on action
fn runCommand(allocator: std.mem.Allocator, cmd: []const u8, action: common.Action, packages: []const []const u8) !void {
    // Set Debian/APT-specific environment variables on top of the parent
    // environment. When the process env map is unavailable (unit tests, before
    // main ran), inherit the real parent env instead of spawning with only the
    // overrides.
    var env_map_storage: ?std.process.Environ.Map = null;
    defer if (env_map_storage) |*map| map.deinit();
    var environ_map: ?*const std.process.Environ.Map = null;
    if (global_io.environMap()) |parent| {
        var env_map = try parent.clone(allocator);
        try env_map.put("DEBIAN_FRONTEND", "noninteractive");
        try env_map.put("APT_LISTCHANGES_FRONTEND", "none");
        try env_map.put("NEEDRESTART_MODE", "l"); // Avoid needrestart prompts
        env_map_storage = env_map;
        environ_map = &env_map_storage.?;
    }

    // stdin is set to /dev/null (via std.process.run) to prevent interactive prompts
    const result = try std.process.run(allocator, global_io.io(), .{
        .argv = &[_][]const u8{ "/bin/sh", "-c", cmd },
        .environ_map = environ_map,
    });

    const stdout = result.stdout;
    const stderr = result.stderr;
    defer allocator.free(stdout);
    defer allocator.free(stderr);

    const term = result.term;

    // Log output (but don't display it)
    if (stdout.len > 0) {
        const trimmed = std.mem.trim(u8, stdout, &std.ascii.whitespace);
        if (trimmed.len > 0) {
            logger.debug("  stdout: {s}", .{trimmed});
        }
    }

    if (stderr.len > 0) {
        const trimmed = std.mem.trim(u8, stderr, &std.ascii.whitespace);
        if (trimmed.len > 0) {
            logger.warn("  stderr: {s}", .{trimmed});
        }
    }

    // Check exit status and return appropriate error based on action
    switch (term) {
        .exited => |code| {
            if (code != 0) {
                // Format package list for error message
                const pkg_list = std.mem.join(allocator, ", ", packages) catch "unknown";
                defer if (pkg_list.ptr != "unknown".ptr) allocator.free(pkg_list);

                logger.err("[apt_package] {s} failed for package(s): {s}", .{ action.toString(), pkg_list });
                logger.err("[apt_package] exit code: {d}", .{code});
                if (stderr.len > 0) {
                    logger.err("[apt_package] error: {s}", .{stderr});
                }
                // Map action to corresponding error type
                return switch (action) {
                    .install => common.PackageError.InstallFailed,
                    .remove => common.PackageError.RemoveFailed,
                    .upgrade => common.PackageError.UpgradeFailed,
                    .nothing => common.PackageError.CommandFailed,
                };
            }
        },
        .signal => |sig| {
            const pkg_list = std.mem.join(allocator, ", ", packages) catch "unknown";
            defer if (pkg_list.ptr != "unknown".ptr) allocator.free(pkg_list);
            logger.err("[apt_package] command killed by signal {d} for package(s): {s}", .{ @intFromEnum(sig), pkg_list });
            return common.PackageError.CommandFailed;
        },
        else => {
            const pkg_list = std.mem.join(allocator, ", ", packages) catch "unknown";
            defer if (pkg_list.ptr != "unknown".ptr) allocator.free(pkg_list);
            logger.err("[apt_package] command failed with unknown status for package(s): {s}", .{pkg_list});
            return common.PackageError.CommandFailed;
        },
    }
}

/// Ruby prelude for apt_package resource
pub const ruby_prelude = @embedFile("apt_package_resource.rb");

/// Zig callback: called from Ruby to add an apt_package resource
pub fn zigAddResource(
    mrb: *mruby.mrb_state,
    self: mruby.mrb_value,
    resources: *std.ArrayList(Resource),
    allocator: std.mem.Allocator,
) mruby.mrb_value {
    _ = self;

    // Parse common arguments using shared helper
    const args = common.parsePackageArgs(mrb, allocator) orelse return mruby.mrb_nil_value();

    // Move parsed args into resource (ownership transfer)
    resources.append(allocator, args.intoResource(Resource)) catch {
        // Clean up parsed args if append fails
        args.deinit(allocator);
        return mruby.mrb_nil_value();
    };

    return mruby.mrb_nil_value();
}
