const std = @import("std");
const mruby = @import("../mruby.zig");
const base = @import("../base_resource.zig");
const ansi = @import("../ansi_constants.zig");
const logger = @import("../logger.zig");

/// Execute resource data structure
pub const Resource = struct {
    // Resource-specific properties
    name: []const u8, // Resource name (for identification)
    command: []const u8,
    cwd: ?[]const u8, // Working directory
    user: ?[]const u8, // User to run as (future)
    environment: ?[]const u8, // Environment variables (future)
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
        if (self.environment) |env| allocator.free(env);

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

    fn applyRun(self: Resource) !void {
        // Don't output debug info during ANSI progress display

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        // Prepare command for shell execution
        const shell_cmd = try std.fmt.allocPrint(allocator, "{s}", .{self.command});

        // Create child process
        var child = std.process.Child.init(&[_][]const u8{ "/bin/sh", "-c", shell_cmd }, allocator);

        // Set working directory if specified
        if (self.cwd) |cwd| {
            child.cwd = cwd;
        }

        // Capture output
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        // Read output for display
        const stdout = try child.stdout.?.readToEndAlloc(allocator, std.math.maxInt(usize));
        const stderr = try child.stderr.?.readToEndAlloc(allocator, std.math.maxInt(usize));
        defer allocator.free(stdout);
        defer allocator.free(stderr);

        const term = try child.wait();

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

        logger.log(level, "execute[{s}]: {s}{s}\n", .{ self.name, shell_cmd, exit_msg });

        if (stdout.len > 0) {
            const stdout_trimmed = std.mem.trim(u8, stdout, &std.ascii.whitespace);
            if (stdout_trimmed.len > 0) {
                logger.debug("  stdout: {s}\n", .{stdout_trimmed});
            }
        }

        if (stderr.len > 0) {
            const stderr_trimmed = std.mem.trim(u8, stderr, &std.ascii.whitespace);
            if (stderr_trimmed.len > 0) {
                logger.warn("  stderr: {s}\n", .{stderr_trimmed});
            }
        }

        // Display command output like Docker build
        if (stdout.len > 0) {
            showCommandOutput(stdout);
        }
        if (stderr.len > 0) {
            // Show stderr in red to indicate errors
            std.debug.print("   {s}", .{ansi.ANSI.RED});
            showCommandOutput(stderr);
            std.debug.print("{s}", .{ansi.ANSI.RESET});
        }

        // Check exit status
        switch (term) {
            .Exited => |code| {
                if (code != 0) {
                    std.debug.print("[execute] command exited with code {d}\n", .{code});
                    return error.CommandFailed;
                }
            },
            .Signal => |sig| {
                std.debug.print("[execute] command killed by signal {d}\n", .{sig});
                return error.CommandKilled;
            },
            .Stopped => |sig| {
                std.debug.print("[execute] command stopped by signal {d}\n", .{sig});
                return error.CommandStopped;
            },
            .Unknown => |status| {
                std.debug.print("[execute] command exited with unknown status {d}\n", .{status});
                return error.CommandFailed;
            },
        }

        // std.debug.print("[execute] command completed successfully\n", .{});
    }
};

/// Ruby prelude for execute resource
pub const ruby_prelude = @embedFile("execute_resource.rb");

/// Zig callback: called from Ruby to add an execute resource
/// Format: add_execute(name, command, cwd, action, only_if_block, not_if_block, notifications_array)
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
    var action_val: mruby.mrb_value = undefined;
    var only_if_val: mruby.mrb_value = undefined;
    var not_if_val: mruby.mrb_value = undefined;
    var notifications_val: mruby.mrb_value = undefined;

    // Get 4 strings + 3 optional (blocks + array)
    _ = mruby.mrb_get_args(mrb, "SSSS|ooA", &name_val, &command_val, &cwd_val, &action_val, &only_if_val, &not_if_val, &notifications_val);

    const name_cstr = mruby.mrb_str_to_cstr(mrb, name_val);
    const command_cstr = mruby.mrb_str_to_cstr(mrb, command_val);
    const cwd_cstr = mruby.mrb_str_to_cstr(mrb, cwd_val);
    const action_cstr = mruby.mrb_str_to_cstr(mrb, action_val);

    const name = allocator.dupe(u8, std.mem.span(name_cstr)) catch return mruby.mrb_nil_value();
    const command = allocator.dupe(u8, std.mem.span(command_cstr)) catch return mruby.mrb_nil_value();

    const cwd_str = std.mem.span(cwd_cstr);
    const cwd: ?[]const u8 = if (cwd_str.len > 0)
        allocator.dupe(u8, cwd_str) catch return mruby.mrb_nil_value()
    else
        null;

    const action_str = std.mem.span(action_cstr);
    const action: Resource.Action = if (std.mem.eql(u8, action_str, "nothing"))
        .nothing
    else
        .run;

    // Build common properties (guards + notifications)
    var common = base.CommonProps.init(allocator);
    base.fillCommonFromRuby(&common, mrb, only_if_val, not_if_val, notifications_val, allocator);

    resources.append(allocator, .{
        .name = name,
        .command = command,
        .cwd = cwd,
        .user = null,
        .environment = null,
        .action = action,
        .common = common,
    }) catch return mruby.mrb_nil_value();

    return mruby.mrb_nil_value();
}
