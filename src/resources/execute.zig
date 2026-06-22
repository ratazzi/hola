const std = @import("std");
const mruby = @import("../mruby.zig");
const base = @import("../base_resource.zig");
const ansi = @import("../ansi_constants.zig");
const logger = @import("../logger.zig");
const AsyncExecutor = @import("../async_executor.zig").AsyncExecutor;

const DEFAULT_TIMEOUT_S: u32 = 3600;
const MAX_OUTPUT_BYTES: usize = 10 * 1024 * 1024;
const READ_BUFFER_SIZE: usize = 16 * 1024;
const POLL_INTERVAL_MS: i64 = 50;
const TERM_GRACE_MS: i64 = 2000;
const PIPE_CLOSE_GRACE_MS: i64 = 5000;
const POST_EXIT_PIPE_GRACE_MS: i64 = 1000;
const REAP_GRACE_MS: i64 = 2000;

/// Execute resource data structure
pub const Resource = struct {
    // Resource-specific properties
    name: []const u8, // Resource name (for identification)
    command: []const u8,
    cwd: ?[]const u8, // Working directory
    user: ?[]const u8, // User to run as
    group: ?[]const u8, // Group to run as
    environment: ?[]const u8, // Environment variables (future)
    live_stream: bool, // Whether to output command result to stdout
    creates: ?[]const u8, // Path to a file - skip execution if it exists
    timeout_s: u32, // Hard timeout in seconds; 0 disables
    action: Action,

    // Common properties (guards, notifications, etc.)
    common: base.CommonProps,

    pub const Action = enum {
        run,
        nothing, // Don't execute (useful with guards)
    };

    pub fn deinit(self: Resource, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.command);
        if (self.cwd) |cwd| allocator.free(cwd);
        if (self.user) |user| allocator.free(user);
        if (self.group) |group| allocator.free(group);
        if (self.environment) |env| allocator.free(env);
        if (self.creates) |creates| allocator.free(creates);

        // Deinit common props
        var common = self.common;
        common.deinit(allocator);
    }

    pub fn apply(self: Resource) !base.ApplyResult {
        const skip_reason = try self.common.shouldRun(self.user, self.group);
        if (skip_reason) |reason| {
            const action_name = switch (self.action) {
                .run => "run",
                .nothing => "nothing",
            };
            return base.ApplyResult{
                .was_updated = false,
                .action = action_name,
                .skip_reason = reason,
            };
        }

        // Check 'creates' property - skip if file exists
        if (self.creates) |creates_path| {
            const file_exists = blk: {
                std.fs.cwd().access(creates_path, .{}) catch |err| {
                    if (err != error.FileNotFound) {
                        logger.warn("execute[{s}]: Error checking creates path '{s}': {}", .{ self.name, creates_path, err });
                    }
                    break :blk false; // File doesn't exist
                };
                break :blk true; // File exists
            };

            if (file_exists) {
                return base.ApplyResult{
                    .was_updated = false,
                    .action = "run",
                    .skip_reason = "up to date",
                };
            }
        }

        switch (self.action) {
            .run => {
                const output = try applyRun(self);
                return base.ApplyResult{
                    .was_updated = true,
                    .action = "run",
                    .skip_reason = null,
                    .output = output,
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

    /// Helper to show command output (indented)
    fn showCommandOutput(output: []const u8) void {
        if (output.len == 0) return;

        // Split output into lines and indent each line
        var lines = std.mem.splitSequence(u8, output, "\n");
        while (lines.next()) |line| {
            if (line.len > 0) {
                std.debug.print("   {s}\n", .{line});
            }
        }
    }

    const ExecuteResult = struct {
        term: std.process.Child.Term,
        stdout: []u8,
        stderr: []u8,
        timed_out: bool,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *const ExecuteResult) void {
            self.allocator.free(self.stdout);
            self.allocator.free(self.stderr);
        }
    };

    const ExecuteContext = struct {
        command: []const u8,
        cwd: ?[]const u8,
        user: ?[]const u8,
        group: ?[]const u8,
        environment: ?[]const u8,
        timeout_s: u32,
    };

    fn termFromStatus(status: u32) std.process.Child.Term {
        return if (std.posix.W.IFEXITED(status))
            .{ .Exited = std.posix.W.EXITSTATUS(status) }
        else if (std.posix.W.IFSIGNALED(status))
            .{ .Signal = std.posix.W.TERMSIG(status) }
        else if (std.posix.W.IFSTOPPED(status))
            .{ .Stopped = std.posix.W.STOPSIG(status) }
        else
            .{ .Unknown = status };
    }

    fn pollChildTerm(pid: std.posix.pid_t) ?std.process.Child.Term {
        const result = std.posix.waitpid(pid, std.posix.W.NOHANG);
        if (result.pid == 0) return null;
        return termFromStatus(result.status);
    }

    fn closePipe(pipe: *?std.fs.File) void {
        if (pipe.*) |*file| {
            file.close();
            pipe.* = null;
        }
    }

    fn closeChildPipes(child: *std.process.Child) void {
        closePipe(&child.stdin);
        closePipe(&child.stdout);
        closePipe(&child.stderr);
    }

    fn signalProcessGroup(pid: std.posix.pid_t, sig: u8) void {
        std.posix.kill(-pid, sig) catch |err| {
            if (err != error.ProcessNotFound) {
                logger.warn("[execute] failed to signal process group {d}: {}", .{ pid, err });
            }
        };
    }

    /// Best-effort reap after SIGKILL so we don't leak a zombie. Polls for a
    /// short grace period but never blocks indefinitely: a process stuck in
    /// uninterruptible sleep must not hang the caller.
    fn reapAfterKill(pid: std.posix.pid_t) void {
        const deadline = std.time.milliTimestamp() + REAP_GRACE_MS;
        while (std.time.milliTimestamp() < deadline) {
            if (pollChildTerm(pid) != null) return;
            std.Thread.sleep(POLL_INTERVAL_MS * std.time.ns_per_ms);
        }
        logger.warn("[execute] child {d} not reaped after SIGKILL; possible zombie", .{pid});
    }

    /// Cleanup helper for error paths: SIGKILL the group and reap, but only if
    /// the child has not already been reaped. Reaping an already-reaped pid
    /// would hit ECHILD, which std.posix.waitpid treats as unreachable (panic).
    fn killAndReap(pid: std.posix.pid_t, child_running: *bool) void {
        if (!child_running.*) return;
        signalProcessGroup(pid, std.posix.SIG.KILL);
        reapAfterKill(pid);
        child_running.* = false;
    }

    fn appendOutputBounded(
        allocator: std.mem.Allocator,
        output: *std.ArrayList(u8),
        bytes: []const u8,
    ) !void {
        if (output.items.len + bytes.len > MAX_OUTPUT_BYTES) return error.CommandOutputTooLarge;
        try output.appendSlice(allocator, bytes);
    }

    fn drainPipe(
        allocator: std.mem.Allocator,
        file: std.fs.File,
        output: *std.ArrayList(u8),
    ) !bool {
        var buf: [READ_BUFFER_SIZE]u8 = undefined;
        const n = try file.read(&buf);
        if (n == 0) return false;
        try appendOutputBounded(allocator, output, buf[0..n]);
        return true;
    }

    fn drainReadyPipe(
        allocator: std.mem.Allocator,
        pipe: *?std.fs.File,
        output: *std.ArrayList(u8),
        is_open: *bool,
    ) !void {
        if (!is_open.*) return;
        const file = pipe.* orelse {
            is_open.* = false;
            return;
        };

        const still_open = try drainPipe(allocator, file, output);
        if (!still_open) {
            closePipe(pipe);
            is_open.* = false;
        }
    }

    fn buildPollTimeoutMs(
        now: i64,
        deadline_ms: ?i64,
        kill_deadline_ms: ?i64,
        close_deadline_ms: ?i64,
        post_exit_pipe_deadline_ms: ?i64,
    ) i32 {
        var timeout = POLL_INTERVAL_MS;
        if (deadline_ms) |deadline| timeout = @min(timeout, deadline - now);
        if (kill_deadline_ms) |deadline| timeout = @min(timeout, deadline - now);
        if (close_deadline_ms) |deadline| timeout = @min(timeout, deadline - now);
        if (post_exit_pipe_deadline_ms) |deadline| timeout = @min(timeout, deadline - now);
        return @intCast(@max(timeout, 0));
    }

    fn collectOutputAndWait(
        child: *std.process.Child,
        allocator: std.mem.Allocator,
        timeout_s: u32,
    ) !ExecuteResult {
        var stdout = std.ArrayList(u8).empty;
        defer stdout.deinit(allocator);
        var stderr = std.ArrayList(u8).empty;
        defer stderr.deinit(allocator);

        try child.spawn();
        // On a pre-exec failure (bad cwd, setpgid, etc.) the forked child
        // reports the error and _exit()s. Close our pipe ends and reap it so
        // the error path doesn't leak fds or leave a zombie.
        child.waitForSpawn() catch |err| {
            closeChildPipes(child);
            reapAfterKill(child.id);
            return err;
        };

        var stdout_open = child.stdout != null;
        var stderr_open = child.stderr != null;
        var child_running = true;
        var term: ?std.process.Child.Term = null;
        var timed_out = false;
        var sent_kill = false;
        var post_exit_pipe_deadline_ms: ?i64 = null;

        const pid = child.id;
        const deadline_ms: ?i64 = if (timeout_s == 0)
            null
        else
            std.time.milliTimestamp() + @as(i64, timeout_s) * std.time.ms_per_s;
        var kill_deadline_ms: ?i64 = null;
        var close_deadline_ms: ?i64 = null;

        while (child_running or stdout_open or stderr_open) {
            const now = std.time.milliTimestamp();

            // Reap the child FIRST so the timeout decision below sees accurate
            // liveness in this same iteration. Otherwise a command that exits
            // right as the deadline elapses could be flagged as timed out (and
            // have its process group signaled) before we notice it already left.
            if (child_running) {
                if (pollChildTerm(pid)) |child_term| {
                    term = child_term;
                    child_running = false;
                    if (stdout_open or stderr_open) {
                        post_exit_pipe_deadline_ms = now + POST_EXIT_PIPE_GRACE_MS;
                    }
                }
            }

            // Drive the timeout/kill state machine only while the child is alive.
            if (child_running and !timed_out) {
                if (deadline_ms) |deadline| {
                    if (now >= deadline) {
                        timed_out = true;
                        kill_deadline_ms = now + TERM_GRACE_MS;
                        close_deadline_ms = now + PIPE_CLOSE_GRACE_MS;
                        signalProcessGroup(pid, std.posix.SIG.TERM);
                    }
                }
            } else if (child_running and !sent_kill) {
                if (kill_deadline_ms) |deadline| {
                    if (now >= deadline) {
                        sent_kill = true;
                        kill_deadline_ms = null; // done; keep it out of the poll-timeout calc
                        signalProcessGroup(pid, std.posix.SIG.KILL);
                    }
                }
            }

            if (timed_out) {
                if (close_deadline_ms) |deadline| {
                    if (now >= deadline) {
                        closeChildPipes(child);
                        stdout_open = false;
                        stderr_open = false;
                        if (child_running) {
                            // SIGKILL was already sent; reap to avoid a zombie.
                            reapAfterKill(pid);
                            child_running = false;
                        }
                        break;
                    }
                }
            } else if (!child_running) {
                // Child exited but a grandchild may still hold the pipes open.
                // Drain briefly, then give up so we never block forever.
                if (post_exit_pipe_deadline_ms) |deadline| {
                    if (now >= deadline) {
                        closeChildPipes(child);
                        stdout_open = false;
                        stderr_open = false;
                        break;
                    }
                }
            }

            if (!stdout_open and !stderr_open) {
                if (child_running) std.Thread.sleep(POLL_INTERVAL_MS * std.time.ns_per_ms);
                continue;
            }

            const events: i16 = std.posix.POLL.IN;
            var fds = [_]std.posix.pollfd{
                .{
                    .fd = if (stdout_open) child.stdout.?.handle else -1,
                    .events = events,
                    .revents = 0,
                },
                .{
                    .fd = if (stderr_open) child.stderr.?.handle else -1,
                    .events = events,
                    .revents = 0,
                },
            };

            // Once timed out, the main deadline is in the past; the close_deadline
            // drives the poll cadence from here, so don't let the expired main
            // deadline pin the poll timeout at 0 and spin the CPU.
            const poll_timeout_ms = buildPollTimeoutMs(now, if (timed_out) null else deadline_ms, kill_deadline_ms, close_deadline_ms, post_exit_pipe_deadline_ms);
            const ready = std.posix.poll(&fds, poll_timeout_ms) catch |err| {
                killAndReap(pid, &child_running);
                closeChildPipes(child);
                return err;
            };
            if (ready == 0) continue;

            if (stdout_open and fds[0].revents != 0) {
                drainReadyPipe(allocator, &child.stdout, &stdout, &stdout_open) catch |err| {
                    killAndReap(pid, &child_running);
                    closeChildPipes(child);
                    return err;
                };
            }
            if (stderr_open and fds[1].revents != 0) {
                drainReadyPipe(allocator, &child.stderr, &stderr, &stderr_open) catch |err| {
                    killAndReap(pid, &child_running);
                    closeChildPipes(child);
                    return err;
                };
            }
        }

        // Safety net: every loop-exit path above already reaps the child, so
        // child_running should be false here. Reap defensively without ever
        // blocking indefinitely in case a future change leaves it running.
        if (child_running) {
            if (pollChildTerm(pid)) |child_term| {
                term = child_term;
            } else {
                reapAfterKill(pid);
            }
        }

        closeChildPipes(child);

        const result_allocator = std.heap.page_allocator;
        return ExecuteResult{
            .term = term orelse .{ .Unknown = 0 },
            .stdout = try result_allocator.dupe(u8, stdout.items),
            .stderr = try result_allocator.dupe(u8, stderr.items),
            .timed_out = timed_out,
            .allocator = result_allocator,
        };
    }

    fn executeCommand(ctx: ExecuteContext) !ExecuteResult {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const temp_allocator = arena.allocator();

        // Prepare command for shell execution
        const shell_cmd = try std.fmt.allocPrint(temp_allocator, "{s}", .{ctx.command});

        // Create child process
        var child = std.process.Child.init(&[_][]const u8{ "/bin/sh", "-c", shell_cmd }, temp_allocator);

        // Set working directory if specified
        if (ctx.cwd) |cwd| {
            child.cwd = cwd;
        }

        // Set environment variables if specified
        // Note: env_map must live until child.wait() completes
        var env_map_storage: ?std.process.EnvMap = null;
        defer if (env_map_storage) |*map| map.deinit();

        if (ctx.environment) |env_str| {
            // Parse environment string "KEY=VALUE\0KEY2=VALUE2\0" into a map
            // Start with current environment
            var env_map = try std.process.getEnvMap(temp_allocator);

            // Parse and add/override environment variables
            var pos: usize = 0;
            while (pos < env_str.len) {
                // Find next KEY=VALUE pair (null-terminated)
                const start = pos;
                while (pos < env_str.len and env_str[pos] != 0) : (pos += 1) {}

                const pair = env_str[start..pos];
                if (pair.len > 0) {
                    // Split on '='
                    if (std.mem.indexOfScalar(u8, pair, '=')) |eq_pos| {
                        const key = pair[0..eq_pos];
                        const value = pair[eq_pos + 1 ..];
                        try env_map.put(key, value);
                    }
                }

                pos += 1; // Skip null terminator
            }

            env_map_storage = env_map;
            child.env_map = &env_map_storage.?;
        }

        // Set user and/or group if specified (requires root privileges)
        if (ctx.user != null or ctx.group != null) {
            const c = @cImport({
                @cInclude("pwd.h");
                @cInclude("grp.h");
            });

            // Get user info if user is specified
            if (ctx.user) |user| {
                const username_z = std.posix.toPosixPath(user) catch |err| {
                    logger.err("[execute] failed to convert username '{s}': {}", .{ user, err });
                    return error.UserInfoFailed;
                };

                const pwd = c.getpwnam(&username_z);
                if (pwd == null) {
                    logger.err("[execute] user '{s}' not found", .{user});
                    return error.UserNotFound;
                }

                child.uid = @intCast(pwd.*.pw_uid);
                child.gid = @intCast(pwd.*.pw_gid);
            }

            // Override with group if specified
            if (ctx.group) |group| {
                const groupname_z = std.posix.toPosixPath(group) catch |err| {
                    logger.err("[execute] failed to convert groupname '{s}': {}", .{ group, err });
                    return error.GroupInfoFailed;
                };

                const grp = c.getgrnam(&groupname_z);
                if (grp == null) {
                    logger.err("[execute] group '{s}' not found", .{group});
                    return error.GroupNotFound;
                }

                child.gid = @intCast(grp.*.gr_gid);
            }
        }

        // Capture output
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        child.pgid = 0;

        return try collectOutputAndWait(&child, temp_allocator, ctx.timeout_s);
    }

    fn applyRun(self: Resource) !?[]const u8 {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        // Execute command asynchronously to allow spinner to continue
        const ctx = ExecuteContext{
            .command = self.command,
            .cwd = self.cwd,
            .user = self.user,
            .group = self.group,
            .environment = self.environment,
            .timeout_s = self.timeout_s,
        };

        const result = try AsyncExecutor.executeWithContext(
            ExecuteContext,
            ExecuteResult,
            ctx,
            executeCommand,
        );
        defer result.deinit();

        const term = result.term;
        const stdout = result.stdout;
        const stderr = result.stderr;

        // Log command execution
        const exit_code: ?i32 = switch (term) {
            .Exited => |code| code,
            else => null,
        };

        // Log execute resource command with clear identification
        const level = if (exit_code) |code| blk: {
            break :blk if (code == 0) logger.Level.info else logger.Level.err;
        } else logger.Level.info;

        const exit_msg = if (result.timed_out) blk: {
            const msg = try std.fmt.allocPrint(allocator, " (timeout: {d}s)", .{self.timeout_s});
            break :blk msg;
        } else if (exit_code) |code| blk: {
            const msg = try std.fmt.allocPrint(allocator, " (exit: {d})", .{code});
            break :blk msg;
        } else try allocator.dupe(u8, "");
        defer allocator.free(exit_msg);

        logger.log(level, "execute[{s}]: {s}{s}\n", .{ self.name, self.command, exit_msg });

        if (stdout.len > 0) {
            const stdout_trimmed = std.mem.trim(u8, stdout, &std.ascii.whitespace);
            if (stdout_trimmed.len > 0) {
                logger.debug("  stdout: {s}", .{stdout_trimmed});
            }
        }

        if (stderr.len > 0) {
            const stderr_trimmed = std.mem.trim(u8, stderr, &std.ascii.whitespace);
            if (stderr_trimmed.len > 0) {
                logger.warn("  stderr: {s}", .{stderr_trimmed});
            }
        }

        // Display command output only if live_stream is enabled
        if (self.live_stream) {
            if (stdout.len > 0) {
                showCommandOutput(stdout);
            }
            if (stderr.len > 0) {
                // Show stderr in red to indicate errors
                std.debug.print("   {s}", .{ansi.ANSI.RED});
                showCommandOutput(stderr);
                std.debug.print("{s}", .{ansi.ANSI.RESET});
            }
        }

        if (result.timed_out) {
            logger.err("[execute] command timed out after {d}s", .{self.timeout_s});
            return error.CommandTimedOut;
        }

        // Check exit status
        switch (term) {
            .Exited => |code| {
                if (code != 0) {
                    logger.err("[execute] command exited with code {d}", .{code});
                    return error.CommandFailed;
                }
            },
            .Signal => |sig| {
                logger.err("[execute] command killed by signal {d}", .{sig});
                return error.CommandKilled;
            },
            .Stopped => |sig| {
                logger.err("[execute] command stopped by signal {d}", .{sig});
                return error.CommandStopped;
            },
            .Unknown => |unknown_status| {
                logger.err("[execute] command exited with unknown status {d}", .{unknown_status});
                return error.CommandFailed;
            },
        }

        // Build combined output for structured result
        const stdout_trimmed = std.mem.trim(u8, stdout, &std.ascii.whitespace);
        const stderr_trimmed = std.mem.trim(u8, stderr, &std.ascii.whitespace);
        if (stdout_trimmed.len == 0 and stderr_trimmed.len == 0) return null;

        if (stderr_trimmed.len == 0) return try std.heap.c_allocator.dupe(u8, stdout_trimmed);
        if (stdout_trimmed.len == 0) return try std.heap.c_allocator.dupe(u8, stderr_trimmed);
        return try std.fmt.allocPrint(std.heap.c_allocator, "{s}\n{s}", .{ stdout_trimmed, stderr_trimmed });
    }
};

/// Ruby prelude for execute resource
pub const ruby_prelude = @embedFile("execute_resource.rb");

/// Zig callback: called from Ruby to add an execute resource
/// Format: add_execute(name, command, cwd, user, group, environment_array, live_stream, creates, action, timeout_s, only_if_block, not_if_block, ignore_failure, notifications_array, subscriptions_array)
pub fn zigAddResource(
    mrb: *mruby.mrb_state,
    self: mruby.mrb_value,
    resources: *std.ArrayList(Resource),
    allocator: std.mem.Allocator,
) mruby.mrb_value {
    _ = self;

    var name_val: mruby.mrb_value = undefined;
    var command_val: mruby.mrb_value = undefined;
    var cwd_val: mruby.mrb_value = undefined;
    var user_val: mruby.mrb_value = undefined;
    var group_val: mruby.mrb_value = undefined;
    var environment_val: mruby.mrb_value = undefined;
    var live_stream_val: mruby.mrb_value = undefined;
    var creates_val: mruby.mrb_value = undefined;
    var action_val: mruby.mrb_value = undefined;
    var timeout_val: mruby.mrb_int = DEFAULT_TIMEOUT_S;
    var only_if_val: mruby.mrb_value = undefined;
    var not_if_val: mruby.mrb_value = undefined;
    var ignore_failure_val: mruby.mrb_value = undefined;
    var notifications_val: mruby.mrb_value = undefined;
    var subscriptions_val: mruby.mrb_value = undefined;

    // Get 5 strings + 1 array + 1 bool + 2 strings + timeout + common optional args.
    _ = mruby.mrb_get_args(mrb, "SSSSSAoSSi|oooAA", &name_val, &command_val, &cwd_val, &user_val, &group_val, &environment_val, &live_stream_val, &creates_val, &action_val, &timeout_val, &only_if_val, &not_if_val, &ignore_failure_val, &notifications_val, &subscriptions_val);

    const name_cstr = mruby.mrb_str_to_cstr(mrb, name_val);
    const command_cstr = mruby.mrb_str_to_cstr(mrb, command_val);
    const cwd_cstr = mruby.mrb_str_to_cstr(mrb, cwd_val);
    const user_cstr = mruby.mrb_str_to_cstr(mrb, user_val);
    const group_cstr = mruby.mrb_str_to_cstr(mrb, group_val);
    const creates_cstr = mruby.mrb_str_to_cstr(mrb, creates_val);
    const action_cstr = mruby.mrb_str_to_cstr(mrb, action_val);

    const name = allocator.dupe(u8, std.mem.span(name_cstr)) catch return mruby.mrb_nil_value();
    const command = allocator.dupe(u8, std.mem.span(command_cstr)) catch return mruby.mrb_nil_value();

    const cwd_str = std.mem.span(cwd_cstr);
    const cwd: ?[]const u8 = if (cwd_str.len > 0)
        allocator.dupe(u8, cwd_str) catch return mruby.mrb_nil_value()
    else
        null;

    const user_str = std.mem.span(user_cstr);
    const user: ?[]const u8 = if (user_str.len > 0)
        allocator.dupe(u8, user_str) catch return mruby.mrb_nil_value()
    else
        null;

    const group_str = std.mem.span(group_cstr);
    const group: ?[]const u8 = if (group_str.len > 0)
        allocator.dupe(u8, group_str) catch return mruby.mrb_nil_value()
    else
        null;

    const live_stream = mruby.mrb_test(live_stream_val);

    const creates_str = std.mem.span(creates_cstr);
    const creates: ?[]const u8 = if (creates_str.len > 0)
        allocator.dupe(u8, creates_str) catch return mruby.mrb_nil_value()
    else
        null;

    const action_str = std.mem.span(action_cstr);
    const action: Resource.Action = if (std.mem.eql(u8, action_str, "nothing"))
        .nothing
    else
        .run;
    const timeout_s: u32 = if (timeout_val <= 0)
        0
    else
        @intCast(@min(timeout_val, @as(mruby.mrb_int, std.math.maxInt(u32))));

    // Parse environment array [[key, value], ...]
    var environment: ?[]const u8 = null;
    const env_len = mruby.mrb_ary_len(mrb, environment_val);
    if (env_len > 0) {
        // Build environment string in format "KEY=VALUE\0KEY2=VALUE2\0"
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

            const key_str = std.mem.span(key_cstr);
            const val_str = std.mem.span(val_cstr);

            // Append "KEY=VALUE\0"
            env_list.appendSlice(allocator, key_str) catch return mruby.mrb_nil_value();
            env_list.append(allocator, '=') catch return mruby.mrb_nil_value();
            env_list.appendSlice(allocator, val_str) catch return mruby.mrb_nil_value();
            env_list.append(allocator, 0) catch return mruby.mrb_nil_value();
        }

        if (env_list.items.len > 0) {
            environment = allocator.dupe(u8, env_list.items) catch return mruby.mrb_nil_value();
        }
    }

    // Build common properties (guards + notifications)
    var common = base.CommonProps.init(allocator);
    base.fillCommonFromRuby(&common, mrb, only_if_val, not_if_val, ignore_failure_val, notifications_val, subscriptions_val, allocator);

    resources.append(allocator, .{
        .name = name,
        .command = command,
        .cwd = cwd,
        .user = user,
        .group = group,
        .environment = environment,
        .live_stream = live_stream,
        .creates = creates,
        .timeout_s = timeout_s,
        .action = action,
        .common = common,
    }) catch return mruby.mrb_nil_value();

    return mruby.mrb_nil_value();
}
