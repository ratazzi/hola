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

        // Perform clone
        var repo_ptr: ?*c.git_repository = null;
        const code = c.git_clone(&repo_ptr, url_c.ptr, dest_c.ptr, &clone_opts);
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

        // Fetch from remote
        const remote_c = try dupZ(allocator, self.remote);
        defer allocator.free(remote_c);

        var remote: ?*c.git_remote = null;
        var code = c.git_remote_lookup(&remote, repo, remote_c.ptr);
        if (code != 0) {
            return error.RemoteLookupFailed;
        }
        defer if (remote) |r| c.git_remote_free(r);

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
        const target_ref = if (std.mem.eql(u8, self.revision, "HEAD"))
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.remote, self.checkout_branch orelse "deploy" })
        else
            try allocator.dupe(u8, self.revision);
        defer allocator.free(target_ref);

        const target_rev = try resolveRevision(allocator, repo, target_ref);
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

    fn applySync(self: Resource) !bool {
        // Initialize libgit2
        var git = try git_client.Client.init();
        defer git.deinit();

        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

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
            try self.cloneRepository(allocator);
            was_updated = true;
        } else {
            // Repository exists, fetch and reset (async)
            const repo = try openRepository(allocator, self.destination) orelse return error.OpenRepoFailed;
            defer c.git_repository_free(repo);

            const fetch_ctx = FetchContext{
                .resource = self,
                .allocator = allocator,
                .repo = repo,
            };
            was_updated = try AsyncExecutor.executeWithContext(FetchContext, bool, fetch_ctx, fetchAndUpdateAsync);
        }

        // Update submodules if enabled
        if (self.enable_submodules and was_updated) {
            const repo = try openRepository(allocator, self.destination) orelse return error.OpenRepoFailed;
            defer c.git_repository_free(repo);

            // Initialize and update submodules
            const code = c.git_submodule_foreach(repo, submoduleUpdateCallback, null);
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
    var action_val: mruby.mrb_value = undefined;
    var only_if_block: mruby.mrb_value = undefined;
    var not_if_block: mruby.mrb_value = undefined;
    var ignore_failure_val: mruby.mrb_value = undefined;
    var notifications_array: mruby.mrb_value = undefined;
    var subscriptions_array: mruby.mrb_value = undefined;

    // Get arguments: 13 required + 5 optional
    // S=string, o=object (bool), i=integer, |=optional separator, A=array
    _ = mruby.mrb_get_args(mrb, "SSSSSiooSoSSS|oooAA", &repository_val, &destination_val, &revision_val, &checkout_branch_val, &remote_val, &depth_val, &enable_checkout_val, &enable_submodules_val, &ssh_key_val, &enable_strict_host_key_checking_val, &user_val, &group_val, &action_val, &only_if_block, &not_if_block, &ignore_failure_val, &notifications_array, &subscriptions_array);

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
        common.deinit(allocator);
        return mruby.mrb_nil_value();
    };

    return mruby.mrb_nil_value();
}
