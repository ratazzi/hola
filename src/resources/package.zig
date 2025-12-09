const std = @import("std");
const mruby = @import("../mruby.zig");
const base = @import("../base_resource.zig");
const logger = @import("../logger.zig");
const builtin = @import("builtin");
const AsyncExecutor = @import("../async_executor.zig").AsyncExecutor;

const is_macos = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;

/// Context for async package operations
const PackageApplyContext = struct {
    resource: *const Resource,
    action: Resource.Action,
};

/// Package resource data structure
pub const Resource = struct {
    // Resource-specific properties
    names: std.ArrayList([]const u8), // Package names (supports multiple)
    version: ?[]const u8, // Optional version constraint (only for single package)
    options: ?[]const u8, // Additional package manager options
    action: Action,

    // Common properties (guards, notifications, etc.)
    common: base.CommonProps,

    pub const Action = enum {
        install,
        remove,
        upgrade,
        nothing,
    };

    pub fn deinit(self: Resource, allocator: std.mem.Allocator) void {
        for (self.names.items) |name| {
            allocator.free(name);
        }
        var names_copy = self.names;
        names_copy.deinit(allocator);
        if (self.version) |v| allocator.free(v);
        if (self.options) |o| allocator.free(o);

        var common = self.common;
        common.deinit(allocator);
    }

    /// Get display name for resource (first package or comma-separated list)
    pub fn displayName(self: Resource) []const u8 {
        if (self.names.items.len == 0) return "unknown";
        return self.names.items[0];
    }

    pub fn apply(self: Resource) !base.ApplyResult {
        const skip_reason = try self.common.shouldRun(null, null);
        if (skip_reason) |reason| {
            const action_name = self.actionName();
            return base.ApplyResult{
                .was_updated = false,
                .action = action_name,
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

    fn actionName(self: Resource) []const u8 {
        return switch (self.action) {
            .install => "install",
            .remove => "remove",
            .upgrade => "upgrade",
            .nothing => "nothing",
        };
    }

    fn applyInstallSync(self: Resource) !base.ApplyResult {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        // Build list of packages that need to be installed
        var to_install = std.ArrayList([]const u8).empty;
        defer to_install.deinit(allocator);

        for (self.names.items) |name| {
            if (!try self.isPackageInstalled(allocator, name)) {
                try to_install.append(allocator, name);
            }
        }

        if (to_install.items.len == 0) {
            const names_str = try self.joinNames(allocator);
            defer allocator.free(names_str);
            logger.info("package[{s}]: already installed", .{names_str});
            return base.ApplyResult{
                .was_updated = true,
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
            if (try self.isPackageInstalled(allocator, name)) {
                try to_remove.append(allocator, name);
            }
        }

        if (to_remove.items.len == 0) {
            const names_str = try self.joinNames(allocator);
            defer allocator.free(names_str);
            logger.info("package[{s}]: not installed", .{names_str});
            return base.ApplyResult{
                .was_updated = true,
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

    fn joinNames(self: Resource, allocator: std.mem.Allocator) ![]const u8 {
        if (self.names.items.len == 0) return try allocator.dupe(u8, "");
        if (self.names.items.len == 1) return try allocator.dupe(u8, self.names.items[0]);

        var total_len: usize = 0;
        for (self.names.items) |name| {
            total_len += name.len + 2; // ", "
        }
        total_len -= 2; // Remove last ", "

        var result = try allocator.alloc(u8, total_len);
        var pos: usize = 0;
        for (self.names.items, 0..) |name, i| {
            @memcpy(result[pos .. pos + name.len], name);
            pos += name.len;
            if (i < self.names.items.len - 1) {
                result[pos] = ',';
                result[pos + 1] = ' ';
                pos += 2;
            }
        }
        return result;
    }

    fn isPackageInstalled(self: Resource, allocator: std.mem.Allocator, name: []const u8) !bool {
        _ = self;
        if (is_macos) {
            return try isPackageInstalledBrew(allocator, name);
        } else if (is_linux) {
            return try isPackageInstalledApt(allocator, name);
        } else {
            return error.UnsupportedPlatform;
        }
    }

    fn isPackageInstalledBrew(allocator: std.mem.Allocator, name: []const u8) !bool {
        // Check if package is installed via: brew list --versions <package>
        const cmd = try std.fmt.allocPrint(allocator, "brew list --versions {s} 2>/dev/null", .{name});
        defer allocator.free(cmd);

        var child = std.process.Child.init(&[_][]const u8{ "/bin/sh", "-c", cmd }, allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();
        const stdout = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(stdout);
        _ = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);

        const term = try child.wait();
        const exited_ok = switch (term) {
            .Exited => |code| code == 0,
            else => false,
        };

        // If command succeeded and there's output, package is installed
        return exited_ok and stdout.len > 0;
    }

    fn isPackageInstalledApt(allocator: std.mem.Allocator, name: []const u8) !bool {
        // Check if package is installed via: dpkg-query -W -f='${Status}' <package>
        const cmd = try std.fmt.allocPrint(allocator, "dpkg-query -W -f='${{Status}}' {s} 2>/dev/null | grep -q 'install ok installed'", .{name});
        defer allocator.free(cmd);

        var child = std.process.Child.init(&[_][]const u8{ "/bin/sh", "-c", cmd }, allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();
        _ = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
        _ = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);

        const term = try child.wait();
        return switch (term) {
            .Exited => |code| code == 0,
            else => false,
        };
    }

    fn runInstallPackages(self: Resource, allocator: std.mem.Allocator, packages: []const []const u8) !void {
        const cmd = if (is_macos)
            try self.buildBrewInstallCmd(allocator, packages)
        else if (is_linux)
            try self.buildAptInstallCmd(allocator, packages)
        else
            return error.UnsupportedPlatform;
        defer allocator.free(cmd);

        const pkg_list = try std.mem.join(allocator, " ", packages);
        defer allocator.free(pkg_list);
        logger.info("package[{s}]: installing via {s}", .{ pkg_list, if (is_macos) "homebrew" else "apt" });
        try self.runCommand(allocator, cmd);
    }

    fn runRemovePackages(self: Resource, allocator: std.mem.Allocator, packages: []const []const u8) !void {
        const cmd = if (is_macos)
            try self.buildBrewRemoveCmd(allocator, packages)
        else if (is_linux)
            try self.buildAptRemoveCmd(allocator, packages)
        else
            return error.UnsupportedPlatform;
        defer allocator.free(cmd);

        const pkg_list = try std.mem.join(allocator, " ", packages);
        defer allocator.free(pkg_list);
        logger.info("package[{s}]: removing via {s}", .{ pkg_list, if (is_macos) "homebrew" else "apt" });
        try self.runCommand(allocator, cmd);
    }

    fn runUpgradePackages(self: Resource, allocator: std.mem.Allocator, packages: []const []const u8) !void {
        const cmd = if (is_macos)
            try self.buildBrewUpgradeCmd(allocator, packages)
        else if (is_linux)
            try self.buildAptUpgradeCmd(allocator, packages)
        else
            return error.UnsupportedPlatform;
        defer allocator.free(cmd);

        const pkg_list = try std.mem.join(allocator, " ", packages);
        defer allocator.free(pkg_list);
        logger.info("package[{s}]: upgrading via {s}", .{ pkg_list, if (is_macos) "homebrew" else "apt" });
        try self.runCommand(allocator, cmd);
    }

    fn buildBrewInstallCmd(self: Resource, allocator: std.mem.Allocator, packages: []const []const u8) ![]const u8 {
        const pkg_list = try std.mem.join(allocator, " ", packages);
        defer allocator.free(pkg_list);

        if (self.options) |opts| {
            return try std.fmt.allocPrint(allocator, "brew install {s} {s}", .{ opts, pkg_list });
        } else {
            return try std.fmt.allocPrint(allocator, "brew install {s}", .{pkg_list});
        }
    }

    fn buildAptInstallCmd(self: Resource, allocator: std.mem.Allocator, packages: []const []const u8) ![]const u8 {
        const pkg_list = try std.mem.join(allocator, " ", packages);
        defer allocator.free(pkg_list);

        if (self.options) |opts| {
            return try std.fmt.allocPrint(allocator, "apt-get install -y {s} {s}", .{ opts, pkg_list });
        } else {
            return try std.fmt.allocPrint(allocator, "apt-get install -y {s}", .{pkg_list});
        }
    }

    fn buildBrewRemoveCmd(self: Resource, allocator: std.mem.Allocator, packages: []const []const u8) ![]const u8 {
        const pkg_list = try std.mem.join(allocator, " ", packages);
        defer allocator.free(pkg_list);

        if (self.options) |opts| {
            return try std.fmt.allocPrint(allocator, "brew uninstall {s} {s}", .{ opts, pkg_list });
        } else {
            return try std.fmt.allocPrint(allocator, "brew uninstall {s}", .{pkg_list});
        }
    }

    fn buildAptRemoveCmd(self: Resource, allocator: std.mem.Allocator, packages: []const []const u8) ![]const u8 {
        const pkg_list = try std.mem.join(allocator, " ", packages);
        defer allocator.free(pkg_list);

        if (self.options) |opts| {
            return try std.fmt.allocPrint(allocator, "apt-get remove -y {s} {s}", .{ opts, pkg_list });
        } else {
            return try std.fmt.allocPrint(allocator, "apt-get remove -y {s}", .{pkg_list});
        }
    }

    fn buildBrewUpgradeCmd(self: Resource, allocator: std.mem.Allocator, packages: []const []const u8) ![]const u8 {
        const pkg_list = try std.mem.join(allocator, " ", packages);
        defer allocator.free(pkg_list);

        if (self.options) |opts| {
            return try std.fmt.allocPrint(allocator, "brew upgrade {s} {s}", .{ opts, pkg_list });
        } else {
            return try std.fmt.allocPrint(allocator, "brew upgrade {s}", .{pkg_list});
        }
    }

    fn buildAptUpgradeCmd(self: Resource, allocator: std.mem.Allocator, packages: []const []const u8) ![]const u8 {
        const pkg_list = try std.mem.join(allocator, " ", packages);
        defer allocator.free(pkg_list);

        if (self.options) |opts| {
            return try std.fmt.allocPrint(allocator, "apt-get install -y --only-upgrade {s} {s}", .{ opts, pkg_list });
        } else {
            return try std.fmt.allocPrint(allocator, "apt-get install -y --only-upgrade {s}", .{pkg_list});
        }
    }

    fn runCommand(self: Resource, allocator: std.mem.Allocator, cmd: []const u8) !void {
        _ = self;

        var child = std.process.Child.init(&[_][]const u8{ "/bin/sh", "-c", cmd }, allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

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

        // Check exit status
        switch (term) {
            .Exited => |code| {
                if (code != 0) {
                    logger.err("[package] command failed with code {d}", .{code});
                    if (stderr.len > 0) {
                        logger.err("   {s}", .{stderr});
                    }
                    return error.PackageOperationFailed;
                }
            },
            .Signal => |sig| {
                logger.err("[package] command killed by signal {d}", .{sig});
                return error.CommandKilled;
            },
            else => {
                logger.err("[package] command failed with unknown status", .{});
                return error.CommandFailed;
            },
        }
    }
};

/// Ruby prelude for package resource
pub const ruby_prelude = @embedFile("package_resource.rb");

/// Zig callback: called from Ruby to add a package resource
/// Format: add_package(names_array, version, options, action, only_if_block, not_if_block, notifications_array)
pub fn zigAddResource(
    mrb: *mruby.mrb_state,
    self: mruby.mrb_value,
    resources: *std.ArrayList(Resource),
    allocator: std.mem.Allocator,
) mruby.mrb_value {
    _ = self;

    var names_val: mruby.mrb_value = undefined;
    var version_val: mruby.mrb_value = undefined;
    var options_val: mruby.mrb_value = undefined;
    var action_val: mruby.mrb_value = undefined;
    var only_if_val: mruby.mrb_value = undefined;
    var not_if_val: mruby.mrb_value = undefined;
    var ignore_failure_val: mruby.mrb_value = undefined;
    var notifications_val: mruby.mrb_value = undefined;
    var subscriptions_val: mruby.mrb_value = undefined;

    // Get array + 3 strings + 4 optional (blocks + arrays)
    _ = mruby.mrb_get_args(mrb, "ASSS|oooAA", &names_val, &version_val, &options_val, &action_val, &only_if_val, &not_if_val, &ignore_failure_val, &notifications_val, &subscriptions_val);

    // Parse names array
    var names = std.ArrayList([]const u8).empty;
    const names_len = mruby.mrb_ary_len(mrb, names_val);
    for (0..@intCast(names_len)) |i| {
        const name_val = mruby.mrb_ary_ref(mrb, names_val, @intCast(i));
        const name_cstr = mruby.mrb_str_to_cstr(mrb, name_val);
        const name = allocator.dupe(u8, std.mem.span(name_cstr)) catch return mruby.mrb_nil_value();
        names.append(allocator, name) catch return mruby.mrb_nil_value();
    }

    const version_cstr = mruby.mrb_str_to_cstr(mrb, version_val);
    const options_cstr = mruby.mrb_str_to_cstr(mrb, options_val);
    const action_cstr = mruby.mrb_str_to_cstr(mrb, action_val);

    const version_str = std.mem.span(version_cstr);
    const version: ?[]const u8 = if (version_str.len > 0)
        allocator.dupe(u8, version_str) catch return mruby.mrb_nil_value()
    else
        null;

    const options_str = std.mem.span(options_cstr);
    const options: ?[]const u8 = if (options_str.len > 0)
        allocator.dupe(u8, options_str) catch return mruby.mrb_nil_value()
    else
        null;

    const action_str = std.mem.span(action_cstr);
    const action: Resource.Action = if (std.mem.eql(u8, action_str, "remove"))
        .remove
    else if (std.mem.eql(u8, action_str, "upgrade"))
        .upgrade
    else if (std.mem.eql(u8, action_str, "nothing"))
        .nothing
    else
        .install;

    // Build common properties (guards + notifications)
    var common = base.CommonProps.init(allocator);
    base.fillCommonFromRuby(&common, mrb, only_if_val, not_if_val, ignore_failure_val, notifications_val, subscriptions_val, allocator);

    resources.append(allocator, .{
        .names = names,
        .version = version,
        .options = options,
        .action = action,
        .common = common,
    }) catch return mruby.mrb_nil_value();

    return mruby.mrb_nil_value();
}
