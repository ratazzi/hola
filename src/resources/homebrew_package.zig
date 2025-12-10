const std = @import("std");
const mruby = @import("../mruby.zig");
const base = @import("../base_resource.zig");
const logger = @import("../logger.zig");
const builtin = @import("builtin");
const AsyncExecutor = @import("../async_executor.zig").AsyncExecutor;
const common = @import("package_common.zig");

// Only compile on macOS
comptime {
    if (builtin.os.tag != .macos) {
        @compileError("homebrew_package resource is only available on macOS");
    }
}

/// Context for async package operations
const PackageApplyContext = struct {
    resource: *const Resource,
    action: common.Action,
};

/// Homebrew package resource data structure
pub const Resource = struct {
    // Resource-specific properties
    names: std.ArrayList([]const u8), // Package names (supports multiple)
    display_name: []const u8, // Pre-formatted display name (e.g., "pkg1, pkg2, pkg3")
    version: ?[]const u8, // Optional version constraint (only for single package)
    options: ?[]const u8, // Additional Homebrew options
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
            logger.info("homebrew_package[{s}]: already installed", .{names_str});
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
            logger.info("homebrew_package[{s}]: not installed", .{names_str});
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
        logger.info("homebrew_package[{s}]: installing", .{pkg_list});
        try runCommand(allocator, cmd, .install);
    }

    fn runRemovePackages(self: Resource, allocator: std.mem.Allocator, packages: []const []const u8) !void {
        const cmd = try self.buildRemoveCmd(allocator, packages);
        defer allocator.free(cmd);

        const pkg_list = try std.mem.join(allocator, " ", packages);
        defer allocator.free(pkg_list);
        logger.info("homebrew_package[{s}]: removing", .{pkg_list});
        try runCommand(allocator, cmd, .remove);
    }

    fn runUpgradePackages(self: Resource, allocator: std.mem.Allocator, packages: []const []const u8) !void {
        const cmd = try self.buildUpgradeCmd(allocator, packages);
        defer allocator.free(cmd);

        const pkg_list = try std.mem.join(allocator, " ", packages);
        defer allocator.free(pkg_list);
        logger.info("homebrew_package[{s}]: upgrading", .{pkg_list});
        try runCommand(allocator, cmd, .upgrade);
    }

    fn buildInstallCmd(self: Resource, allocator: std.mem.Allocator, packages: []const []const u8) ![]const u8 {
        const pkg_list = try std.mem.join(allocator, " ", packages);
        defer allocator.free(pkg_list);

        // Use --quiet to suppress output
        const base_opts = "--quiet";

        if (self.options) |opts| {
            return try std.fmt.allocPrint(allocator, "brew install {s} {s} {s}", .{ base_opts, opts, pkg_list });
        } else {
            return try std.fmt.allocPrint(allocator, "brew install {s} {s}", .{ base_opts, pkg_list });
        }
    }

    fn buildRemoveCmd(self: Resource, allocator: std.mem.Allocator, packages: []const []const u8) ![]const u8 {
        const pkg_list = try std.mem.join(allocator, " ", packages);
        defer allocator.free(pkg_list);

        const base_opts = "--quiet";

        if (self.options) |opts| {
            return try std.fmt.allocPrint(allocator, "brew uninstall {s} {s} {s}", .{ base_opts, opts, pkg_list });
        } else {
            return try std.fmt.allocPrint(allocator, "brew uninstall {s} {s}", .{ base_opts, pkg_list });
        }
    }

    fn buildUpgradeCmd(self: Resource, allocator: std.mem.Allocator, packages: []const []const u8) ![]const u8 {
        const pkg_list = try std.mem.join(allocator, " ", packages);
        defer allocator.free(pkg_list);

        const base_opts = "--quiet";

        if (self.options) |opts| {
            return try std.fmt.allocPrint(allocator, "brew upgrade {s} {s} {s}", .{ base_opts, opts, pkg_list });
        } else {
            return try std.fmt.allocPrint(allocator, "brew upgrade {s} {s}", .{ base_opts, pkg_list });
        }
    }
};

/// Check if a Homebrew package is installed
fn isInstalled(allocator: std.mem.Allocator, name: []const u8) !bool {
    // Check if package is installed via: brew list --versions <package>
    const cmd = try std.fmt.allocPrint(allocator, "brew list --versions {s} 2>/dev/null", .{name});
    defer allocator.free(cmd);

    var child = std.process.Child.init(&[_][]const u8{ "/bin/sh", "-c", cmd }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    const stdout = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stdout);
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr);

    const term = try child.wait();
    const exited_ok = switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };

    // If command succeeded and there's output, package is installed
    return exited_ok and stdout.len > 0;
}

/// Execute a Homebrew command with appropriate error mapping based on action
fn runCommand(allocator: std.mem.Allocator, cmd: []const u8, action: common.Action) !void {
    var child = std.process.Child.init(&[_][]const u8{ "/bin/sh", "-c", cmd }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    // Set stdin to /dev/null to prevent any interactive prompts
    child.stdin_behavior = .Ignore;

    try child.spawn();

    const stdout = try child.stdout.?.readToEndAlloc(allocator, std.math.maxInt(usize));
    const stderr = try child.stderr.?.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(stdout);
    defer allocator.free(stderr);

    const term = try child.wait();

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
        .Exited => |code| {
            if (code != 0) {
                logger.err("[homebrew_package] {s} command failed with code {d}", .{ action.toString(), code });
                if (stderr.len > 0) {
                    logger.err("   {s}", .{stderr});
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
        .Signal => |sig| {
            logger.err("[homebrew_package] command killed by signal {d}", .{sig});
            return common.PackageError.CommandFailed;
        },
        else => {
            logger.err("[homebrew_package] command failed with unknown status", .{});
            return common.PackageError.CommandFailed;
        },
    }
}

/// Ruby prelude for homebrew_package resource
pub const ruby_prelude = @embedFile("homebrew_package_resource.rb");

/// Zig callback: called from Ruby to add a homebrew_package resource
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
