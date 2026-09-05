const std = @import("std");
const mruby = @import("../mruby.zig");
const base = @import("../base_resource.zig");
const http = @import("../http.zig");
const logger = @import("../logger.zig");
const json_helpers = @import("../json.zig");
const AsyncExecutor = @import("../async_executor.zig").AsyncExecutor;
const global_io = @import("../global_io.zig");

/// Download outcome for downloadDirect
const DownloadOutcome = struct {
    downloaded: bool,
    etag: ?[]const u8 = null,
    last_modified: ?[]const u8 = null,
};

const RemoteFileErrorDetail = struct {
    buffer: [1024]u8 = undefined,
    len: usize = 0,

    fn clear(self: *RemoteFileErrorDetail) void {
        self.len = 0;
    }

    fn set(self: *RemoteFileErrorDetail, detail: []const u8) void {
        const n = @min(detail.len, self.buffer.len);
        @memcpy(self.buffer[0..n], detail[0..n]);
        self.len = n;
    }

    fn get(self: *const RemoteFileErrorDetail) ?[]const u8 {
        if (self.len == 0) return null;
        return self.buffer[0..self.len];
    }
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
        const io = global_io.io();
        var gpa: std.heap.DebugAllocator(.{}) = .{};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        try base.ensureParentDir(self.path);

        const local_exists = blk: {
            std.Io.Dir.cwd().access(io, self.path, .{}) catch |err| switch (err) {
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
            self.findPreDownloadedFile(allocator) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return err,
            };

        if (predownloaded_path) |temp_path| {
            defer allocator.free(temp_path);
            // A cache entry is not proof that the requested content is valid.
            if (self.checksum) |expected_checksum| {
                try http.download.downloader.verifyChecksum(allocator, temp_path, expected_checksum);
            }
            // Use pre-downloaded file
            // Create backup if specified
            if (self.backup) |backup_ext| {
                try base.createBackup(allocator, self.path, backup_ext);
            }

            if (self.force_unlink) {
                self.deleteTargetIfExists() catch {};
            }

            // Move from temp to final location
            try std.Io.Dir.cwd().rename(temp_path, std.Io.Dir.cwd(), self.path, io);

            // Apply file attributes (mode, owner, group)
            base.applyFileAttributes(self.path, self.attrs) catch |err| {
                logger.warn("Failed to apply file attributes for {s}: {}", .{ self.path, err });
            };
        } else {
            // File not pre-downloaded (likely has conditions)
            // Download directly (conditional downloads are not batched)
            // Use AsyncExecutor to avoid blocking the main thread
            const DownloadContext = struct {
                resource: Resource,
                allocator: std.mem.Allocator,
                previous_etag: ?[]const u8,
                previous_last_modified: ?[]const u8,
                error_detail: *RemoteFileErrorDetail,
            };
            var error_detail = RemoteFileErrorDetail{};
            const download_ctx = DownloadContext{
                .resource = self,
                .allocator = allocator,
                .previous_etag = previous_etag,
                .previous_last_modified = previous_last_modified,
                .error_detail = &error_detail,
            };
            const downloadAsync = struct {
                fn run(ctx: DownloadContext) !DownloadOutcome {
                    return ctx.resource.downloadDirect(ctx.allocator, ctx.previous_etag, ctx.previous_last_modified) catch |err| {
                        ctx.resource.copyRemoteFileFailure(ctx.error_detail, "download", err);
                        return err;
                    };
                }
            }.run;

            var outcome = AsyncExecutor.executeWithContext(DownloadContext, DownloadOutcome, download_ctx, downloadAsync) catch |err| {
                self.recordRemoteFileFailure("download", err, error_detail.get());
                return err;
            };

            // If server reported not modified but we have no local file, fall back to unconditional download
            if (!outcome.downloaded and !local_exists) {
                logger.debug("Server returned not_modified but local file doesn't exist, retrying without conditions", .{});
                error_detail.clear();
                const retry_ctx = DownloadContext{
                    .resource = self,
                    .allocator = allocator,
                    .previous_etag = null,
                    .previous_last_modified = null,
                    .error_detail = &error_detail,
                };
                const retry = AsyncExecutor.executeWithContext(DownloadContext, DownloadOutcome, retry_ctx, downloadAsync) catch |err| {
                    self.recordRemoteFileFailure("download retry", err, error_detail.get());
                    return err;
                };
                if (!retry.downloaded) {
                    var source_buf: [512]u8 = undefined;
                    base.recordProvisionErrorDetail(
                        "remote_file[{s}] conditional download returned not modified, but destination does not exist: {s}",
                        .{ self.path, http.maskUrlPassword(self.source, &source_buf) },
                    );
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
                    self.recordChecksumMismatch(expected_checksum, actual_checksum);
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

    /// Only consume completed downloads belonging to this provisioning run.
    fn findPreDownloadedFile(self: Resource, allocator: std.mem.Allocator) !?[]const u8 {
        const io = global_io.io();
        const manager = http.download.Manager.getCurrent() orelse return null;
        const resource_id = try std.fmt.allocPrint(allocator, "remote_file[{s}]", .{self.path});
        defer allocator.free(resource_id);
        const task = manager.getTask(resource_id) orelse return null;
        if (task.status.load(.acquire) != .completed or !std.mem.eql(u8, task.url, self.source)) return null;
        const file_path = try allocator.dupe(u8, task.temp_path);

        // Check if file exists
        std.Io.Dir.cwd().access(io, file_path, .{}) catch |err| switch (err) {
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
        const io = global_io.io();
        // Check if file exists
        const file = std.Io.Dir.cwd().openFile(io, self.path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                const was_updated = try applyCreate(self);
                return was_updated;
            },
            else => return err,
        };
        defer file.close(io);
        // File exists, do nothing
        return false; // File was up to date
    }

    fn applyDelete(self: Resource) !void {
        const io = global_io.io();
        const is_abs = std.fs.path.isAbsolute(self.path);
        if (is_abs) {
            std.Io.Dir.deleteFileAbsolute(io, self.path) catch |err| switch (err) {
                error.FileNotFound => return, // Already deleted, that's fine
                else => return err,
            };
        } else {
            std.Io.Dir.cwd().deleteFile(io, self.path) catch |err| switch (err) {
                error.FileNotFound => return, // Already deleted, that's fine
                else => return err,
            };
        }
    }

    fn applyTouch(self: Resource) !void {
        const io = global_io.io();
        try base.ensureParentDir(self.path);

        const is_abs = std.fs.path.isAbsolute(self.path);
        const file = if (is_abs)
            try std.Io.Dir.createFileAbsolute(io, self.path, .{ .truncate = false })
        else
            try std.Io.Dir.cwd().createFile(io, self.path, .{ .truncate = false });
        defer file.close(io);

        // Update modification time to current time
        try file.setTimestampsNow(io);
    }

    fn needsDownload(self: Resource) !bool {
        const io = global_io.io();
        // Check if local file exists
        const local_file = std.Io.Dir.cwd().openFile(io, self.path, .{}) catch |err| switch (err) {
            error.FileNotFound => return true, // File doesn't exist, need to download
            else => return err,
        };
        defer local_file.close(io);

        // TODO: Add more sophisticated comparison (size, modification time, etag)
        // For now, always download if file exists
        return true;
    }

    fn downloadDirect(self: Resource, allocator: std.mem.Allocator, previous_etag: ?[]const u8, previous_last_modified: ?[]const u8) !DownloadOutcome {
        const io = global_io.io();
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
            std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};
            return DownloadOutcome{ .downloaded = false, .etag = null };
        }

        // Verify checksum before touching destination
        if (self.checksum) |expected_checksum| {
            const actual_checksum = try http.calculateSha256(allocator, temp_path);
            defer allocator.free(actual_checksum);
            if (!std.mem.eql(u8, actual_checksum, expected_checksum)) {
                std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};
                self.recordChecksumMismatch(expected_checksum, actual_checksum);
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
        try std.Io.Dir.cwd().rename(temp_path, std.Io.Dir.cwd(), self.path, io);

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
        const io = global_io.io();
        const etag_path = try self.getEtagPath(allocator);
        defer allocator.free(etag_path);

        return std.Io.Dir.cwd().readFileAlloc(io, etag_path, allocator, .unlimited) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
    }

    fn saveEtag(self: Resource, allocator: std.mem.Allocator, etag: []const u8) !void {
        if (etag.len == 0) return;

        const io = global_io.io();
        const etag_path = try self.getEtagPath(allocator);
        defer allocator.free(etag_path);

        try base.ensureParentDir(etag_path);

        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = etag_path, .data = etag });
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
        const io = global_io.io();
        const lm_path = try self.getLastModifiedPath(allocator);
        defer allocator.free(lm_path);

        return std.Io.Dir.cwd().readFileAlloc(io, lm_path, allocator, .unlimited) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
    }

    fn saveLastModified(self: Resource, allocator: std.mem.Allocator, last_modified: []const u8) !void {
        if (last_modified.len == 0) return;

        const io = global_io.io();
        const lm_path = try self.getLastModifiedPath(allocator);
        defer allocator.free(lm_path);

        try base.ensureParentDir(lm_path);

        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = lm_path, .data = last_modified });
    }

    fn deleteTargetIfExists(self: Resource) !void {
        const io = global_io.io();
        const is_abs = std.fs.path.isAbsolute(self.path);
        const result = if (is_abs)
            std.Io.Dir.deleteFileAbsolute(io, self.path)
        else
            std.Io.Dir.cwd().deleteFile(io, self.path);

        result catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    fn copyRemoteFileFailure(self: Resource, detail: *RemoteFileErrorDetail, operation: []const u8, err: anyerror) void {
        var buf: [1024]u8 = undefined;
        const message = self.formatRemoteFileFailure(&buf, operation, err);
        detail.set(message);
    }

    fn recordRemoteFileFailure(self: Resource, operation: []const u8, err: anyerror, detail: ?[]const u8) void {
        if (detail) |message| {
            base.recordProvisionErrorDetailSlice(message);
            return;
        }

        var buf: [1024]u8 = undefined;
        const message = self.formatRemoteFileFailure(&buf, operation, err);
        base.recordProvisionErrorDetailSlice(message);
    }

    fn formatRemoteFileFailure(self: Resource, buf: []u8, operation: []const u8, err: anyerror) []const u8 {
        if (base.getProvisionErrorDetail()) |detail| {
            const n = @min(detail.len, buf.len);
            @memcpy(buf[0..n], detail[0..n]);
            return buf[0..n];
        }

        if (http.download.downloader.getLastDownloadError()) |detail| {
            return std.fmt.bufPrint(
                buf,
                "remote_file[{s}] {s} failed: {s}",
                .{ self.path, operation, detail },
            ) catch fallbackRemoteFileFailure(buf, self.path, operation, err);
        }

        if (http.getLastError()) |detail| {
            var detail_buf: [1024]u8 = undefined;
            return std.fmt.bufPrint(
                buf,
                "remote_file[{s}] {s} failed: {s}: {s}",
                .{ self.path, operation, @errorName(err), http.redactPassword(self.source, detail, &detail_buf) },
            ) catch fallbackRemoteFileFailure(buf, self.path, operation, err);
        }

        return fallbackRemoteFileFailure(buf, self.path, operation, err);
    }

    fn recordChecksumMismatch(self: Resource, expected: []const u8, actual: []const u8) void {
        base.recordProvisionErrorDetail(
            "remote_file[{s}] checksum mismatch: expected SHA256 {s}, got {s}",
            .{ self.path, expected, actual },
        );
    }
};

fn fallbackRemoteFileFailure(buf: []u8, path: []const u8, operation: []const u8, err: anyerror) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "remote_file[{s}] {s} failed: {s}",
        .{ path, operation, @errorName(err) },
    ) catch blk: {
        const fallback = "remote_file failed (message truncated)";
        const n = @min(fallback.len, buf.len);
        @memcpy(buf[0..n], fallback[0..n]);
        break :blk buf[0..n];
    };
}

test "remote file create follows a symlinked parent directory" {
    const allocator = std.testing.allocator;
    const io = global_io.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "assets", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "source.json", .data = "{\"version\":\"test\"}" });

    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);
    const assets_path = try tmp.dir.realPathFileAlloc(io, "assets", allocator);
    defer allocator.free(assets_path);
    const assets_link = try std.fs.path.join(allocator, &.{ tmp_path, "assets-link" });
    defer allocator.free(assets_link);
    try std.Io.Dir.symLinkAbsolute(io, assets_path, assets_link, .{});

    const destination = try std.fs.path.join(allocator, &.{ assets_link, ".manifest.json" });
    defer allocator.free(destination);
    const source_path = try tmp.dir.realPathFileAlloc(io, "source.json", allocator);
    defer allocator.free(source_path);
    const source_url = try std.fmt.allocPrint(allocator, "file://{s}", .{source_path});
    defer allocator.free(source_url);

    var resource = Resource{
        .path = destination,
        .source = source_url,
        .attrs = .{},
        .action = .create,
        .common = base.CommonProps.init(allocator),
    };
    defer resource.common.deinit(allocator);

    try std.testing.expect(try resource.applyCreate());
    const content = try tmp.dir.readFileAlloc(io, "assets/.manifest.json", allocator, .unlimited);
    defer allocator.free(content);
    try std.testing.expectEqualStrings("{\"version\":\"test\"}", content);
}

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
