const std = @import("std");
const notification = @import("notification.zig");
const base = @import("base_resource.zig");
const builtin = @import("builtin");

// Import all resource types
pub const file = @import("resources/file.zig");
pub const execute = @import("resources/execute.zig");
pub const remote_file = @import("resources/remote_file.zig");
pub const template = @import("resources/template.zig");
pub const directory = @import("resources/directory.zig");
pub const link = @import("resources/link.zig");
pub const route = @import("resources/route.zig");
pub const git = @import("resources/git.zig");
pub const aws_kms = @import("resources/aws_kms.zig");
pub const file_edit = @import("resources/file_edit.zig");
pub const extract = @import("resources/extract.zig");

// macOS-only resources
pub const macos_dock = if (builtin.os.tag == .macos)
    @import("resources/macos_dock.zig")
else
    struct {
        pub const ruby_prelude = @embedFile("resources/macos_dock_resource.rb");
    };

/// macos_defaults resource implementation:
/// - On macOS: full Zig implementation in resources/macos_defaults.zig
/// - On other platforms: Ruby DSL prelude only, so Ruby `macos_defaults` helper exists
///   but does not call into ZigBackend (handled in the Ruby prelude itself).
pub const macos_defaults = if (builtin.os.tag == .macos)
    @import("resources/macos_defaults.zig")
else
    struct {
        pub const ruby_prelude = @embedFile("resources/macos_defaults_resource.rb");
    };

// Linux-only resources
pub const apt_repository = if (builtin.os.tag == .linux)
    @import("resources/apt_repository.zig")
else
    struct {
        pub const ruby_prelude = @embedFile("resources/apt_repository_resource.rb");
    };

pub const systemd_unit = if (builtin.os.tag == .linux)
    @import("resources/systemd_unit.zig")
else
    struct {
        pub const ruby_prelude = @embedFile("resources/systemd_unit_resource.rb");
    };

pub const mount_res = if (builtin.os.tag == .linux)
    @import("resources/mount.zig")
else
    struct {
        pub const ruby_prelude = @embedFile("resources/mount_resource.rb");
    };

// Cross-platform package resource (supports homebrew on macOS, apt on Linux)
pub const package = @import("resources/package.zig");

// Platform-specific package managers
pub const homebrew_package = if (builtin.os.tag == .macos)
    @import("resources/homebrew_package.zig")
else
    struct {
        pub const ruby_prelude = @embedFile("resources/homebrew_package_resource.rb");
    };

pub const apt_package = if (builtin.os.tag == .linux)
    @import("resources/apt_package.zig")
else
    struct {
        pub const ruby_prelude = @embedFile("resources/apt_package_resource.rb");
    };

// Cross-platform ruby_block resource
pub const ruby_block = @import("resources/ruby_block.zig");

// User and group management resources
pub const user = @import("resources/user.zig");
pub const group = @import("resources/group.zig");

pub const Notification = notification.Notification;
pub const ResourceId = notification.ResourceId;
pub const NotificationTiming = notification.Timing;
pub const ApplyResult = base.ApplyResult;

/// Wrapper for a resource with metadata
pub const ResourceWithMetadata = struct {
    resource: Resource,
    id: ResourceId,
    notifications: std.ArrayList(Notification),
    was_updated: bool = false, // Track if resource was changed

    pub fn deinit(self: *ResourceWithMetadata, allocator: std.mem.Allocator) void {
        self.resource.deinit(allocator);
        self.id.deinit(allocator);
        for (self.notifications.items) |notif| {
            notif.deinit(allocator);
        }
        self.notifications.deinit(allocator);
    }
};

const has_macos = builtin.os.tag == .macos;

/// Unified resource enum supporting all resource types
pub const Resource = if (has_macos) ResourceMacOs else ResourceGeneric;

fn deinitResourceUnion(resource: anytype, allocator: std.mem.Allocator) void {
    switch (resource) {
        inline else => |res| res.deinit(allocator),
    }
}

fn applyResourceUnion(resource: anytype) !ApplyResult {
    return switch (resource) {
        inline else => |res| try res.apply(),
    };
}

fn payloadName(payload: anytype) []const u8 {
    const Payload = @TypeOf(payload);

    if (Payload == macos_dock.Resource) return "Dock";
    if (Payload == aws_kms.Resource) return payload.name;
    if (Payload == package.Resource or Payload == homebrew_package.Resource or Payload == apt_package.Resource) {
        return payload.displayName();
    }
    if (@hasField(Payload, "path")) return payload.path;
    if (@hasField(Payload, "target")) return payload.target;
    if (@hasField(Payload, "mount_point")) return payload.mount_point;
    if (@hasField(Payload, "destination")) return payload.destination;
    if (@hasField(Payload, "username")) return payload.username;
    if (@hasField(Payload, "group_name")) return payload.group_name;
    if (@hasField(Payload, "key")) return payload.key;
    if (@hasField(Payload, "name")) return payload.name;

    @compileError("Unsupported resource payload for getName");
}

fn payloadCommonProps(payload: anytype) *base.CommonProps {
    const Payload = @TypeOf(payload.*);

    if (Payload == package.Resource) {
        if (builtin.os.tag == .macos) {
            return switch (payload.backend) {
                .homebrew => |*hb| &hb.common_props,
            };
        } else if (builtin.os.tag == .linux) {
            return switch (payload.backend) {
                .apt => |*apt| &apt.common_props,
            };
        } else {
            unreachable;
        }
    }
    if (@hasField(Payload, "common")) return &payload.common;
    if (@hasField(Payload, "common_props")) return &payload.common_props;

    @compileError("Unsupported resource payload for getCommonProps");
}

fn payloadShouldIgnoreFailure(payload: anytype) bool {
    const Payload = @TypeOf(payload);

    if (Payload == package.Resource) {
        if (builtin.os.tag == .macos) {
            return switch (payload.backend) {
                .homebrew => |hb| hb.common_props.ignore_failure,
            };
        } else if (builtin.os.tag == .linux) {
            return switch (payload.backend) {
                .apt => |apt| apt.common_props.ignore_failure,
            };
        } else {
            return false;
        }
    }
    if (@hasField(Payload, "common")) return payload.common.ignore_failure;
    if (@hasField(Payload, "common_props")) return payload.common_props.ignore_failure;

    @compileError("Unsupported resource payload for shouldIgnoreFailure");
}

fn resourceName(resource: anytype) []const u8 {
    return switch (resource) {
        inline else => |res| payloadName(res),
    };
}

fn resourceCommonProps(resource: anytype) *base.CommonProps {
    return switch (resource.*) {
        inline else => |*res| payloadCommonProps(res),
    };
}

fn resourceShouldIgnoreFailure(resource: anytype) bool {
    return switch (resource) {
        inline else => |res| payloadShouldIgnoreFailure(res),
    };
}

const ResourceMacOs = union(enum) {
    file: file.Resource,
    execute: execute.Resource,
    remote_file: remote_file.Resource,
    template: template.Resource,
    macos_dock: macos_dock.Resource,
    macos_defaults: macos_defaults.Resource,
    directory: directory.Resource,
    link: link.Resource,
    route: route.Resource,
    package: package.Resource,
    homebrew_package: homebrew_package.Resource,
    ruby_block: ruby_block.Resource,
    git: git.Resource,
    user: user.Resource,
    group: group.Resource,
    aws_kms: aws_kms.Resource,
    file_edit: file_edit.Resource,
    extract: extract.Resource,

    pub fn deinit(self: ResourceMacOs, allocator: std.mem.Allocator) void {
        deinitResourceUnion(self, allocator);
    }

    pub fn apply(self: ResourceMacOs) !ApplyResult {
        return applyResourceUnion(self);
    }

    pub fn getName(self: ResourceMacOs) []const u8 {
        return resourceName(self);
    }

    pub fn getCommonProps(self: *ResourceMacOs) *base.CommonProps {
        return resourceCommonProps(self);
    }

    pub fn shouldIgnoreFailure(self: ResourceMacOs) bool {
        return resourceShouldIgnoreFailure(self);
    }
};

const ResourceGeneric = union(enum) {
    file: file.Resource,
    execute: execute.Resource,
    remote_file: remote_file.Resource,
    template: template.Resource,
    directory: directory.Resource,
    link: link.Resource,
    apt_repository: apt_repository.Resource,
    systemd_unit: systemd_unit.Resource,
    mount_res: mount_res.Resource,
    package: package.Resource,
    apt_package: apt_package.Resource,
    ruby_block: ruby_block.Resource,
    route: route.Resource,
    git: git.Resource,
    user: user.Resource,
    group: group.Resource,
    aws_kms: aws_kms.Resource,
    file_edit: file_edit.Resource,
    extract: extract.Resource,

    pub fn deinit(self: ResourceGeneric, allocator: std.mem.Allocator) void {
        deinitResourceUnion(self, allocator);
    }

    pub fn apply(self: ResourceGeneric) !ApplyResult {
        return applyResourceUnion(self);
    }

    pub fn getName(self: ResourceGeneric) []const u8 {
        return resourceName(self);
    }

    pub fn getCommonProps(self: *ResourceGeneric) *base.CommonProps {
        return resourceCommonProps(self);
    }

    pub fn shouldIgnoreFailure(self: ResourceGeneric) bool {
        return resourceShouldIgnoreFailure(self);
    }
};
