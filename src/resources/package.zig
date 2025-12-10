const std = @import("std");
const mruby = @import("../mruby.zig");
const base = @import("../base_resource.zig");
const logger = @import("../logger.zig");
const builtin = @import("builtin");
const common = @import("package_common.zig");

// Platform-specific imports with conditional compilation
const homebrew_package = if (builtin.os.tag == .macos)
    @import("homebrew_package.zig")
else
    struct {
        pub const Resource = void;
        pub const ruby_prelude = "";
    };

const apt_package = if (builtin.os.tag == .linux)
    @import("apt_package.zig")
else
    struct {
        pub const Resource = void;
        pub const ruby_prelude = "";
    };

const is_macos = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;

/// Package resource - thin delegator to platform-specific implementations
pub const Resource = struct {
    // Delegate to platform-specific backend
    backend: BackendType,

    const BackendType = if (is_macos)
        union(enum) {
            homebrew: homebrew_package.Resource,
        }
    else if (is_linux)
        union(enum) {
            apt: apt_package.Resource,
        }
    else
        void;

    pub fn deinit(self: Resource, allocator: std.mem.Allocator) void {
        if (is_macos) {
            switch (self.backend) {
                .homebrew => |res| res.deinit(allocator),
            }
        } else if (is_linux) {
            switch (self.backend) {
                .apt => |res| res.deinit(allocator),
            }
        }
    }

    pub fn displayName(self: Resource) []const u8 {
        if (is_macos) {
            return switch (self.backend) {
                .homebrew => |res| res.displayName(),
            };
        } else if (is_linux) {
            return switch (self.backend) {
                .apt => |res| res.displayName(),
            };
        } else {
            return "unknown";
        }
    }

    pub fn apply(self: Resource) !base.ApplyResult {
        if (is_macos) {
            return switch (self.backend) {
                .homebrew => |res| try res.apply(),
            };
        } else if (is_linux) {
            return switch (self.backend) {
                .apt => |res| try res.apply(),
            };
        } else {
            return common.PackageError.UnsupportedPlatform;
        }
    }
};

/// Ruby prelude for package resource
pub const ruby_prelude = @embedFile("package_resource.rb");

/// Zig callback: called from Ruby to add a package resource
/// This delegator parses the provider and creates the appropriate backend
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
    var provider_val: mruby.mrb_value = undefined; // NEW: provider parameter
    var only_if_val: mruby.mrb_value = undefined;
    var not_if_val: mruby.mrb_value = undefined;
    var ignore_failure_val: mruby.mrb_value = undefined;
    var notifications_val: mruby.mrb_value = undefined;
    var subscriptions_val: mruby.mrb_value = undefined;

    // Get array + 4 strings + 5 optional (provider + blocks + arrays)
    _ = mruby.mrb_get_args(mrb, "ASSS|SoooAA", &names_val, &version_val, &options_val, &action_val, &provider_val, &only_if_val, &not_if_val, &ignore_failure_val, &notifications_val, &subscriptions_val);

    // Parse provider (optional, auto-detect if not specified)
    const provider_cstr = mruby.mrb_str_to_cstr(mrb, provider_val);
    const provider_str = std.mem.span(provider_cstr);
    const provider_type: common.ProviderType = if (provider_str.len > 0)
        common.ProviderType.fromString(provider_str) catch blk: {
            logger.warn("Invalid provider '{s}', using platform default", .{provider_str});
            break :blk detectProvider();
        }
    else
        detectProvider();

    // Helper to clean up allocated resources on error
    const cleanupResources = struct {
        fn call(alloc: std.mem.Allocator, names_list: *std.ArrayList([]const u8), ver: ?[]const u8, opts: ?[]const u8, props: *base.CommonProps) void {
            for (names_list.items) |name| {
                alloc.free(name);
            }
            names_list.deinit(alloc);
            if (ver) |v| alloc.free(v);
            if (opts) |o| alloc.free(o);
            props.deinit(alloc);
        }
    }.call;

    // Parse names array
    var names = std.ArrayList([]const u8).empty;
    const names_len = mruby.mrb_ary_len(mrb, names_val);
    for (0..@intCast(names_len)) |i| {
        const name_val = mruby.mrb_ary_ref(mrb, names_val, @intCast(i));
        const name_cstr = mruby.mrb_str_to_cstr(mrb, name_val);
        const name = allocator.dupe(u8, std.mem.span(name_cstr)) catch {
            // Clean up previously allocated names
            for (names.items) |n| allocator.free(n);
            names.deinit(allocator);
            return mruby.mrb_nil_value();
        };
        names.append(allocator, name) catch {
            // Clean up current name and all previous names
            allocator.free(name);
            for (names.items) |n| allocator.free(n);
            names.deinit(allocator);
            return mruby.mrb_nil_value();
        };
    }

    const version_cstr = mruby.mrb_str_to_cstr(mrb, version_val);
    const options_cstr = mruby.mrb_str_to_cstr(mrb, options_val);
    const action_cstr = mruby.mrb_str_to_cstr(mrb, action_val);

    const version_str = std.mem.span(version_cstr);
    const version: ?[]const u8 = if (version_str.len > 0)
        allocator.dupe(u8, version_str) catch {
            for (names.items) |n| allocator.free(n);
            names.deinit(allocator);
            return mruby.mrb_nil_value();
        }
    else
        null;

    const options_str = std.mem.span(options_cstr);
    const options: ?[]const u8 = if (options_str.len > 0)
        allocator.dupe(u8, options_str) catch {
            for (names.items) |n| allocator.free(n);
            names.deinit(allocator);
            if (version) |v| allocator.free(v);
            return mruby.mrb_nil_value();
        }
    else
        null;

    const action_str = std.mem.span(action_cstr);
    const action = common.Action.fromString(action_str) catch .install;

    // Build common properties (guards + notifications)
    var common_props = base.CommonProps.init(allocator);
    base.fillCommonFromRuby(&common_props, mrb, only_if_val, not_if_val, ignore_failure_val, notifications_val, subscriptions_val, allocator);

    // Pre-format display name for multiple packages
    const display_name = common.formatPackageList(allocator, names.items) catch {
        cleanupResources(allocator, &names, version, options, &common_props);
        return mruby.mrb_nil_value();
    };

    // Create backend based on provider
    const backend: Resource.BackendType = switch (provider_type) {
        .homebrew => blk: {
            if (!is_macos) {
                logger.err("homebrew_package provider is only available on macOS", .{});
                allocator.free(display_name);
                cleanupResources(allocator, &names, version, options, &common_props);
                return mruby.mrb_nil_value();
            }
            break :blk .{
                .homebrew = homebrew_package.Resource{
                    .names = names,
                    .display_name = display_name,
                    .version = version,
                    .options = options,
                    .action = action,
                    .common_props = common_props,
                },
            };
        },
        .apt => blk: {
            if (!is_linux) {
                logger.err("apt_package provider is only available on Linux", .{});
                allocator.free(display_name);
                cleanupResources(allocator, &names, version, options, &common_props);
                return mruby.mrb_nil_value();
            }
            break :blk .{
                .apt = apt_package.Resource{
                    .names = names,
                    .display_name = display_name,
                    .version = version,
                    .options = options,
                    .action = action,
                    .common_props = common_props,
                },
            };
        },
    };

    resources.append(allocator, .{
        .backend = backend,
    }) catch {
        // Clean up the backend resource if append fails
        const temp_resource = Resource{ .backend = backend };
        temp_resource.deinit(allocator);
        return mruby.mrb_nil_value();
    };

    return mruby.mrb_nil_value();
}

/// Auto-detect provider based on platform
fn detectProvider() common.ProviderType {
    if (is_macos) return .homebrew;
    if (is_linux) return .apt;
    @compileError("Unsupported platform for package resource");
}
