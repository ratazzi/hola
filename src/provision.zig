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
};

// Global resource collector (will be initialized per-run)
var g_allocator: std.mem.Allocator = undefined;
var g_resources: std.ArrayList(resources.ResourceWithMetadata) = undefined;
var g_display: ?*modern_display.ModernProvisionDisplay = null;

// Poll callback for async executor
fn pollDisplayUpdate() !void {
    if (g_display) |display| {
        try display.update();
    }
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
    // Create a temporary ArrayList for this resource type
    var tmp_resources = std.ArrayList(T).empty;
    defer tmp_resources.deinit(g_allocator);

    // Call the resource-specific Zig add function
    const result = add_fn(mrb, self, &tmp_resources, g_allocator);

    // If nothing was added, just return the result from the resource handler
    if (tmp_resources.items.len == 0) return result;

    // Process all resources in tmp_resources (some resources like systemd_unit create multiple)
    for (tmp_resources.items) |res| {
        // Build ResourceId
        const id = build_id(g_allocator, &res) catch return mruby.mrb_nil_value();

        // Copy notifications from common props into metadata
        const common_ref = get_common_props(&res);
        const notifications = cloneNotificationsFromCommon(g_allocator, common_ref) catch return mruby.mrb_nil_value();

        // Wrap into unified Resource enum
        const res_with_meta = resources.ResourceWithMetadata{
            .resource = wrap(res),
            .id = id,
            .notifications = notifications,
        };

        g_resources.append(g_allocator, res_with_meta) catch return mruby.mrb_nil_value();
    }

    return result;
}

fn buildExecuteId(allocator: std.mem.Allocator, res: *const resources.execute.Resource) !resources.ResourceId {
    return makeResourceId(allocator, "execute", res.name);
}
fn wrapExecute(res: resources.execute.Resource) resources.Resource {
    return .{ .execute = res };
}
fn getCommonPropsExecute(res: *const resources.execute.Resource) *const base.CommonProps {
    return &res.common;
}

fn buildFileId(allocator: std.mem.Allocator, res: *const resources.file.Resource) !resources.ResourceId {
    return makeResourceId(allocator, "file", res.path);
}
fn wrapFile(res: resources.file.Resource) resources.Resource {
    return .{ .file = res };
}
fn getCommonPropsFile(res: *const resources.file.Resource) *const base.CommonProps {
    return &res.common;
}

fn buildRemoteFileId(allocator: std.mem.Allocator, res: *const resources.remote_file.Resource) !resources.ResourceId {
    return makeResourceId(allocator, "remote_file", res.path);
}
fn wrapRemoteFile(res: resources.remote_file.Resource) resources.Resource {
    return .{ .remote_file = res };
}
fn getCommonPropsRemoteFile(res: *const resources.remote_file.Resource) *const base.CommonProps {
    return &res.common;
}

fn buildTemplateId(allocator: std.mem.Allocator, res: *const resources.template.Resource) !resources.ResourceId {
    return makeResourceId(allocator, "template", res.path);
}
fn wrapTemplate(res: resources.template.Resource) resources.Resource {
    return .{ .template = res };
}
fn getCommonPropsTemplate(res: *const resources.template.Resource) *const base.CommonProps {
    return &res.common;
}

fn buildMacosDockId(allocator: std.mem.Allocator, res: *const resources.macos_dock.Resource) !resources.ResourceId {
    _ = res;
    return makeResourceId(allocator, "macos_dock", "Dock");
}
fn wrapMacosDock(res: resources.macos_dock.Resource) resources.Resource {
    return .{ .macos_dock = res };
}
fn getCommonPropsMacosDock(res: *const resources.macos_dock.Resource) *const base.CommonProps {
    return &res.common;
}

fn buildDirectoryId(allocator: std.mem.Allocator, res: *const resources.directory.Resource) !resources.ResourceId {
    return makeResourceId(allocator, "directory", res.path);
}
fn wrapDirectory(res: resources.directory.Resource) resources.Resource {
    return .{ .directory = res };
}
fn getCommonPropsDirectory(res: *const resources.directory.Resource) *const base.CommonProps {
    return &res.common;
}

fn buildLinkId(allocator: std.mem.Allocator, res: *const resources.link.Resource) !resources.ResourceId {
    return makeResourceId(allocator, "link", res.path);
}
fn wrapLink(res: resources.link.Resource) resources.Resource {
    return .{ .link = res };
}
fn getCommonPropsLink(res: *const resources.link.Resource) *const base.CommonProps {
    return &res.common;
}

fn buildRouteId(allocator: std.mem.Allocator, res: *const resources.route.Resource) !resources.ResourceId {
    return makeResourceId(allocator, "route", res.target);
}
fn wrapRoute(res: resources.route.Resource) resources.Resource {
    return .{ .route = res };
}
fn getCommonPropsRoute(res: *const resources.route.Resource) *const base.CommonProps {
    return &res.common;
}

fn buildMacosDefaultsId(allocator: std.mem.Allocator, res: *const resources.macos_defaults.Resource) !resources.ResourceId {
    const id_str = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ res.domain, res.key });
    defer allocator.free(id_str);
    return makeResourceId(allocator, "macos_defaults", id_str);
}
fn wrapMacosDefaults(res: resources.macos_defaults.Resource) resources.Resource {
    return .{ .macos_defaults = res };
}
fn getCommonPropsMacosDefaults(res: *const resources.macos_defaults.Resource) *const base.CommonProps {
    return &res.common;
}

fn buildAptRepositoryId(allocator: std.mem.Allocator, res: *const resources.apt_repository.Resource) !resources.ResourceId {
    return makeResourceId(allocator, "apt_repository", res.name);
}
fn wrapAptRepository(res: resources.apt_repository.Resource) resources.Resource {
    return .{ .apt_repository = res };
}
fn getCommonPropsAptRepository(res: *const resources.apt_repository.Resource) *const base.CommonProps {
    return &res.common;
}

fn buildSystemdUnitId(allocator: std.mem.Allocator, res: *const resources.systemd_unit.Resource) !resources.ResourceId {
    return makeResourceId(allocator, "systemd_unit", res.name);
}
fn wrapSystemdUnit(res: resources.systemd_unit.Resource) resources.Resource {
    return .{ .systemd_unit = res };
}
fn getCommonPropsSystemdUnit(res: *const resources.systemd_unit.Resource) *const base.CommonProps {
    return &res.common;
}

fn buildPackageId(allocator: std.mem.Allocator, res: *const resources.package.Resource) !resources.ResourceId {
    // Use first package name for ID, or join all names if multiple
    const display_name = res.displayName();
    return makeResourceId(allocator, "package", display_name);
}
fn wrapPackage(res: resources.package.Resource) resources.Resource {
    return .{ .package = res };
}
fn getCommonPropsPackage(res: *const resources.package.Resource) *const base.CommonProps {
    // Package is a delegator, need to get common from backend
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

// Homebrew package (macOS only)
fn buildHomebrewPackageId(allocator: std.mem.Allocator, res: *const resources.homebrew_package.Resource) !resources.ResourceId {
    const display_name = res.displayName();
    return makeResourceId(allocator, "homebrew_package", display_name);
}
fn wrapHomebrewPackage(res: resources.homebrew_package.Resource) resources.Resource {
    return .{ .homebrew_package = res };
}
fn getCommonPropsHomebrewPackage(res: *const resources.homebrew_package.Resource) *const base.CommonProps {
    return &res.common_props;
}

// APT package (Linux only)
fn buildAptPackageId(allocator: std.mem.Allocator, res: *const resources.apt_package.Resource) !resources.ResourceId {
    const display_name = res.displayName();
    return makeResourceId(allocator, "apt_package", display_name);
}
fn wrapAptPackage(res: resources.apt_package.Resource) resources.Resource {
    return .{ .apt_package = res };
}
fn getCommonPropsAptPackage(res: *const resources.apt_package.Resource) *const base.CommonProps {
    return &res.common_props;
}

fn buildRubyBlockId(allocator: std.mem.Allocator, res: *const resources.ruby_block.Resource) !resources.ResourceId {
    return makeResourceId(allocator, "ruby_block", res.name);
}
fn wrapRubyBlock(res: resources.ruby_block.Resource) resources.Resource {
    return .{ .ruby_block = res };
}
fn getCommonPropsRubyBlock(res: *const resources.ruby_block.Resource) *const base.CommonProps {
    return &res.common;
}

fn buildGitId(allocator: std.mem.Allocator, res: *const resources.git.Resource) !resources.ResourceId {
    return makeResourceId(allocator, "git", res.destination);
}
fn wrapGit(res: resources.git.Resource) resources.Resource {
    return .{ .git = res };
}
fn getCommonPropsGit(res: *const resources.git.Resource) *const base.CommonProps {
    return &res.common;
}

fn buildUserId(allocator: std.mem.Allocator, res: *const resources.user.Resource) !resources.ResourceId {
    return makeResourceId(allocator, "user", res.username);
}
fn wrapUser(res: resources.user.Resource) resources.Resource {
    return .{ .user = res };
}
fn getCommonPropsUser(res: *const resources.user.Resource) *const base.CommonProps {
    return &res.common;
}

fn buildGroupId(allocator: std.mem.Allocator, res: *const resources.group.Resource) !resources.ResourceId {
    return makeResourceId(allocator, "group", res.group_name);
}
fn wrapGroup(res: resources.group.Resource) resources.Resource {
    return .{ .group = res };
}
fn getCommonPropsGroup(res: *const resources.group.Resource) *const base.CommonProps {
    return &res.common;
}

fn buildAwsKmsId(allocator: std.mem.Allocator, res: *const resources.aws_kms.Resource) !resources.ResourceId {
    return makeResourceId(allocator, "aws_kms", res.name);
}
fn wrapAwsKms(res: resources.aws_kms.Resource) resources.Resource {
    return .{ .aws_kms = res };
}
fn getCommonPropsAwsKms(res: *const resources.aws_kms.Resource) *const base.CommonProps {
    return &res.common;
}


fn buildFileEditId(allocator: std.mem.Allocator, res: *const resources.file_edit.Resource) !resources.ResourceId {
    return makeResourceId(allocator, "file_edit", res.path);
}
fn wrapFileEdit(res: resources.file_edit.Resource) resources.Resource {
    return .{ .file_edit = res };
}
fn getCommonPropsFileEdit(res: *const resources.file_edit.Resource) *const base.CommonProps {
    return &res.common;
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
    for (g_resources.items) |*target_res| {
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
    return addResourceWithMetadata(
        resources.execute.Resource,
        mrb,
        self,
        resources.execute.zigAddResource,
        buildExecuteId,
        wrapExecute,
        getCommonPropsExecute,
    );
}

// Zig callback for file resource
export fn zig_add_file_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    return addResourceWithMetadata(
        resources.file.Resource,
        mrb,
        self,
        resources.file.zigAddResource,
        buildFileId,
        wrapFile,
        getCommonPropsFile,
    );
}

// Zig callback for remote_file resource
export fn zig_add_remote_file_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    return addResourceWithMetadata(
        resources.remote_file.Resource,
        mrb,
        self,
        resources.remote_file.zigAddResource,
        buildRemoteFileId,
        wrapRemoteFile,
        getCommonPropsRemoteFile,
    );
}

// Zig callback for template resource
export fn zig_add_template_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    return addResourceWithMetadata(
        resources.template.Resource,
        mrb,
        self,
        resources.template.zigAddResource,
        buildTemplateId,
        wrapTemplate,
        getCommonPropsTemplate,
    );
}

// Zig callback for macos_dock resource (macOS only)
export fn zig_add_macos_dock_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    if (!is_macos) {
        return mruby.mrb_nil_value();
    }

    return addResourceWithMetadata(
        resources.macos_dock.Resource,
        mrb,
        self,
        resources.macos_dock.zigAddResource,
        buildMacosDockId,
        wrapMacosDock,
        getCommonPropsMacosDock,
    );
}

// Zig callback for directory resource
export fn zig_add_directory_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    return addResourceWithMetadata(
        resources.directory.Resource,
        mrb,
        self,
        resources.directory.zigAddResource,
        buildDirectoryId,
        wrapDirectory,
        getCommonPropsDirectory,
    );
}

// Zig callback for link resource
export fn zig_add_link_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    return addResourceWithMetadata(
        resources.link.Resource,
        mrb,
        self,
        resources.link.zigAddResource,
        buildLinkId,
        wrapLink,
        getCommonPropsLink,
    );
}

// Zig callback for route resource
export fn zig_add_route_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    return addResourceWithMetadata(
        resources.route.Resource,
        mrb,
        self,
        resources.route.zigAddResource,
        buildRouteId,
        wrapRoute,
        getCommonPropsRoute,
    );
}

// Zig callback for macos_defaults resource (macOS only)
export fn zig_add_macos_defaults_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    if (!is_macos) {
        return mruby.mrb_nil_value();
    }

    return addResourceWithMetadata(
        resources.macos_defaults.Resource,
        mrb,
        self,
        resources.macos_defaults.zigAddResource,
        buildMacosDefaultsId,
        wrapMacosDefaults,
        getCommonPropsMacosDefaults,
    );
}

// Zig callback for apt_repository resource (Linux only)
export fn zig_add_apt_repository_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    if (!is_linux) {
        return mruby.mrb_nil_value();
    }

    return addResourceWithMetadata(
        resources.apt_repository.Resource,
        mrb,
        self,
        resources.apt_repository.zigAddResource,
        buildAptRepositoryId,
        wrapAptRepository,
        getCommonPropsAptRepository,
    );
}

// Zig callback for systemd_unit resource (Linux-only)
export fn zig_add_systemd_unit_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    if (!is_linux) {
        return mruby.mrb_nil_value();
    }

    return addResourceWithMetadata(
        resources.systemd_unit.Resource,
        mrb,
        self,
        resources.systemd_unit.zigAddResource,
        buildSystemdUnitId,
        wrapSystemdUnit,
        getCommonPropsSystemdUnit,
    );
}

// Zig callback for package resource (cross-platform)
export fn zig_add_package_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    return addResourceWithMetadata(
        resources.package.Resource,
        mrb,
        self,
        resources.package.zigAddResource,
        buildPackageId,
        wrapPackage,
        getCommonPropsPackage,
    );
}

// Zig callback for homebrew_package resource (macOS only)
export fn zig_add_homebrew_package_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    if (builtin.os.tag != .macos) {
        logger.err("homebrew_package resource is only available on macOS", .{});
        return mruby.mrb_nil_value();
    }
    return addResourceWithMetadata(
        resources.homebrew_package.Resource,
        mrb,
        self,
        resources.homebrew_package.zigAddResource,
        buildHomebrewPackageId,
        wrapHomebrewPackage,
        getCommonPropsHomebrewPackage,
    );
}

// Zig callback for apt_package resource (Linux only)
export fn zig_add_apt_package_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    if (builtin.os.tag != .linux) {
        logger.err("apt_package resource is only available on Linux", .{});
        return mruby.mrb_nil_value();
    }
    return addResourceWithMetadata(
        resources.apt_package.Resource,
        mrb,
        self,
        resources.apt_package.zigAddResource,
        buildAptPackageId,
        wrapAptPackage,
        getCommonPropsAptPackage,
    );
}

// Zig callback for ruby_block resource (cross-platform)
export fn zig_add_ruby_block_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    return addResourceWithMetadata(
        resources.ruby_block.Resource,
        mrb,
        self,
        resources.ruby_block.zigAddResource,
        buildRubyBlockId,
        wrapRubyBlock,
        getCommonPropsRubyBlock,
    );
}

// Zig callback for git resource (cross-platform)
export fn zig_add_git_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    return addResourceWithMetadata(
        resources.git.Resource,
        mrb,
        self,
        resources.git.zigAddResource,
        buildGitId,
        wrapGit,
        getCommonPropsGit,
    );
}

// Zig callback for user resource (cross-platform)
export fn zig_add_user_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    return addResourceWithMetadata(
        resources.user.Resource,
        mrb,
        self,
        resources.user.zigAddResource,
        buildUserId,
        wrapUser,
        getCommonPropsUser,
    );
}

// Zig callback for group resource (cross-platform)
export fn zig_add_group_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    return addResourceWithMetadata(
        resources.group.Resource,
        mrb,
        self,
        resources.group.zigAddResource,
        buildGroupId,
        wrapGroup,
        getCommonPropsGroup,
    );
}

// Zig callback for aws_kms resource (cross-platform)
export fn zig_add_aws_kms_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    return addResourceWithMetadata(
        resources.aws_kms.Resource,
        mrb,
        self,
        resources.aws_kms.zigAddResource,
        buildAwsKmsId,
        wrapAwsKms,
        getCommonPropsAwsKms,
    );
}

// Zig callback for file_edit resource (cross-platform)
export fn zig_add_file_edit_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    return addResourceWithMetadata(
        resources.file_edit.Resource,
        mrb,
        self,
        resources.file_edit.zigAddResource,
        buildFileEditId,
        wrapFileEdit,
        getCommonPropsFileEdit,
    );
}

pub fn run(allocator: std.mem.Allocator, opts: Options) !void {
    // Initialize global state
    g_allocator = allocator;
    g_resources = std.ArrayList(resources.ResourceWithMetadata).empty;
    defer {
        // Clean up resources
        for (g_resources.items) |*res| {
            res.deinit(allocator);
        }
        g_resources.deinit(allocator);
    }

    var mrb = try mruby.State.init();
    defer mrb.deinit();

    // Register Zig functions in mruby
    const mrb_ptr = mrb.mrb orelse return error.MRubyNotInitialized;
    const zig_module = mruby.mrb_define_module(mrb_ptr, "ZigBackend");

    // Register file resource
    // Signature: add_file(path, content, action, mode, owner, group, only_if_block=nil, not_if_block=nil, ignore_failure=nil, notifications=nil)
    mruby.mrb_define_module_function(
        mrb_ptr,
        zig_module,
        "add_file",
        zig_add_file_resource,
        mruby.MRB_ARGS_REQ(6) | mruby.MRB_ARGS_OPT(4), // 6 required + 4 optional
    );

    // Register execute resource
    // Signature: add_execute(name, command, cwd, action, only_if_block=nil, not_if_block=nil, ignore_failure=nil, notifications=nil)
    mruby.mrb_define_module_function(
        mrb_ptr,
        zig_module,
        "add_execute",
        zig_add_execute_resource,
        mruby.MRB_ARGS_REQ(4) | mruby.MRB_ARGS_OPT(4), // 4 required + 4 optional
    );

    // Register remote_file resource
    // Signature: add_remote_file(path, source, mode, owner, group, checksum, backup, headers, action, only_if_block=nil, not_if_block=nil, ignore_failure=nil, notifications=nil)
    mruby.mrb_define_module_function(
        mrb_ptr,
        zig_module,
        "add_remote_file",
        zig_add_remote_file_resource,
        mruby.MRB_ARGS_REQ(9) | mruby.MRB_ARGS_OPT(4), // 9 required + 4 optional
    );

    // Register template resource
    // Signature: add_template(path, source, mode, variables_array, action, only_if_block=nil, not_if_block=nil, ignore_failure=nil, notifications=nil)
    mruby.mrb_define_module_function(
        mrb_ptr,
        zig_module,
        "add_template",
        zig_add_template_resource,
        mruby.MRB_ARGS_REQ(5) | mruby.MRB_ARGS_OPT(4), // 5 required + 4 optional
    );

    // Register macos_dock resource (macOS only)
    // Signature: add_macos_dock(apps_array, tilesize=nil, orientation=nil, autohide=nil, magnification=nil, largesize=nil, only_if_block=nil, not_if_block=nil, ignore_failure=nil, notifications=nil)
    if (is_macos) {
        mruby.mrb_define_module_function(
            mrb_ptr,
            zig_module,
            "add_macos_dock",
            zig_add_macos_dock_resource,
            mruby.MRB_ARGS_REQ(1) | mruby.MRB_ARGS_OPT(9), // 1 required + 9 optional
        );
    }

    // Register directory resource
    // Signature: add_directory(path, mode=nil, recursive=false, action="create", only_if_block=nil, not_if_block=nil, ignore_failure=nil, notifications=nil)
    mruby.mrb_define_module_function(
        mrb_ptr,
        zig_module,
        "add_directory",
        zig_add_directory_resource,
        mruby.MRB_ARGS_REQ(1) | mruby.MRB_ARGS_OPT(7), // 1 required + 7 optional
    );

    // Register link resource
    // Signature: add_link(path, target, action="create", only_if_block=nil, not_if_block=nil, ignore_failure=nil, notifications=nil)
    mruby.mrb_define_module_function(
        mrb_ptr,
        zig_module,
        "add_link",
        zig_add_link_resource,
        mruby.MRB_ARGS_REQ(2) | mruby.MRB_ARGS_OPT(5), // 2 required + 5 optional
    );

    // Register route resource
    // Signature: add_route(target, gateway, netmask, device, action, only_if, not_if, ignore_failure, notifications)
    mruby.mrb_define_module_function(
        mrb_ptr,
        zig_module,
        "add_route",
        zig_add_route_resource,
        mruby.MRB_ARGS_REQ(5) | mruby.MRB_ARGS_OPT(4),
    );

    // Register macos_defaults resource (macOS only)
    // Signature: add_macos_defaults(domain, key, value_array=nil, action="write", only_if_block=nil, not_if_block=nil, ignore_failure=nil, notifications=nil)
    if (is_macos) {
        mruby.mrb_define_module_function(
            mrb_ptr,
            zig_module,
            "add_macos_defaults",
            zig_add_macos_defaults_resource,
            mruby.MRB_ARGS_REQ(2) | mruby.MRB_ARGS_OPT(6), // 2 required + 6 optional
        );
    }

    // Register apt_repository resource (Linux only)
    // Signature: add_apt_repository(name, uri, key_url, key_path, distribution, components, arch, options, repo_type, action, only_if_block=nil, not_if_block=nil, ignore_failure=nil, notifications=nil)
    if (is_linux) {
        mruby.mrb_define_module_function(
            mrb_ptr,
            zig_module,
            "add_apt_repository",
            zig_add_apt_repository_resource,
            mruby.MRB_ARGS_REQ(10) | mruby.MRB_ARGS_OPT(4), // 10 required + 4 optional
        );
    }

    // Register systemd_unit resource (Linux only)
    // Signature: add_systemd_unit(name, content, actions, only_if_block=nil, not_if_block=nil, ignore_failure=nil, notifications=nil)
    if (is_linux) {
        mruby.mrb_define_module_function(
            mrb_ptr,
            zig_module,
            "add_systemd_unit",
            zig_add_systemd_unit_resource,
            mruby.MRB_ARGS_REQ(3) | mruby.MRB_ARGS_OPT(4), // 3 required + 4 optional
        );
    }

    // Register package resource (cross-platform: homebrew on macOS, apt on Linux)
    // Signature: add_package(names, version, options, action, provider=nil, only_if_block=nil, not_if_block=nil, ignore_failure=nil, notifications=nil, subscriptions=nil)
    mruby.mrb_define_module_function(
        mrb_ptr,
        zig_module,
        "add_package",
        zig_add_package_resource,
        mruby.MRB_ARGS_REQ(4) | mruby.MRB_ARGS_OPT(6), // 4 required + 6 optional
    );

    // Register homebrew_package resource (macOS only)
    // Signature: add_homebrew_package(names, version, options, action, only_if_block=nil, not_if_block=nil, ignore_failure=nil, notifications=nil, subscriptions=nil)
    if (is_macos) {
        mruby.mrb_define_module_function(
            mrb_ptr,
            zig_module,
            "add_homebrew_package",
            zig_add_homebrew_package_resource,
            mruby.MRB_ARGS_REQ(4) | mruby.MRB_ARGS_OPT(5), // 4 required + 5 optional
        );
    }

    // Register apt_package resource (Linux only)
    // Signature: add_apt_package(names, version, options, action, only_if_block=nil, not_if_block=nil, ignore_failure=nil, notifications=nil, subscriptions=nil)
    if (is_linux) {
        mruby.mrb_define_module_function(
            mrb_ptr,
            zig_module,
            "add_apt_package",
            zig_add_apt_package_resource,
            mruby.MRB_ARGS_REQ(4) | mruby.MRB_ARGS_OPT(5), // 4 required + 5 optional
        );
    }

    // Register ruby_block resource (cross-platform)
    // Signature: add_ruby_block(name, block_proc, action, only_if_block=nil, not_if_block=nil, ignore_failure=nil, notifications=nil)
    mruby.mrb_define_module_function(
        mrb_ptr,
        zig_module,
        "add_ruby_block",
        zig_add_ruby_block_resource,
        mruby.MRB_ARGS_REQ(3) | mruby.MRB_ARGS_OPT(4), // 3 required + 4 optional
    );

    // Register git resource (cross-platform)
    // Signature: add_git(repository, destination, revision, checkout_branch, remote, depth,
    //   enable_checkout, enable_submodules, ssh_key, enable_strict_host_key_checking,
    //   user, group, action, only_if_block=nil, not_if_block=nil, ignore_failure=nil,
    //   notifications=nil, subscriptions=nil)
    mruby.mrb_define_module_function(
        mrb_ptr,
        zig_module,
        "add_git",
        zig_add_git_resource,
        mruby.MRB_ARGS_REQ(13) | mruby.MRB_ARGS_OPT(5), // 13 required + 5 optional
    );

    // Register user resource (cross-platform)
    // Signature: add_user(username, uid, gid, comment, home, shell, password, system, manage_home, non_unique, action, only_if_block=nil, not_if_block=nil, ignore_failure=nil, notifications=nil, subscriptions=nil)
    mruby.mrb_define_module_function(
        mrb_ptr,
        zig_module,
        "add_user",
        zig_add_user_resource,
        mruby.MRB_ARGS_REQ(11) | mruby.MRB_ARGS_OPT(5), // 11 required + 5 optional
    );

    // Register group resource (cross-platform)
    // Signature: add_group(group_name, gid, members, excluded_members, append, comment, system, non_unique, action, only_if_block=nil, not_if_block=nil, ignore_failure=nil, notifications=nil, subscriptions=nil)
    mruby.mrb_define_module_function(
        mrb_ptr,
        zig_module,
        "add_group",
        zig_add_group_resource,
        mruby.MRB_ARGS_REQ(9) | mruby.MRB_ARGS_OPT(5), // 9 required + 5 optional
    );

    // Register aws_kms resource (cross-platform)
    // Signature: add_aws_kms(name, region, access_key_id, secret_access_key, session_token, key_id, algorithm, source, source_encoding, target_encoding, path, mode, owner, group, action, only_if_block=nil, not_if_block=nil, ignore_failure=nil, notifications=nil, subscriptions=nil)
    mruby.mrb_define_module_function(
        mrb_ptr,
        zig_module,
        "add_aws_kms",
        zig_add_aws_kms_resource,
        mruby.MRB_ARGS_REQ(15) | mruby.MRB_ARGS_OPT(5), // 15 required + 5 optional
    );

    // Register file_edit resource (cross-platform)
    // Signature: add_file_edit(path, operations, backup, mode, owner, group, only_if_block=nil, not_if_block=nil, ignore_failure=nil, notifications=nil, subscriptions=nil)
    mruby.mrb_define_module_function(
        mrb_ptr,
        zig_module,
        "add_file_edit",
        zig_add_file_edit_resource,
        mruby.MRB_ARGS_REQ(6) | mruby.MRB_ARGS_OPT(5), // 6 required + 5 optional
    );

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
    // Load Ruby-only custom resources
    try mrb.evalString(@embedFile("resources/apt_update_resource.rb"));

    // Load and execute user's recipe
    // Use evalFile instead of evalString to preserve file path and line numbers in error messages
    try mrb.evalFile(opts.script_path);

    // Record start time for timer
    const start_time = std.time.nanoTimestamp();

    // Initialize modern display with the specified output mode
    var display = try modern_display.ModernProvisionDisplay.init(allocator, opts.use_pretty_output);
    defer display.deinit();

    // Set global display for async executor callback
    g_display = &display;
    defer g_display = null;

    // Set poll callback for async executor
    AsyncExecutor.setPollCallback(pollDisplayUpdate);

    // Show section header
    try display.showSection("Applying Configuration");

    // Set total number of resources for progress display
    display.setTotalResources(g_resources.items.len);

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
    for (g_resources.items) |*res| {
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
    for (g_resources.items) |*subscriber_res| {
        const common = subscriber_res.resource.getCommonProps();
        for (common.subscriptions.items) |sub| {
            // Find the source resource that this resource is subscribing to
            const source_id_parsed = base.notification.ResourceId.parse(allocator, sub.target_resource_id) catch continue;
            defer source_id_parsed.deinit(allocator);

            // Find the source resource in our list
            for (g_resources.items) |*source_res| {
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
    for (g_resources.items) |*res| {
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
            try display.resourceError(res.id.type_name, res.id.name, @errorName(err));
            try display.update();

            // Check if this resource has ignore_failure set
            if (res.resource.shouldIgnoreFailure()) {
                // Continue to next resource if ignore_failure is true
                continue;
            } else {
                // Stop execution and return error
                return err;
            }
        };
        res.was_updated = result.was_updated;

        // Update resource status with action and skip reason
        // If skip_reason is "up to date", show it even if was_updated is false
        if (result.was_updated) {
            // Pass skip_reason to resourceUpdated so it can handle "up to date" case
            try display.resourceUpdated(res.id.type_name, res.id.name, result.action, result.skip_reason);
            try display.update();

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
}
