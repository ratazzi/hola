const std = @import("std");
const mruby = @import("../mruby.zig");
const base = @import("../base_resource.zig");

/// Link resource data structure
pub const Resource = struct {
    // Resource-specific properties
    path: []const u8,
    target: []const u8,
    action: Action,

    // Common properties (guards, notifications, etc.)
    common: base.CommonProps,

    pub const Action = enum {
        create,
        delete,
    };

    pub fn deinit(self: Resource, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.target);

        // Deinit common props (handles GC, notifications, etc.)
        var common = self.common;
        common.deinit(allocator);
    }

    pub fn apply(self: Resource) !base.ApplyResult {
        const skip_reason = try self.common.shouldRun();
        if (skip_reason) |reason| {
            const action_name = switch (self.action) {
                .create => "create",
                .delete => "delete",
            };
            return base.ApplyResult{
                .was_updated = false,
                .action = action_name,
                .skip_reason = reason,
            };
        }

        const action_name = switch (self.action) {
            .create => "create",
            .delete => "delete",
        };

        switch (self.action) {
            .create => {
                const was_created = try applyCreate(self);
                return base.ApplyResult{
                    .was_updated = was_created,
                    .action = action_name,
                    .skip_reason = if (was_created) null else "up to date",
                };
            },
            .delete => {
                try applyDelete(self);
                return base.ApplyResult{
                    .was_updated = false,
                    .action = action_name,
                    .skip_reason = "up to date",
                };
            },
        }
    }

    fn applyCreate(self: Resource) !bool {
        const is_abs = std.fs.path.isAbsolute(self.path);

        // Check if link already exists
        var link_buf: [std.fs.max_path_bytes]u8 = undefined;
        const link_exists = blk: {
            if (is_abs) {
                _ = std.fs.readLinkAbsolute(self.path, &link_buf) catch |err| switch (err) {
                    error.FileNotFound => break :blk false,
                    else => return err,
                };
            } else {
                _ = std.fs.cwd().readLink(self.path, &link_buf) catch |err| switch (err) {
                    error.FileNotFound => break :blk false,
                    else => return err,
                };
            }
            break :blk true;
        };

        if (link_exists) {
            // Check if link points to correct target
            var target_buf: [std.fs.max_path_bytes]u8 = undefined;
            const current_target = if (is_abs)
                try std.fs.readLinkAbsolute(self.path, &target_buf)
            else
                try std.fs.cwd().readLink(self.path, &target_buf);

            // Normalize paths for comparison
            const normalized_current = try normalizePath(std.heap.page_allocator, current_target);
            defer std.heap.page_allocator.free(normalized_current);
            const normalized_target = try normalizePath(std.heap.page_allocator, self.target);
            defer std.heap.page_allocator.free(normalized_target);

            if (std.mem.eql(u8, normalized_current, normalized_target)) {
                return false; // Link already points to correct target
            } else {
                // Delete existing link and create new one
                if (is_abs) {
                    try std.fs.deleteFileAbsolute(self.path);
                } else {
                    try std.fs.cwd().deleteFile(self.path);
                }
            }
        }

        // Create parent directory if it doesn't exist
        if (std.fs.path.dirname(self.path)) |dir| {
            try std.fs.cwd().makePath(dir);
        }

        // Create symbolic link
        if (is_abs) {
            try std.fs.symLinkAbsolute(self.target, self.path, .{});
        } else {
            try std.fs.cwd().symLink(self.target, self.path, .{});
        }

        return true; // Link was created
    }

    fn applyDelete(self: Resource) !void {
        const is_abs = std.fs.path.isAbsolute(self.path);

        // Check if link exists
        var link_buf: [std.fs.max_path_bytes]u8 = undefined;
        const link_exists = blk: {
            if (is_abs) {
                _ = std.fs.readLinkAbsolute(self.path, &link_buf) catch |err| switch (err) {
                    error.FileNotFound => break :blk false,
                    else => return err,
                };
            } else {
                _ = std.fs.cwd().readLink(self.path, &link_buf) catch |err| switch (err) {
                    error.FileNotFound => break :blk false,
                    else => return err,
                };
            }
            break :blk true;
        };

        if (!link_exists) {
            return; // Already deleted
        }

        // Delete link
        if (is_abs) {
            try std.fs.deleteFileAbsolute(self.path);
        } else {
            try std.fs.cwd().deleteFile(self.path);
        }
    }

    fn normalizePath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
        // Resolve relative paths and remove redundant components
        const resolved = if (std.fs.path.isAbsolute(path))
            try allocator.dupe(u8, path)
        else blk: {
            // For relative paths, resolve them relative to current working directory
            const cwd = try std.process.getCwdAlloc(allocator);
            defer allocator.free(cwd);
            const full_path = try std.fs.path.join(allocator, &.{ cwd, path });
            break :blk full_path;
        };

        // Remove trailing slashes
        var normalized = resolved;
        while (normalized.len > 1 and normalized[normalized.len - 1] == '/') {
            normalized = normalized[0 .. normalized.len - 1];
        }

        return normalized;
    }
};

/// Ruby prelude for link resource
pub const ruby_prelude = @embedFile("link_resource.rb");

/// Zig callback for adding link resource from Ruby
pub fn zigAddResource(
    mrb: *mruby.mrb_state,
    _: mruby.mrb_value,
    resources: *std.ArrayList(Resource),
    allocator: std.mem.Allocator,
) mruby.mrb_value {
    // Parse arguments: path, target, action, only_if_block, not_if_block, notifications
    var path_val: mruby.mrb_value = undefined;
    var target_val: mruby.mrb_value = undefined;
    var action_val: mruby.mrb_value = undefined;
    var only_if_val: mruby.mrb_value = undefined;
    var not_if_val: mruby.mrb_value = undefined;
    var ignore_failure_val: mruby.mrb_value = undefined;
    var notifications_val: mruby.mrb_value = undefined;

    // Format: S|SooooA
    // S: required string (path)
    // |: optional arguments start
    // S: optional string (target)
    // o: optional object (action)
    // o: optional object (only_if)
    // o: optional object (not_if)
    // o: optional object (ignore_failure)
    // A: optional array (notifications)
    _ = mruby.mrb_get_args(mrb, "S|SooooA", &path_val, &target_val, &action_val, &only_if_val, &not_if_val, &ignore_failure_val, &notifications_val);

    // Extract path
    const path_cstr = mruby.mrb_str_to_cstr(mrb, path_val);
    const path = allocator.dupe(u8, std.mem.span(path_cstr)) catch return mruby.mrb_nil_value();

    // Extract target (required)
    const target_cstr = mruby.mrb_str_to_cstr(mrb, target_val);
    const target = allocator.dupe(u8, std.mem.span(target_cstr)) catch return mruby.mrb_nil_value();

    // Parse action (optional, default create)
    const action: Resource.Action = if (mruby.mrb_test(action_val)) blk: {
        const action_cstr = mruby.mrb_str_to_cstr(mrb, action_val);
        const action_str = std.mem.span(action_cstr);
        if (std.mem.eql(u8, action_str, "delete")) {
            break :blk .delete;
        }
        break :blk .create;
    } else .create;

    // Build common properties (guards + notifications)
    var common = base.CommonProps.init(allocator);
    base.fillCommonFromRuby(&common, mrb, only_if_val, not_if_val, ignore_failure_val, notifications_val, allocator);

    resources.append(allocator, .{
        .path = path,
        .target = target,
        .action = action,
        .common = common,
    }) catch return mruby.mrb_nil_value();

    return mruby.mrb_nil_value();
}
