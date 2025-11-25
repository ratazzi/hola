const std = @import("std");
const mruby = @import("../mruby.zig");
const base = @import("../base_resource.zig");
const builtin = @import("builtin");
const logger = @import("../logger.zig");

/// Systemd unit resource data structure
pub const Resource = struct {
    // Resource-specific properties
    name: []const u8, // Unit name (e.g., "nginx.service")
    content: ?[]const u8, // Unit file content
    enabled: ?bool, // Whether to enable the unit
    active: ?bool, // Whether to start the unit
    action: Action, // Single action to perform

    // Common properties (guards, notifications, etc.)
    common: base.CommonProps,

    pub const Action = enum {
        create, // Create unit file
        enable, // Enable unit
        disable, // Disable unit
        start, // Start unit
        stop, // Stop unit
        restart, // Restart unit
        reload, // Reload unit
        reload_or_restart, // Reload if possible, otherwise restart
        nothing, // Do nothing
    };

    pub fn deinit(self: Resource, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.content) |content| allocator.free(content);

        // Deinit common props
        var common = self.common;
        common.deinit(allocator);
    }

    pub fn apply(self: Resource) !base.ApplyResult {
        // Skip on non-Linux systems
        if (builtin.os.tag != .linux) {
            return base.ApplyResult{
                .was_updated = false,
                .action = "skipped",
                .skip_reason = "systemd only available on Linux",
            };
        }

        const skip_reason = try self.common.shouldRun();
        if (skip_reason) |reason| {
            return base.ApplyResult{
                .was_updated = false,
                .action = @tagName(self.action),
                .skip_reason = reason,
            };
        }

        const was_updated = try applyAction(self, self.action);

        return base.ApplyResult{
            .was_updated = was_updated,
            .action = @tagName(self.action),
            .skip_reason = if (was_updated) null else "up to date",
        };
    }

    fn applyAction(self: Resource, action: Action) !bool {
        switch (action) {
            .create => return try applyCreate(self),
            .enable => return try applyEnable(self, true),
            .disable => return try applyEnable(self, false),
            .start => return try applyStart(self, true),
            .stop => return try applyStart(self, false),
            .restart => return try applyRestart(self),
            .reload => return try applyReload(self),
            .reload_or_restart => return try applyReloadOrRestart(self),
            .nothing => return false,
        }
    }

    fn applyCreate(self: Resource) !bool {
        if (self.content == null) {
            return false; // No content to create
        }

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        // Determine unit file path
        const unit_path = try getUnitPath(allocator, self.name);

        // Check if file exists and has same content
        const file_exists = blk: {
            const file = std.fs.openFileAbsolute(unit_path, .{}) catch |err| switch (err) {
                error.FileNotFound => break :blk false,
                else => return err,
            };
            defer file.close();

            const existing_content = try file.readToEndAlloc(allocator, 1024 * 1024); // 1MB max
            break :blk std.mem.eql(u8, existing_content, self.content.?);
        };

        if (file_exists) {
            return false; // Already up to date
        }

        // Write unit file
        const file = try std.fs.createFileAbsolute(unit_path, .{ .truncate = true });
        defer file.close();

        try file.writeAll(self.content.?);

        // Reload systemd daemon
        _ = try runSystemctl(allocator, &[_][]const u8{"daemon-reload"});

        return true;
    }

    fn applyEnable(self: Resource, enable: bool) !bool {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        // Check current state
        const is_enabled = try isUnitEnabled(allocator, self.name);

        if (is_enabled == enable) {
            return false; // Already in desired state
        }

        const action = if (enable) "enable" else "disable";
        _ = try runSystemctl(allocator, &[_][]const u8{ action, self.name });

        return true;
    }

    fn applyStart(self: Resource, start: bool) !bool {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        // Check current state
        const is_active = try isUnitActive(allocator, self.name);

        if (is_active == start) {
            return false; // Already in desired state
        }

        const action = if (start) "start" else "stop";
        _ = try runSystemctl(allocator, &[_][]const u8{ action, self.name });

        return true;
    }

    fn applyRestart(self: Resource) !bool {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        _ = try runSystemctl(allocator, &[_][]const u8{ "restart", self.name });
        return true;
    }

    fn applyReload(self: Resource) !bool {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        _ = try runSystemctl(allocator, &[_][]const u8{ "reload", self.name });
        return true;
    }

    fn applyReloadOrRestart(self: Resource) !bool {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        _ = try runSystemctl(allocator, &[_][]const u8{ "reload-or-restart", self.name });
        return true;
    }

    fn getUnitPath(allocator: std.mem.Allocator, unit_name: []const u8) ![]const u8 {
        // Systemd unit files are typically in /etc/systemd/system/
        return std.fmt.allocPrint(allocator, "/etc/systemd/system/{s}", .{unit_name});
    }

    fn isUnitEnabled(allocator: std.mem.Allocator, unit_name: []const u8) !bool {
        const result = runSystemctl(allocator, &[_][]const u8{ "is-enabled", unit_name }) catch {
            return false; // If command fails, assume not enabled
        };
        defer allocator.free(result);

        return std.mem.startsWith(u8, result, "enabled");
    }

    fn isUnitActive(allocator: std.mem.Allocator, unit_name: []const u8) !bool {
        const result = runSystemctl(allocator, &[_][]const u8{ "is-active", unit_name }) catch {
            return false; // If command fails, assume not active
        };
        defer allocator.free(result);

        return std.mem.startsWith(u8, result, "active");
    }

    fn runSystemctl(allocator: std.mem.Allocator, args: []const []const u8) ![]const u8 {
        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(allocator);

        try argv.append(allocator, "systemctl");
        for (args) |arg| {
            try argv.append(allocator, arg);
        }

        var child = std.process.Child.init(argv.items, allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        const stdout = try child.stdout.?.readToEndAlloc(allocator, std.math.maxInt(usize));
        const stderr = try child.stderr.?.readToEndAlloc(allocator, std.math.maxInt(usize));
        defer allocator.free(stderr);

        const term = try child.wait();

        switch (term) {
            .Exited => |code| {
                if (code != 0) {
                    logger.debug("[systemd_unit] systemctl {s} failed with code {d}\n", .{ args[0], code });
                    if (stderr.len > 0) {
                        logger.err("  stderr: {s}\n", .{stderr});
                    }
                    return error.SystemctlFailed;
                }
            },
            else => return error.SystemctlFailed,
        }

        return stdout;
    }

    fn actionFromString(action_str: []const u8) Action {
        if (std.mem.eql(u8, action_str, "create")) return .create;
        if (std.mem.eql(u8, action_str, "enable")) return .enable;
        if (std.mem.eql(u8, action_str, "disable")) return .disable;
        if (std.mem.eql(u8, action_str, "start")) return .start;
        if (std.mem.eql(u8, action_str, "stop")) return .stop;
        if (std.mem.eql(u8, action_str, "restart")) return .restart;
        if (std.mem.eql(u8, action_str, "reload")) return .reload;
        if (std.mem.eql(u8, action_str, "reload_or_restart")) return .reload_or_restart;
        return .nothing;
    }
};

/// Ruby prelude for systemd_unit resource
pub const ruby_prelude = @embedFile("systemd_unit_resource.rb");

/// Zig callback for adding systemd_unit resource from Ruby
pub fn zigAddResource(
    mrb: *mruby.mrb_state,
    _: mruby.mrb_value,
    resources: *std.ArrayList(Resource),
    allocator: std.mem.Allocator,
) mruby.mrb_value {
    // Parse arguments: name, content, actions, verify, only_if_block, not_if_block, notifications
    var name_val: mruby.mrb_value = undefined;
    var content_val: mruby.mrb_value = undefined;
    var actions_val: mruby.mrb_value = undefined;
    var only_if_val: mruby.mrb_value = undefined;
    var not_if_val: mruby.mrb_value = undefined;
    var ignore_failure_val: mruby.mrb_value = undefined;
    var notifications_val: mruby.mrb_value = undefined;

    // Format: SSA|oooA (name, content, actions array, optional blocks, optional notifications)
    _ = mruby.mrb_get_args(mrb, "SSA|oooA", &name_val, &content_val, &actions_val, &only_if_val, &not_if_val, &ignore_failure_val, &notifications_val);

    // Extract name
    const name_cstr = mruby.mrb_str_to_cstr(mrb, name_val);
    const name_span = std.mem.span(name_cstr);

    // Extract content (optional)
    const content_cstr = mruby.mrb_str_to_cstr(mrb, content_val);
    const content_str = std.mem.span(content_cstr);

    // Parse actions array
    const actions_len = mruby.mrb_ary_len(mrb, actions_val);

    // For each action, create a separate resource
    var i: usize = 0;
    while (i < actions_len) : (i += 1) {
        const action_val = mruby.mrb_ary_ref(mrb, actions_val, @intCast(i));
        const action_cstr = mruby.mrb_str_to_cstr(mrb, action_val);
        const action_str = std.mem.span(action_cstr);

        const action = Resource.actionFromString(action_str);

        // Duplicate name and content for each resource
        const name = allocator.dupe(u8, name_span) catch return mruby.mrb_nil_value();
        const content: ?[]const u8 = if (content_str.len > 0)
            allocator.dupe(u8, content_str) catch return mruby.mrb_nil_value()
        else
            null;

        // Build common properties (guards + notifications) for each resource
        var common = base.CommonProps.init(allocator);
        base.fillCommonFromRuby(&common, mrb, only_if_val, not_if_val, ignore_failure_val, notifications_val, allocator);

        resources.append(allocator, .{
            .name = name,
            .content = content,
            .enabled = null,
            .active = null,
            .action = action,
            .common = common,
        }) catch return mruby.mrb_nil_value();
    }

    return mruby.mrb_nil_value();
}
