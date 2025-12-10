const std = @import("std");
const mruby = @import("../mruby.zig");
const base = @import("../base_resource.zig");
const http = @import("../http.zig");
const logger = @import("../logger.zig");
const json_helpers = @import("../json.zig");
const xdg_mod = @import("../xdg.zig");
const AsyncExecutor = @import("../async_executor.zig").AsyncExecutor;

/// Download outcome for downloadDirect
const DownloadOutcome = struct {
    downloaded: bool,
    etag: ?[]const u8 = null,
    last_modified: ?[]const u8 = null,
};

/// Remote file resource data structure
pub const Resource = struct {
    // Resource-specific properties
    path: []const u8, // Local file path where to save the file
    source: []const u8, // URL to download from
    attrs: base.FileAttributes, // File attributes (mode, owner, group)
    checksum: ?[]const u8 = null, // Expected checksum (SHA256, MD5, etc.)
    backup: ?[]const u8 = null, // Backup extension before overwriting
    headers: ?[]const u8 = null, // JSON-encoded HTTP headers
    use_etag: bool = true, // Whether to use ETag for conditional downloads (Chef default: true)
    use_last_modified: bool = true, // Whether to use Last-Modified for conditional downloads (Chef default: true)
    force_unlink: bool = false, // Delete destination before placing downloaded file

    // Authentication (Chef-compatible parameters)
    remote_user: ?[]const u8 = null, // Username for SFTP authentication
    remote_password: ?[]const u8 = null, // Password for SFTP authentication
    remote_domain: ?[]const u8 = null, // Domain for Windows authentication (reserved, not used)

    // Hola-specific: SSH key authentication for SFTP
    ssh_private_key: ?[]const u8 = null, // Path to SSH private key
    ssh_public_key: ?[]const u8 = null, // Path to SSH public key
    ssh_known_hosts: ?[]const u8 = null, // Path to SSH known_hosts file

    // Hola-specific: AWS S3 authentication
    aws_access_key_id: ?[]const u8 = null, // AWS Access Key ID
    aws_secret_access_key: ?[]const u8 = null, // AWS Secret Access Key
    aws_region: ?[]const u8 = null, // AWS region (default: "auto")
    aws_endpoint: ?[]const u8 = null, // AWS S3 endpoint URL (required for s3:// URLs)

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
        if (self.headers) |headers| allocator.free(headers);

        // Authentication fields
        if (self.remote_user) |user| allocator.free(user);
        if (self.remote_password) |pass| allocator.free(pass);
        if (self.remote_domain) |domain| allocator.free(domain);

        // SSH fields
        if (self.ssh_private_key) |key| allocator.free(key);
        if (self.ssh_public_key) |key| allocator.free(key);
        if (self.ssh_known_hosts) |hosts| allocator.free(hosts);

        // AWS fields
        if (self.aws_access_key_id) |key| allocator.free(key);
        if (self.aws_secret_access_key) |key| allocator.free(key);
        if (self.aws_region) |region| allocator.free(region);
        if (self.aws_endpoint) |endpoint| allocator.free(endpoint);

        // Deinit common props
        var common = self.common;
        common.deinit(allocator);
    }

    pub fn apply(self: Resource) !base.ApplyResult {
        const skip_reason = try self.common.shouldRun(self.attrs.owner, self.attrs.group);
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

        const local_exists = blk: {
            std.fs.cwd().access(self.path, .{}) catch |err| switch (err) {
                error.FileNotFound => break :blk false,
                else => return err,
            };
            break :blk true;
        };

        var previous_etag: ?[]const u8 = null;
        if (self.use_etag and local_exists) {
            previous_etag = self.loadSavedEtag(allocator) catch null;
        }
        defer if (previous_etag) |etag| allocator.free(etag);

        var previous_last_modified: ?[]const u8 = null;
        if (self.use_last_modified and local_exists) {
            previous_last_modified = self.loadSavedLastModified(allocator) catch null;
        }
        defer if (previous_last_modified) |lm| allocator.free(lm);

        // Always attempt download/conditional fetch; conditional headers only when local file exists
        var downloaded_etag: ?[]const u8 = null;
        defer if (downloaded_etag) |etag| allocator.free(etag);

        var downloaded_last_modified: ?[]const u8 = null;
        defer if (downloaded_last_modified) |lm| allocator.free(lm);

        // Try to find pre-downloaded file first
        const predownloaded_path = if (self.use_etag)
            null
        else
            findPreDownloadedFile(self.path, allocator) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return err,
            };

        if (predownloaded_path) |temp_path| {
            // Use pre-downloaded file
            // Create backup if specified
            if (self.backup) |backup_ext| {
                try base.createBackup(allocator, self.path, backup_ext);
            }

            if (self.force_unlink) {
                self.deleteTargetIfExists() catch {};
            }

            // Move from temp to final location
            try std.fs.cwd().rename(temp_path, self.path);

            // Apply file attributes (mode, owner, group)
            base.applyFileAttributes(self.path, self.attrs) catch |err| {
                logger.warn("Failed to apply file attributes for {s}: {}", .{ self.path, err });
            };

            // Clean up the temp path string
            allocator.free(temp_path);
        } else {
            // File not pre-downloaded (likely has conditions)
            // Download directly (conditional downloads are not batched)
            // Use AsyncExecutor to avoid blocking the main thread
            const DownloadContext = struct {
                resource: Resource,
                allocator: std.mem.Allocator,
                previous_etag: ?[]const u8,
                previous_last_modified: ?[]const u8,
            };
            const download_ctx = DownloadContext{
                .resource = self,
                .allocator = allocator,
                .previous_etag = previous_etag,
                .previous_last_modified = previous_last_modified,
            };
            const downloadAsync = struct {
                fn run(ctx: DownloadContext) !DownloadOutcome {
                    const outcome = try ctx.resource.downloadDirect(ctx.allocator, ctx.previous_etag, ctx.previous_last_modified);
                    return outcome;
                }
            }.run;

            var outcome = try AsyncExecutor.executeWithContext(DownloadContext, DownloadOutcome, download_ctx, downloadAsync);

            // If server reported not modified but we have no local file, fall back to unconditional download
            if (!outcome.downloaded and !local_exists) {
                logger.debug("Server returned not_modified but local file doesn't exist, retrying without conditions", .{});
                const retry_ctx = DownloadContext{
                    .resource = self,
                    .allocator = allocator,
                    .previous_etag = null,
                    .previous_last_modified = null,
                };
                const retry = try AsyncExecutor.executeWithContext(DownloadContext, DownloadOutcome, retry_ctx, downloadAsync);
                if (!retry.downloaded) {
                    return error.HttpError;
                }
                outcome = retry;
            }

            if (!outcome.downloaded) {
                return false;
            }
            downloaded_etag = outcome.etag;
            downloaded_last_modified = outcome.last_modified;

            // Apply file attributes (mode, owner, group)
            base.applyFileAttributes(self.path, self.attrs) catch |err| {
                logger.warn("Failed to apply file attributes for {s}: {}", .{ self.path, err });
            };

            // Verify checksum if provided
            if (self.checksum) |expected_checksum| {
                const actual_checksum = try http.calculateSha256(allocator, self.path);
                defer allocator.free(actual_checksum);
                if (!std.mem.eql(u8, actual_checksum, expected_checksum)) {
                    return error.ChecksumMismatch;
                }
            }

            if (self.use_etag) {
                if (downloaded_etag) |etag| {
                    try self.saveEtag(allocator, etag);
                }
            }

            if (self.use_last_modified) {
                if (downloaded_last_modified) |lm| {
                    try self.saveLastModified(allocator, lm);
                }
            }
        }
        return true; // File was downloaded/updated
    }

    /// Find a pre-downloaded file by matching the slugified final path
    fn findPreDownloadedFile(final_path: []const u8, allocator: std.mem.Allocator) !?[]const u8 {
        // Get the download temp directory
        const xdg_instance = xdg_mod.XDG.init(allocator);
        const temp_dir = try xdg_instance.getDownloadsDir();
        defer allocator.free(temp_dir);

        // Slugify the final path to match the naming scheme in provision.zig
        const path_slug = try http.slugifyPath(allocator, final_path);
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

    fn downloadDirect(self: Resource, allocator: std.mem.Allocator, previous_etag: ?[]const u8, previous_last_modified: ?[]const u8) !DownloadOutcome {
        const temp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{self.path});
        defer allocator.free(temp_path);

        // Parse headers from JSON if provided
        var headers_map: ?std.StringHashMap([]const u8) = null;
        if (self.headers) |headers_json| {
            headers_map = try http.parseHeadersFromJson(allocator, headers_json);
        }
        defer if (headers_map) |*hm| {
            var it = hm.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            hm.deinit();
        };

        // Build authentication config from resource parameters
        var auth_config: ?http.types.AuthConfig = null;
        if (self.remote_user != null or self.ssh_private_key != null or self.aws_access_key_id != null) {
            auth_config = http.types.AuthConfig{
                .username = self.remote_user,
                .password = self.remote_password,
                .ssh_private_key = self.ssh_private_key,
                .ssh_public_key = self.ssh_public_key,
                .ssh_known_hosts = self.ssh_known_hosts,
                .aws_access_key_id = self.aws_access_key_id,
                .aws_secret_access_key = self.aws_secret_access_key,
                .aws_region = self.aws_region orelse "auto",
                .aws_endpoint = self.aws_endpoint,
            };
        }

        const download_result = try http.downloadFile(allocator, self.source, temp_path, .{
            .headers = headers_map,
            .if_none_match = if (self.use_etag) previous_etag else null,
            .if_modified_since = if (self.use_last_modified) previous_last_modified else null,
            .auth = auth_config,
        });
        defer {
            var mut_result = download_result;
            mut_result.deinit(allocator);
        }

        if (download_result.status == .not_modified) {
            // Cleanup temp path if created (ignore missing)
            std.fs.cwd().deleteFile(temp_path) catch {};
            return DownloadOutcome{ .downloaded = false, .etag = null };
        }

        // Verify checksum before touching destination
        if (self.checksum) |expected_checksum| {
            const actual_checksum = try http.calculateSha256(allocator, temp_path);
            defer allocator.free(actual_checksum);
            if (!std.mem.eql(u8, actual_checksum, expected_checksum)) {
                std.fs.cwd().deleteFile(temp_path) catch {};
                return error.ChecksumMismatch;
            }
        }

        // Create backup if specified
        if (self.backup) |backup_ext| {
            try base.createBackup(allocator, self.path, backup_ext);
        }

        // Move to final location
        if (self.force_unlink) {
            self.deleteTargetIfExists() catch {};
        }
        try std.fs.cwd().rename(temp_path, self.path);

        const etag_copy: ?[]const u8 = if (download_result.etag) |etag| try allocator.dupe(u8, etag) else null;
        const lm_copy: ?[]const u8 = if (download_result.last_modified) |lm| try allocator.dupe(u8, lm) else null;
        return DownloadOutcome{ .downloaded = true, .etag = etag_copy, .last_modified = lm_copy };
    }

    fn getEtagPath(self: Resource, allocator: std.mem.Allocator) ![]const u8 {
        const xdg = @import("../xdg.zig").XDG.init(allocator);
        const state_home = try xdg.getStateHome();
        defer allocator.free(state_home);

        const slug = try http.slugifyPath(allocator, self.path);
        defer allocator.free(slug);

        return std.fs.path.join(allocator, &.{ state_home, "etag", "remote_file", slug });
    }

    fn loadSavedEtag(self: Resource, allocator: std.mem.Allocator) !?[]const u8 {
        const etag_path = try self.getEtagPath(allocator);
        defer allocator.free(etag_path);

        const file = std.fs.cwd().openFile(etag_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close();

        const stat = try file.stat();
        const buf = try allocator.alloc(u8, stat.size);
        const read_len = try file.readAll(buf);
        return buf[0..read_len];
    }

    fn saveEtag(self: Resource, allocator: std.mem.Allocator, etag: []const u8) !void {
        if (etag.len == 0) return;

        const etag_path = try self.getEtagPath(allocator);
        defer allocator.free(etag_path);

        if (std.fs.path.dirname(etag_path)) |dir| {
            try std.fs.cwd().makePath(dir);
        }

        const file = try std.fs.cwd().createFile(etag_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(etag);
    }

    fn getLastModifiedPath(self: Resource, allocator: std.mem.Allocator) ![]const u8 {
        const xdg = @import("../xdg.zig").XDG.init(allocator);
        const state_home = try xdg.getStateHome();
        defer allocator.free(state_home);

        const slug = try http.slugifyPath(allocator, self.path);
        defer allocator.free(slug);

        return std.fs.path.join(allocator, &.{ state_home, "last_modified", "remote_file", slug });
    }

    fn loadSavedLastModified(self: Resource, allocator: std.mem.Allocator) !?[]const u8 {
        const lm_path = try self.getLastModifiedPath(allocator);
        defer allocator.free(lm_path);

        const file = std.fs.cwd().openFile(lm_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close();

        const stat = try file.stat();
        const buf = try allocator.alloc(u8, stat.size);
        const read_len = try file.readAll(buf);
        return buf[0..read_len];
    }

    fn saveLastModified(self: Resource, allocator: std.mem.Allocator, last_modified: []const u8) !void {
        if (last_modified.len == 0) return;

        const lm_path = try self.getLastModifiedPath(allocator);
        defer allocator.free(lm_path);

        if (std.fs.path.dirname(lm_path)) |dir| {
            try std.fs.cwd().makePath(dir);
        }

        const file = try std.fs.cwd().createFile(lm_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(last_modified);
    }

    fn deleteTargetIfExists(self: Resource) !void {
        const is_abs = std.fs.path.isAbsolute(self.path);
        const result = if (is_abs)
            std.fs.deleteFileAbsolute(self.path)
        else
            std.fs.cwd().deleteFile(self.path);

        result catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
};

/// Ruby prelude for remote_file resource
pub const ruby_prelude = @embedFile("remote_file_resource.rb");

// C helper for checking nil values
extern fn zig_mrb_nil_p(val: mruby.mrb_value) c_int;

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
    var headers_val: mruby.mrb_value = undefined;
    var action_val: mruby.mrb_value = undefined;
    var use_etag_val: mruby.mrb_bool = undefined;
    var use_last_modified_val: mruby.mrb_bool = undefined;
    var only_if_val: mruby.mrb_value = undefined;
    var not_if_val: mruby.mrb_value = undefined;
    var ignore_failure_val: mruby.mrb_value = undefined;
    var notifications_val: mruby.mrb_value = undefined;
    var subscriptions_val: mruby.mrb_value = undefined;
    var force_unlink_val: mruby.mrb_bool = undefined;

    // Authentication parameters
    var remote_user_val: mruby.mrb_value = undefined;
    var remote_password_val: mruby.mrb_value = undefined;
    var remote_domain_val: mruby.mrb_value = undefined;
    var ssh_private_key_val: mruby.mrb_value = undefined;
    var ssh_public_key_val: mruby.mrb_value = undefined;
    var ssh_known_hosts_val: mruby.mrb_value = undefined;
    var aws_access_key_id_val: mruby.mrb_value = undefined;
    var aws_secret_access_key_val: mruby.mrb_value = undefined;
    var aws_region_val: mruby.mrb_value = undefined;
    var aws_endpoint_val: mruby.mrb_value = undefined;

    // Get 7 strings + 1 object (hash) + 3 bools + 1 string + 3 optional (2 blocks + 1 bool + 2 arrays) + 10 auth objects (can be nil)
    _ = mruby.mrb_get_args(mrb, "SSSSSSSobbbS|oooAAoooooooooo", &path_val, &source_val, &mode_val, &owner_val, &group_val, &checksum_val, &backup_val, &headers_val, &use_etag_val, &use_last_modified_val, &force_unlink_val, &action_val, &only_if_val, &not_if_val, &ignore_failure_val, &notifications_val, &subscriptions_val, &remote_user_val, &remote_password_val, &remote_domain_val, &ssh_private_key_val, &ssh_public_key_val, &ssh_known_hosts_val, &aws_access_key_id_val, &aws_secret_access_key_val, &aws_region_val, &aws_endpoint_val);

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

    const use_etag = use_etag_val != 0;
    const use_last_modified = use_last_modified_val != 0;
    const force_unlink = force_unlink_val != 0;

    // Parse authentication parameters
    const remote_user = if (zig_mrb_nil_p(remote_user_val) != 0) null else blk: {
        const str = std.mem.span(mruby.mrb_str_to_cstr(mrb, remote_user_val));
        break :blk if (str.len > 0) allocator.dupe(u8, str) catch return mruby.mrb_nil_value() else null;
    };

    const remote_password = if (zig_mrb_nil_p(remote_password_val) != 0) null else blk: {
        const str = std.mem.span(mruby.mrb_str_to_cstr(mrb, remote_password_val));
        break :blk if (str.len > 0) allocator.dupe(u8, str) catch return mruby.mrb_nil_value() else null;
    };

    const remote_domain = if (zig_mrb_nil_p(remote_domain_val) != 0) null else blk: {
        const str = std.mem.span(mruby.mrb_str_to_cstr(mrb, remote_domain_val));
        break :blk if (str.len > 0) allocator.dupe(u8, str) catch return mruby.mrb_nil_value() else null;
    };

    const ssh_private_key = if (zig_mrb_nil_p(ssh_private_key_val) != 0) null else blk: {
        const str = std.mem.span(mruby.mrb_str_to_cstr(mrb, ssh_private_key_val));
        break :blk if (str.len > 0) allocator.dupe(u8, str) catch return mruby.mrb_nil_value() else null;
    };

    const ssh_public_key = if (zig_mrb_nil_p(ssh_public_key_val) != 0) null else blk: {
        const str = std.mem.span(mruby.mrb_str_to_cstr(mrb, ssh_public_key_val));
        break :blk if (str.len > 0) allocator.dupe(u8, str) catch return mruby.mrb_nil_value() else null;
    };

    const ssh_known_hosts = if (zig_mrb_nil_p(ssh_known_hosts_val) != 0) null else blk: {
        const str = std.mem.span(mruby.mrb_str_to_cstr(mrb, ssh_known_hosts_val));
        break :blk if (str.len > 0) allocator.dupe(u8, str) catch return mruby.mrb_nil_value() else null;
    };

    const aws_access_key_id = if (zig_mrb_nil_p(aws_access_key_id_val) != 0) null else blk: {
        const str = std.mem.span(mruby.mrb_str_to_cstr(mrb, aws_access_key_id_val));
        break :blk if (str.len > 0) allocator.dupe(u8, str) catch return mruby.mrb_nil_value() else null;
    };

    const aws_secret_access_key = if (zig_mrb_nil_p(aws_secret_access_key_val) != 0) null else blk: {
        const str = std.mem.span(mruby.mrb_str_to_cstr(mrb, aws_secret_access_key_val));
        break :blk if (str.len > 0) allocator.dupe(u8, str) catch return mruby.mrb_nil_value() else null;
    };

    const aws_region = if (zig_mrb_nil_p(aws_region_val) != 0) null else blk: {
        const str = std.mem.span(mruby.mrb_str_to_cstr(mrb, aws_region_val));
        break :blk if (str.len > 0) allocator.dupe(u8, str) catch return mruby.mrb_nil_value() else null;
    };

    const aws_endpoint = if (zig_mrb_nil_p(aws_endpoint_val) != 0) null else blk: {
        const str = std.mem.span(mruby.mrb_str_to_cstr(mrb, aws_endpoint_val));
        break :blk if (str.len > 0) allocator.dupe(u8, str) catch return mruby.mrb_nil_value() else null;
    };

    // Convert Ruby Hash to JSON string for headers
    const headers: ?[]const u8 = if (zig_mrb_nil_p(headers_val) != 0)
        null
    else blk: {
        // Convert mruby Hash to std.json.Value
        var json_value = json_helpers.mrubyValueToJsonValue(mrb, allocator, headers_val) catch return mruby.mrb_nil_value();
        defer json_helpers.freeJsonValue(allocator, &json_value);

        // Format as JSON string
        const json_str = std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(json_value, .{})}) catch return mruby.mrb_nil_value();
        break :blk json_str;
    };

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
    base.fillCommonFromRuby(&common, mrb, only_if_val, not_if_val, ignore_failure_val, notifications_val, subscriptions_val, allocator);

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
        .headers = headers,
        .use_etag = use_etag,
        .use_last_modified = use_last_modified,
        .force_unlink = force_unlink,
        .remote_user = remote_user,
        .remote_password = remote_password,
        .remote_domain = remote_domain,
        .ssh_private_key = ssh_private_key,
        .ssh_public_key = ssh_public_key,
        .ssh_known_hosts = ssh_known_hosts,
        .aws_access_key_id = aws_access_key_id,
        .aws_secret_access_key = aws_secret_access_key,
        .aws_region = aws_region,
        .aws_endpoint = aws_endpoint,
        .action = action,
        .common = common,
    }) catch return mruby.mrb_nil_value();

    return mruby.mrb_nil_value();
}
