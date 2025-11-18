const std = @import("std");
const mruby = @import("../mruby.zig");
const base = @import("../base_resource.zig");
const http_utils = @import("../http_utils.zig");
const download_manager = @import("../download_manager.zig");

/// Remote file resource data structure
pub const Resource = struct {
    // Resource-specific properties
    path: []const u8, // Local file path where to save the file
    source: []const u8, // URL to download from
    attrs: base.FileAttributes, // File attributes (mode, owner, group)
    checksum: ?[]const u8 = null, // Expected checksum (SHA256, MD5, etc.)
    backup: ?[]const u8 = null, // Backup extension before overwriting
    action: Action,

    // Common properties (guards, notifications, etc.)
    common: base.CommonProps,

    pub const Action = enum {
        create, // Download and create the file
        create_if_missing, // Only create if file doesn't exist
        delete, // Delete the local file
        touch, // Create empty file or update timestamp
    };

    pub fn deinit(self: Resource, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.source);
        self.attrs.deinit(allocator);
        if (self.checksum) |checksum| allocator.free(checksum);
        if (self.backup) |backup| allocator.free(backup);

        // Deinit common props
        var common = self.common;
        common.deinit(allocator);
    }

    pub fn apply(self: Resource) !base.ApplyResult {
        const skip_reason = try self.common.shouldRun();
        if (skip_reason) |reason| {
            const action_name = switch (self.action) {
                .create => "create",
                .create_if_missing => "create_if_missing",
                .delete => "delete",
                .touch => "touch",
            };
            return base.ApplyResult{
                .was_updated = false,
                .action = action_name,
                .skip_reason = reason,
            };
        }

        const action_name = switch (self.action) {
            .create => "create",
            .create_if_missing => "create_if_missing",
            .delete => "delete",
            .touch => "touch",
        };

        switch (self.action) {
            .create => {
                const was_updated = try applyCreate(self);
                return base.ApplyResult{
                    .was_updated = was_updated,
                    .action = action_name,
                    .skip_reason = if (was_updated) null else "up to date",
                };
            },
            .create_if_missing => {
                const was_created = try applyCreateIfMissing(self);
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
            .touch => {
                try applyTouch(self);
                return base.ApplyResult{
                    .was_updated = false,
                    .action = action_name,
                    .skip_reason = "up to date",
                };
            },
        }
    }

    fn applyCreate(self: Resource) !bool {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        if (std.fs.path.dirname(self.path)) |dir| {
            try std.fs.cwd().makePath(dir);
        }

        // Check if file exists and compare with remote
        const needs_download = try self.needsDownload();

        if (needs_download) {
            // Try to find pre-downloaded file first
            const predownloaded_path = findPreDownloadedFile(self.path, allocator) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return err,
            };

            if (predownloaded_path) |temp_path| {
                // Use pre-downloaded file
                // Create backup if specified
                if (self.backup) |backup_ext| {
                    try base.createBackup(allocator, self.path, backup_ext);
                }

                // Move from temp to final location
                try std.fs.cwd().rename(temp_path, self.path);

                // Apply file attributes (mode, owner, group)
                base.applyFileAttributes(self.path, self.attrs) catch |err| {
                    std.log.warn("Failed to apply file attributes for {s}: {}", .{ self.path, err });
                };

                // Clean up the temp path string
                allocator.free(temp_path);
            } else {
                // File not pre-downloaded (likely has conditions)
                // Try to use DownloadManager if available
                if (download_manager.DownloadManager.getCurrent()) |dl_mgr| {
                    // Submit to download manager and wait for completion
                    try downloadViaManager(self, dl_mgr, allocator);
                } else {
                    // Fallback to direct download (no manager available)
                    // Create backup if specified
                    if (self.backup) |backup_ext| {
                        try base.createBackup(allocator, self.path, backup_ext);
                    }

                    // Download the file
                    try downloadFile(self.source, self.path);

                    // Apply file attributes (mode, owner, group)
                    base.applyFileAttributes(self.path, self.attrs) catch |err| {
                        std.log.warn("Failed to apply file attributes for {s}: {}", .{ self.path, err });
                    };

                    // Verify checksum if provided
                    if (self.checksum) |expected_checksum| {
                        const actual_checksum = try http_utils.calculateSha256(allocator, self.path);
                        defer allocator.free(actual_checksum);
                        if (!std.mem.eql(u8, actual_checksum, expected_checksum)) {
                            return error.ChecksumMismatch;
                        }
                    }
                }
            }
            return true; // File was downloaded/updated
        }
        return false; // File was up to date
    }

    /// Find a pre-downloaded file by matching the slugified final path
    fn findPreDownloadedFile(final_path: []const u8, allocator: std.mem.Allocator) !?[]const u8 {
        // Get the download temp directory
        const temp_dir = try download_manager.DownloadManager.getDownloadTempDir(allocator);
        defer allocator.free(temp_dir);

        // Slugify the final path to match the naming scheme in provision.zig
        const path_slug = try http_utils.slugifyPath(allocator, final_path);
        defer allocator.free(path_slug);

        // Expected filename is just the slugified path (no prefix needed)
        const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ temp_dir, path_slug });

        // Check if file exists
        std.fs.cwd().access(file_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                allocator.free(file_path);
                return error.FileNotFound;
            },
            else => {
                allocator.free(file_path);
                return err;
            },
        };

        return file_path;
    }

    fn applyCreateIfMissing(self: Resource) !bool {
        // Check if file exists
        const file = std.fs.cwd().openFile(self.path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                const was_updated = try applyCreate(self);
                return was_updated;
            },
            else => return err,
        };
        defer file.close();
        // File exists, do nothing
        return false; // File was up to date
    }

    fn applyDelete(self: Resource) !void {
        const is_abs = std.fs.path.isAbsolute(self.path);
        if (is_abs) {
            std.fs.deleteFileAbsolute(self.path) catch |err| switch (err) {
                error.FileNotFound => return, // Already deleted, that's fine
                else => return err,
            };
        } else {
            std.fs.cwd().deleteFile(self.path) catch |err| switch (err) {
                error.FileNotFound => return, // Already deleted, that's fine
                else => return err,
            };
        }
    }

    fn applyTouch(self: Resource) !void {
        if (std.fs.path.dirname(self.path)) |dir| {
            try std.fs.cwd().makePath(dir);
        }

        const is_abs = std.fs.path.isAbsolute(self.path);
        const file = if (is_abs)
            try std.fs.createFileAbsolute(self.path, .{ .truncate = false })
        else
            try std.fs.cwd().createFile(self.path, .{ .truncate = false });
        defer file.close();

        // Update modification time to current time
        const current_time = std.time.timestamp();
        try file.updateTimes(current_time, current_time);
    }

    fn needsDownload(self: Resource) !bool {
        // Check if local file exists
        const local_file = std.fs.cwd().openFile(self.path, .{}) catch |err| switch (err) {
            error.FileNotFound => return true, // File doesn't exist, need to download
            else => return err,
        };
        defer local_file.close();

        // TODO: Add more sophisticated comparison (size, modification time, etag)
        // For now, always download if file exists
        return true;
    }

    fn downloadViaManager(self: Resource, dl_mgr: *download_manager.DownloadManager, allocator: std.mem.Allocator) !void {
        // Generate slugified path for temp file
        const path_slug = try http_utils.slugifyPath(allocator, self.path);
        defer allocator.free(path_slug);

        // Generate temporary file path
        const temp_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dl_mgr.temp_dir, path_slug });

        // Download directly to temp path (manager controls concurrency via its semaphore/queue)
        // For simplicity, we'll just download directly here
        // The DownloadManager's worker pool is for pre-downloads only
        // On-demand downloads go through the direct path but could use a semaphore for concurrency control

        // Create backup if specified
        if (self.backup) |backup_ext| {
            try base.createBackup(allocator, self.path, backup_ext);
        }

        // Download to temp path
        try http_utils.downloadFile(allocator, self.source, temp_path);
        defer allocator.free(temp_path);

        // Verify checksum if provided
        if (self.checksum) |expected_checksum| {
            const actual_checksum = try http_utils.calculateSha256(allocator, temp_path);
            defer allocator.free(actual_checksum);
            if (!std.mem.eql(u8, actual_checksum, expected_checksum)) {
                return error.ChecksumMismatch;
            }
        }

        // Create parent directory if needed
        if (std.fs.path.dirname(self.path)) |dir| {
            try std.fs.cwd().makePath(dir);
        }

        // Move to final location
        try std.fs.cwd().rename(temp_path, self.path);

        // Apply file attributes (mode, owner, group)
        base.applyFileAttributes(self.path, self.attrs) catch |err| {
            std.log.warn("Failed to apply file attributes for {s}: {}", .{ self.path, err });
        };
    }

    fn downloadFile(url: []const u8, dest_path: []const u8) !void {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        try http_utils.downloadFile(allocator, url, dest_path);
    }
};

/// Ruby prelude for remote_file resource
pub const ruby_prelude = @embedFile("remote_file_resource.rb");

/// Zig callback: called from Ruby to add a remote_file resource
pub fn zigAddResource(
    mrb: *mruby.mrb_state,
    self: mruby.mrb_value,
    resources: *std.ArrayList(Resource),
    allocator: std.mem.Allocator,
) mruby.mrb_value {
    _ = self;

    var path_val: mruby.mrb_value = undefined;
    var source_val: mruby.mrb_value = undefined;
    var mode_val: mruby.mrb_value = undefined;
    var owner_val: mruby.mrb_value = undefined;
    var group_val: mruby.mrb_value = undefined;
    var checksum_val: mruby.mrb_value = undefined;
    var backup_val: mruby.mrb_value = undefined;
    var action_val: mruby.mrb_value = undefined;
    var only_if_val: mruby.mrb_value = undefined;
    var not_if_val: mruby.mrb_value = undefined;
    var notifications_val: mruby.mrb_value = undefined;

    // Get 7 strings + 4 optional (blocks + array)
    _ = mruby.mrb_get_args(mrb, "SSSSSSSS|ooA", &path_val, &source_val, &mode_val, &owner_val, &group_val, &checksum_val, &backup_val, &action_val, &only_if_val, &not_if_val, &notifications_val);

    const path_cstr = mruby.mrb_str_to_cstr(mrb, path_val);
    const source_cstr = mruby.mrb_str_to_cstr(mrb, source_val);
    const mode_cstr = mruby.mrb_str_to_cstr(mrb, mode_val);
    const owner_cstr = mruby.mrb_str_to_cstr(mrb, owner_val);
    const group_cstr = mruby.mrb_str_to_cstr(mrb, group_val);
    const checksum_cstr = mruby.mrb_str_to_cstr(mrb, checksum_val);
    const backup_cstr = mruby.mrb_str_to_cstr(mrb, backup_val);
    const action_cstr = mruby.mrb_str_to_cstr(mrb, action_val);

    const path = allocator.dupe(u8, std.mem.span(path_cstr)) catch return mruby.mrb_nil_value();
    const source = allocator.dupe(u8, std.mem.span(source_cstr)) catch return mruby.mrb_nil_value();

    // Parse mode as u32 (octal)
    const mode_str = std.mem.span(mode_cstr);
    const mode: ?u32 = if (mode_str.len > 0)
        std.fmt.parseInt(u32, mode_str, 8) catch null
    else
        null;

    // Parse owner and group
    const owner_str = std.mem.span(owner_cstr);
    const owner: ?[]const u8 = if (owner_str.len > 0)
        allocator.dupe(u8, owner_str) catch return mruby.mrb_nil_value()
    else
        null;

    const group_str = std.mem.span(group_cstr);
    const group: ?[]const u8 = if (group_str.len > 0)
        allocator.dupe(u8, group_str) catch return mruby.mrb_nil_value()
    else
        null;

    const checksum_str = std.mem.span(checksum_cstr);
    const checksum: ?[]const u8 = if (checksum_str.len > 0)
        allocator.dupe(u8, checksum_str) catch return mruby.mrb_nil_value()
    else
        null;

    const backup_str = std.mem.span(backup_cstr);
    const backup: ?[]const u8 = if (backup_str.len > 0)
        allocator.dupe(u8, backup_str) catch return mruby.mrb_nil_value()
    else
        null;

    const action_str = std.mem.span(action_cstr);
    const action: Resource.Action = if (std.mem.eql(u8, action_str, "create_if_missing"))
        .create_if_missing
    else if (std.mem.eql(u8, action_str, "delete"))
        .delete
    else if (std.mem.eql(u8, action_str, "touch"))
        .touch
    else
        .create;

    // Build common properties (guards + notifications)
    var common = base.CommonProps.init(allocator);
    base.fillCommonFromRuby(&common, mrb, only_if_val, not_if_val, notifications_val, allocator);

    resources.append(allocator, .{
        .path = path,
        .source = source,
        .attrs = .{
            .mode = mode,
            .owner = owner,
            .group = group,
        },
        .checksum = checksum,
        .backup = backup,
        .action = action,
        .common = common,
    }) catch return mruby.mrb_nil_value();

    return mruby.mrb_nil_value();
}
