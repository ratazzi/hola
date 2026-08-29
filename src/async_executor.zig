const std = @import("std");
const global_io = @import("global_io.zig");

/// Global poll callback for UI updates during async execution
threadlocal var global_poll_callback: ?*const fn () anyerror!void = null;

/// Generic async executor for long-running resource operations
/// Runs tasks in a separate thread while allowing the main thread to update UI
pub const AsyncExecutor = struct {
    const Self = @This();

    /// Set global poll callback for UI updates
    pub fn setPollCallback(callback: ?*const fn () anyerror!void) void {
        global_poll_callback = callback;
    }

    /// Task context that tracks execution state
    pub fn Context(comptime T: type) type {
        return struct {
            status: std.atomic.Value(u8), // 0=running, 1=completed, 2=failed
            result: ?T = null,
            err: ?anyerror = null,
            mutex: std.Io.Mutex = .init,

            pub fn init() @This() {
                return .{
                    .status = std.atomic.Value(u8).init(0),
                };
            }
        };
    }

    /// Execute a function asynchronously in a separate thread
    /// The main thread will poll the status and can update UI while waiting
    pub fn execute(
        comptime T: type,
        comptime func: fn () anyerror!T,
    ) !T {
        var ctx = Context(T).init();

        // Worker function that will run in separate thread
        const Worker = struct {
            fn run(context: *Context(T)) void {
                const result = func() catch |err| {
                    context.mutex.lockUncancelable(global_io.io());
                    context.err = err;
                    context.mutex.unlock(global_io.io());
                    context.status.store(2, .release);
                    return;
                };

                context.mutex.lockUncancelable(global_io.io());
                context.result = result;
                context.mutex.unlock(global_io.io());
                context.status.store(1, .release);
            }
        };

        // Spawn worker thread
        const thread = try std.Thread.spawn(.{}, Worker.run, .{&ctx});

        // Poll status until completion
        while (true) {
            const status = ctx.status.load(.acquire);
            if (status != 0) {
                break;
            }
            // Sleep briefly to allow main thread to update UI
            global_io.io().sleep(.fromNanoseconds(50 * std.time.ns_per_ms), .awake) catch {};
        }

        // Wait for thread to complete
        thread.join();
        if (global_poll_callback) |callback| callback() catch {};

        // Check result
        ctx.mutex.lockUncancelable(global_io.io());
        defer ctx.mutex.unlock(global_io.io());

        if (ctx.status.load(.acquire) == 2) {
            return ctx.err orelse error.UnknownError;
        }

        return ctx.result.?;
    }

    /// Execute a function with context asynchronously
    /// This version allows passing additional context/arguments
    /// Optionally takes a callback to call during polling (for UI updates)
    pub fn executeWithContext(
        comptime ContextType: type,
        comptime ResultType: type,
        context: ContextType,
        comptime func: fn (ContextType) anyerror!ResultType,
    ) !ResultType {
        return executeWithContextAndCallback(ContextType, ResultType, context, func, null);
    }

    /// Execute with context and optional callback for UI updates
    pub fn executeWithContextAndCallback(
        comptime ContextType: type,
        comptime ResultType: type,
        context: ContextType,
        comptime func: fn (ContextType) anyerror!ResultType,
        poll_callback: ?*const fn () anyerror!void,
    ) !ResultType {
        const TaskContext = struct {
            user_context: ContextType,
            status: std.atomic.Value(u8),
            result: ?ResultType = null,
            err: ?anyerror = null,
            mutex: std.Io.Mutex = .init,
        };

        var ctx = TaskContext{
            .user_context = context,
            .status = std.atomic.Value(u8).init(0),
        };

        // Worker function that will run in separate thread
        const Worker = struct {
            fn run(task_ctx: *TaskContext) void {
                const result = func(task_ctx.user_context) catch |err| {
                    task_ctx.mutex.lockUncancelable(global_io.io());
                    task_ctx.err = err;
                    task_ctx.mutex.unlock(global_io.io());
                    task_ctx.status.store(2, .release);
                    return;
                };

                task_ctx.mutex.lockUncancelable(global_io.io());
                task_ctx.result = result;
                task_ctx.mutex.unlock(global_io.io());
                task_ctx.status.store(1, .release);
            }
        };

        // Spawn worker thread
        const thread = try std.Thread.spawn(.{}, Worker.run, .{&ctx});

        // Poll status until completion (allows main thread to update UI)
        while (true) {
            const status = ctx.status.load(.acquire);
            if (status != 0) {
                break;
            }

            // Call poll callback if provided (for UI updates)
            const callback = poll_callback orelse global_poll_callback;
            if (callback) |cb| {
                cb() catch {};
            }

            // Sleep briefly to yield to main thread
            global_io.io().sleep(.fromNanoseconds(50 * std.time.ns_per_ms), .awake) catch {};
        }

        // Wait for thread to complete
        thread.join();
        const final_callback = poll_callback orelse global_poll_callback;
        if (final_callback) |callback| callback() catch {};

        // Check result
        ctx.mutex.lockUncancelable(global_io.io());
        defer ctx.mutex.unlock(global_io.io());

        if (ctx.status.load(.acquire) == 2) {
            return ctx.err orelse error.UnknownError;
        }

        return ctx.result.?;
    }
};
