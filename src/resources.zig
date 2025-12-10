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

    pub fn deinit(self: ResourceMacOs, allocator: std.mem.Allocator) void {
        switch (self) {
            .file => |res| res.deinit(allocator),
            .execute => |res| res.deinit(allocator),
            .remote_file => |res| res.deinit(allocator),
            .template => |res| res.deinit(allocator),
            .macos_dock => |res| res.deinit(allocator),
            .macos_defaults => |res| res.deinit(allocator),
            .directory => |res| res.deinit(allocator),
            .link => |res| res.deinit(allocator),
            .route => |res| res.deinit(allocator),
            .package => |res| res.deinit(allocator),
            .homebrew_package => |res| res.deinit(allocator),
            .ruby_block => |res| res.deinit(allocator),
            .git => |res| res.deinit(allocator),
            .user => |res| res.deinit(allocator),
            .group => |res| res.deinit(allocator),
        }
    }

    pub fn apply(self: ResourceMacOs) !ApplyResult {
        return switch (self) {
            .file => |res| try res.apply(),
            .execute => |res| try res.apply(),
            .remote_file => |res| try res.apply(),
            .template => |res| try res.apply(),
            .macos_dock => |res| try res.apply(),
            .macos_defaults => |res| try res.apply(),
            .directory => |res| try res.apply(),
            .link => |res| try res.apply(),
            .route => |res| try res.apply(),
            .package => |res| try res.apply(),
            .homebrew_package => |res| try res.apply(),
            .ruby_block => |res| try res.apply(),
            .git => |res| try res.apply(),
            .user => |res| try res.apply(),
            .group => |res| try res.apply(),
        };
    }

    pub fn getName(self: ResourceMacOs) []const u8 {
        return switch (self) {
            .file => |res| res.path,
            .execute => |res| res.name,
            .remote_file => |res| res.path,
            .template => |res| res.path,
            .macos_dock => "Dock",
            .macos_defaults => |res| res.key,
            .directory => |res| res.path,
            .link => |res| res.path,
            .route => |res| res.target,
            .package => |res| res.displayName(),
            .homebrew_package => |res| res.displayName(),
            .ruby_block => |res| res.name,
            .git => |res| res.destination,
            .user => |res| res.username,
            .group => |res| res.group_name,
        };
    }

    pub fn getCommonProps(self: *ResourceMacOs) *base.CommonProps {
        return switch (self.*) {
            .file => |*res| &res.common,
            .execute => |*res| &res.common,
            .remote_file => |*res| &res.common,
            .template => |*res| &res.common,
            .macos_dock => |*res| &res.common,
            .macos_defaults => |*res| &res.common,
            .directory => |*res| &res.common,
            .link => |*res| &res.common,
            .route => |*res| &res.common,
            .package => |*res| blk: {
                // package is a delegator, need to get common from backend
                if (builtin.os.tag == .macos) {
                    break :blk switch (res.backend) {
                        .homebrew => |*hb| &hb.common_props,
                    };
                } else {
                    unreachable;
                }
            },
            .homebrew_package => |*res| &res.common_props,
            .ruby_block => |*res| &res.common,
            .git => |*res| &res.common,
            .user => |*res| &res.common,
            .group => |*res| &res.common,
        };
    }

    pub fn shouldIgnoreFailure(self: ResourceMacOs) bool {
        return switch (self) {
            .file => |res| res.common.ignore_failure,
            .execute => |res| res.common.ignore_failure,
            .remote_file => |res| res.common.ignore_failure,
            .template => |res| res.common.ignore_failure,
            .macos_dock => |res| res.common.ignore_failure,
            .macos_defaults => |res| res.common.ignore_failure,
            .directory => |res| res.common.ignore_failure,
            .link => |res| res.common.ignore_failure,
            .route => |res| res.common.ignore_failure,
            .package => |res| blk: {
                // package is a delegator, need to get common from backend
                if (builtin.os.tag == .macos) {
                    break :blk switch (res.backend) {
                        .homebrew => |hb| hb.common_props.ignore_failure,
                    };
                } else {
                    break :blk false;
                }
            },
            .homebrew_package => |res| res.common_props.ignore_failure,
            .ruby_block => |res| res.common.ignore_failure,
            .git => |res| res.common.ignore_failure,
            .user => |res| res.common.ignore_failure,
            .group => |res| res.common.ignore_failure,
        };
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
    package: package.Resource,
    apt_package: apt_package.Resource,
    ruby_block: ruby_block.Resource,
    route: route.Resource,
    git: git.Resource,
    user: user.Resource,
    group: group.Resource,

    pub fn deinit(self: ResourceGeneric, allocator: std.mem.Allocator) void {
        switch (self) {
            .file => |res| res.deinit(allocator),
            .execute => |res| res.deinit(allocator),
            .remote_file => |res| res.deinit(allocator),
            .template => |res| res.deinit(allocator),
            .directory => |res| res.deinit(allocator),
            .link => |res| res.deinit(allocator),
            .apt_repository => |res| res.deinit(allocator),
            .systemd_unit => |res| res.deinit(allocator),
            .package => |res| res.deinit(allocator),
            .apt_package => |res| res.deinit(allocator),
            .ruby_block => |res| res.deinit(allocator),
            .route => |res| res.deinit(allocator),
            .git => |res| res.deinit(allocator),
            .user => |res| res.deinit(allocator),
            .group => |res| res.deinit(allocator),
        }
    }

    pub fn apply(self: ResourceGeneric) !ApplyResult {
        return switch (self) {
            .file => |res| try res.apply(),
            .execute => |res| try res.apply(),
            .remote_file => |res| try res.apply(),
            .template => |res| try res.apply(),
            .directory => |res| try res.apply(),
            .link => |res| try res.apply(),
            .apt_repository => |res| try res.apply(),
            .systemd_unit => |res| try res.apply(),
            .package => |res| try res.apply(),
            .apt_package => |res| try res.apply(),
            .ruby_block => |res| try res.apply(),
            .route => |res| try res.apply(),
            .git => |res| try res.apply(),
            .user => |res| try res.apply(),
            .group => |res| try res.apply(),
        };
    }

    pub fn getName(self: ResourceGeneric) []const u8 {
        return switch (self) {
            .file => |res| res.path,
            .execute => |res| res.name,
            .remote_file => |res| res.path,
            .template => |res| res.path,
            .directory => |res| res.path,
            .link => |res| res.path,
            .apt_repository => |res| res.name,
            .systemd_unit => |res| res.name,
            .package => |res| res.displayName(),
            .apt_package => |res| res.displayName(),
            .ruby_block => |res| res.name,
            .route => |res| res.target,
            .git => |res| res.destination,
            .user => |res| res.username,
            .group => |res| res.group_name,
        };
    }

    pub fn getCommonProps(self: *ResourceGeneric) *base.CommonProps {
        return switch (self.*) {
            .file => |*res| &res.common,
            .execute => |*res| &res.common,
            .remote_file => |*res| &res.common,
            .template => |*res| &res.common,
            .directory => |*res| &res.common,
            .link => |*res| &res.common,
            .apt_repository => |*res| &res.common,
            .systemd_unit => |*res| &res.common,
            .package => |*res| blk: {
                // package is a delegator, need to get common from backend
                if (builtin.os.tag == .linux) {
                    break :blk switch (res.backend) {
                        .apt => |*apt| &apt.common_props,
                    };
                } else {
                    unreachable;
                }
            },
            .apt_package => |*res| &res.common_props,
            .ruby_block => |*res| &res.common,
            .route => |*res| &res.common,
            .git => |*res| &res.common,
            .user => |*res| &res.common,
            .group => |*res| &res.common,
        };
    }

    pub fn shouldIgnoreFailure(self: ResourceGeneric) bool {
        return switch (self) {
            .file => |res| res.common.ignore_failure,
            .execute => |res| res.common.ignore_failure,
            .remote_file => |res| res.common.ignore_failure,
            .template => |res| res.common.ignore_failure,
            .directory => |res| res.common.ignore_failure,
            .link => |res| res.common.ignore_failure,
            .apt_repository => |res| res.common.ignore_failure,
            .systemd_unit => |res| res.common.ignore_failure,
            .package => |res| blk: {
                // package is a delegator, need to get common from backend
                if (builtin.os.tag == .linux) {
                    break :blk switch (res.backend) {
                        .apt => |apt| apt.common_props.ignore_failure,
                    };
                } else {
                    break :blk false;
                }
            },
            .apt_package => |res| res.common_props.ignore_failure,
            .ruby_block => |res| res.common.ignore_failure,
            .route => |res| res.common.ignore_failure,
            .git => |res| res.common.ignore_failure,
            .user => |res| res.common.ignore_failure,
            .group => |res| res.common.ignore_failure,
        };
    }
};
