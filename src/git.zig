const std = @import("std");

const log = std.log.scoped(.git);

const c = @cImport({
    @cInclude("git2.h");
});

pub const Error = error{
    InitFailed,
    OptionsInitFailed,
    CloneFailed,
    ClientShutdown,
};

pub const CloneOptions = struct {
    /// When false we perform a bare clone (no checkout).
    checkout_workdir: bool = true,
    /// Optional branch to checkout after clone.
    branch: ?[]const u8 = null,
    /// Whether to emit progress similar to `git clone`.
    show_progress: bool = true,
};

pub const Client = struct {
    initialized: bool = true,

    pub fn init() !Client {
        const init_count = c.git_libgit2_init();
        if (init_count < 0) {
            logLibGit2Error(init_count);
            return Error.InitFailed;
        }
        return .{};
    }

    pub fn deinit(self: *Client) void {
        if (!self.initialized) return;
        _ = c.git_libgit2_shutdown();
        self.initialized = false;
    }

    pub fn clone(self: *Client, allocator: std.mem.Allocator, url: []const u8, destination: []const u8, options: CloneOptions) !void {
        if (!self.initialized) return Error.ClientShutdown;
        try cloneInternal(allocator, url, destination, options);
    }
};

pub fn cloneOnce(allocator: std.mem.Allocator, url: []const u8, destination: []const u8, options: CloneOptions) !void {
    var client = try Client.init();
    defer client.deinit();
    try client.clone(allocator, url, destination, options);
}

fn cloneInternal(allocator: std.mem.Allocator, url: []const u8, destination: []const u8, options: CloneOptions) !void {
    const url_c = try dupZ(allocator, url);
    defer allocator.free(url_c);

    const destination_c = try dupZ(allocator, destination);
    defer allocator.free(destination_c);

    var clone_opts: c.git_clone_options = undefined;
    try check(c.git_clone_options_init(&clone_opts, c.GIT_CLONE_OPTIONS_VERSION), Error.OptionsInitFailed);

    if (!options.checkout_workdir) {
        clone_opts.checkout_opts.checkout_strategy = c.GIT_CHECKOUT_NONE;
    }

    var branch_storage: ?[:0]u8 = null;
    if (options.branch) |branch_name| {
        branch_storage = try dupZ(allocator, branch_name);
        clone_opts.checkout_branch = branch_storage.?.ptr;
    }
    defer if (branch_storage) |buf| allocator.free(buf);

    var progress_ctx = ProgressContext{ .show = options.show_progress };
    if (options.show_progress) installProgressCallbacks(&clone_opts, &progress_ctx);

    var repo_ptr: ?*c.git_repository = null;
    const code = c.git_clone(&repo_ptr, url_c.ptr, destination_c.ptr, &clone_opts);
    if (code != 0) {
        logLibGit2Error(code);
        return Error.CloneFailed;
    }

    if (repo_ptr) |repo| {
        defer c.git_repository_free(repo);
    }

    log.info("Cloned {s} -> {s}", .{ url, destination });
}

fn check(code: c_int, err: Error) Error!void {
    if (code == 0) return;
    logLibGit2Error(code);
    return err;
}

fn logLibGit2Error(code: c_int) void {
    const err_ptr = c.git_error_last();
    if (err_ptr != null) {
        const err = err_ptr.*;
        if (err.message != null) {
            const msg_ptr: [*:0]const u8 = @ptrCast(err.message);
            const msg = std.mem.span(msg_ptr);
            log.err("libgit2 ({d}): {s}", .{ code, msg });
            return;
        }
    }
    log.err("libgit2 ({d}): <no details>", .{ code });
}

/// Credential callback used by libgit2 for both SSH and HTTPS.
///
/// We intentionally rely on libgit2's built-in discovery mechanisms
/// (SSH agent, default platform creds) instead of implementing our
/// own key loading logic.
fn credentialsCallback(
    out: ?*?*c.git_credential,
    url: [*c]const u8,
    username_from_url: [*c]const u8,
    allowed_types: c_uint,
    payload: ?*anyopaque,
) callconv(.c) c_int {
    _ = url;
    _ = payload;

    const types: c_uint = allowed_types;

    // Decide which username to use: prefer the one coming from URL,
    // otherwise fall back to the conventional "git" user.
    const default_user: [*c]const u8 = "git";
    const user: [*c]const u8 = blk: {
        // libgit2 may pass NULL or an empty string.
        if (username_from_url == null) break :blk default_user;
        if (username_from_url[0] == 0) break :blk default_user;
        break :blk username_from_url;
    };

    // Prefer SSH key-based auth when allowed. libgit2 will talk to
    // the SSH agent and discover keys; we do not touch ~/.ssh ourselves.
    if ((types & c.GIT_CREDTYPE_SSH_KEY) != 0) {
        return c.git_credential_ssh_key_from_agent(out, user);
    }

    // For HTTPS, try platform default credentials (Keychain, etc.).
    if ((types & c.GIT_CREDTYPE_DEFAULT) != 0) {
        return c.git_credential_default_new(out);
    }

    // Some servers ask first for just a username.
    if ((types & c.GIT_CREDTYPE_USERNAME) != 0) {
        return c.git_credential_username_new(out, user);
    }

    // No supported credential type – tell libgit2 auth failed.
    return c.GIT_EAUTH;
}

fn dupZ(allocator: std.mem.Allocator, input: []const u8) ![:0]u8 {
    var buf = try allocator.alloc(u8, input.len + 1);
    @memcpy(buf[0..input.len], input);
    buf[input.len] = 0;
    return buf[0..input.len :0];
}

test "libgit2 client init/shutdown" {
    var client = try Client.init();
    defer client.deinit();
    try std.testing.expect(client.initialized);
}

fn installProgressCallbacks(opts: *c.git_clone_options, ctx: *ProgressContext) void {
    // Progress callbacks
    opts.fetch_opts.callbacks.transfer_progress = transferProgressCb;
    opts.fetch_opts.callbacks.sideband_progress = sidebandProgressCb;
    opts.fetch_opts.callbacks.payload = ctx;
    opts.checkout_opts.progress_cb = checkoutProgressCb;
    opts.checkout_opts.progress_payload = ctx;

    // Authentication callbacks (SSH/HTTPS). This lets libgit2
    // discover credentials via SSH agent / platform helpers.
    opts.fetch_opts.callbacks.credentials = credentialsCallback;
}

fn transferProgressCb(stats: ?*const c.git_transfer_progress, payload: ?*anyopaque) callconv(.c) c_int {
    if (stats == null or payload == null) return 0;
    const ctx: *ProgressContext = @ptrCast(payload.?);
    if (!ctx.show) return 0;

    const data = stats.?;
    if (data.total_objects == 0) return 0;

    const percent: u8 = @intCast((data.received_objects * 100) / data.total_objects);
    if (percent == ctx.last_fetch_percent) return 0;
    ctx.last_fetch_percent = percent;

    std.debug.print("\rReceiving objects: {d}% ({d}/{d})", .{ percent, data.received_objects, data.total_objects });
    if (percent == 100) {
        std.debug.print("\nResolving deltas: {d}/{d}\n", .{ data.indexed_deltas, data.total_deltas });
    }
    return 0;
}

fn checkoutProgressCb(path: [*c]const u8, completed: usize, total: usize, payload: ?*anyopaque) callconv(.c) void {
    _ = path;
    if (payload == null or total == 0) return;
    const ctx: *ProgressContext = @ptrCast(payload.?);
    if (!ctx.show) return;

    const percent: u8 = @intCast((completed * 100) / total);
    if (percent == ctx.last_checkout_percent) return;
    ctx.last_checkout_percent = percent;

    std.debug.print("\rCheckout files: {d}% ({d}/{d})", .{ percent, completed, total });
    if (percent == 100) std.debug.print("\n", .{});
}

fn sidebandProgressCb(str: [*c]const u8, len: c_int, payload: ?*anyopaque) callconv(.c) c_int {
    _ = payload;
    if (len <= 0 or str == null) return 0;
    const message = str[0..@intCast(len)];
    std.debug.print("{s}", .{message});
    return 0;
}

const ProgressContext = struct {
    show: bool = true,
    last_fetch_percent: u8 = 101,
    last_checkout_percent: u8 = 101,
};

/// Generate unified diff between two strings
pub fn diffStrings(allocator: std.mem.Allocator, old_content: []const u8, new_content: []const u8, old_path: []const u8, new_path: []const u8) ![]const u8 {
    var client = try Client.init();
    defer client.deinit();
    
    const old_path_c = try dupZ(allocator, old_path);
    defer allocator.free(old_path_c);
    
    const new_path_c = try dupZ(allocator, new_path);
    defer allocator.free(new_path_c);
    
    // Create diff from buffers using patch generation
    var patch: ?*c.git_patch = null;
    var diff_opts: c.git_diff_options = undefined;
    _ = c.git_diff_options_init(&diff_opts, c.GIT_DIFF_OPTIONS_VERSION);
    diff_opts.context_lines = 3;
    
    const code = c.git_patch_from_buffers(
        &patch,
        old_content.ptr, old_content.len, old_path_c.ptr,
        new_content.ptr, new_content.len, new_path_c.ptr,
        &diff_opts
    );
    
    if (code != 0) {
        logLibGit2Error(code);
        return error.DiffFailed;
    }
    
    defer if (patch) |p| c.git_patch_free(p);
    
    if (patch == null) {
        return try allocator.dupe(u8, "");
    }
    
    // Format patch as string
    var buf: c.git_buf = .{ .ptr = null, .size = 0 };
    defer c.git_buf_dispose(&buf);
    
    const patch_code = c.git_patch_to_buf(&buf, patch);
    if (patch_code != 0) {
        logLibGit2Error(patch_code);
        return error.PatchFailed;
    }
    
    if (buf.ptr == null or buf.size == 0) {
        return try allocator.dupe(u8, "");
    }
    
    const patch_slice = buf.ptr[0..buf.size];
    return try allocator.dupe(u8, patch_slice);
}
