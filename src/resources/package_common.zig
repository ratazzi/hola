const std = @import("std");

/// Specification for package operations
/// Used by delegator (package.zig) to communicate with specific implementations
pub const PackageSpec = struct {
    names: []const []const u8, // Package names (supports multiple)
    version: ?[]const u8, // Optional version constraint
    options: ?[]const u8, // Additional package manager options
    action: Action, // Operation to perform
    provider: ?[]const u8, // Explicit provider ("homebrew_package" | "apt_package")

    /// Free allocated memory
    pub fn deinit(self: PackageSpec, allocator: std.mem.Allocator) void {
        for (self.names) |name| {
            allocator.free(name);
        }
        allocator.free(self.names);
        if (self.version) |v| allocator.free(v);
        if (self.options) |o| allocator.free(o);
        if (self.provider) |p| allocator.free(p);
    }
};

/// Package action types
pub const Action = enum {
    install, // Install packages
    remove, // Remove/uninstall packages
    upgrade, // Upgrade packages to latest version
    nothing, // Do nothing (useful with guards)

    /// Convert action to string for display
    pub fn toString(self: Action) []const u8 {
        return switch (self) {
            .install => "install",
            .remove => "remove",
            .upgrade => "upgrade",
            .nothing => "nothing",
        };
    }

    /// Parse action from string
    pub fn fromString(str: []const u8) !Action {
        if (std.mem.eql(u8, str, "install")) return .install;
        if (std.mem.eql(u8, str, "remove")) return .remove;
        if (std.mem.eql(u8, str, "upgrade")) return .upgrade;
        if (std.mem.eql(u8, str, "nothing")) return .nothing;
        return error.InvalidAction;
    }
};

/// Provider types
pub const ProviderType = enum {
    homebrew, // macOS Homebrew
    apt, // Debian/Ubuntu APT

    /// Convert provider to string
    pub fn toString(self: ProviderType) []const u8 {
        return switch (self) {
            .homebrew => "homebrew_package",
            .apt => "apt_package",
        };
    }

    /// Parse provider from string
    pub fn fromString(str: []const u8) !ProviderType {
        if (std.mem.eql(u8, str, "homebrew_package") or std.mem.eql(u8, str, "homebrew")) {
            return .homebrew;
        }
        if (std.mem.eql(u8, str, "apt_package") or std.mem.eql(u8, str, "apt")) {
            return .apt;
        }
        return error.InvalidProvider;
    }
};

/// Unified error types for package operations
pub const PackageError = error{
    /// Platform is not supported
    UnsupportedPlatform,
    /// Package installation failed
    InstallFailed,
    /// Package removal failed
    RemoveFailed,
    /// Package upgrade failed
    UpgradeFailed,
    /// Package not found in repository
    NotFound,
    /// Invalid provider specified
    InvalidProvider,
    /// Command execution failed
    CommandFailed,
};

/// Helper to format package list for display
pub fn formatPackageList(allocator: std.mem.Allocator, names: []const []const u8) ![]const u8 {
    if (names.len == 0) return try allocator.dupe(u8, "unknown");
    if (names.len == 1) return try allocator.dupe(u8, names[0]);
    return try std.mem.join(allocator, ", ", names);
}

/// Parsed package resource arguments from Ruby
pub const ParsedPackageArgs = struct {
    names: std.ArrayList([]const u8),
    display_name: []const u8, // Pre-formatted display name for multiple packages
    version: ?[]const u8,
    options: ?[]const u8,
    action: Action,
    common_props: @import("../base_resource.zig").CommonProps,

    /// Free all allocated memory (only call if resource creation failed)
    pub fn deinit(self: ParsedPackageArgs, allocator: std.mem.Allocator) void {
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

    /// Move fields into a resource struct (ownership transfer, do not call deinit after this)
    pub fn intoResource(self: ParsedPackageArgs, comptime ResourceType: type) ResourceType {
        return ResourceType{
            .names = self.names,
            .display_name = self.display_name,
            .version = self.version,
            .options = self.options,
            .action = self.action,
            .common_props = self.common_props,
        };
    }
};

/// Parse package resource arguments from Ruby (common logic for all package backends)
/// Returns null on error (caller should return mrb_nil_value())
pub fn parsePackageArgs(
    mrb: *@import("../mruby.zig").mrb_state,
    allocator: std.mem.Allocator,
) ?ParsedPackageArgs {
    const mruby = @import("../mruby.zig");
    const base = @import("../base_resource.zig");

    var names_val: mruby.mrb_value = undefined;
    var version_val: mruby.mrb_value = undefined;
    var options_val: mruby.mrb_value = undefined;
    var action_val: mruby.mrb_value = undefined;
    var only_if_val: mruby.mrb_value = undefined;
    var not_if_val: mruby.mrb_value = undefined;
    var ignore_failure_val: mruby.mrb_value = undefined;
    var notifications_val: mruby.mrb_value = undefined;
    var subscriptions_val: mruby.mrb_value = undefined;

    // Get array + 3 strings + 5 optional (blocks + arrays)
    _ = mruby.mrb_get_args(mrb, "ASSS|oooAA", &names_val, &version_val, &options_val, &action_val, &only_if_val, &not_if_val, &ignore_failure_val, &notifications_val, &subscriptions_val);

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
            return null;
        };
        names.append(allocator, name) catch {
            // Clean up current name and all previous names
            allocator.free(name);
            for (names.items) |n| allocator.free(n);
            names.deinit(allocator);
            return null;
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
            return null;
        }
    else
        null;

    const options_str = std.mem.span(options_cstr);
    const options: ?[]const u8 = if (options_str.len > 0)
        allocator.dupe(u8, options_str) catch {
            for (names.items) |n| allocator.free(n);
            names.deinit(allocator);
            if (version) |v| allocator.free(v);
            return null;
        }
    else
        null;

    const action_str = std.mem.span(action_cstr);
    const action = Action.fromString(action_str) catch .install;

    // Build common properties (guards + notifications)
    var common_props = base.CommonProps.init(allocator);
    base.fillCommonFromRuby(&common_props, mrb, only_if_val, not_if_val, ignore_failure_val, notifications_val, subscriptions_val, allocator);

    // Pre-format display name for multiple packages
    const display_name = formatPackageList(allocator, names.items) catch {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
        if (version) |v| allocator.free(v);
        if (options) |o| allocator.free(o);
        common_props.deinit(allocator);
        return null;
    };

    return ParsedPackageArgs{
        .names = names,
        .display_name = display_name,
        .version = version,
        .options = options,
        .action = action,
        .common_props = common_props,
    };
}
