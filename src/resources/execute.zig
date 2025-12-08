const std = @import("std");
const mruby = @import("../mruby.zig");
const base = @import("../base_resource.zig");
const ansi = @import("../ansi_constants.zig");
const logger = @import("../logger.zig");
const AsyncExecutor = @import("../async_executor.zig").AsyncExecutor;

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
        const skip_reason = try self.common.shouldRun();
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
                    .skip_reason = "file specified by 'creates' already exists",
                };
            }
        }

        switch (self.action) {
            .run => {
                try applyRun(self);
                return base.ApplyResult{
                    .was_updated = true,
                    .action = "run",
                    .skip_reason = "up to date",
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
    };

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
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        // Blocking wait in worker thread (main thread polls our status)
        const stdout = try child.stdout.?.readToEndAlloc(temp_allocator, std.math.maxInt(usize));
        const stderr = try child.stderr.?.readToEndAlloc(temp_allocator, std.math.maxInt(usize));
        const term = try child.wait();

        // Allocate result using page allocator (will be freed by caller)
        const result_allocator = std.heap.page_allocator;
        return ExecuteResult{
            .term = term,
            .stdout = try result_allocator.dupe(u8, stdout),
            .stderr = try result_allocator.dupe(u8, stderr),
            .allocator = result_allocator,
        };
    }

    fn applyRun(self: Resource) !void {
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

        const exit_msg = if (exit_code) |code| blk: {
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
    }
};

/// Ruby prelude for execute resource
pub const ruby_prelude = @embedFile("execute_resource.rb");

/// Zig callback: called from Ruby to add an execute resource
/// Format: add_execute(name, command, cwd, user, group, environment_array, live_stream, creates, action, only_if_block, not_if_block, ignore_failure, notifications_array, subscriptions_array)
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
    var only_if_val: mruby.mrb_value = undefined;
    var not_if_val: mruby.mrb_value = undefined;
    var ignore_failure_val: mruby.mrb_value = undefined;
    var notifications_val: mruby.mrb_value = undefined;
    var subscriptions_val: mruby.mrb_value = undefined;

    // Get 5 strings + 1 array + 1 bool + 2 strings + 3 optional (2 blocks + 1 bool + 2 arrays)
    _ = mruby.mrb_get_args(mrb, "SSSSSAoSS|oooAA", &name_val, &command_val, &cwd_val, &user_val, &group_val, &environment_val, &live_stream_val, &creates_val, &action_val, &only_if_val, &not_if_val, &ignore_failure_val, &notifications_val, &subscriptions_val);

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
        .action = action,
        .common = common,
    }) catch return mruby.mrb_nil_value();

    return mruby.mrb_nil_value();
}
