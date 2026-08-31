const std = @import("std");
const mruby = @import("mruby.zig");
pub const notification = @import("notification.zig");
const builtin = @import("builtin");
const global_io = @import("global_io.zig");

// Guards (only_if/not_if) run arbitrary shell commands; a stuck one (e.g.
// `only_if "sleep 99999"`) must not hang provisioning forever. Bound them with
// a hard timeout that escalates SIGTERM -> SIGKILL on the process group.
const GUARD_TIMEOUT_S: u32 = 300;
const GUARD_POLL_INTERVAL_MS: i64 = 50;
const GUARD_TERM_GRACE_MS: i64 = 2000;
const GUARD_REAP_GRACE_MS: i64 = 2000;

// --- Provision error detail context ----------------------------------------
// Whenever a resource can provide more context than the raw Zig error name,
// capture that friendly summary into a thread-local buffer. The top-level
// apply loop and the agent callback can then show details like the raised Ruby
// exception, failed URL, HTTP status, or checksum mismatch.
const PROVISION_ERROR_DETAIL_BUF_SIZE = 1024;
const PROVISION_ERROR_TRACE_BUF_SIZE = 4 * 1024;
const COMMAND_STDERR_SUMMARY_SIZE = 768;
const COMMAND_OUTPUT_CAPTURE_SIZE = 8 * 1024;
threadlocal var provision_error_detail_buf: [PROVISION_ERROR_DETAIL_BUF_SIZE]u8 = undefined;
threadlocal var provision_error_detail_len: usize = 0;
threadlocal var provision_error_trace_buf: [PROVISION_ERROR_TRACE_BUF_SIZE]u8 = undefined;
threadlocal var provision_error_trace_len: usize = 0;
threadlocal var command_term: ?std.process.Child.Term = null;
threadlocal var command_timeout_s: ?u32 = null;
threadlocal var command_stdout_buf: [COMMAND_OUTPUT_CAPTURE_SIZE]u8 = undefined;
threadlocal var command_stdout_len: usize = 0;
threadlocal var command_stderr_buf: [COMMAND_OUTPUT_CAPTURE_SIZE]u8 = undefined;
threadlocal var command_stderr_len: usize = 0;

pub const CommandDiagnostic = struct {
    term: ?std.process.Child.Term,
    timeout_s: ?u32,
    stdout: ?[]const u8,
    stderr: ?[]const u8,
};

pub const CommandDiagnosticSnapshot = struct {
    term: ?std.process.Child.Term = null,
    timeout_s: ?u32 = null,
    stdout: [COMMAND_OUTPUT_CAPTURE_SIZE]u8 = undefined,
    stdout_len: usize = 0,
    stderr: [COMMAND_OUTPUT_CAPTURE_SIZE]u8 = undefined,
    stderr_len: usize = 0,
};

pub fn clearProvisionErrorDetail() void {
    provision_error_detail_len = 0;
    provision_error_trace_len = 0;
    command_term = null;
    command_timeout_s = null;
    command_stdout_len = 0;
    command_stderr_len = 0;
}

pub fn getProvisionErrorDetail() ?[]const u8 {
    if (provision_error_detail_len == 0) return null;
    return provision_error_detail_buf[0..provision_error_detail_len];
}

pub fn getProvisionErrorTrace() ?[]const u8 {
    if (provision_error_trace_len == 0) return null;
    return provision_error_trace_buf[0..provision_error_trace_len];
}

pub fn recordProvisionErrorDetailSlice(detail: []const u8) void {
    const n = @min(detail.len, provision_error_detail_buf.len);
    @memcpy(provision_error_detail_buf[0..n], detail[0..n]);
    provision_error_detail_len = n;
}

pub fn recordProvisionErrorDetail(comptime fmt: []const u8, args: anytype) void {
    const written = std.fmt.bufPrint(&provision_error_detail_buf, fmt, args) catch blk: {
        const fallback = "provision error (message truncated)";
        @memcpy(provision_error_detail_buf[0..fallback.len], fallback);
        break :blk provision_error_detail_buf[0..fallback.len];
    };
    provision_error_detail_len = written.len;
}

/// Translate internal Zig errors into stable, familiar operator-facing text.
/// Structured results may keep the original error name as a machine-readable
/// code, but terminal output should read like the underlying OS/tool error.
pub fn userFacingError(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "No such file or directory",
        error.NotDir => "Not a directory",
        error.IsDir => "Is a directory",
        error.AccessDenied, error.PermissionDenied => "Permission denied",
        error.ReadOnlyFileSystem => "Read-only file system",
        error.PathAlreadyExists => "File exists",
        error.DirNotEmpty => "Directory not empty",
        error.NameTooLong => "File name too long",
        error.SymLinkLoop => "Too many levels of symbolic links",
        error.NoSpaceLeft => "No space left on device",
        error.DiskQuota => "Disk quota exceeded",
        error.FileTooBig => "File too large",
        error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => "Too many open files",
        error.DeviceBusy => "Device or resource busy",
        error.CommandFailed => "Command failed",
        error.CommandTimedOut => "Command timed out",
        error.CommandKilled => "Command terminated",
        error.CommandStopped => "Command stopped",
        error.RubyBlockFailed => "Ruby block failed",
        error.DownloadFailed => "Download failed",
        error.ChecksumMismatch => "Checksum mismatch",
        else => @errorName(err),
    };
}

test "internal errors have operator-facing descriptions" {
    try std.testing.expectEqualStrings("No such file or directory", userFacingError(error.FileNotFound));
    try std.testing.expectEqualStrings("Not a directory", userFacingError(error.NotDir));
    try std.testing.expectEqualStrings("Permission denied", userFacingError(error.AccessDenied));
    try std.testing.expectEqualStrings("Command failed", userFacingError(error.CommandFailed));
}

/// Record a process failure with the exit status and a bounded, single-line
/// stderr summary suitable for both the progress display and structured result.
pub fn recordCommandFailure(term: std.process.Child.Term, stderr: []const u8) void {
    recordCommandFailureOutput(term, "", stderr);
}

pub fn recordCommandFailureOutput(term: std.process.Child.Term, stdout: []const u8, stderr: []const u8) void {
    storeCommandDiagnostic(term, null, stdout, stderr);
    var stderr_buf: [COMMAND_STDERR_SUMMARY_SIZE]u8 = undefined;
    const stderr_summary = normalizeCommandDiagnostic(stderr, &stderr_buf);

    switch (term) {
        .exited => |code| if (stderr_summary.len > 0)
            recordProvisionErrorDetail("command exited with status {d}; stderr: {s}", .{ code, stderr_summary })
        else
            recordProvisionErrorDetail("command exited with status {d}", .{code}),
        .signal => |signal| if (stderr_summary.len > 0)
            recordProvisionErrorDetail("command terminated by signal {d}; stderr: {s}", .{ @intFromEnum(signal), stderr_summary })
        else
            recordProvisionErrorDetail("command terminated by signal {d}", .{@intFromEnum(signal)}),
        .stopped => |signal| if (stderr_summary.len > 0)
            recordProvisionErrorDetail("command stopped by signal {d}; stderr: {s}", .{ @intFromEnum(signal), stderr_summary })
        else
            recordProvisionErrorDetail("command stopped by signal {d}", .{@intFromEnum(signal)}),
        .unknown => |status| if (stderr_summary.len > 0)
            recordProvisionErrorDetail("command returned unknown status {d}; stderr: {s}", .{ status, stderr_summary })
        else
            recordProvisionErrorDetail("command returned unknown status {d}", .{status}),
    }
}

pub fn recordCommandTimeout(seconds: u32, stderr: []const u8) void {
    recordCommandTimeoutOutput(seconds, "", stderr);
}

pub fn recordCommandTimeoutOutput(seconds: u32, stdout: []const u8, stderr: []const u8) void {
    storeCommandDiagnostic(null, seconds, stdout, stderr);
    var stderr_buf: [COMMAND_STDERR_SUMMARY_SIZE]u8 = undefined;
    const stderr_summary = normalizeCommandDiagnostic(stderr, &stderr_buf);
    if (stderr_summary.len > 0) {
        recordProvisionErrorDetail("command timed out after {d}s; stderr: {s}", .{ seconds, stderr_summary });
    } else {
        recordProvisionErrorDetail("command timed out after {d}s", .{seconds});
    }
}

fn copyCommandOutput(destination: []u8, input: []const u8) usize {
    const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);
    const copy_len = @min(destination.len, trimmed.len);
    @memcpy(destination[0..copy_len], trimmed[0..copy_len]);
    return copy_len;
}

fn storeCommandDiagnostic(term: ?std.process.Child.Term, timeout_s: ?u32, stdout: []const u8, stderr: []const u8) void {
    command_term = term;
    command_timeout_s = timeout_s;
    command_stdout_len = copyCommandOutput(&command_stdout_buf, stdout);
    command_stderr_len = copyCommandOutput(&command_stderr_buf, stderr);
}

pub fn getCommandDiagnostic() ?CommandDiagnostic {
    if (command_term == null and command_timeout_s == null and command_stdout_len == 0 and command_stderr_len == 0) return null;
    return .{
        .term = command_term,
        .timeout_s = command_timeout_s,
        .stdout = if (command_stdout_len > 0) command_stdout_buf[0..command_stdout_len] else null,
        .stderr = if (command_stderr_len > 0) command_stderr_buf[0..command_stderr_len] else null,
    };
}

pub fn snapshotCommandDiagnostic() CommandDiagnosticSnapshot {
    var snapshot = CommandDiagnosticSnapshot{
        .term = command_term,
        .timeout_s = command_timeout_s,
        .stdout_len = command_stdout_len,
        .stderr_len = command_stderr_len,
    };
    @memcpy(snapshot.stdout[0..command_stdout_len], command_stdout_buf[0..command_stdout_len]);
    @memcpy(snapshot.stderr[0..command_stderr_len], command_stderr_buf[0..command_stderr_len]);
    return snapshot;
}

pub fn restoreCommandDiagnostic(snapshot: *const CommandDiagnosticSnapshot) void {
    command_term = snapshot.term;
    command_timeout_s = snapshot.timeout_s;
    command_stdout_len = snapshot.stdout_len;
    command_stderr_len = snapshot.stderr_len;
    @memcpy(command_stdout_buf[0..command_stdout_len], snapshot.stdout[0..command_stdout_len]);
    @memcpy(command_stderr_buf[0..command_stderr_len], snapshot.stderr[0..command_stderr_len]);
}

fn normalizeCommandDiagnostic(input: []const u8, output: []u8) []const u8 {
    const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);
    if (trimmed.len == 0 or output.len == 0) return "";

    var output_len: usize = 0;
    var pending_space = false;
    var truncated = false;
    for (trimmed) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            pending_space = output_len > 0;
            continue;
        }

        const required = @as(usize, @intFromBool(pending_space)) + 1;
        const reserve: usize = if (output.len >= 3) 3 else 0;
        if (output_len + required > output.len - reserve) {
            truncated = true;
            break;
        }
        if (pending_space) {
            output[output_len] = ' ';
            output_len += 1;
            pending_space = false;
        }
        output[output_len] = byte;
        output_len += 1;
    }

    if (truncated and output.len - output_len >= 3) {
        @memcpy(output[output_len..][0..3], "...");
        output_len += 3;
    }
    return output[0..output_len];
}

/// Capture a friendly summary of an mruby exception into the thread-local
/// error detail buffer. If `prefix` is non-null the buffer stores
/// "{prefix}: {ClassName}: {message}"; otherwise just "{ClassName}: {message}".
pub fn recordProvisionException(mrb: *mruby.mrb_state, exc: mruby.mrb_value, prefix: ?[]const u8) void {
    var summary_buf: [200]u8 = undefined;
    mruby.zig_mrb_exc_summary(mrb, exc, &summary_buf, summary_buf.len);
    const summary = std.mem.sliceTo(&summary_buf, 0);

    const written = if (prefix) |p|
        std.fmt.bufPrint(&provision_error_detail_buf, "{s}: {s}", .{ p, summary }) catch blk: {
            const fallback = "provision error (message truncated)";
            @memcpy(provision_error_detail_buf[0..fallback.len], fallback);
            break :blk provision_error_detail_buf[0..fallback.len];
        }
    else
        std.fmt.bufPrint(&provision_error_detail_buf, "{s}", .{summary}) catch blk: {
            const fallback = "provision error (message truncated)";
            @memcpy(provision_error_detail_buf[0..fallback.len], fallback);
            break :blk provision_error_detail_buf[0..fallback.len];
        };
    provision_error_detail_len = written.len;
    captureProvisionBacktrace(mrb, exc);
}

fn captureProvisionBacktrace(mrb: *mruby.mrb_state, exc: mruby.mrb_value) void {
    provision_error_trace_len = 0;
    const backtrace = switch (mruby.callProtected(mrb, exc, "backtrace", &.{})) {
        .ok => |value| value,
        .raised => return,
    };
    if (mruby.zig_mrb_array_p(backtrace) == 0) return;

    const line_count: usize = @intCast(@max(mruby.mrb_ary_len(mrb, backtrace), 0));
    for (0..@min(line_count, 32)) |index| {
        const value = mruby.mrb_ary_ref(mrb, backtrace, @intCast(index));
        if (mruby.zig_mrb_string_p(value) == 0) continue;
        const line = std.mem.span(mruby.mrb_str_to_cstr(mrb, value));
        const remaining = provision_error_trace_buf.len - provision_error_trace_len;
        if (remaining <= 1) break;
        const copy_len = @min(line.len, remaining - 1);
        @memcpy(provision_error_trace_buf[provision_error_trace_len..][0..copy_len], line[0..copy_len]);
        provision_error_trace_len += copy_len;
        provision_error_trace_buf[provision_error_trace_len] = '\n';
        provision_error_trace_len += 1;
        if (copy_len < line.len) break;
    }
    if (provision_error_trace_len > 0 and provision_error_trace_buf[provision_error_trace_len - 1] == '\n') {
        provision_error_trace_len -= 1;
    }
}

/// Result of applying a resource
pub const ApplyResult = struct {
    was_updated: bool,
    action: []const u8,
    skip_reason: ?[]const u8 = null, // null means "up to date", non-null means skipped with reason
    output: ?[]const u8 = null, // resource output: execute stdout/stderr, file/template diff, etc.
};

/// Common properties shared by all resources
pub const CommonProps = struct {
    // Conditional execution (guards) - can be either Ruby block or shell command string
    only_if_block: ?mruby.mrb_value = null,
    only_if_command: ?[]const u8 = null, // Shell command string
    not_if_block: ?mruby.mrb_value = null,
    not_if_command: ?[]const u8 = null, // Shell command string

    // Error handling
    ignore_failure: bool = false,

    // Notifications
    notifications: std.ArrayList(notification.Notification),

    // Subscriptions (will be converted to notifications during processing)
    subscriptions: std.ArrayList(notification.Notification),

    // mruby state for calling blocks
    mrb_state: ?*mruby.mrb_state = null,

    pub fn init(allocator: std.mem.Allocator) CommonProps {
        return .{
            .notifications = std.ArrayList(notification.Notification).initCapacity(allocator, 0) catch std.ArrayList(notification.Notification).empty,
            .subscriptions = std.ArrayList(notification.Notification).initCapacity(allocator, 0) catch std.ArrayList(notification.Notification).empty,
        };
    }

    pub fn deinit(self: *CommonProps, allocator: std.mem.Allocator) void {
        // Unregister blocks from GC
        if (self.mrb_state) |mrb| {
            if (self.only_if_block) |block| {
                mruby.mrb_gc_unregister(mrb, block);
            }
            if (self.not_if_block) |block| {
                mruby.mrb_gc_unregister(mrb, block);
            }
        }

        // Free string commands
        if (self.only_if_command) |cmd| allocator.free(cmd);
        if (self.not_if_command) |cmd| allocator.free(cmd);

        // Free notifications
        for (self.notifications.items) |notif| {
            notif.deinit(allocator);
        }
        self.notifications.deinit(allocator);

        // Free subscriptions
        for (self.subscriptions.items) |sub| {
            sub.deinit(allocator);
        }
        self.subscriptions.deinit(allocator);
    }

    /// Evaluate guards (only_if/not_if) to determine if resource should run
    /// Returns the reason if skipped, null if should run
    /// Optionally runs guard commands as specified user/group
    pub fn shouldRun(self: CommonProps, user: ?[]const u8, group: ?[]const u8) !?[]const u8 {
        const mrb = self.mrb_state orelse return null;

        // Evaluate only_if (must be true to run)
        // Check command string first (higher priority)
        if (self.only_if_command) |cmd| {
            // Execute shell command - exit code 0 means true
            const success = try executeShellCommand(cmd, user, group);
            if (!success) {
                return "skipped due to only_if"; // command failed (non-zero exit)
            }
        } else if (self.only_if_block) |block| {
            const result = switch (mruby.callProtected(mrb, block, "call", &.{})) {
                .ok => |value| value,
                .raised => |exc| {
                    recordProvisionException(mrb, exc, "only_if block raised");
                    mruby.zig_mrb_print_exc(mrb, exc);
                    return error.MRubyException;
                },
            };

            if (!mruby.mrb_test(result)) {
                return "skipped due to only_if"; // only_if returned falsy
            }
        }

        // Evaluate not_if (must be false to run)
        // Check command string first (higher priority)
        if (self.not_if_command) |cmd| {
            // Execute shell command - exit code 0 means true
            const success = try executeShellCommand(cmd, user, group);
            if (success) {
                return "skipped due to not_if"; // command succeeded (exit 0)
            }
        } else if (self.not_if_block) |block| {
            const result = switch (mruby.callProtected(mrb, block, "call", &.{})) {
                .ok => |value| value,
                .raised => |exc| {
                    recordProvisionException(mrb, exc, "not_if block raised");
                    mruby.zig_mrb_print_exc(mrb, exc);
                    return error.MRubyException;
                },
            };

            if (mruby.mrb_test(result)) {
                return "skipped due to not_if"; // not_if returned truthy
            }
        }

        return null; // Should run
    }

    /// Execute a shell command and return true if exit code is 0
    /// Optionally runs as specified user/group
    fn executeShellCommand(command: []const u8, user: ?[]const u8, group: ?[]const u8) !bool {
        const io = global_io.io();

        // Resolve user/group to uid/gid before spawning (same logic as execute resource)
        var uid: ?std.posix.uid_t = null;
        var gid: ?std.posix.gid_t = null;
        if (user != null or group != null) {
            const c = @cImport({
                @cInclude("pwd.h");
                @cInclude("grp.h");
            });

            // Get user info if user is specified
            if (user) |username| {
                const username_z = std.posix.toPosixPath(username) catch |err| {
                    const logger = @import("logger.zig");
                    logger.warn("guard: failed to convert username '{s}': {}", .{ username, err });
                    return error.UserInfoFailed;
                };

                const pwd = c.getpwnam(&username_z);
                if (pwd == null) {
                    const logger = @import("logger.zig");
                    logger.warn("guard: user '{s}' not found", .{username});
                    return error.UserNotFound;
                }

                uid = @intCast(pwd.*.pw_uid);
                gid = @intCast(pwd.*.pw_gid);
            }

            // Override with group if specified
            if (group) |groupname| {
                const groupname_z = std.posix.toPosixPath(groupname) catch |err| {
                    const logger = @import("logger.zig");
                    logger.warn("guard: failed to convert groupname '{s}': {}", .{ groupname, err });
                    return error.GroupInfoFailed;
                };

                const grp = c.getgrnam(&groupname_z);
                if (grp == null) {
                    const logger = @import("logger.zig");
                    logger.warn("guard: group '{s}' not found", .{groupname});
                    return error.GroupNotFound;
                }

                gid = @intCast(grp.*.gr_gid);
            }
        }

        // A pre-exec failure is reported by spawn itself (which reaps the
        // forked child); stdio is .ignore, so there are no parent-held pipes.
        const child = try std.process.spawn(io, .{
            .argv = &[_][]const u8{ "/bin/sh", "-c", command },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            .pgid = 0, // own process group, so a timeout can signal the whole tree
            .uid = uid,
            .gid = gid,
        });

        const child_pid = child.id orelse return error.SpawnFailed;
        const term = waitGuardWithTimeout(child_pid);

        return switch (term) {
            .exited => |code| code == 0,
            else => false, // signalled / timed out / unknown => treat as non-zero
        };
    }

    fn termFromStatus(status: u32) std.process.Child.Term {
        return if (std.posix.W.IFEXITED(status))
            .{ .exited = std.posix.W.EXITSTATUS(status) }
        else if (std.posix.W.IFSIGNALED(status))
            .{ .signal = std.posix.W.TERMSIG(status) }
        else if (std.posix.W.IFSTOPPED(status))
            .{ .stopped = std.posix.W.STOPSIG(status) }
        else
            .{ .unknown = status };
    }

    /// Best-effort non-blocking reap for an already-dead child.
    fn reapGuardChild(pid: std.posix.pid_t) void {
        const io = global_io.io();
        const deadline = std.Io.Timestamp.now(io, .real).toMilliseconds() + GUARD_REAP_GRACE_MS;
        while (std.Io.Timestamp.now(io, .real).toMilliseconds() < deadline) {
            var status: c_int = 0;
            const res = std.c.waitpid(pid, &status, std.posix.W.NOHANG);
            if (res > 0) return;
            io.sleep(.fromNanoseconds(GUARD_POLL_INTERVAL_MS * std.time.ns_per_ms), .awake) catch {};
        }
    }

    /// Wait for a guard child with a hard timeout. Guards ignore their stdio so
    /// there are no pipes to drain: poll for exit, and if the deadline passes
    /// escalate SIGTERM -> SIGKILL on the process group, then reap. Never blocks
    /// indefinitely — if the child is unresponsive even to SIGKILL we abandon it.
    fn waitGuardWithTimeout(pid: std.posix.pid_t) std.process.Child.Term {
        const logger = @import("logger.zig");
        const io = global_io.io();
        const deadline = std.Io.Timestamp.now(io, .real).toMilliseconds() + @as(i64, GUARD_TIMEOUT_S) * std.time.ms_per_s;
        var timed_out = false;
        var kill_deadline_ms: ?i64 = null;
        var give_up_deadline_ms: ?i64 = null;

        while (true) {
            var status: c_int = 0;
            const res = std.c.waitpid(pid, &status, std.posix.W.NOHANG);
            if (res > 0) return termFromStatus(@bitCast(status));

            const now = std.Io.Timestamp.now(io, .real).toMilliseconds();
            if (!timed_out) {
                if (now >= deadline) {
                    timed_out = true;
                    logger.warn("guard: command timed out after {d}s; terminating", .{GUARD_TIMEOUT_S});
                    std.posix.kill(-pid, std.posix.SIG.TERM) catch {};
                    kill_deadline_ms = now + GUARD_TERM_GRACE_MS;
                    give_up_deadline_ms = now + GUARD_TERM_GRACE_MS + GUARD_REAP_GRACE_MS;
                }
            } else {
                if (kill_deadline_ms) |kd| {
                    if (now >= kd) {
                        kill_deadline_ms = null;
                        std.posix.kill(-pid, std.posix.SIG.KILL) catch {};
                    }
                }
                if (give_up_deadline_ms) |gd| {
                    if (now >= gd) {
                        logger.warn("guard: child {d} unresponsive after SIGKILL; abandoning", .{pid});
                        return .{ .unknown = 0 };
                    }
                }
            }
            io.sleep(.fromNanoseconds(GUARD_POLL_INTERVAL_MS * std.time.ns_per_ms), .awake) catch {};
        }
    }

    /// Register blocks with GC to prevent collection
    pub fn protectBlocks(self: *CommonProps) void {
        const mrb = self.mrb_state orelse return;

        if (self.only_if_block) |block| {
            mruby.mrb_gc_register(mrb, block);
        }
        if (self.not_if_block) |block| {
            mruby.mrb_gc_register(mrb, block);
        }
    }
};

/// Helper for parsing common arguments from Ruby
pub const CommonArgs = struct {
    only_if_block: ?mruby.mrb_value = null,
    not_if_block: ?mruby.mrb_value = null,
    notifications_array: ?mruby.mrb_value = null,

    /// Parse common optional arguments from mruby
    /// Expected format after resource-specific args: |ooA
    /// - only_if: optional block
    /// - not_if: optional block
    /// - notifications: optional array
    pub fn parse(_: *mruby.mrb_state, _: i32) !CommonArgs {
        // Placeholder (kept for future use). Most callers now use fillCommonFromRuby.
        return CommonArgs{};
    }
};

/// Populate CommonProps from Ruby args (only_if/not_if/ignore_failure/notifications/subscriptions) and protect blocks
pub fn fillCommonFromRuby(
    common: *CommonProps,
    mrb: *mruby.mrb_state,
    only_if_val: mruby.mrb_value,
    not_if_val: mruby.mrb_value,
    ignore_failure_val: mruby.mrb_value,
    notifications_val: mruby.mrb_value,
    subscriptions_val: mruby.mrb_value,
    allocator: std.mem.Allocator,
) void {
    const logger = @import("logger.zig");
    logger.debug("fillCommonFromRuby called", .{});
    logger.debug("only_if_val test: {}", .{mruby.mrb_test(only_if_val)});

    // Attach mruby state
    common.mrb_state = mrb;
    common.ignore_failure = mruby.mrb_test(ignore_failure_val);

    // Parse only_if - can be string (shell command) or proc (Ruby block)
    if (mruby.mrb_test(only_if_val)) {
        const is_string = mruby.zig_mrb_string_p(only_if_val) != 0;

        if (is_string) {
            // String guard - execute as shell command
            const cmd_cstr = mruby.mrb_str_to_cstr(mrb, only_if_val);
            const cmd_str = std.mem.span(cmd_cstr);
            logger.debug("only_if command: {s}", .{cmd_str});
            common.only_if_command = allocator.dupe(u8, cmd_str) catch |err| blk: {
                logger.warn("Failed to allocate memory for only_if command: {}", .{err});
                logger.warn("Guard 'only_if' will be ignored - this may cause unexpected resource execution!", .{});
                break :blk null;
            };
        } else {
            // Proc or other callable - store for later evaluation
            logger.debug("only_if is block/proc", .{});
            common.only_if_block = only_if_val;
        }
    }

    // Parse not_if - can be string (shell command) or proc (Ruby block)
    if (mruby.mrb_test(not_if_val)) {
        const is_string = mruby.zig_mrb_string_p(not_if_val) != 0;

        if (is_string) {
            // String guard - execute as shell command
            const cmd_cstr = mruby.mrb_str_to_cstr(mrb, not_if_val);
            const cmd_str = std.mem.span(cmd_cstr);
            common.not_if_command = allocator.dupe(u8, cmd_str) catch |err| blk: {
                logger.warn("Failed to allocate memory for not_if command: {}", .{err});
                logger.warn("Guard 'not_if' will be ignored - this may cause unexpected resource execution!", .{});
                break :blk null;
            };
        } else {
            // Proc or other callable - store for later evaluation
            common.not_if_block = not_if_val;
        }
    }

    // Parse notifications array if provided: each item is [target, action, timing]
    if (mruby.mrb_test(notifications_val)) {
        const arr_len = mruby.mrb_ary_len(mrb, notifications_val);
        var i: mruby.mrb_int = 0;
        while (i < arr_len) : (i += 1) {
            const notif_arr = mruby.mrb_ary_ref(mrb, notifications_val, i);

            const target_val = mruby.mrb_ary_ref(mrb, notif_arr, 0);
            const action_val_n = mruby.mrb_ary_ref(mrb, notif_arr, 1);
            const timing_val = mruby.mrb_ary_ref(mrb, notif_arr, 2);

            const target_cstr = mruby.mrb_str_to_cstr(mrb, target_val);
            const action_cstr_n = mruby.mrb_str_to_cstr(mrb, action_val_n);
            const timing_cstr = mruby.mrb_str_to_cstr(mrb, timing_val);

            const target = allocator.dupe(u8, std.mem.span(target_cstr)) catch |err| {
                logger.warn("Failed to allocate notification target: {}", .{err});
                continue;
            };
            const action_name = allocator.dupe(u8, std.mem.span(action_cstr_n)) catch |err| {
                allocator.free(target);
                logger.warn("Failed to allocate notification action: {}", .{err});
                continue;
            };
            const timing_str = std.mem.span(timing_cstr);

            const timing: notification.Timing = if (std.mem.eql(u8, timing_str, "immediate"))
                .immediate
            else
                .delayed;

            const notif = notification.Notification{
                .target_resource_id = target,
                .action = .{ .action_name = action_name },
                .timing = timing,
            };

            common.notifications.append(allocator, notif) catch |err| {
                logger.warn("Failed to append notification: {}", .{err});
                allocator.free(target);
                allocator.free(action_name);
                continue;
            };
        }
    }

    // Parse subscriptions array if provided: each item is [target, action, timing]
    if (mruby.mrb_test(subscriptions_val)) {
        const arr_len = mruby.mrb_ary_len(mrb, subscriptions_val);
        var i: mruby.mrb_int = 0;
        while (i < arr_len) : (i += 1) {
            const sub_arr = mruby.mrb_ary_ref(mrb, subscriptions_val, i);

            const target_val = mruby.mrb_ary_ref(mrb, sub_arr, 0);
            const action_val_s = mruby.mrb_ary_ref(mrb, sub_arr, 1);
            const timing_val = mruby.mrb_ary_ref(mrb, sub_arr, 2);

            const target_cstr = mruby.mrb_str_to_cstr(mrb, target_val);
            const action_cstr_s = mruby.mrb_str_to_cstr(mrb, action_val_s);
            const timing_cstr = mruby.mrb_str_to_cstr(mrb, timing_val);

            const target = allocator.dupe(u8, std.mem.span(target_cstr)) catch |err| {
                logger.warn("Failed to allocate subscription target: {}", .{err});
                continue;
            };
            const action_name = allocator.dupe(u8, std.mem.span(action_cstr_s)) catch |err| {
                allocator.free(target);
                logger.warn("Failed to allocate subscription action: {}", .{err});
                continue;
            };
            const timing_str = std.mem.span(timing_cstr);

            const timing: notification.Timing = if (std.mem.eql(u8, timing_str, "immediate"))
                .immediate
            else
                .delayed;

            const sub = notification.Notification{
                .target_resource_id = target,
                .action = .{ .action_name = action_name },
                .timing = timing,
            };

            common.subscriptions.append(allocator, sub) catch |err| {
                logger.warn("Failed to append subscription: {}", .{err});
                allocator.free(target);
                allocator.free(action_name);
                continue;
            };
        }
    }

    // Prevent GC from collecting guard blocks
    common.protectBlocks();
}

/// File system attributes that can be managed
pub const FileAttributes = struct {
    mode: ?u32 = null,
    owner: ?[]const u8 = null,
    group: ?[]const u8 = null,

    pub fn deinit(self: FileAttributes, allocator: std.mem.Allocator) void {
        if (self.owner) |o| allocator.free(o);
        if (self.group) |g| allocator.free(g);
    }
};

/// Set file mode (permissions) for a given file path using POSIX fchmodat
/// Uses AT_FDCWD to work with the current working directory
/// Silently ignores errors to maintain backward compatibility
pub fn setFileMode(file_path: []const u8, mode: u32) void {
    const path_z = std.posix.toPosixPath(file_path) catch return;
    _ = std.c.fchmodat(std.posix.AT.FDCWD, &path_z, @as(std.posix.mode_t, @intCast(mode)), 0);
}

/// Set file owner (user) for a given file path
/// On non-macOS systems, uses chown system call
/// On macOS, uses chown system call (requires root or matching uid)
pub fn setFileOwner(file_path: []const u8, owner: []const u8) !void {
    const c = @cImport({
        @cInclude("unistd.h");
    });

    // Get UID from username
    const uid = try getUserId(owner);

    // POSIX: (gid_t)-1 leaves the group unchanged - no stat needed
    // (std.c.stat is unavailable on linux and musl's struct stat does not
    // survive translate-c).
    const path_z = try std.posix.toPosixPath(file_path);
    const gid: std.posix.gid_t = @bitCast(@as(i32, -1));

    // Change ownership
    if (c.chown(&path_z, uid, gid) != 0) {
        return error.ChownFailed;
    }
}

/// Set file group for a given file path
pub fn setFileGroup(file_path: []const u8, group: []const u8) !void {
    const c = @cImport({
        @cInclude("unistd.h");
    });

    // Get GID from group name
    const gid = try getGroupId(group);

    // POSIX: (uid_t)-1 leaves the owner unchanged - no stat needed.
    const path_z = try std.posix.toPosixPath(file_path);
    const uid: std.posix.uid_t = @bitCast(@as(i32, -1));

    // Change ownership
    if (c.chown(&path_z, uid, gid) != 0) {
        return error.ChownFailed;
    }
}

/// Set file owner and group together
pub fn setFileOwnerAndGroup(file_path: []const u8, owner: ?[]const u8, group: ?[]const u8) !void {
    const c = @cImport({
        @cInclude("unistd.h");
    });

    const path_z = try std.posix.toPosixPath(file_path);

    // POSIX: an id of -1 leaves that field unchanged - no stat needed.
    const uid: std.posix.uid_t = if (owner) |o| try getUserId(o) else @bitCast(@as(i32, -1));
    const gid: std.posix.gid_t = if (group) |g| try getGroupId(g) else @bitCast(@as(i32, -1));

    if (c.chown(&path_z, uid, gid) != 0) {
        return error.ChownFailed;
    }
}

/// Apply file attributes (mode, owner, group) to a file
pub fn applyFileAttributes(file_path: []const u8, attrs: FileAttributes) !void {
    // Set mode if specified
    if (attrs.mode) |m| {
        setFileMode(file_path, m);
    }

    // Set owner and/or group if specified
    if (attrs.owner != null or attrs.group != null) {
        try setFileOwnerAndGroup(file_path, attrs.owner, attrs.group);
    }
}

/// Get UID from username using getpwnam
pub fn getUserId(username: []const u8) !std.posix.uid_t {
    const c = @cImport({
        @cInclude("pwd.h");
        @cInclude("string.h");
    });

    const username_z = try std.posix.toPosixPath(username);
    const pwd = c.getpwnam(&username_z);
    if (pwd == null) {
        return error.UserNotFound;
    }

    return @intCast(pwd.*.pw_uid);
}

/// Get GID from group name using getgrnam
pub fn getGroupId(groupname: []const u8) !std.posix.gid_t {
    const c = @cImport({
        @cInclude("grp.h");
        @cInclude("string.h");
    });

    const groupname_z = try std.posix.toPosixPath(groupname);
    const grp = c.getgrnam(&groupname_z);
    if (grp == null) {
        return error.GroupNotFound;
    }

    return @intCast(grp.*.gr_gid);
}
/// Create a backup copy of a file by appending backup_ext to the filename
/// Returns void and closes the backup file properly to prevent fd leaks
/// If the original file doesn't exist, returns error.FileNotFound
pub fn createBackup(allocator: std.mem.Allocator, file_path: []const u8, backup_ext: []const u8) !void {
    const io = global_io.io();
    const backup_path = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ file_path, backup_ext });
    defer allocator.free(backup_path);

    // Open original file for reading
    const original = std.Io.Dir.cwd().openFile(io, file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound, // No file to backup
        else => return err,
    };
    defer original.close(io);

    // Create backup file (with parent directories if needed)
    const backup = blk: {
        if (std.Io.Dir.cwd().createFile(io, backup_path, .{ .truncate = true })) |file| {
            break :blk file;
        } else |err| {
            if (err == error.FileNotFound) {
                if (std.fs.path.dirname(backup_path)) |dir| {
                    try std.Io.Dir.cwd().createDirPath(io, dir);
                }
                break :blk try std.Io.Dir.cwd().createFile(io, backup_path, .{ .truncate = true });
            }
            return err;
        }
    };
    defer backup.close(io); // Properly close to prevent fd leak

    // Copy file contents from original to backup
    var read_buf: [4096]u8 = undefined;
    var original_reader = original.reader(io, &read_buf);
    var write_buf: [4096]u8 = undefined;
    var backup_writer = backup.writer(io, &write_buf);
    _ = original_reader.interface.streamRemaining(&backup_writer.interface) catch |err| switch (err) {
        error.ReadFailed => return original_reader.err.?,
        error.WriteFailed => return backup_writer.err.?,
    };
    backup_writer.interface.flush() catch return backup_writer.err.?;
}

/// Ensure the parent directory for `path` exists, handling absolute and relative paths.
pub fn ensureParentDir(path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        if (parent.len == 0) return;
        try ensurePath(parent);
    }
}

/// Ensure the provided path exists as a directory (creates parents as needed).
pub fn ensurePath(path: []const u8) !void {
    const io = global_io.io();
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.createDirAbsolute(io, path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            error.FileNotFound => {
                if (std.fs.path.dirname(path)) |parent| {
                    if (parent.len == 0) return err;
                    try ensurePath(parent);
                    try std.Io.Dir.createDirAbsolute(io, path, .default_dir);
                } else {
                    return err;
                }
            },
            else => return err,
        };
    } else {
        try std.Io.Dir.cwd().createDirPath(io, path);
    }
}
