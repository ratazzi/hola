const std = @import("std");
const mruby = @import("../mruby.zig");
const base = @import("../base_resource.zig");
const logger = @import("../logger.zig");
const git_client = @import("../git.zig");
const AsyncExecutor = @import("../async_executor.zig").AsyncExecutor;

const c = @cImport({
    @cInclude("git2.h");
});

/// Git resource data structure
pub const Resource = struct {
    // Resource-specific properties
    repository: []const u8, // Git repository URL
    destination: []const u8, // Destination path where to clone/checkout
    revision: []const u8, // Branch, tag, or commit SHA (default: "HEAD")
    checkout_branch: ?[]const u8, // Branch to checkout (default: "deploy")
    remote: []const u8, // Remote name (default: "origin")
    depth: ?u32, // Shallow clone depth (not yet supported by our git.zig)
    enable_checkout: bool, // Whether to checkout files (default: true)
    enable_submodules: bool, // Whether to update submodules (default: false)
    ssh_key: ?[]const u8, // Path to SSH private key for authentication
    ssh_wrapper: ?[]const u8, // For compatibility with Chef (ignored - use ssh_key instead)
    enable_strict_host_key_checking: bool, // Verify SSH host keys (default: true for security)
    user: ?[]const u8, // File owner after clone (e.g., "deploy", "www-data")
    group: ?[]const u8, // File group after clone (e.g., "deploy", "www-data")
    environment: ?[]const u8, // Environment variables ("KEY=VALUE\0KEY2=VALUE2\0")
    action: Action,

    // Common properties (guards, notifications, etc.)
    common: base.CommonProps,

    pub const Action = enum {
        sync, // Default: update source or clone if needed
        checkout, // Clone or checkout, but don't update if already exists
        @"export", // Export without VCS artifacts
        nothing,
    };

    pub fn deinit(self: Resource, allocator: std.mem.Allocator) void {
        allocator.free(self.repository);
        allocator.free(self.destination);
        allocator.free(self.revision);
        if (self.checkout_branch) |cb| allocator.free(cb);
        allocator.free(self.remote);
        if (self.ssh_key) |key| allocator.free(key);
        if (self.ssh_wrapper) |wrapper| allocator.free(wrapper);
        if (self.user) |u| allocator.free(u);
        if (self.group) |g| allocator.free(g);
        if (self.environment) |env| allocator.free(env);

        // Deinit common props
        var common = self.common;
        common.deinit(allocator);
    }

    pub fn apply(self: Resource) !base.ApplyResult {
        const skip_reason = try self.common.shouldRun(self.user, self.group);
        if (skip_reason) |reason| {
            const action_name = switch (self.action) {
                .sync => "sync",
                .checkout => "checkout",
                .@"export" => "export",
                .nothing => "nothing",
            };
            return base.ApplyResult{
                .was_updated = false,
                .action = action_name,
                .skip_reason = reason,
            };
        }

        switch (self.action) {
            .sync => {
                const was_updated = try applySync(self);
                return base.ApplyResult{
                    .was_updated = was_updated,
                    .action = "sync",
                    .skip_reason = if (was_updated) null else "up to date",
                };
            },
            .checkout => {
                const was_updated = try applyCheckout(self);
                return base.ApplyResult{
                    .was_updated = was_updated,
                    .action = "checkout",
                    .skip_reason = if (was_updated) null else "up to date",
                };
            },
            .@"export" => {
                const was_updated = try applyExport(self);
                return base.ApplyResult{
                    .was_updated = was_updated,
                    .action = "export",
                    .skip_reason = if (was_updated) null else "up to date",
                };
            },
            .nothing => {
                return base.ApplyResult{
                    .was_updated = false,
                    .action = "nothing",
                    .skip_reason = "skipped due to action :nothing",
                };
            },
        }
    }

    fn isGitRepo(path: []const u8) bool {
        var git_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const git_dir = std.fmt.bufPrint(&git_dir_buf, "{s}/.git", .{path}) catch return false;
        std.fs.accessAbsolute(git_dir, .{}) catch return false;
        return true;
    }

    fn dupZ(allocator: std.mem.Allocator, input: []const u8) ![:0]u8 {
        var buf = try allocator.alloc(u8, input.len + 1);
        @memcpy(buf[0..input.len], input);
        buf[input.len] = 0;
        return buf[0..input.len :0];
    }

    /// Recursively set ownership for a directory and all its contents
    fn setDirectoryOwnership(allocator: std.mem.Allocator, dir_path: []const u8, user: ?[]const u8, group: ?[]const u8) !void {
        // First set ownership on the directory itself
        try base.setFileOwnerAndGroup(dir_path, user, group);

        // Then recursively set ownership on all contents
        var dir = try std.fs.openDirAbsolute(dir_path, .{ .iterate = true });
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            const full_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
            defer allocator.free(full_path);

            // Set ownership on this entry
            base.setFileOwnerAndGroup(full_path, user, group) catch |err| {
                logger.warn("[git] failed to set ownership on {s}: {}", .{ full_path, err });
            };

            // If it's a directory, recurse
            if (entry.kind == .directory) {
                setDirectoryOwnership(allocator, full_path, user, group) catch |err| {
                    logger.warn("[git] failed to recursively set ownership in {s}: {}", .{ full_path, err });
                };
            }
        }
    }

    /// State for temporarily switching effective user/group identity.
    /// Used so that libgit2 operations (clone, fetch, open) run under the
    /// uid/gid specified by the resource's `user`/`group` attributes.
    const MAX_NGROUPS = 64;

    const UserSwitch = struct {
        original_uid: c_uint,
        original_gid: c_uint,
        original_ngroups: c_int,
        original_groups: [MAX_NGROUPS]c_uint,
        switched: bool,
    };

    const posix_c = @cImport({
        @cInclude("unistd.h");
        @cInclude("pwd.h");
        @cInclude("grp.h");
    });

    /// Switch the process effective uid/gid to the target user/group.
    /// Returns a context that must be passed to `restoreEffectiveUser` to undo the switch.
    /// If user and group are both null, returns a no-op context.
    fn switchEffectiveUser(user: ?[]const u8, group: ?[]const u8) !UserSwitch {
        if (user == null and group == null) {
            return UserSwitch{ .original_uid = 0, .original_gid = 0, .original_ngroups = 0, .original_groups = undefined, .switched = false };
        }

        const original_uid = posix_c.geteuid();
        const original_gid = posix_c.getegid();

        // Save supplementary groups before initgroups overwrites them
        var original_groups: [MAX_NGROUPS]c_uint = undefined;
        const original_ngroups = posix_c.getgroups(MAX_NGROUPS, &original_groups);

        // Set group first (must be done while still running as root)
        if (group) |groupname| {
            const gid = try base.getGroupId(groupname);
            if (posix_c.setegid(gid) != 0) {
                logger.err("[git] failed to setegid for group '{s}'", .{groupname});
                return error.SetGroupFailed;
            }
        } else if (user) |username| {
            // No explicit group — use the user's primary group
            const username_z = try std.posix.toPosixPath(username);
            const pwd = posix_c.getpwnam(&username_z);
            if (pwd != null) {
                _ = posix_c.setegid(pwd.*.pw_gid);
            }
        }

        // Initialize supplementary groups for proper file access
        if (user) |username| {
            const username_z = try std.posix.toPosixPath(username);
            const current_egid = posix_c.getegid();
            _ = posix_c.initgroups(&username_z, @intCast(current_egid));
        }

        // Switch effective uid last (drops privileges)
        if (user) |username| {
            const uid = try base.getUserId(username);
            if (posix_c.seteuid(uid) != 0) {
                // Rollback group change
                _ = posix_c.setegid(original_gid);
                logger.err("[git] failed to seteuid for user '{s}'", .{username});
                return error.SetUserFailed;
            }
            logger.debug("[git] switched effective user to '{s}' (uid={})", .{ username, uid });
        }

        return UserSwitch{
            .original_uid = original_uid,
            .original_gid = original_gid,
            .original_ngroups = original_ngroups,
            .original_groups = original_groups,
            .switched = true,
        };
    }

    /// Restore effective uid/gid to the values saved in the UserSwitch context.
    fn restoreEffectiveUser(ctx: UserSwitch) void {
        if (!ctx.switched) return;
        // Restore uid first — real uid is still root so this always succeeds,
        // and we need root back before we can restore the group.
        _ = posix_c.seteuid(ctx.original_uid);
        _ = posix_c.setegid(ctx.original_gid);
        // Restore supplementary groups that initgroups may have overwritten
        if (ctx.original_ngroups >= 0) {
            _ = posix_c.setgroups(@intCast(ctx.original_ngroups), &ctx.original_groups);
        }
        logger.debug("[git] restored effective user (uid={}, gid={})", .{ ctx.original_uid, ctx.original_gid });
    }

    /// Context for custom credentials and certificate callbacks
    const SshContext = struct {
        ssh_key_path: ?[]const u8,
        enable_strict_host_key_checking: bool,
        retries: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    };

    /// Custom credentials callback that supports SSH key files
    fn credentialsCallback(
        out: ?*?*c.git_credential,
        url: [*c]const u8,
        username_from_url: [*c]const u8,
        allowed_types: c_uint,
        payload: ?*anyopaque,
    ) callconv(.c) c_int {
        const url_str = std.mem.span(url);

        // Get context if provided
        const ctx: ?*SshContext = if (payload) |p| @ptrCast(@alignCast(p)) else null;

        // Limit retries to avoid infinite loops
        if (ctx) |c_ctx| {
            const retry_count = c_ctx.retries.fetchAdd(1, .monotonic);
            if (retry_count >= 3) {
                logger.warn("[git] authentication failed after 3 attempts for: {s}", .{url_str});
                return c.GIT_EAUTH;
            }
        }

        const types: c_uint = allowed_types;

        // Use username from URL if available, otherwise let libgit2 use system default
        // This inherits the running user's permissions instead of hardcoding "git"
        const user: [*c]const u8 = if (username_from_url != null and username_from_url[0] != 0)
            username_from_url
        else
            null;

        // SSH key-based authentication
        if ((types & c.GIT_CREDTYPE_SSH_KEY) != 0) {
            // Priority 1: If custom SSH key is explicitly provided, use it first
            if (ctx) |c_ctx| {
                if (c_ctx.ssh_key_path) |key_path| {
                    const private_key: [*c]const u8 = @ptrCast(key_path.ptr);
                    const public_key: [*c]const u8 = null; // libgit2 will derive from private key
                    const passphrase: [*c]const u8 = null; // No passphrase support yet
                    return c.git_credential_ssh_key_new(out, user, public_key, private_key, passphrase);
                }
            }

            // Priority 2: Try SSH agent (keys actively added by user)
            const agent_result = c.git_credential_ssh_key_from_agent(out, user);
            if (agent_result == 0) {
                return 0;
            }

            // Priority 3: Fall back to default SSH key files (automatic discovery)
            const home = std.posix.getenv("HOME") orelse "/tmp";
            const key_names = [_][]const u8{ "id_ed25519", "id_rsa", "id_ecdsa", "id_dsa" };

            for (key_names) |key_name| {
                var key_path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
                const key_path = std.fmt.bufPrintZ(&key_path_buf, "{s}/.ssh/{s}", .{ home, key_name }) catch continue;

                // Check if key file exists
                std.fs.accessAbsolute(key_path, .{}) catch continue;

                // Try this key
                const key_path_c: [*c]const u8 = @ptrCast(key_path.ptr);
                const result = c.git_credential_ssh_key_new(out, user, null, key_path_c, null);
                if (result == 0) {
                    return 0;
                }
            }

            // No authentication method worked
            return c.GIT_EAUTH;
        }

        // HTTPS with platform credentials
        if ((types & c.GIT_CREDTYPE_DEFAULT) != 0) {
            return c.git_credential_default_new(out);
        }

        // Username-only
        if ((types & c.GIT_CREDTYPE_USERNAME) != 0) {
            return c.git_credential_username_new(out, user);
        }

        return c.GIT_EAUTH;
    }

    /// Certificate check callback for SSH host key verification
    /// When enable_strict_host_key_checking is false, accepts all host keys (like StrictHostKeyChecking=no)
    fn certificateCheckCallback(
        cert: ?*c.git_cert,
        valid: c_int,
        host: [*c]const u8,
        payload: ?*anyopaque,
    ) callconv(.c) c_int {
        _ = cert;
        _ = host;

        // Get context if provided
        const ctx: ?*SshContext = if (payload) |p| @ptrCast(@alignCast(p)) else null;

        // If strict host key checking is disabled, accept all certificates
        if (ctx) |c_ctx| {
            if (!c_ctx.enable_strict_host_key_checking) {
                return 0; // Accept the certificate
            }
        }

        // Otherwise, use libgit2's default validation
        if (valid != 0) {
            return 0; // Certificate is valid
        }

        return c.GIT_ECERTIFICATE; // Certificate validation failed
    }

    fn openRepository(allocator: std.mem.Allocator, path: []const u8) !?*c.git_repository {
        const path_c = try dupZ(allocator, path);
        defer allocator.free(path_c);

        var repo: ?*c.git_repository = null;
        const code = c.git_repository_open(&repo, path_c.ptr);
        if (code != 0) {
            const err = c.git_error_last();
            if (err != null) {
                logger.err("[git] failed to open repository at {s}: {s}", .{ path, std.mem.span(err.*.message) });
            } else {
                logger.err("[git] failed to open repository at {s} (error code: {})", .{ path, code });
            }
            return null;
        }
        return repo;
    }

    fn getCurrentRevision(allocator: std.mem.Allocator, repo: *c.git_repository) ![]const u8 {
        var head_ref: ?*c.git_reference = null;
        const code = c.git_repository_head(&head_ref, repo);
        if (code != 0) {
            return error.GetHeadFailed;
        }
        defer if (head_ref) |ref| c.git_reference_free(ref);

        const oid = c.git_reference_target(head_ref);
        if (oid == null) {
            return error.NoOid;
        }

        var buf: [41]u8 = undefined;
        _ = c.git_oid_tostr(&buf, buf.len, oid);
        const sha = std.mem.span(@as([*:0]const u8, @ptrCast(&buf)));
        return try allocator.dupe(u8, sha);
    }

    fn resolveRevision(allocator: std.mem.Allocator, repo: *c.git_repository, revision: []const u8) ![]const u8 {
        const rev_c = try dupZ(allocator, revision);
        defer allocator.free(rev_c);

        var obj: ?*c.git_object = null;
        const code = c.git_revparse_single(&obj, repo, rev_c.ptr);
        if (code != 0) {
            return error.RevParseFailed;
        }
        defer if (obj) |o| c.git_object_free(o);

        const oid = c.git_object_id(obj);
        if (oid == null) {
            return error.NoOid;
        }

        var buf: [41]u8 = undefined;
        _ = c.git_oid_tostr(&buf, buf.len, oid);
        const sha = std.mem.span(@as([*:0]const u8, @ptrCast(&buf)));
        return try allocator.dupe(u8, sha);
    }

    /// Context for async clone operation
    const CloneContext = struct {
        resource: Resource,
        allocator: std.mem.Allocator,
    };

    /// Async wrapper for clone operation (runs in background thread)
    fn cloneRepositoryAsync(ctx: CloneContext) !void {
        return cloneRepositoryImpl(ctx.resource, ctx.allocator);
    }

    /// Actual clone implementation
    fn cloneRepositoryImpl(self: Resource, allocator: std.mem.Allocator) !void {
        // Initialize libgit2 in this thread
        var git = try git_client.Client.init();
        defer git.deinit();

        const url_c = try dupZ(allocator, self.repository);
        defer allocator.free(url_c);

        const dest_c = try dupZ(allocator, self.destination);
        defer allocator.free(dest_c);

        var clone_opts: c.git_clone_options = undefined;
        const init_code = c.git_clone_options_init(&clone_opts, c.GIT_CLONE_OPTIONS_VERSION);
        if (init_code != 0) return error.CloneOptionsInitFailed;

        // Set checkout options
        if (!self.enable_checkout) {
            clone_opts.checkout_opts.checkout_strategy = c.GIT_CHECKOUT_NONE;
        }

        // Note: We don't set checkout_branch here because it causes issues
        // with remote refs not being set up yet. Instead, we let libgit2
        // checkout the default branch, and we'll switch branches after clone if needed.

        // Setup credentials and certificate callbacks
        var ssh_ctx = SshContext{
            .ssh_key_path = self.ssh_key,
            .enable_strict_host_key_checking = self.enable_strict_host_key_checking,
        };
        clone_opts.fetch_opts.callbacks.credentials = credentialsCallback;
        clone_opts.fetch_opts.callbacks.certificate_check = certificateCheckCallback;
        clone_opts.fetch_opts.callbacks.payload = &ssh_ctx;

        // Switch effective user so libgit2 creates files with correct ownership
        // and passes safe.directory / SSH key permission checks
        const user_ctx = try switchEffectiveUser(self.user, self.group);
        errdefer restoreEffectiveUser(user_ctx);

        // Perform clone
        var repo_ptr: ?*c.git_repository = null;
        const code = c.git_clone(&repo_ptr, url_c.ptr, dest_c.ptr, &clone_opts);

        // Restore root before ownership fixup (chown requires root)
        restoreEffectiveUser(user_ctx);

        if (code != 0) {
            const err = c.git_error_last();
            if (err != null) {
                const err_msg = std.mem.span(err.*.message);
                logger.err("[git] clone failed for {s}: {s}", .{ self.repository, err_msg });
            } else {
                logger.err("[git] clone failed for {s} (error code: {})", .{ self.repository, code });
            }
            return error.GitCloneFailed;
        }

        if (repo_ptr) |repo| {
            defer c.git_repository_free(repo);
        }

        // Set file ownership if user or group is specified
        if (self.user != null or self.group != null) {
            try setDirectoryOwnership(allocator, self.destination, self.user, self.group);
        }
    }

    /// Clone repository with async execution (doesn't block spinner)
    fn cloneRepository(self: Resource, allocator: std.mem.Allocator) !void {
        const ctx = CloneContext{
            .resource = self,
            .allocator = allocator,
        };
        return AsyncExecutor.executeWithContext(CloneContext, void, ctx, cloneRepositoryAsync);
    }

    /// Context for async fetch and update operation
    const FetchContext = struct {
        resource: Resource,
        allocator: std.mem.Allocator,
        repo: *c.git_repository,
    };

    /// Async wrapper for fetch operation (runs in background thread)
    fn fetchAndUpdateAsync(ctx: FetchContext) !bool {
        return fetchAndUpdateImpl(ctx.resource, ctx.allocator, ctx.repo);
    }

    /// Actual fetch and update implementation
    fn fetchAndUpdateImpl(self: Resource, allocator: std.mem.Allocator, repo: *c.git_repository) !bool {
        // Initialize libgit2 in this thread
        var git = try git_client.Client.init();
        defer git.deinit();

        // Switch effective user for fetch/reset operations
        const user_ctx = try switchEffectiveUser(self.user, self.group);
        defer restoreEffectiveUser(user_ctx);

        // Fetch from remote
        const remote_c = try dupZ(allocator, self.remote);
        defer allocator.free(remote_c);

        var remote: ?*c.git_remote = null;
        var code = c.git_remote_lookup(&remote, repo, remote_c.ptr);
        if (code != 0) {
            return error.RemoteLookupFailed;
        }
        defer if (remote) |r| c.git_remote_free(r);

        // Ensure remote URL matches the resource's repository URL
        if (remote) |r| {
            const current_url_ptr = c.git_remote_url(r);
            if (current_url_ptr != null) {
                const current_url = std.mem.span(current_url_ptr);
                if (!std.mem.eql(u8, current_url, self.repository)) {
                    const repo_url_c = try dupZ(allocator, self.repository);
                    defer allocator.free(repo_url_c);
                    const set_code = c.git_remote_set_url(repo, remote_c.ptr, repo_url_c.ptr);
                    if (set_code != 0) {
                        const err = c.git_error_last();
                        if (err != null) {
                            logger.err("[git] failed to update remote URL: {s}", .{std.mem.span(err.*.message)});
                        }
                        return error.RemoteSetUrlFailed;
                    }
                    logger.info("[git] updated remote '{s}' URL: {s} -> {s}", .{ self.remote, current_url, self.repository });
                    // Re-lookup remote to pick up the new URL
                    c.git_remote_free(r);
                    remote = null;
                    code = c.git_remote_lookup(&remote, repo, remote_c.ptr);
                    if (code != 0) return error.RemoteLookupFailed;
                }
            }
        }

        // Perform fetch with custom credentials
        var fetch_opts: c.git_fetch_options = undefined;
        code = c.git_fetch_options_init(&fetch_opts, c.GIT_FETCH_OPTIONS_VERSION);
        if (code != 0) {
            return error.FetchOptionsInitFailed;
        }

        // Setup credentials and certificate callbacks for fetch
        var ssh_ctx = SshContext{
            .ssh_key_path = self.ssh_key,
            .enable_strict_host_key_checking = self.enable_strict_host_key_checking,
        };
        fetch_opts.callbacks.credentials = credentialsCallback;
        fetch_opts.callbacks.certificate_check = certificateCheckCallback;
        fetch_opts.callbacks.payload = &ssh_ctx;

        code = c.git_remote_fetch(remote, null, &fetch_opts, null);
        if (code != 0) {
            const err = c.git_error_last();
            if (err != null) {
                const err_msg = std.mem.span(err.*.message);
                logger.err("[git] fetch failed: {s} (code: {})", .{ err_msg, code });
            } else {
                logger.err("[git] fetch failed (code: {})", .{code});
            }
            return error.FetchFailed;
        }

        // Get current revision
        const current_rev = try getCurrentRevision(allocator, repo);
        defer allocator.free(current_rev);

        // Resolve target revision
        // For "HEAD", use checkout_branch on the remote.
        // For other values, try as-is first (tag, SHA, or already-qualified ref),
        // then fall back to {remote}/{revision} (bare branch name after fetch).
        const target_rev = blk: {
            if (std.mem.eql(u8, self.revision, "HEAD")) {
                const ref = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.remote, self.checkout_branch orelse "deploy" });
                defer allocator.free(ref);
                break :blk try resolveRevision(allocator, repo, ref);
            }
            break :blk resolveRevision(allocator, repo, self.revision) catch {
                const qualified = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.remote, self.revision });
                defer allocator.free(qualified);
                break :blk try resolveRevision(allocator, repo, qualified);
            };
        };
        defer allocator.free(target_rev);

        // Compare revisions
        if (!std.mem.eql(u8, current_rev, target_rev)) {
            // Reset to target revision
            const target_rev_c = try dupZ(allocator, target_rev);
            defer allocator.free(target_rev_c);

            var target_obj: ?*c.git_object = null;
            code = c.git_revparse_single(&target_obj, repo, target_rev_c.ptr);
            if (code != 0) {
                return error.RevParseFailed;
            }
            defer if (target_obj) |o| c.git_object_free(o);

            code = c.git_reset(repo, target_obj, c.GIT_RESET_HARD, null);
            if (code != 0) {
                return error.ResetFailed;
            }

            return true; // was_updated
        }

        return false; // not updated
    }

    /// Apply environment variables from "KEY=VALUE\0..." format string using setenv().
    /// Returns saved original values for restoration.
    fn applyEnvironment(allocator: std.mem.Allocator, env_str: []const u8) !std.ArrayList(EnvSaved) {
        var saved = std.ArrayList(EnvSaved).empty;
        errdefer restoreEnvironment(allocator, &saved);
        var pos: usize = 0;
        while (pos < env_str.len) {
            const start = pos;
            while (pos < env_str.len and env_str[pos] != 0) : (pos += 1) {}
            const pair = env_str[start..pos];
            if (pair.len > 0) {
                if (std.mem.indexOfScalar(u8, pair, '=')) |eq_pos| {
                    const key = pair[0..eq_pos];
                    const value = pair[eq_pos + 1 ..];
                    // Save original value
                    const key_z = try allocator.dupeZ(u8, key);
                    const orig = std.posix.getenv(key);
                    const orig_dup: ?[]const u8 = if (orig) |o| try allocator.dupe(u8, o) else null;
                    try saved.append(allocator, .{ .key = key_z, .original = orig_dup });
                    // Set new value
                    const value_z = try allocator.dupeZ(u8, value);
                    defer allocator.free(value_z);
                    _ = setenv(key_z.ptr, value_z.ptr, 1);
                }
            }
            pos += 1;
        }
        return saved;
    }

    const EnvSaved = struct {
        key: [:0]u8,
        original: ?[]const u8,
    };

    fn restoreEnvironment(allocator: std.mem.Allocator, saved: *std.ArrayList(EnvSaved)) void {
        for (saved.items) |entry| {
            if (entry.original) |orig| {
                const orig_z = allocator.dupeZ(u8, orig) catch continue;
                defer allocator.free(orig_z);
                _ = setenv(entry.key.ptr, orig_z.ptr, 1);
                allocator.free(orig);
            } else {
                _ = unsetenv(entry.key.ptr);
            }
            allocator.free(entry.key);
        }
        saved.deinit(allocator);
    }

    extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern fn unsetenv(name: [*:0]const u8) c_int;

    const SAVED_HOME_BUF_SIZE = 4096; // PATH_MAX on Linux; covers all POSIX platforms
    threadlocal var saved_home_buf: [SAVED_HOME_BUF_SIZE]u8 = undefined;

    const HomedirState = struct {
        changed: bool = false,
        has_original_home: bool = false,
    };

    /// Set home directory for the target user (from passwd).
    /// Updates libgit2 search paths and HOME env var so that gitconfig
    /// loading and SSH key discovery work when running as root with seteuid.
    fn setHomedirForUser(user: []const u8) !HomedirState {
        var state = HomedirState{};

        const username_z = std.posix.toPosixPath(user) catch return state;
        const pwd = posix_c.getpwnam(&username_z);
        if (pwd == null) return state;
        const home = pwd.*.pw_dir orelse return state;

        // Copy original HOME to stable buffer before setenv may invalidate getenv pointer
        const original_c = getenv("HOME");
        if (original_c) |orig| {
            const span = std.mem.span(orig);
            if (span.len >= SAVED_HOME_BUF_SIZE) {
                logger.err("[git] original HOME too long ({d} bytes), cannot safely switch homedir", .{span.len});
                return error.HomePathTooLong;
            }
            @memcpy(saved_home_buf[0..span.len], span);
            saved_home_buf[span.len] = 0;
            state.has_original_home = true;
        }

        // Set libgit2 internal search paths
        _ = c.git_libgit2_opts(c.GIT_OPT_SET_HOMEDIR, home);
        _ = c.git_libgit2_opts(c.GIT_OPT_SET_SEARCH_PATH, c.GIT_CONFIG_LEVEL_GLOBAL, home);

        // Set HOME env var for SSH key discovery in credential callback
        _ = setenv("HOME", home, 1);

        state.changed = true;
        logger.debug("[git] set homedir to '{s}' for user '{s}'", .{ std.mem.span(home), user });
        return state;
    }

    fn restoreHomedir(state: *const HomedirState) void {
        if (!state.changed) return;

        if (state.has_original_home) {
            const ptr: [*:0]const u8 = @ptrCast(&saved_home_buf);
            _ = setenv("HOME", ptr, 1);
            _ = c.git_libgit2_opts(c.GIT_OPT_SET_HOMEDIR, ptr);
            _ = c.git_libgit2_opts(c.GIT_OPT_SET_SEARCH_PATH, c.GIT_CONFIG_LEVEL_GLOBAL, ptr);
        } else {
            _ = unsetenv("HOME");
            const null_ptr: ?[*:0]const u8 = null;
            _ = c.git_libgit2_opts(c.GIT_OPT_SET_HOMEDIR, null_ptr);
            _ = c.git_libgit2_opts(c.GIT_OPT_SET_SEARCH_PATH, c.GIT_CONFIG_LEVEL_GLOBAL, null_ptr);
        }
    }

    extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;

    fn applySync(self: Resource) !bool {
        // Initialize libgit2
        var git = try git_client.Client.init();
        defer git.deinit();

        // Disable owner validation — hola manages user context via seteuid,
        // and libgit2's check can fail under root-with-seteuid scenarios.
        _ = c.git_libgit2_opts(c.GIT_OPT_SET_OWNER_VALIDATION, @as(c_int, 0));

        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        // Set home directory for the target user so that gitconfig loading
        // and SSH key discovery work when running as root with seteuid.
        var homedir_state = if (self.user) |user| try setHomedirForUser(user) else HomedirState{};
        defer restoreHomedir(&homedir_state);

        // Apply environment variables if specified
        var env_saved = if (self.environment) |env|
            try applyEnvironment(allocator, env)
        else
            std.ArrayList(EnvSaved).empty;
        defer restoreEnvironment(allocator, &env_saved);

        // Check if destination exists and is a git repo
        const dest_exists = blk: {
            std.fs.accessAbsolute(self.destination, .{}) catch |err| switch (err) {
                error.FileNotFound => break :blk false,
                else => return err,
            };
            break :blk true;
        };

        var was_updated = false;

        if (!dest_exists or !isGitRepo(self.destination)) {
            // Clone the repository with custom credentials (async)
            // (cloneRepositoryImpl handles user switching internally)
            try self.cloneRepository(allocator);
            was_updated = true;
        } else {
            // Switch effective user for git_repository_open (safe.directory check)
            const open_ctx = try switchEffectiveUser(self.user, self.group);
            const repo = openRepository(allocator, self.destination) catch |err| {
                restoreEffectiveUser(open_ctx);
                return err;
            };
            restoreEffectiveUser(open_ctx);

            const repo_nonnull = repo orelse return error.OpenRepoFailed;
            defer c.git_repository_free(repo_nonnull);

            const fetch_ctx = FetchContext{
                .resource = self,
                .allocator = allocator,
                .repo = repo_nonnull,
            };
            was_updated = try AsyncExecutor.executeWithContext(FetchContext, bool, fetch_ctx, fetchAndUpdateAsync);
        }

        // Update submodules if enabled
        if (self.enable_submodules and was_updated) {
            const sub_ctx = try switchEffectiveUser(self.user, self.group);
            const sub_repo_opt = openRepository(allocator, self.destination) catch |err| {
                restoreEffectiveUser(sub_ctx);
                return err;
            };
            const sub_repo = sub_repo_opt orelse {
                restoreEffectiveUser(sub_ctx);
                return error.OpenRepoFailed;
            };
            defer c.git_repository_free(sub_repo);

            // Initialize and update submodules
            const code = c.git_submodule_foreach(sub_repo, submoduleUpdateCallback, null);
            restoreEffectiveUser(sub_ctx);
            if (code != 0) {
                logger.warn("[git] submodule update failed", .{});
            }
        }

        // Set file ownership if user or group is specified and files were updated
        if (was_updated and (self.user != null or self.group != null)) {
            try setDirectoryOwnership(allocator, self.destination, self.user, self.group);
        }

        return was_updated;
    }

    fn submoduleUpdateCallback(sm: ?*c.git_submodule, name: [*c]const u8, payload: ?*anyopaque) callconv(.c) c_int {
        _ = payload;
        _ = name;
        if (sm == null) return 0;

        var init_code = c.git_submodule_init(sm, 1);
        if (init_code != 0) return init_code;

        var update_opts: c.git_submodule_update_options = undefined;
        init_code = c.git_submodule_update_options_init(&update_opts, c.GIT_SUBMODULE_UPDATE_OPTIONS_VERSION);
        if (init_code != 0) return init_code;

        return c.git_submodule_update(sm, 1, &update_opts);
    }

    fn applyCheckout(self: Resource) !bool {
        // Similar to sync but don't update if already exists
        const dest_exists = blk: {
            std.fs.accessAbsolute(self.destination, .{}) catch |err| switch (err) {
                error.FileNotFound => break :blk false,
                else => return err,
            };
            break :blk true;
        };

        if (dest_exists and isGitRepo(self.destination)) {
            // Already checked out, do nothing
            return false;
        }

        // Clone the repository
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        var git = try git_client.Client.init();
        defer git.deinit();

        _ = c.git_libgit2_opts(c.GIT_OPT_SET_OWNER_VALIDATION, @as(c_int, 0));
        var homedir_state = if (self.user) |user| try setHomedirForUser(user) else HomedirState{};
        defer restoreHomedir(&homedir_state);

        var env_saved = if (self.environment) |env|
            try applyEnvironment(allocator, env)
        else
            std.ArrayList(EnvSaved).empty;
        defer restoreEnvironment(allocator, &env_saved);

        try self.cloneRepository(allocator);

        // Set file ownership if user or group is specified
        if (self.user != null or self.group != null) {
            try setDirectoryOwnership(allocator, self.destination, self.user, self.group);
        }

        return true;
    }

    fn applyExport(self: Resource) !bool {
        // First ensure we have the repo (like checkout)
        const was_cloned = try applyCheckout(self);

        if (was_cloned) {
            // Remove .git directory
            var git_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
            const git_dir = try std.fmt.bufPrint(&git_dir_buf, "{s}/.git", .{self.destination});

            std.fs.deleteTreeAbsolute(git_dir) catch |err| {
                logger.warn("[git] failed to remove .git directory: {}", .{err});
            };
        }

        return was_cloned;
    }
};

pub const ruby_prelude = @embedFile("git_resource.rb");

/// Zig function called from Ruby to add git resource
pub fn zigAddResource(
    mrb: *mruby.mrb_state,
    _: mruby.mrb_value,
    resources: *std.ArrayList(Resource),
    allocator: std.mem.Allocator,
) mruby.mrb_value {
    // Define all argument variables
    var repository_val: mruby.mrb_value = undefined;
    var destination_val: mruby.mrb_value = undefined;
    var revision_val: mruby.mrb_value = undefined;
    var checkout_branch_val: mruby.mrb_value = undefined;
    var remote_val: mruby.mrb_value = undefined;
    var depth_val: mruby.mrb_value = undefined;
    var enable_checkout_val: mruby.mrb_value = undefined;
    var enable_submodules_val: mruby.mrb_value = undefined;
    var ssh_key_val: mruby.mrb_value = undefined;
    var enable_strict_host_key_checking_val: mruby.mrb_value = undefined;
    var user_val: mruby.mrb_value = undefined;
    var group_val: mruby.mrb_value = undefined;
    var environment_val: mruby.mrb_value = undefined;
    var action_val: mruby.mrb_value = undefined;
    var only_if_block: mruby.mrb_value = undefined;
    var not_if_block: mruby.mrb_value = undefined;
    var ignore_failure_val: mruby.mrb_value = undefined;
    var notifications_array: mruby.mrb_value = undefined;
    var subscriptions_array: mruby.mrb_value = undefined;

    // Get arguments: 14 required + 5 optional
    // S=string, o=object (bool), i=integer, A=array, |=optional separator
    _ = mruby.mrb_get_args(mrb, "SSSSSiooSoSSAS|oooAA", &repository_val, &destination_val, &revision_val, &checkout_branch_val, &remote_val, &depth_val, &enable_checkout_val, &enable_submodules_val, &ssh_key_val, &enable_strict_host_key_checking_val, &user_val, &group_val, &environment_val, &action_val, &only_if_block, &not_if_block, &ignore_failure_val, &notifications_array, &subscriptions_array);

    // Extract required arguments
    const repository = std.mem.span(mruby.mrb_str_to_cstr(mrb, repository_val));
    const destination = std.mem.span(mruby.mrb_str_to_cstr(mrb, destination_val));
    const revision = std.mem.span(mruby.mrb_str_to_cstr(mrb, revision_val));
    const remote = std.mem.span(mruby.mrb_str_to_cstr(mrb, remote_val));
    const enable_checkout = mruby.mrb_test(enable_checkout_val);
    const enable_submodules = mruby.mrb_test(enable_submodules_val);
    const enable_strict_host_key_checking = mruby.mrb_test(enable_strict_host_key_checking_val);
    const action_str = std.mem.span(mruby.mrb_str_to_cstr(mrb, action_val));

    // Parse optional string fields with proper cleanup on failure
    const checkout_branch_str = std.mem.span(mruby.mrb_str_to_cstr(mrb, checkout_branch_val));
    const checkout_branch: ?[]const u8 = if (checkout_branch_str.len > 0)
        allocator.dupe(u8, checkout_branch_str) catch return mruby.mrb_nil_value()
    else
        null;
    errdefer if (checkout_branch) |cb| allocator.free(cb);

    // For depth, we assume it's passed as an integer from Ruby
    // Note: depth/shallow clone not yet supported by our git.zig, but we accept it
    const depth_int = mruby.zig_mrb_fixnum(mrb, depth_val);
    const depth: ?u32 = if (depth_int > 0) @intCast(depth_int) else null;

    const ssh_key_str = std.mem.span(mruby.mrb_str_to_cstr(mrb, ssh_key_val));
    const ssh_key: ?[]const u8 = if (ssh_key_str.len > 0)
        allocator.dupe(u8, ssh_key_str) catch return mruby.mrb_nil_value()
    else
        null;
    errdefer if (ssh_key) |key| allocator.free(key);

    const user_str = std.mem.span(mruby.mrb_str_to_cstr(mrb, user_val));
    const user: ?[]const u8 = if (user_str.len > 0)
        allocator.dupe(u8, user_str) catch return mruby.mrb_nil_value()
    else
        null;
    errdefer if (user) |u| allocator.free(u);

    const group_str = std.mem.span(mruby.mrb_str_to_cstr(mrb, group_val));
    const group: ?[]const u8 = if (group_str.len > 0)
        allocator.dupe(u8, group_str) catch return mruby.mrb_nil_value()
    else
        null;
    errdefer if (group) |g| allocator.free(g);

    // Parse action
    const action: Resource.Action = blk: {
        if (std.mem.eql(u8, action_str, "sync")) break :blk .sync;
        if (std.mem.eql(u8, action_str, "checkout")) break :blk .checkout;
        if (std.mem.eql(u8, action_str, "export")) break :blk .@"export";
        if (std.mem.eql(u8, action_str, "nothing")) break :blk .nothing;
        break :blk .sync; // Default
    };

    // Parse environment array [[key, value], ...]
    var environment: ?[]const u8 = null;
    const env_len = mruby.mrb_ary_len(mrb, environment_val);
    if (env_len > 0) {
        var env_list = std.ArrayList(u8).initCapacity(allocator, @intCast(env_len * 32)) catch std.ArrayList(u8).empty;
        defer env_list.deinit(allocator);

        var i: mruby.mrb_int = 0;
        while (i < env_len) : (i += 1) {
            const pair = mruby.mrb_ary_ref(mrb, environment_val, i);
            if (mruby.mrb_ary_len(mrb, pair) != 2) continue;

            const key_val = mruby.mrb_ary_ref(mrb, pair, 0);
            const val_val = mruby.mrb_ary_ref(mrb, pair, 1);
            const key_cstr = mruby.mrb_str_to_cstr(mrb, key_val);
            const val_cstr = mruby.mrb_str_to_cstr(mrb, val_val);
            const key_span = std.mem.span(key_cstr);
            const val_span = std.mem.span(val_cstr);

            env_list.appendSlice(allocator, key_span) catch return mruby.mrb_nil_value();
            env_list.append(allocator, '=') catch return mruby.mrb_nil_value();
            env_list.appendSlice(allocator, val_span) catch return mruby.mrb_nil_value();
            env_list.append(allocator, 0) catch return mruby.mrb_nil_value();
        }

        if (env_list.items.len > 0) {
            environment = allocator.dupe(u8, env_list.items) catch return mruby.mrb_nil_value();
        }
    }
    errdefer if (environment) |env| allocator.free(env);

    // Duplicate required strings with cleanup on failure
    const repository_dup = allocator.dupe(u8, repository) catch return mruby.mrb_nil_value();
    errdefer allocator.free(repository_dup);

    const destination_dup = allocator.dupe(u8, destination) catch return mruby.mrb_nil_value();
    errdefer allocator.free(destination_dup);

    const revision_dup = allocator.dupe(u8, revision) catch return mruby.mrb_nil_value();
    errdefer allocator.free(revision_dup);

    const remote_dup = allocator.dupe(u8, remote) catch return mruby.mrb_nil_value();
    errdefer allocator.free(remote_dup);

    // Build common properties (guards + notifications)
    var common = base.CommonProps.init(allocator);
    base.fillCommonFromRuby(&common, mrb, only_if_block, not_if_block, ignore_failure_val, notifications_array, subscriptions_array, allocator);

    const res = Resource{
        .repository = repository_dup,
        .destination = destination_dup,
        .revision = revision_dup,
        .checkout_branch = checkout_branch,
        .remote = remote_dup,
        .depth = depth,
        .enable_checkout = enable_checkout,
        .enable_submodules = enable_submodules,
        .ssh_key = ssh_key,
        .ssh_wrapper = null, // Not used with libgit2
        .enable_strict_host_key_checking = enable_strict_host_key_checking,
        .user = user,
        .group = group,
        .environment = environment,
        .action = action,
        .common = common,
    };

    resources.append(allocator, res) catch {
        // On append failure, we need to clean up the resource
        // Note: errdefer won't trigger here since we're catching, so we must do it manually
        allocator.free(repository_dup);
        allocator.free(destination_dup);
        allocator.free(revision_dup);
        allocator.free(remote_dup);
        if (checkout_branch) |cb| allocator.free(cb);
        if (ssh_key) |key| allocator.free(key);
        if (user) |u| allocator.free(u);
        if (group) |g| allocator.free(g);
        if (environment) |env| allocator.free(env);
        common.deinit(allocator);
        return mruby.mrb_nil_value();
    };

    return mruby.mrb_nil_value();
}
