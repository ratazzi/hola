const std = @import("std");
const mruby = @import("mruby.zig");
const mruby_module = @import("mruby_module.zig");
const resources = @import("resources.zig");
const modern_display = @import("modern_provision_display.zig");
const logger = @import("logger.zig");
const http = @import("http.zig");
const resolv = @import("resolv.zig");
const json = @import("json.zig");
const base64 = @import("base64.zig");
const hola_logger = @import("hola_logger.zig");
const node_info = @import("node_info.zig");
const env_access = @import("env_access.zig");
const file_ext = @import("file_ext.zig");
const base = @import("base_resource.zig");
const builtin = @import("builtin");
const is_macos = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;
const AsyncExecutor = @import("async_executor.zig").AsyncExecutor;

pub const Options = struct {
    script_path: []const u8,
    use_pretty_output: bool = true, // Default to pretty output
    params_json: ?[]const u8 = null, // JSON string for data_bag injection
    secrets_json: ?[]const u8 = null, // JSON string for secrets_bag injection
};

pub const ResourceResult = struct {
    type_name: []const u8,
    name: []const u8,
    action: []const u8,
    was_updated: bool,
    skipped: bool,
    skip_reason: ?[]const u8,
    error_name: ?[]const u8,
    error_message: ?[]const u8 = null,
    output: ?[]const u8,
};

pub const ProvisionResult = struct {
    executed_count: usize,
    updated_count: usize,
    skipped_count: usize,
    failed_count: usize,
    duration_ms: i64,
    resource_results: std.ArrayList(ResourceResult),

    pub fn deinit(self: *ProvisionResult, allocator: std.mem.Allocator) void {
        for (self.resource_results.items) |rr| {
            allocator.free(rr.type_name);
            allocator.free(rr.name);
            allocator.free(rr.action);
            if (rr.skip_reason) |sr| allocator.free(sr);
            if (rr.error_name) |en| allocator.free(en);
            if (rr.error_message) |em| allocator.free(em);
            if (rr.output) |o| allocator.free(o);
        }
        self.resource_results.deinit(allocator);
    }
};

const ProvisionRunner = struct {
    allocator: std.mem.Allocator,
    resources: std.ArrayList(resources.ResourceWithMetadata),
    display: ?*modern_display.ModernProvisionDisplay = null,

    fn init(allocator: std.mem.Allocator) ProvisionRunner {
        return .{
            .allocator = allocator,
            .resources = std.ArrayList(resources.ResourceWithMetadata).empty,
        };
    }

    fn deinit(self: *ProvisionRunner) void {
        for (self.resources.items) |*res| {
            res.deinit(self.allocator);
        }
        self.resources.deinit(self.allocator);
    }
};

threadlocal var current_runner: ?*ProvisionRunner = null;

fn requireRunner() *ProvisionRunner {
    return current_runner orelse @panic("provision runner is not initialized");
}

// Poll callback for async executor
fn pollDisplayUpdate() !void {
    if (current_runner) |runner| {
        if (runner.display) |display| {
            try display.update();
        }
    }
}

fn currentRunnerOrNilValue() ?*ProvisionRunner {
    return current_runner;
}

// Pending notification wrapper
const PendingNotification = struct {
    notification: resources.Notification,
    source_id: []const u8,
};

fn cloneNotificationsFromCommon(
    allocator: std.mem.Allocator,
    common: *const base.CommonProps,
) !std.ArrayList(resources.Notification) {
    var notifications = std.ArrayList(resources.Notification).empty;
    for (common.notifications.items) |notif| {
        const target_id = try allocator.dupe(u8, notif.target_resource_id);
        const action_name = try allocator.dupe(u8, notif.action.action_name);

        const notif_copy = resources.Notification{
            .target_resource_id = target_id,
            .action = .{ .action_name = action_name },
            .timing = notif.timing,
        };
        try notifications.append(allocator, notif_copy);
    }
    return notifications;
}

fn makeResourceId(
    allocator: std.mem.Allocator,
    type_name: []const u8,
    name: []const u8,
) !resources.ResourceId {
    return resources.ResourceId{
        .type_name = try allocator.dupe(u8, type_name),
        .name = try allocator.dupe(u8, name),
    };
}

fn addResourceWithMetadata(
    comptime T: type,
    mrb: *mruby.mrb_state,
    self: mruby.mrb_value,
    add_fn: fn (*mruby.mrb_state, mruby.mrb_value, *std.ArrayList(T), std.mem.Allocator) mruby.mrb_value,
    build_id: fn (std.mem.Allocator, *const T) anyerror!resources.ResourceId,
    wrap: fn (T) resources.Resource,
    get_common_props: fn (*const T) *const base.CommonProps,
) mruby.mrb_value {
    const runner = currentRunnerOrNilValue() orelse return mruby.mrb_nil_value();
    const allocator = runner.allocator;

    // Create a temporary ArrayList for this resource type
    var tmp_resources = std.ArrayList(T).empty;
    defer tmp_resources.deinit(allocator);

    // Call the resource-specific Zig add function
    const result = add_fn(mrb, self, &tmp_resources, allocator);

    // If nothing was added, just return the result from the resource handler
    if (tmp_resources.items.len == 0) return result;

    // Process all resources in tmp_resources (some resources like systemd_unit create multiple)
    for (tmp_resources.items) |res| {
        // Build ResourceId
        const id = build_id(allocator, &res) catch return mruby.mrb_nil_value();

        // Copy notifications from common props into metadata
        const common_ref = get_common_props(&res);
        const notifications = cloneNotificationsFromCommon(allocator, common_ref) catch return mruby.mrb_nil_value();

        // Wrap into unified Resource enum
        const res_with_meta = resources.ResourceWithMetadata{
            .resource = wrap(res),
            .id = id,
            .notifications = notifications,
        };

        runner.resources.append(allocator, res_with_meta) catch return mruby.mrb_nil_value();
    }

    return result;
}

fn addSimpleResourceWithMetadata(
    comptime T: type,
    comptime type_name: []const u8,
    comptime id_field: []const u8,
    comptime union_field: []const u8,
    comptime common_field: []const u8,
    mrb: *mruby.mrb_state,
    self: mruby.mrb_value,
    add_fn: fn (*mruby.mrb_state, mruby.mrb_value, *std.ArrayList(T), std.mem.Allocator) mruby.mrb_value,
) mruby.mrb_value {
    const Adapters = struct {
        fn buildId(allocator: std.mem.Allocator, res: *const T) !resources.ResourceId {
            return makeResourceId(allocator, type_name, @field(res.*, id_field));
        }
        fn wrap(res: T) resources.Resource {
            return @unionInit(resources.Resource, union_field, res);
        }
        fn getCommonProps(res: *const T) *const base.CommonProps {
            return &@field(res.*, common_field);
        }
    };
    return addResourceWithMetadata(
        T,
        mrb,
        self,
        add_fn,
        Adapters.buildId,
        Adapters.wrap,
        Adapters.getCommonProps,
    );
}

fn addFixedIdResourceWithMetadata(
    comptime T: type,
    comptime type_name: []const u8,
    comptime fixed_name: []const u8,
    comptime union_field: []const u8,
    comptime common_field: []const u8,
    mrb: *mruby.mrb_state,
    self: mruby.mrb_value,
    add_fn: fn (*mruby.mrb_state, mruby.mrb_value, *std.ArrayList(T), std.mem.Allocator) mruby.mrb_value,
) mruby.mrb_value {
    const Adapters = struct {
        fn buildId(allocator: std.mem.Allocator, res: *const T) !resources.ResourceId {
            _ = res;
            return makeResourceId(allocator, type_name, fixed_name);
        }
        fn wrap(res: T) resources.Resource {
            return @unionInit(resources.Resource, union_field, res);
        }
        fn getCommonProps(res: *const T) *const base.CommonProps {
            return &@field(res.*, common_field);
        }
    };
    return addResourceWithMetadata(
        T,
        mrb,
        self,
        add_fn,
        Adapters.buildId,
        Adapters.wrap,
        Adapters.getCommonProps,
    );
}

fn addDisplayNameResourceWithMetadata(
    comptime T: type,
    comptime type_name: []const u8,
    comptime union_field: []const u8,
    comptime common_field: []const u8,
    mrb: *mruby.mrb_state,
    self: mruby.mrb_value,
    add_fn: fn (*mruby.mrb_state, mruby.mrb_value, *std.ArrayList(T), std.mem.Allocator) mruby.mrb_value,
) mruby.mrb_value {
    const Adapters = struct {
        fn buildId(allocator: std.mem.Allocator, res: *const T) !resources.ResourceId {
            return makeResourceId(allocator, type_name, res.displayName());
        }
        fn wrap(res: T) resources.Resource {
            return @unionInit(resources.Resource, union_field, res);
        }
        fn getCommonProps(res: *const T) *const base.CommonProps {
            return &@field(res.*, common_field);
        }
    };
    return addResourceWithMetadata(
        T,
        mrb,
        self,
        add_fn,
        Adapters.buildId,
        Adapters.wrap,
        Adapters.getCommonProps,
    );
}

fn addMacosDefaultsResourceWithMetadata(
    mrb: *mruby.mrb_state,
    self: mruby.mrb_value,
) mruby.mrb_value {
    const T = resources.macos_defaults.Resource;
    const Adapters = struct {
        fn buildId(allocator: std.mem.Allocator, res: *const T) !resources.ResourceId {
            const id_str = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ res.domain, res.key });
            defer allocator.free(id_str);
            return makeResourceId(allocator, "macos_defaults", id_str);
        }
        fn wrap(res: T) resources.Resource {
            return .{ .macos_defaults = res };
        }
        fn getCommonProps(res: *const T) *const base.CommonProps {
            return &res.common;
        }
    };
    return addResourceWithMetadata(
        T,
        mrb,
        self,
        resources.macos_defaults.zigAddResource,
        Adapters.buildId,
        Adapters.wrap,
        Adapters.getCommonProps,
    );
}

fn addPackageResourceWithMetadata(
    mrb: *mruby.mrb_state,
    self: mruby.mrb_value,
) mruby.mrb_value {
    const T = resources.package.Resource;
    const Adapters = struct {
        fn buildId(allocator: std.mem.Allocator, res: *const T) !resources.ResourceId {
            return makeResourceId(allocator, "package", res.displayName());
        }
        fn wrap(res: T) resources.Resource {
            return .{ .package = res };
        }
        fn getCommonProps(res: *const T) *const base.CommonProps {
            if (is_macos) {
                return switch (res.backend) {
                    .homebrew => |*hb| &hb.common_props,
                };
            } else if (is_linux) {
                return switch (res.backend) {
                    .apt => |*apt| &apt.common_props,
                };
            } else {
                unreachable;
            }
        }
    };
    return addResourceWithMetadata(
        T,
        mrb,
        self,
        resources.package.zigAddResource,
        Adapters.buildId,
        Adapters.wrap,
        Adapters.getCommonProps,
    );
}

/// Get a short filename from URL for display
fn getShortFileNameFromUrl(url: []const u8) []const u8 {
    if (std.mem.lastIndexOf(u8, url, "/")) |last_slash| {
        return url[last_slash + 1 ..];
    }
    return url;
}

/// Process a notification by finding the target resource and triggering the action
fn processNotification(allocator: std.mem.Allocator, pending: PendingNotification, display: *modern_display.ModernProvisionDisplay) !void {
    const runner = requireRunner();
    const notif = pending.notification;

    // Parse target resource ID
    const target_id = resources.ResourceId.parse(allocator, notif.target_resource_id) catch |err| {
        const error_msg = try std.fmt.allocPrint(allocator, "Invalid target resource ID '{s}': {}", .{ notif.target_resource_id, err });
        defer allocator.free(error_msg);
        try display.showInfo(error_msg);
        return;
    };
    defer target_id.deinit(allocator);

    // Find target resource
    var found = false;
    for (runner.resources.items) |*target_res| {
        if (std.mem.eql(u8, target_res.id.type_name, target_id.type_name) and
            std.mem.eql(u8, target_res.id.name, target_id.name))
        {
            found = true;
            const target_desc = try std.fmt.allocPrint(allocator, "{s}[{s}]", .{ target_res.id.type_name, target_res.id.name });
            defer allocator.free(target_desc);
            try display.showNotification(pending.source_id, target_desc, notif.action.action_name);

            // TODO: For now, just log. In the future, resources will have an "actions" map
            // that allows triggering specific actions like "restart", "reload", etc.
            break;
        }
    }

    if (!found) {
        const error_msg = try std.fmt.allocPrint(allocator, "Target resource '{s}' not found", .{notif.target_resource_id});
        defer allocator.free(error_msg);
        try display.showInfo(error_msg);
    }
}

// Zig callback for execute resource
export fn zig_add_execute_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    return addSimpleResourceWithMetadata(
        resources.execute.Resource,
        "execute",
        "name",
        "execute",
        "common",
        mrb,
        self,
        resources.execute.zigAddResource,
    );
}

// Zig callback for file resource
export fn zig_add_file_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    return addSimpleResourceWithMetadata(
        resources.file.Resource,
        "file",
        "path",
        "file",
        "common",
        mrb,
        self,
        resources.file.zigAddResource,
    );
}

// Zig callback for remote_file resource
export fn zig_add_remote_file_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    return addSimpleResourceWithMetadata(
        resources.remote_file.Resource,
        "remote_file",
        "path",
        "remote_file",
        "common",
        mrb,
        self,
        resources.remote_file.zigAddResource,
    );
}

// Zig callback for template resource
export fn zig_add_template_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    return addSimpleResourceWithMetadata(
        resources.template.Resource,
        "template",
        "path",
        "template",
        "common",
        mrb,
        self,
        resources.template.zigAddResource,
    );
}

// Zig callback for macos_dock resource (macOS only)
export fn zig_add_macos_dock_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    if (!is_macos) {
        return mruby.mrb_nil_value();
    }

    return addFixedIdResourceWithMetadata(
        resources.macos_dock.Resource,
        "macos_dock",
        "Dock",
        "macos_dock",
        "common",
        mrb,
        self,
        resources.macos_dock.zigAddResource,
    );
}

// Zig callback for directory resource
export fn zig_add_directory_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    return addSimpleResourceWithMetadata(
        resources.directory.Resource,
        "directory",
        "path",
        "directory",
        "common",
        mrb,
        self,
        resources.directory.zigAddResource,
    );
}

// Zig callback for link resource
export fn zig_add_link_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    return addSimpleResourceWithMetadata(
        resources.link.Resource,
        "link",
        "path",
        "link",
        "common",
        mrb,
        self,
        resources.link.zigAddResource,
    );
}

// Zig callback for route resource
export fn zig_add_route_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    return addSimpleResourceWithMetadata(
        resources.route.Resource,
        "route",
        "target",
        "route",
        "common",
        mrb,
        self,
        resources.route.zigAddResource,
    );
}

// Zig callback for macos_defaults resource (macOS only)
export fn zig_add_macos_defaults_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    if (!is_macos) {
        return mruby.mrb_nil_value();
    }

    return addMacosDefaultsResourceWithMetadata(mrb, self);
}

// Zig callback for apt_repository resource (Linux only)
export fn zig_add_apt_repository_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    if (!is_linux) {
        return mruby.mrb_nil_value();
    }

    return addSimpleResourceWithMetadata(
        resources.apt_repository.Resource,
        "apt_repository",
        "name",
        "apt_repository",
        "common",
        mrb,
        self,
        resources.apt_repository.zigAddResource,
    );
}

// Zig callback for systemd_unit resource (Linux-only)
export fn zig_add_systemd_unit_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    if (!is_linux) {
        return mruby.mrb_nil_value();
    }

    return addSimpleResourceWithMetadata(
        resources.systemd_unit.Resource,
        "systemd_unit",
        "name",
        "systemd_unit",
        "common",
        mrb,
        self,
        resources.systemd_unit.zigAddResource,
    );
}

// Zig callback for mount resource (Linux-only)
export fn zig_add_mount_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    if (!is_linux) {
        return mruby.mrb_nil_value();
    }

    return addSimpleResourceWithMetadata(
        resources.mount_res.Resource,
        "mount",
        "mount_point",
        "mount_res",
        "common",
        mrb,
        self,
        resources.mount_res.zigAddResource,
    );
}

// Zig callback for package resource (cross-platform)
export fn zig_add_package_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    return addPackageResourceWithMetadata(mrb, self);
}

// Zig callback for homebrew_package resource (macOS only)
export fn zig_add_homebrew_package_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    if (builtin.os.tag != .macos) {
        logger.err("homebrew_package resource is only available on macOS", .{});
        return mruby.mrb_nil_value();
    }
    return addDisplayNameResourceWithMetadata(
        resources.homebrew_package.Resource,
        "homebrew_package",
        "homebrew_package",
        "common_props",
        mrb,
        self,
        resources.homebrew_package.zigAddResource,
    );
}

// Zig callback for apt_package resource (Linux only)
export fn zig_add_apt_package_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    if (builtin.os.tag != .linux) {
        logger.err("apt_package resource is only available on Linux", .{});
        return mruby.mrb_nil_value();
    }
    return addDisplayNameResourceWithMetadata(
        resources.apt_package.Resource,
        "apt_package",
        "apt_package",
        "common_props",
        mrb,
        self,
        resources.apt_package.zigAddResource,
    );
}

// Zig callback for ruby_block resource (cross-platform)
export fn zig_add_ruby_block_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    return addSimpleResourceWithMetadata(
        resources.ruby_block.Resource,
        "ruby_block",
        "name",
        "ruby_block",
        "common",
        mrb,
        self,
        resources.ruby_block.zigAddResource,
    );
}

// Zig callback for git resource (cross-platform)
export fn zig_add_git_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    return addSimpleResourceWithMetadata(
        resources.git.Resource,
        "git",
        "destination",
        "git",
        "common",
        mrb,
        self,
        resources.git.zigAddResource,
    );
}

// Zig callback for user resource (cross-platform)
export fn zig_add_user_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    return addSimpleResourceWithMetadata(
        resources.user.Resource,
        "user",
        "username",
        "user",
        "common",
        mrb,
        self,
        resources.user.zigAddResource,
    );
}

// Zig callback for group resource (cross-platform)
export fn zig_add_group_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    return addSimpleResourceWithMetadata(
        resources.group.Resource,
        "group",
        "group_name",
        "group",
        "common",
        mrb,
        self,
        resources.group.zigAddResource,
    );
}

// Zig callback for aws_kms resource (cross-platform)
export fn zig_add_aws_kms_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    return addSimpleResourceWithMetadata(
        resources.aws_kms.Resource,
        "aws_kms",
        "name",
        "aws_kms",
        "common",
        mrb,
        self,
        resources.aws_kms.zigAddResource,
    );
}

// Zig callback for file_edit resource (cross-platform)
export fn zig_add_file_edit_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    return addSimpleResourceWithMetadata(
        resources.file_edit.Resource,
        "file_edit",
        "path",
        "file_edit",
        "common",
        mrb,
        self,
        resources.file_edit.zigAddResource,
    );
}

// Zig callback for extract resource (cross-platform)
export fn zig_add_extract_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    return addSimpleResourceWithMetadata(
        resources.extract.Resource,
        "extract",
        "destination",
        "extract",
        "common",
        mrb,
        self,
        resources.extract.zigAddResource,
    );
}

const ResourcePlatform = enum {
    all,
    macos,
    linux,

    fn isSupported(self: ResourcePlatform) bool {
        return switch (self) {
            .all => true,
            .macos => is_macos,
            .linux => is_linux,
        };
    }
};

const ResourceBinding = struct {
    name: [*:0]const u8,
    handler: mruby.mrb_func_t,
    args_spec: mruby.mrb_aspec,
    platform: ResourcePlatform = .all,
};

fn registerResourceBindings(mrb_ptr: *mruby.mrb_state, zig_module: *mruby.RClass) void {
    const bindings = [_]ResourceBinding{
        .{ .name = "add_file", .handler = zig_add_file_resource, .args_spec = mruby.MRB_ARGS_REQ(6) | mruby.MRB_ARGS_OPT(4) },
        .{ .name = "add_execute", .handler = zig_add_execute_resource, .args_spec = mruby.MRB_ARGS_REQ(4) | mruby.MRB_ARGS_OPT(4) },
        .{ .name = "add_remote_file", .handler = zig_add_remote_file_resource, .args_spec = mruby.MRB_ARGS_REQ(9) | mruby.MRB_ARGS_OPT(4) },
        .{ .name = "add_template", .handler = zig_add_template_resource, .args_spec = mruby.MRB_ARGS_REQ(5) | mruby.MRB_ARGS_OPT(4) },
        .{ .name = "add_macos_dock", .handler = zig_add_macos_dock_resource, .args_spec = mruby.MRB_ARGS_REQ(1) | mruby.MRB_ARGS_OPT(9), .platform = .macos },
        .{ .name = "add_directory", .handler = zig_add_directory_resource, .args_spec = mruby.MRB_ARGS_REQ(1) | mruby.MRB_ARGS_OPT(7) },
        .{ .name = "add_link", .handler = zig_add_link_resource, .args_spec = mruby.MRB_ARGS_REQ(2) | mruby.MRB_ARGS_OPT(5) },
        .{ .name = "add_route", .handler = zig_add_route_resource, .args_spec = mruby.MRB_ARGS_REQ(5) | mruby.MRB_ARGS_OPT(4) },
        .{ .name = "add_macos_defaults", .handler = zig_add_macos_defaults_resource, .args_spec = mruby.MRB_ARGS_REQ(2) | mruby.MRB_ARGS_OPT(6), .platform = .macos },
        .{ .name = "add_apt_repository", .handler = zig_add_apt_repository_resource, .args_spec = mruby.MRB_ARGS_REQ(10) | mruby.MRB_ARGS_OPT(4), .platform = .linux },
        .{ .name = "add_systemd_unit", .handler = zig_add_systemd_unit_resource, .args_spec = mruby.MRB_ARGS_REQ(3) | mruby.MRB_ARGS_OPT(4), .platform = .linux },
        .{ .name = "add_mount", .handler = zig_add_mount_resource, .args_spec = mruby.MRB_ARGS_REQ(9) | mruby.MRB_ARGS_OPT(5), .platform = .linux },
        .{ .name = "add_package", .handler = zig_add_package_resource, .args_spec = mruby.MRB_ARGS_REQ(4) | mruby.MRB_ARGS_OPT(6) },
        .{ .name = "add_homebrew_package", .handler = zig_add_homebrew_package_resource, .args_spec = mruby.MRB_ARGS_REQ(4) | mruby.MRB_ARGS_OPT(5), .platform = .macos },
        .{ .name = "add_apt_package", .handler = zig_add_apt_package_resource, .args_spec = mruby.MRB_ARGS_REQ(4) | mruby.MRB_ARGS_OPT(5), .platform = .linux },
        .{ .name = "add_ruby_block", .handler = zig_add_ruby_block_resource, .args_spec = mruby.MRB_ARGS_REQ(3) | mruby.MRB_ARGS_OPT(4) },
        .{ .name = "add_git", .handler = zig_add_git_resource, .args_spec = mruby.MRB_ARGS_REQ(14) | mruby.MRB_ARGS_OPT(5) },
        .{ .name = "add_user", .handler = zig_add_user_resource, .args_spec = mruby.MRB_ARGS_REQ(11) | mruby.MRB_ARGS_OPT(5) },
        .{ .name = "add_group", .handler = zig_add_group_resource, .args_spec = mruby.MRB_ARGS_REQ(9) | mruby.MRB_ARGS_OPT(5) },
        .{ .name = "add_aws_kms", .handler = zig_add_aws_kms_resource, .args_spec = mruby.MRB_ARGS_REQ(15) | mruby.MRB_ARGS_OPT(5) },
        .{ .name = "add_file_edit", .handler = zig_add_file_edit_resource, .args_spec = mruby.MRB_ARGS_REQ(6) | mruby.MRB_ARGS_OPT(5) },
        .{ .name = "add_extract", .handler = zig_add_extract_resource, .args_spec = mruby.MRB_ARGS_REQ(8) | mruby.MRB_ARGS_OPT(5) },
    };

    inline for (bindings) |binding| {
        if (binding.platform.isSupported()) {
            mruby.mrb_define_module_function(
                mrb_ptr,
                zig_module,
                binding.name,
                binding.handler,
                binding.args_spec,
            );
        }
    }
}

/// Inject a JSON string into mruby as a global variable via JSON.parse.
fn injectJsonGlobal(mrb: *mruby.mrb_state, global_name: []const u8, json_str: []const u8) !void {
    var escaped_len: usize = 0;
    for (json_str) |ch| {
        escaped_len += if (ch == '\'' or ch == '\\') @as(usize, 2) else 1;
    }

    const allocator = std.heap.c_allocator;
    const buf = try allocator.alloc(u8, global_name.len + escaped_len + 64 + 1);
    defer allocator.free(buf);

    var pos: usize = 0;
    @memcpy(buf[pos .. pos + global_name.len], global_name);
    pos += global_name.len;
    const assign = " = JSON.parse('";
    @memcpy(buf[pos .. pos + assign.len], assign);
    pos += assign.len;

    for (json_str) |ch| {
        if (ch == '\'' or ch == '\\') {
            buf[pos] = '\\';
            pos += 1;
        }
        buf[pos] = ch;
        pos += 1;
    }

    const suffix = "')";
    @memcpy(buf[pos .. pos + suffix.len], suffix);
    pos += suffix.len;

    buf[pos] = 0;
    _ = mruby.mrb_load_string(mrb, buf.ptr);

    const exc = mruby.mrb_get_exception(mrb);
    if (mruby.mrb_test(exc)) {
        mruby.mrb_print_error(mrb);
        return error.MRubyException;
    }
}

/// Inject params JSON into mruby as $_hola_params global variable.
fn injectParams(mrb: *mruby.mrb_state, params_json: []const u8) !void {
    try injectJsonGlobal(mrb, "$_hola_params", params_json);
}

/// Inject secrets JSON into mruby as $_hola_secrets global variable.
fn injectSecrets(mrb: *mruby.mrb_state, secrets_json: []const u8) !void {
    try injectJsonGlobal(mrb, "$_hola_secrets", secrets_json);
}

pub fn run(allocator: std.mem.Allocator, opts: Options) !ProvisionResult {
    // Guard-error buffer is threadlocal; clear at entry so a prior invocation
    // on this thread can't leak into this run.
    base.clearGuardError();

    var runner = ProvisionRunner.init(allocator);
    defer runner.deinit();

    current_runner = &runner;
    defer current_runner = null;

    var mrb = try mruby.State.init();
    defer mrb.deinit();

    // Register Zig functions in mruby
    const mrb_ptr = mrb.mrb orelse return error.MRubyNotInitialized;
    const zig_module = mruby.mrb_define_module(mrb_ptr, "ZigBackend");
    registerResourceBindings(mrb_ptr, zig_module);

    // Register all API modules using the unified interface
    // Register modules in dependency order: JSON must be registered before http_client
    // because http_client's Ruby prelude calls JSON.parse in Response#json method
    const api_modules = [_]mruby_module.MRubyModule{
        file_ext.mruby_module_def, // File.stat and File.mtime extensions
        json.mruby_module_def,
        http.mruby_module_def,
        base64.mruby_module_def,
        hola_logger.mruby_module_def,
        node_info.mruby_module_def,
        env_access.mruby_module_def,
        resolv.mruby_module_def,
    };

    for (api_modules) |module| {
        try mruby_module.registerModule(mrb_ptr, zig_module, allocator, module, &mrb);
    }

    // Setup File class methods (must be done after registerModule loads the prelude)
    // This registers File.stat and File.mtime as class methods
    file_ext.setupFileExtensions(mrb_ptr);

    // Load OpenStruct utility class (used by node object and other resources)
    try mrb.evalString(@embedFile("ruby_prelude/open_struct.rb"));

    // Load Ruby DSL preludes for resource types
    try mrb.evalString(resources.file.ruby_prelude);
    try mrb.evalString(resources.execute.ruby_prelude);
    try mrb.evalString(resources.remote_file.ruby_prelude);
    try mrb.evalString(resources.template.ruby_prelude);
    // Always load macOS-specific Ruby DSLs so the methods exist cross-platform.
    // On non-macOS, the Ruby preludes themselves detect the absence of ZigBackend
    // entrypoints and act as no-op helpers.
    try mrb.evalString(resources.macos_dock.ruby_prelude);
    try mrb.evalString(resources.macos_defaults.ruby_prelude);
    try mrb.evalString(resources.directory.ruby_prelude);
    try mrb.evalString(resources.link.ruby_prelude);
    try mrb.evalString(resources.route.ruby_prelude);
    // Load Linux-specific Ruby DSLs (apt_repository, systemd_unit, etc.)
    // On non-Linux, the Ruby preludes detect absence of ZigBackend entrypoints
    try mrb.evalString(resources.apt_repository.ruby_prelude);
    try mrb.evalString(resources.systemd_unit.ruby_prelude);
    try mrb.evalString(resources.mount_res.ruby_prelude);
    // Load package resources (delegator and platform-specific)
    try mrb.evalString(resources.package.ruby_prelude);
    try mrb.evalString(resources.homebrew_package.ruby_prelude);
    try mrb.evalString(resources.apt_package.ruby_prelude);
    // Load ruby_block resource
    try mrb.evalString(resources.ruby_block.ruby_prelude);
    // Load git resource
    try mrb.evalString(resources.git.ruby_prelude);
    // Load user and group resources
    try mrb.evalString(resources.user.ruby_prelude);
    try mrb.evalString(resources.group.ruby_prelude);
    // Load aws_kms resource
    try mrb.evalString(resources.aws_kms.ruby_prelude);
    // Load file_edit resource
    try mrb.evalString(resources.file_edit.ruby_prelude);
    // Load extract resource
    try mrb.evalString(resources.extract.ruby_prelude);
    // Load Ruby-only custom resources
    try mrb.evalString(@embedFile("resources/apt_update_resource.rb"));

    // Load data_bag support
    try mrb.evalString(@embedFile("ruby_prelude/data_bag.rb"));

    // Load secrets_bag support
    try mrb.evalString(@embedFile("ruby_prelude/secrets_bag.rb"));

    // Inject params as $_hola_params if provided (agent mode)
    if (opts.params_json) |params_json| {
        try injectParams(mrb_ptr, params_json);
    }

    // Inject secrets as $_hola_secrets if provided
    if (opts.secrets_json) |secrets_json| {
        try injectSecrets(mrb_ptr, secrets_json);
    }

    // Load test helper only in debug builds
    if (builtin.mode == .Debug) {
        try mrb.evalString(@embedFile("ruby_prelude/test_helper.rb"));
    }

    // Load and execute user's recipe
    // Use evalFile instead of evalString to preserve file path and line numbers in error messages
    try mrb.evalFile(opts.script_path);

    // Record start time for timer
    const start_time = std.time.nanoTimestamp();

    // Initialize resource results collection
    var resource_results = std.ArrayList(ResourceResult).empty;
    errdefer {
        for (resource_results.items) |rr| {
            allocator.free(rr.type_name);
            allocator.free(rr.name);
            allocator.free(rr.action);
            if (rr.skip_reason) |sr| allocator.free(sr);
            if (rr.error_name) |en| allocator.free(en);
            if (rr.error_message) |em| allocator.free(em);
            if (rr.output) |o| allocator.free(o);
        }
        resource_results.deinit(allocator);
    }

    // Initialize modern display with the specified output mode
    var display = try modern_display.ModernProvisionDisplay.init(allocator, opts.use_pretty_output);
    defer display.deinit();

    // Set global display for async executor callback
    runner.display = &display;
    defer runner.display = null;

    // Set poll callback for async executor
    AsyncExecutor.setPollCallback(pollDisplayUpdate);
    defer AsyncExecutor.setPollCallback(null);

    // Show section header
    try display.showSection("Applying Configuration");

    // Set total number of resources for progress display
    display.setTotalResources(runner.resources.items.len);

    // Phase 0: Start parallel downloads for remote files
    // Initialize download manager with the specified output mode
    const download_config = http.download.Manager.Config{
        .max_concurrent = 5,
        .http_config = .{},
    };
    var download_mgr = try http.download.Manager.init(allocator, download_config);
    defer download_mgr.deinit();

    // Set up progress callback for display
    const ProgressContext = struct {
        display: *modern_display.ModernProvisionDisplay,
        allocator: std.mem.Allocator,
        tasks: *std.ArrayList(http.download.Task),
        mutex: *std.Thread.Mutex,
        initialized: [256]std.atomic.Value(bool), // Fixed size array with atomic values

        fn callback(ctx_ptr: *anyopaque, task_index: usize, downloaded: usize, total: usize) void {
            const ctx: *@This() = @ptrCast(@alignCast(ctx_ptr));

            ctx.mutex.lock();
            defer ctx.mutex.unlock();

            if (task_index >= ctx.tasks.items.len or task_index >= 256) return;

            const task = &ctx.tasks.items[task_index];
            const display_name = task.display_name;

            // Check if we've initialized the display for this task
            const is_initialized = ctx.initialized[task_index].load(.acquire);

            if (total > 0) {
                if (!is_initialized) {
                    // First time seeing total > 0, initialize download display
                    ctx.display.addDownload(display_name, total) catch {};
                    ctx.initialized[task_index].store(true, .release);
                } else if (downloaded > 0) {
                    // Subsequent updates with progress
                    ctx.display.updateDownload(display_name, downloaded) catch {};
                }
            }

            // Mark as complete
            if (downloaded >= total and total > 0) {
                ctx.display.finishDownload(display_name, true) catch {};
            }
        }
    };

    var progress_mutex = std.Thread.Mutex{};
    const progress_ctx = try allocator.create(ProgressContext);
    defer allocator.destroy(progress_ctx);
    progress_ctx.* = .{
        .display = &display,
        .allocator = allocator,
        .tasks = &download_mgr.tasks,
        .mutex = &progress_mutex,
        .initialized = undefined, // Will initialize below
    };
    // Initialize all atomic values to false
    for (&progress_ctx.initialized) |*init| {
        init.* = std.atomic.Value(bool).init(false);
    }

    download_mgr.setDisplay(@ptrCast(progress_ctx), ProgressContext.callback);

    // Collect all remote_file resources for parallel download
    // Only pre-download simple files (no conditions like only_if/not_if, and action is :create)
    for (runner.resources.items) |*res| {
        if (res.resource == .remote_file) {
            const remote_res = &res.resource.remote_file;

            // Skip files with conditions - they will be downloaded when executed
            if (remote_res.common.only_if_block != null or remote_res.common.not_if_block != null) {
                continue;
            }

            // Skip non-create actions (create_if_missing needs to check file existence first)
            if (remote_res.action != .create) {
                continue;
            }

            // Skip conditional downloads; they are fetched on-demand to honor conditional requests
            if (remote_res.use_etag or remote_res.use_last_modified) {
                continue;
            }

            // Generate slugified version of the final path for unique temp filename
            const path_slug = try http.slugifyPath(allocator, remote_res.path);
            defer allocator.free(path_slug);

            // Get temp dir from xdg
            const xdg_instance = @import("xdg.zig").XDG.init(allocator);
            const temp_dir = try xdg_instance.getDownloadsDir();
            defer allocator.free(temp_dir);

            // Generate temporary file path with slugified path
            const temp_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ temp_dir, path_slug });
            defer allocator.free(temp_path);

            // Use full destination path for display
            const display_name = remote_res.path;
            const resource_id = try std.fmt.allocPrint(allocator, "{s}[{s}]", .{ res.id.type_name, res.id.name });
            defer allocator.free(resource_id);

            // Create download task using new API
            var task = try http.download.Task.init(
                allocator,
                resource_id,
                remote_res.source,
                display_name,
                temp_path,
                remote_res.path,
            );

            // Set optional fields
            task.mode = if (remote_res.attrs.mode) |mode| try std.fmt.allocPrint(allocator, "{o}", .{mode}) else null;
            task.checksum = if (remote_res.checksum) |checksum| try allocator.dupe(u8, checksum) else null;
            task.backup = if (remote_res.backup) |backup| try allocator.dupe(u8, backup) else null;

            // Parse JSON headers to StringHashMap
            if (remote_res.headers) |headers_json| {
                var headers_map = std.StringHashMap([]const u8).init(allocator);
                errdefer headers_map.deinit();

                const parsed = try std.json.parseFromSlice(std.json.Value, allocator, headers_json, .{});
                defer parsed.deinit();

                if (parsed.value == .object) {
                    var it = parsed.value.object.iterator();
                    while (it.next()) |entry| {
                        const key = try allocator.dupe(u8, entry.key_ptr.*);
                        errdefer allocator.free(key);
                        const value_str = if (entry.value_ptr.* == .string) entry.value_ptr.*.string else "";
                        const value = try allocator.dupe(u8, value_str);
                        errdefer allocator.free(value);
                        try headers_map.put(key, value);
                    }
                }

                task.headers = headers_map;
            }

            try download_mgr.addTask(task);
        }
    }

    if (download_mgr.tasks.items.len > 0) {
        // Show download section header
        try display.showSectionWithLevel("Downloading Remote Files", 3);

        const download_names = try allocator.alloc([]const u8, download_mgr.tasks.items.len);
        defer allocator.free(download_names);
        for (download_mgr.tasks.items, 0..) |task, idx| {
            download_names[idx] = task.display_name;
        }
        try display.reserveDownloadSlots(download_names);
    }

    // Start background download processing if we have tasks
    var download_thread: ?std.Thread = null;
    if (download_mgr.tasks.items.len > 0) {
        const DownloadThread = struct {
            fn run(mgr: *http.download.Manager) void {
                mgr.processAll() catch |err| {
                    logger.err("Download processing failed: {}", .{err});
                };
            }
        };
        download_thread = try std.Thread.spawn(.{}, DownloadThread.run, .{&download_mgr});
    }

    // Start resource execution phase
    try display.showSectionWithLevel("Executing Resources", 3);

    // Start the real-time timer spinner (after all download spinners are created)
    try display.startTimer(start_time);

    // Track immediate and delayed notifications
    var immediate_notifications = std.ArrayList(PendingNotification).empty;
    defer immediate_notifications.deinit(allocator);
    var delayed_notifications = std.ArrayList(PendingNotification).empty;
    defer delayed_notifications.deinit(allocator);

    // Phase 0: Convert subscriptions to reverse notifications
    // When resource A subscribes to resource B, we add a notification from B to A
    for (runner.resources.items) |*subscriber_res| {
        const common = subscriber_res.resource.getCommonProps();
        for (common.subscriptions.items) |sub| {
            // Find the source resource that this resource is subscribing to
            const source_id_parsed = base.notification.ResourceId.parse(allocator, sub.target_resource_id) catch continue;
            defer source_id_parsed.deinit(allocator);

            // Find the source resource in our list
            for (runner.resources.items) |*source_res| {
                if (std.mem.eql(u8, source_res.id.type_name, source_id_parsed.type_name) and
                    std.mem.eql(u8, source_res.id.name, source_id_parsed.name))
                {
                    // Add a notification from source to subscriber
                    const subscriber_id = try subscriber_res.id.toString(allocator);
                    const notif = base.notification.Notification{
                        .target_resource_id = subscriber_id,
                        .action = .{ .action_name = try allocator.dupe(u8, sub.action.action_name) },
                        .timing = sub.timing,
                    };

                    const source_common = source_res.resource.getCommonProps();
                    try source_common.notifications.append(allocator, notif);
                    break;
                }
            }
        }
    }

    // Phase 1: Execute resources and collect notifications
    for (runner.resources.items) |*res| {
        base.clearGuardError();
        try display.startResource(res.id.type_name, res.id.name);
        try display.update();

        // Wait for download task if this is a remote_file resource
        if (res.resource == .remote_file and download_thread != null) {
            // Find the download task for this specific remote_file resource
            const resource_id = try std.fmt.allocPrint(allocator, "{s}[{s}]", .{ res.id.type_name, res.id.name });
            defer allocator.free(resource_id);

            if (download_mgr.getTask(resource_id)) |task| {
                // Check current status first
                const initial_status = task.status.load(.acquire);

                // Only wait if the task is still in progress
                if (initial_status == .queued or initial_status == .downloading) {
                    // Wait for this specific download task to complete
                    var max_wait_iterations: usize = 3000; // 30 seconds max wait (10ms * 3000)
                    while (max_wait_iterations > 0) {
                        const status = task.status.load(.acquire);
                        if (status != .queued and status != .downloading) {
                            break;
                        }

                        try display.update();
                        std.Thread.yield() catch {};
                        std.Thread.sleep(10 * std.time.ns_per_ms);
                        max_wait_iterations -= 1;
                    }
                }

                // Check if the download failed
                const final_status = task.status.load(.acquire);
                if (final_status == .failed) {
                    const err_msg_owned = task.getError(allocator);
                    defer if (err_msg_owned) |msg| allocator.free(msg);
                    const err_msg = err_msg_owned orelse "Unknown error";

                    const msg = try std.fmt.allocPrint(allocator, "Download failed for {s}: {s}", .{ resource_id, err_msg });
                    defer allocator.free(msg);
                    try display.showInfo(msg);
                    return error.DownloadFailed;
                }
            }
        }

        const result = res.resource.apply() catch |err| {
            const guard_msg = base.getGuardError();
            const error_display = guard_msg orelse @errorName(err);
            try display.resourceError(res.id.type_name, res.id.name, error_display);
            try display.update();

            try resource_results.append(allocator, .{
                .type_name = try allocator.dupe(u8, res.id.type_name),
                .name = try allocator.dupe(u8, res.id.name),
                .action = try allocator.dupe(u8, ""),
                .was_updated = false,
                .skipped = false,
                .skip_reason = null,
                .error_name = try allocator.dupe(u8, @errorName(err)),
                .error_message = if (guard_msg) |m| try allocator.dupe(u8, m) else null,
                .output = null,
            });

            // Check if this resource has ignore_failure set
            if (res.resource.shouldIgnoreFailure()) {
                // Continue to next resource if ignore_failure is true
                continue;
            } else {
                // Stop execution and return error
                return err;
            }
        };
        // Free resource-allocated output after duping into resource_results
        defer if (result.output) |o| std.heap.c_allocator.free(o);
        res.was_updated = result.was_updated;

        // Update resource status with action and skip reason
        // If skip_reason is "up to date", show it even if was_updated is false
        if (result.was_updated) {
            // Pass skip_reason to resourceUpdated so it can handle "up to date" case
            try display.resourceUpdated(res.id.type_name, res.id.name, result.action, result.skip_reason);
            try display.update();

            try resource_results.append(allocator, .{
                .type_name = try allocator.dupe(u8, res.id.type_name),
                .name = try allocator.dupe(u8, res.id.name),
                .action = try allocator.dupe(u8, result.action),
                .was_updated = true,
                .skipped = false,
                .skip_reason = if (result.skip_reason) |sr| try allocator.dupe(u8, sr) else null,
                .error_name = null,
                .output = if (result.output) |o| try allocator.dupe(u8, o) else null,
            });

            // Collect notifications from updated resources (only if actually updated, not "up to date")
            if (result.skip_reason == null or !std.mem.eql(u8, result.skip_reason.?, "up to date")) {
                for (res.notifications.items) |notif| {
                    const pending = PendingNotification{
                        .notification = notif,
                        .source_id = try res.id.toString(allocator),
                    };

                    if (notif.timing == .immediate) {
                        try immediate_notifications.append(allocator, pending);
                    } else {
                        try delayed_notifications.append(allocator, pending);
                    }
                }
            }
        } else {
            // Resource was not updated - show skip reason (including "up to date")
            try display.resourceSkipped(res.id.type_name, res.id.name, result.action, result.skip_reason);
            try display.update();

            try resource_results.append(allocator, .{
                .type_name = try allocator.dupe(u8, res.id.type_name),
                .name = try allocator.dupe(u8, res.id.name),
                .action = try allocator.dupe(u8, result.action),
                .was_updated = false,
                .skipped = true,
                .skip_reason = if (result.skip_reason) |sr| try allocator.dupe(u8, sr) else null,
                .error_name = null,
                .output = null,
            });
        }
    }

    // Phase 2: Process immediate notifications
    if (immediate_notifications.items.len > 0) {
        try display.showSectionWithLevel("Processing Immediate Notifications", 3);
        for (immediate_notifications.items) |pending| {
            try processNotification(allocator, pending, &display);
        }
    }

    // Phase 3: Process delayed notifications at end
    if (delayed_notifications.items.len > 0) {
        try display.showSectionWithLevel("Processing Delayed Notifications", 3);
        for (delayed_notifications.items) |pending| {
            try processNotification(allocator, pending, &display);
        }
    }

    // Wait for download thread to complete
    if (download_thread) |thread| {
        try display.showInfo("Waiting for remaining downloads to complete...");
        thread.join();

        // Show final stats
        const stats = download_mgr.getStats();
        if (stats.failed > 0) {
            const msg = try std.fmt.allocPrint(allocator, "{d} downloads failed", .{stats.failed});
            defer allocator.free(msg);
            try display.showInfo(msg);
        }
    }

    // Cleanup pending notifications
    for (immediate_notifications.items) |pending| {
        allocator.free(pending.source_id);
    }
    for (delayed_notifications.items) |pending| {
        allocator.free(pending.source_id);
    }

    // Show execution summary with duration
    try display.showSummaryWithDuration(0, 0);

    // Compute duration
    const end_time = std.time.nanoTimestamp();
    const elapsed_ms = @divTrunc(end_time - start_time, std.time.ns_per_ms);

    return ProvisionResult{
        .executed_count = display.executed_count,
        .updated_count = display.updated_count,
        .skipped_count = display.skipped_count,
        .failed_count = display.failed_count,
        .duration_ms = @intCast(elapsed_ms),
        .resource_results = resource_results,
    };
}

test "injectSecrets and secrets_bag reads values correctly" {
    var mrb = try mruby.State.init();
    defer mrb.deinit();

    const mrb_ptr = mrb.mrb orelse return error.MRubyNotInitialized;

    // Register ZigBackend module with JSON functions
    const zig_module = mruby.mrb_define_module(mrb_ptr, "ZigBackend");
    json.setAllocator(std.testing.allocator);
    for (json.mruby_module_def.getFunctions()) |func| {
        mruby.mrb_define_module_function(mrb_ptr, zig_module, func.name.ptr, func.func, func.args);
    }
    try mrb.evalString(json.ruby_prelude);

    // Load secrets_bag prelude
    try mrb.evalString(@embedFile("ruby_prelude/secrets_bag.rb"));

    // Inject secrets
    try injectSecrets(mrb_ptr, "{\"api_key\":\"sk-123\",\"nested\":{\"token\":\"abc\"}}");

    // Test simple key access
    try mrb.evalString("$_test_result = secrets_bag('api_key')");
    const sym = mruby.mrb_intern_cstr(mrb_ptr, "$_test_result");
    const result = mruby.mrb_gv_get(mrb_ptr, sym);
    try std.testing.expect(mruby.zig_mrb_string_p(result) != 0);
    const cstr = mruby.mrb_str_to_cstr(mrb_ptr, result);
    try std.testing.expectEqualStrings("sk-123", std.mem.span(cstr));

    // Test nested key access
    try mrb.evalString("$_test_result2 = secrets_bag('nested', 'token')");
    const sym2 = mruby.mrb_intern_cstr(mrb_ptr, "$_test_result2");
    const result2 = mruby.mrb_gv_get(mrb_ptr, sym2);
    try std.testing.expect(mruby.zig_mrb_string_p(result2) != 0);
    const cstr2 = mruby.mrb_str_to_cstr(mrb_ptr, result2);
    try std.testing.expectEqualStrings("abc", std.mem.span(cstr2));

    // Test missing key returns nil
    try mrb.evalString("$_test_result3 = secrets_bag('nonexistent')");
    const sym3 = mruby.mrb_intern_cstr(mrb_ptr, "$_test_result3");
    const result3 = mruby.mrb_gv_get(mrb_ptr, sym3);
    try std.testing.expect(!mruby.mrb_test(result3));
}
