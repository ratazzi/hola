const std = @import("std");
const mruby = @import("mruby.zig");
const resources = @import("resources.zig");
const download_manager = @import("download_manager.zig");
const modern_display = @import("modern_provision_display.zig");
const logger = @import("logger.zig");
const http_utils = @import("http_utils.zig");
const http_client = @import("http_client.zig");
const json = @import("json.zig");
const base64 = @import("base64.zig");
const hola_logger = @import("hola_logger.zig");
const node_info = @import("node_info.zig");
const env_access = @import("env_access.zig");
const base = @import("base_resource.zig");
const builtin = @import("builtin");
const is_macos = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;

pub const Options = struct {
    script_path: []const u8,
};

// Global resource collector (will be initialized per-run)
var g_allocator: std.mem.Allocator = undefined;
var g_resources: std.ArrayList(resources.ResourceWithMetadata) = undefined;

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
) mruby.mrb_value {
    // Create a temporary ArrayList for this resource type
    var tmp_resources = std.ArrayList(T).empty;
    defer tmp_resources.deinit(g_allocator);

    // Call the resource-specific Zig add function
    const result = add_fn(mrb, self, &tmp_resources, g_allocator);

    // If nothing was added, just return the result from the resource handler
    if (tmp_resources.items.len == 0) return result;

    const res = tmp_resources.items[0];

    // Build ResourceId
    const id = build_id(g_allocator, &res) catch return mruby.mrb_nil_value();

    // Copy notifications from common props into metadata
    const notifications = cloneNotificationsFromCommon(g_allocator, &res.common) catch return mruby.mrb_nil_value();

    // Wrap into unified Resource enum
    const res_with_meta = resources.ResourceWithMetadata{
        .resource = wrap(res),
        .id = id,
        .notifications = notifications,
    };

    g_resources.append(g_allocator, res_with_meta) catch return mruby.mrb_nil_value();

    return result;
}

fn buildExecuteId(allocator: std.mem.Allocator, res: *const resources.execute.Resource) !resources.ResourceId {
    return makeResourceId(allocator, "execute", res.name);
}
fn wrapExecute(res: resources.execute.Resource) resources.Resource {
    return .{ .execute = res };
}

fn buildFileId(allocator: std.mem.Allocator, res: *const resources.file.Resource) !resources.ResourceId {
    return makeResourceId(allocator, "file", res.path);
}
fn wrapFile(res: resources.file.Resource) resources.Resource {
    return .{ .file = res };
}

fn buildRemoteFileId(allocator: std.mem.Allocator, res: *const resources.remote_file.Resource) !resources.ResourceId {
    return makeResourceId(allocator, "remote_file", res.path);
}
fn wrapRemoteFile(res: resources.remote_file.Resource) resources.Resource {
    return .{ .remote_file = res };
}

fn buildTemplateId(allocator: std.mem.Allocator, res: *const resources.template.Resource) !resources.ResourceId {
    return makeResourceId(allocator, "template", res.path);
}
fn wrapTemplate(res: resources.template.Resource) resources.Resource {
    return .{ .template = res };
}

fn buildMacosDockId(allocator: std.mem.Allocator, res: *const resources.macos_dock.Resource) !resources.ResourceId {
    _ = res;
    return makeResourceId(allocator, "macos_dock", "Dock");
}
fn wrapMacosDock(res: resources.macos_dock.Resource) resources.Resource {
    return .{ .macos_dock = res };
}

fn buildDirectoryId(allocator: std.mem.Allocator, res: *const resources.directory.Resource) !resources.ResourceId {
    return makeResourceId(allocator, "directory", res.path);
}
fn wrapDirectory(res: resources.directory.Resource) resources.Resource {
    return .{ .directory = res };
}

fn buildLinkId(allocator: std.mem.Allocator, res: *const resources.link.Resource) !resources.ResourceId {
    return makeResourceId(allocator, "link", res.path);
}
fn wrapLink(res: resources.link.Resource) resources.Resource {
    return .{ .link = res };
}

fn buildMacosDefaultsId(allocator: std.mem.Allocator, res: *const resources.macos_defaults.Resource) !resources.ResourceId {
    const id_str = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ res.domain, res.key });
    defer allocator.free(id_str);
    return makeResourceId(allocator, "macos_defaults", id_str);
}
fn wrapMacosDefaults(res: resources.macos_defaults.Resource) resources.Resource {
    return .{ .macos_defaults = res };
}

fn buildAptRepositoryId(allocator: std.mem.Allocator, res: *const resources.apt_repository.Resource) !resources.ResourceId {
    return makeResourceId(allocator, "apt_repository", res.name);
}
fn wrapAptRepository(res: resources.apt_repository.Resource) resources.Resource {
    return .{ .apt_repository = res };
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
    // Signature: add_file(path, content, action, mode, only_if_block=nil, not_if_block=nil, notifications=nil)
    mruby.mrb_define_module_function(
        mrb_ptr,
        zig_module,
        "add_file",
        zig_add_file_resource,
        mruby.MRB_ARGS_REQ(4) | mruby.MRB_ARGS_OPT(3), // 4 required + 3 optional
    );

    // Register execute resource
    // Signature: add_execute(name, command, cwd, action, only_if_block=nil, not_if_block=nil, notifications=nil)
    mruby.mrb_define_module_function(
        mrb_ptr,
        zig_module,
        "add_execute",
        zig_add_execute_resource,
        mruby.MRB_ARGS_REQ(4) | mruby.MRB_ARGS_OPT(3), // 4 required + 3 optional
    );

    // Register remote_file resource
    // Signature: add_remote_file(path, source, mode, owner, group, checksum, backup, headers, action, only_if_block=nil, not_if_block=nil, notifications=nil)
    mruby.mrb_define_module_function(
        mrb_ptr,
        zig_module,
        "add_remote_file",
        zig_add_remote_file_resource,
        mruby.MRB_ARGS_REQ(9) | mruby.MRB_ARGS_OPT(3), // 9 required + 3 optional
    );

    // Register template resource
    // Signature: add_template(path, source, mode, variables_array, action, only_if_block=nil, not_if_block=nil, notifications=nil)
    mruby.mrb_define_module_function(
        mrb_ptr,
        zig_module,
        "add_template",
        zig_add_template_resource,
        mruby.MRB_ARGS_REQ(5) | mruby.MRB_ARGS_OPT(3), // 5 required + 3 optional
    );

    // Register macos_dock resource (macOS only)
    // Signature: add_macos_dock(apps_array, tilesize=nil, orientation=nil, autohide=nil, magnification=nil, largesize=nil, only_if_block=nil, not_if_block=nil, notifications=nil)
    if (is_macos) {
        mruby.mrb_define_module_function(
            mrb_ptr,
            zig_module,
            "add_macos_dock",
            zig_add_macos_dock_resource,
            mruby.MRB_ARGS_REQ(1) | mruby.MRB_ARGS_OPT(8), // 1 required + 8 optional
        );
    }

    // Register directory resource
    // Signature: add_directory(path, mode=nil, recursive=false, action="create", only_if_block=nil, not_if_block=nil, notifications=nil)
    mruby.mrb_define_module_function(
        mrb_ptr,
        zig_module,
        "add_directory",
        zig_add_directory_resource,
        mruby.MRB_ARGS_REQ(1) | mruby.MRB_ARGS_OPT(6), // 1 required + 6 optional
    );

    // Register link resource
    // Signature: add_link(path, target, action="create", only_if_block=nil, not_if_block=nil, notifications=nil)
    mruby.mrb_define_module_function(
        mrb_ptr,
        zig_module,
        "add_link",
        zig_add_link_resource,
        mruby.MRB_ARGS_REQ(2) | mruby.MRB_ARGS_OPT(4), // 2 required + 4 optional
    );

    // Register macos_defaults resource (macOS only)
    // Signature: add_macos_defaults(domain, key, value_array=nil, action="write", only_if_block=nil, not_if_block=nil, notifications=nil)
    if (is_macos) {
        mruby.mrb_define_module_function(
            mrb_ptr,
            zig_module,
            "add_macos_defaults",
            zig_add_macos_defaults_resource,
            mruby.MRB_ARGS_REQ(2) | mruby.MRB_ARGS_OPT(5), // 2 required + 5 optional
        );
    }

    // Register apt_repository resource (Linux only)
    // Signature: add_apt_repository(name, uri, key_url, key_path, distribution, components, arch, options, repo_type, action, only_if_block=nil, not_if_block=nil, notifications=nil)
    if (is_linux) {
        mruby.mrb_define_module_function(
            mrb_ptr,
            zig_module,
            "add_apt_repository",
            zig_add_apt_repository_resource,
            mruby.MRB_ARGS_REQ(10) | mruby.MRB_ARGS_OPT(3), // 10 required + 3 optional
        );
    }


    // Register HTTP client functions
    // Initialize HTTP client with allocator
    http_client.setAllocator(allocator);

    // Signature: http_get(url, headers=nil)
    mruby.mrb_define_module_function(
        mrb_ptr,
        zig_module,
        "http_get",
        http_client.zig_http_get,
        mruby.MRB_ARGS_REQ(1) | mruby.MRB_ARGS_OPT(1),
    );

    // Signature: http_post(url, body=nil, content_type=nil, headers=nil)
    mruby.mrb_define_module_function(
        mrb_ptr,
        zig_module,
        "http_post",
        http_client.zig_http_post,
        mruby.MRB_ARGS_REQ(1) | mruby.MRB_ARGS_OPT(3),
    );

    // Register JSON functions
    json.setAllocator(allocator);

    // Signature: json_encode(obj)
    mruby.mrb_define_module_function(
        mrb_ptr,
        zig_module,
        "json_encode",
        json.zig_json_encode,
        mruby.MRB_ARGS_REQ(1),
    );

    // Signature: json_decode(str)
    mruby.mrb_define_module_function(
        mrb_ptr,
        zig_module,
        "json_decode",
        json.zig_json_decode,
        mruby.MRB_ARGS_REQ(1),
    );

    // Register Base64 functions
    base64.setAllocator(allocator);

    // Signature: base64_encode(str)
    mruby.mrb_define_module_function(
        mrb_ptr,
        zig_module,
        "base64_encode",
        base64.zig_base64_encode,
        mruby.MRB_ARGS_REQ(1),
    );

    // Signature: base64_decode(str)
    mruby.mrb_define_module_function(
        mrb_ptr,
        zig_module,
        "base64_decode",
        base64.zig_base64_decode,
        mruby.MRB_ARGS_REQ(1),
    );

    // Signature: base64_urlsafe_encode(str)
    mruby.mrb_define_module_function(
        mrb_ptr,
        zig_module,
        "base64_urlsafe_encode",
        base64.zig_base64_urlsafe_encode,
        mruby.MRB_ARGS_REQ(1),
    );

    // Signature: base64_urlsafe_decode(str)
    mruby.mrb_define_module_function(
        mrb_ptr,
        zig_module,
        "base64_urlsafe_decode",
        base64.zig_base64_urlsafe_decode,
        mruby.MRB_ARGS_REQ(1),
    );

    // Register Hola logging functions
    // Signature: hola_debug(msg), hola_info(msg), hola_warn(msg), hola_error(msg)
    mruby.mrb_define_module_function(
        mrb_ptr,
        zig_module,
        "hola_debug",
        hola_logger.zig_hola_debug,
        mruby.MRB_ARGS_REQ(1),
    );
    mruby.mrb_define_module_function(
        mrb_ptr,
        zig_module,
        "hola_info",
        hola_logger.zig_hola_info,
        mruby.MRB_ARGS_REQ(1),
    );
    mruby.mrb_define_module_function(
        mrb_ptr,
        zig_module,
        "hola_warn",
        hola_logger.zig_hola_warn,
        mruby.MRB_ARGS_REQ(1),
    );
    mruby.mrb_define_module_function(
        mrb_ptr,
        zig_module,
        "hola_error",
        hola_logger.zig_hola_error,
        mruby.MRB_ARGS_REQ(1),
    );

    // Register node info functions
    node_info.setAllocator(allocator);
    mruby.mrb_define_module_function(mrb_ptr, zig_module, "get_node_hostname", node_info.zig_get_node_hostname, mruby.MRB_ARGS_NONE());
    mruby.mrb_define_module_function(mrb_ptr, zig_module, "get_node_fqdn", node_info.zig_get_node_fqdn, mruby.MRB_ARGS_NONE());
    mruby.mrb_define_module_function(mrb_ptr, zig_module, "get_node_platform", node_info.zig_get_node_platform, mruby.MRB_ARGS_NONE());
    mruby.mrb_define_module_function(mrb_ptr, zig_module, "get_node_platform_family", node_info.zig_get_node_platform_family, mruby.MRB_ARGS_NONE());
    mruby.mrb_define_module_function(mrb_ptr, zig_module, "get_node_platform_version", node_info.zig_get_node_platform_version, mruby.MRB_ARGS_NONE());
    mruby.mrb_define_module_function(mrb_ptr, zig_module, "get_node_os", node_info.zig_get_node_os, mruby.MRB_ARGS_NONE());
    mruby.mrb_define_module_function(mrb_ptr, zig_module, "get_node_kernel_name", node_info.zig_get_node_kernel_name, mruby.MRB_ARGS_NONE());
    mruby.mrb_define_module_function(mrb_ptr, zig_module, "get_node_kernel_release", node_info.zig_get_node_kernel_release, mruby.MRB_ARGS_NONE());
    mruby.mrb_define_module_function(mrb_ptr, zig_module, "get_node_machine", node_info.zig_get_node_machine, mruby.MRB_ARGS_NONE());
    mruby.mrb_define_module_function(mrb_ptr, zig_module, "get_node_cpu_arch", node_info.zig_get_node_cpu_arch, mruby.MRB_ARGS_NONE());
    mruby.mrb_define_module_function(mrb_ptr, zig_module, "get_node_network_interfaces", node_info.zig_get_node_network_interfaces, mruby.MRB_ARGS_NONE());
    mruby.mrb_define_module_function(mrb_ptr, zig_module, "get_node_default_gateway_ip", node_info.zig_get_node_default_gateway_ip, mruby.MRB_ARGS_NONE());
    mruby.mrb_define_module_function(mrb_ptr, zig_module, "get_node_default_interface", node_info.zig_get_node_default_interface, mruby.MRB_ARGS_NONE());
    mruby.mrb_define_module_function(mrb_ptr, zig_module, "get_node_lsb_info", node_info.zig_get_node_lsb_info, mruby.MRB_ARGS_NONE());

    // Register ENV access functions
    env_access.setAllocator(allocator);
    mruby.mrb_define_module_function(mrb_ptr, zig_module, "env_get", env_access.zig_env_get, mruby.MRB_ARGS_REQ(1));
    mruby.mrb_define_module_function(mrb_ptr, zig_module, "env_set", env_access.zig_env_set, mruby.MRB_ARGS_REQ(2));
    mruby.mrb_define_module_function(mrb_ptr, zig_module, "env_delete", env_access.zig_env_delete, mruby.MRB_ARGS_REQ(1));
    mruby.mrb_define_module_function(mrb_ptr, zig_module, "env_has_key", env_access.zig_env_has_key, mruby.MRB_ARGS_REQ(1));

    // Future: Register other resources
    // mruby.mrb_define_module_function(mrb_ptr, zig_module, "add_package", zig_add_package_resource, ...);
    // mruby.mrb_define_module_function(mrb_ptr, zig_module, "add_service", zig_add_service_resource, ...);

    // Load Ruby DSL preludes
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
    // Load Linux-specific Ruby DSLs (apt_repository, etc.)
    // On non-Linux, the Ruby preludes detect absence of ZigBackend entrypoints
    try mrb.evalString(resources.apt_repository.ruby_prelude);
    // Load JSON module (must be before HTTP client)
    try mrb.evalString(json.ruby_prelude);
    // Load HTTP client prelude
    try mrb.evalString(http_client.ruby_prelude);
    // Load Base64 module
    try mrb.evalString(base64.ruby_prelude);
    // Load Hola logging module
    try mrb.evalString(hola_logger.ruby_prelude);
    // Load node info module
    try mrb.evalString(node_info.ruby_prelude);
    // Load ENV access module
    try mrb.evalString(env_access.ruby_prelude);
    // Future: Load other resource preludes
    // try mrb.evalString(resources.package.ruby_prelude);
    // try mrb.evalString(resources.service.ruby_prelude);

    // Load and execute user's recipe
    const script = try std.fs.cwd().readFileAlloc(allocator, opts.script_path, std.math.maxInt(usize));
    defer allocator.free(script);
    try mrb.evalString(script);

    // Record start time for timer
    const start_time = std.time.nanoTimestamp();

    // Initialize modern display with indicatif enabled
    var display = try modern_display.ModernProvisionDisplay.init(allocator, true); // Enable indicatif
    defer display.deinit();

    // Show section header
    try display.showSection("Applying Configuration");

    // Set total number of resources for progress display
    display.setTotalResources(g_resources.items.len);

    // Phase 0: Start parallel downloads for remote files
    // Enable download manager's progress display using indicatif
    var download_mgr = try download_manager.DownloadManager.init(allocator, true);
    defer download_mgr.deinit();

    // Set the display for download manager to use indicatif
    download_mgr.setDisplay(&display);

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
            const path_slug = try http_utils.slugifyPath(allocator, remote_res.path);
            defer allocator.free(path_slug);

            // Generate temporary file path with slugified path (no prefix needed, already in dedicated temp dir)
            const temp_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ download_mgr.temp_dir, path_slug });

            // Use full destination path for display (truncated later if needed)
            const display_name = remote_res.path;

            // Create download task
            const task = download_manager.DownloadTask{
                .url = try allocator.dupe(u8, remote_res.source),
                .temp_path = temp_path,
                .final_path = try allocator.dupe(u8, remote_res.path),
                .mode = if (remote_res.attrs.mode) |mode| try std.fmt.allocPrint(allocator, "{o}", .{mode}) else null,
                .checksum = if (remote_res.checksum) |checksum| try allocator.dupe(u8, checksum) else null,
                .backup = if (remote_res.backup) |backup| try allocator.dupe(u8, backup) else null,
                .headers = if (remote_res.headers) |headers| try allocator.dupe(u8, headers) else null,
                .resource_id = try std.fmt.allocPrint(allocator, "{s}[{s}]", .{ res.id.type_name, res.id.name }),
                .display_name = try allocator.dupe(u8, display_name),
            };

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

    var download_session: ?download_manager.DownloadManager.DownloadSession = null;
    errdefer if (download_session) |*session| session.deinit();

    if (download_mgr.tasks.items.len > 0) {
        download_session = try download_mgr.startParallelDownloads();
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

    // Phase 1: Execute resources and collect notifications
    for (g_resources.items) |*res| {
        try display.startResource(res.id.type_name, res.id.name);
        try display.update();

        if (download_session) |*session| {
            if (res.resource == .remote_file and session.is_active) {
                // Find the download task for this specific remote_file resource
                const resource_id = try std.fmt.allocPrint(allocator, "{s}[{s}]", .{ res.id.type_name, res.id.name });
                defer allocator.free(resource_id);

                var task_index: ?usize = null;
                for (download_mgr.tasks.items, 0..) |*task, idx| {
                    if (std.mem.eql(u8, task.resource_id, resource_id)) {
                        task_index = idx;
                        break;
                    }
                }

                if (task_index) |idx| {
                    // Wait for this specific download task to complete
                    var max_wait_iterations: usize = 600; // 30 seconds max wait (50ms * 600)
                    while (session.is_active and max_wait_iterations > 0) {
                        try display.update();
                        std.Thread.yield() catch {}; // Yield to allow download thread to update status
                        std.Thread.sleep(50 * std.time.ns_per_ms);

                        // Check if this specific task is done (status != 0 means completed or failed)
                        // Use atomic load with acquire ordering to ensure we see the latest value
                        const current_status = download_mgr.tasks.items[idx].status.load(.acquire);
                        if (current_status != 0) {
                            break;
                        }
                        max_wait_iterations -= 1;
                    }

                    // Check if the download failed
                    const final_status = download_mgr.tasks.items[idx].status.load(.acquire);
                    if (final_status == 2) { // 2 typically means failed
                        // Wait for all threads to complete before returning error to avoid segfault
                        if (session.is_active) {
                            _ = session.waitForCompletion(allocator) catch {};
                        }
                        const msg = try std.fmt.allocPrint(allocator, "Download failed for {s}", .{resource_id});
                        defer allocator.free(msg);
                        try display.showInfo(msg);
                        return error.DownloadFailed;
                    }
                }
            }
        }

        const result = res.resource.apply() catch |err| {
            try display.resourceError(res.id.type_name, res.id.name, @errorName(err));
            try display.update();
            continue;
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

    // Wait for any downloads that never got awaited during resource execution
    if (download_session) |*session| {
        if (session.is_active) {
            try display.showInfo("Waiting for remaining downloads to complete...");
            session.showFinalStatus(allocator) catch {};
        }
        session.deinit();
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
