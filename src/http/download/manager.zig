const std = @import("std");
const http_client = @import("../client.zig");
const config_mod = @import("../config.zig");
const Task = @import("task.zig").Task;
const downloader = @import("downloader.zig");
const logger = @import("../../logger.zig");

// Thread-local storage for current Manager (for use in remote_file resource)
threadlocal var current_manager: ?*Manager = null;

/// Download manager with worker pool and queue
pub const Manager = struct {
    allocator: std.mem.Allocator,
    client: http_client.Client,
    tasks: std.ArrayList(Task),

    // Worker pool
    workers: []std.Thread,
    max_concurrent: usize,
    mutex: std.Thread.Mutex,
    condition: std.Thread.Condition,
    shutdown: bool,
    next_task_index: usize,

    // Counters
    completed_counter: std.atomic.Value(usize),
    failed_counter: std.atomic.Value(usize),

    // Display integration (optional)
    display: ?*anyopaque = null,
    display_update_fn: ?*const fn (*anyopaque, usize, usize, usize) void = null,

    pub const Config = struct {
        max_concurrent: usize = 5,
        http_config: config_mod.Config = .{},
    };

    pub fn init(allocator: std.mem.Allocator, cfg: Config) !Manager {
        const client = try http_client.Client.init(allocator, cfg.http_config);

        return Manager{
            .allocator = allocator,
            .client = client,
            .tasks = std.ArrayList(Task).empty,
            .workers = &.{},
            .max_concurrent = cfg.max_concurrent,
            .mutex = .{},
            .condition = .{},
            .shutdown = false,
            .next_task_index = 0,
            .completed_counter = std.atomic.Value(usize).init(0),
            .failed_counter = std.atomic.Value(usize).init(0),
        };
    }

    /// Get temporary download directory
    pub fn getDownloadTempDir(allocator: std.mem.Allocator) ![]const u8 {
        const xdg = @import("../../xdg.zig").XDG.init(allocator);
        return try xdg.getDownloadsDir();
    }

    /// Get current thread-local manager (for use in remote_file resource)
    pub fn getCurrent() ?*Manager {
        return current_manager;
    }

    /// Set current thread-local manager
    pub fn setCurrent(self: *Manager) void {
        current_manager = self;
    }

    /// Clear current thread-local manager
    pub fn clearCurrent() void {
        current_manager = null;
    }

    pub fn deinit(self: *Manager) void {
        for (self.tasks.items) |*task| {
            task.deinit(self.allocator);
        }
        self.tasks.deinit(self.allocator);
        self.client.deinit();

        if (self.workers.len > 0) {
            self.allocator.free(self.workers);
        }
    }

    /// Add task to queue
    pub fn addTask(self: *Manager, task: Task) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.tasks.append(self.allocator, task);
    }

    /// Pop next task in queue (used by tests and single-threaded flows)
    pub fn getNextTask(self: *Manager) ?*Task {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.next_task_index >= self.tasks.items.len) {
            return null;
        }

        const task = &self.tasks.items[self.next_task_index];
        self.next_task_index += 1;
        return task;
    }

    /// Get task by ID
    pub fn getTask(self: *Manager, id: []const u8) ?*Task {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.tasks.items) |*task| {
            if (std.mem.eql(u8, task.id, id)) {
                return task;
            }
        }
        return null;
    }

    /// Start worker pool and process all tasks
    pub fn processAll(self: *Manager) !void {
        if (self.tasks.items.len == 0) {
            return;
        }

        // Determine worker count
        const worker_count = @min(self.max_concurrent, self.tasks.items.len);

        // Allocate workers
        self.workers = try self.allocator.alloc(std.Thread, worker_count);

        // Spawn workers
        for (0..worker_count) |i| {
            const ctx = WorkerContext{
                .worker_id = i,
                .manager = self,
            };
            self.workers[i] = try std.Thread.spawn(.{}, workerLoop, .{ctx});
        }

        // Wait for all workers
        for (self.workers) |thread| {
            thread.join();
        }
    }

    /// Cancel all pending tasks
    pub fn cancel(self: *Manager) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.shutdown = true;
        self.condition.broadcast();
    }

    /// Get progress statistics
    pub fn getStats(self: *const Manager) Stats {
        return .{
            .total = self.tasks.items.len,
            .completed = self.completed_counter.load(.acquire),
            .failed = self.failed_counter.load(.acquire),
        };
    }

    pub const Stats = struct {
        total: usize,
        completed: usize,
        failed: usize,

        pub fn inProgress(self: Stats) usize {
            return self.total -| self.completed -| self.failed;
        }
    };

    /// Set display integration callbacks
    pub fn setDisplay(
        self: *Manager,
        display: *anyopaque,
        update_fn: *const fn (*anyopaque, usize, usize, usize) void,
    ) void {
        self.display = display;
        self.display_update_fn = update_fn;
    }

    // Internal: notify display of progress update
    fn notifyDisplay(self: *Manager, task_index: usize, downloaded: usize, total: usize) void {
        if (self.display_update_fn) |update_fn| {
            if (self.display) |display| {
                update_fn(display, task_index, downloaded, total);
            }
        }
    }
};

/// Worker context
const WorkerContext = struct {
    worker_id: usize,
    manager: *Manager,
};

/// Worker loop - processes tasks from queue
fn workerLoop(ctx: WorkerContext) void {
    const mgr = ctx.manager;

    while (true) {
        // Get next task index
        mgr.mutex.lock();

        if (mgr.shutdown) {
            mgr.mutex.unlock();
            break;
        }

        const task_index = mgr.next_task_index;
        if (task_index >= mgr.tasks.items.len) {
            mgr.mutex.unlock();
            break;
        }

        mgr.next_task_index += 1;
        mgr.mutex.unlock();

        // Process task (without holding lock)
        processTask(mgr, task_index);
    }
}

/// Progress callback wrapper for tasks
const TaskProgressContext = struct {
    manager: *Manager,
    task_index: usize,
    task: *Task,
};

fn taskProgressWrapper(downloaded: usize, total: usize, context: *anyopaque) void {
    const ctx: *TaskProgressContext = @ptrCast(@alignCast(context));
    ctx.task.updateProgress(downloaded, total);
    ctx.manager.notifyDisplay(ctx.task_index, downloaded, total);
}

/// Process single task
fn processTask(mgr: *Manager, task_index: usize) void {
    mgr.mutex.lock();
    const task = &mgr.tasks.items[task_index];
    mgr.mutex.unlock();

    logger.debug("Worker processing task {d}: {s}", .{ task_index, task.display_name });

    // Create progress context
    var progress_ctx = TaskProgressContext{
        .manager = mgr,
        .task_index = task_index,
        .task = task,
    };

    // Download with progress callback
    const opts = downloader.Options{
        .headers = task.headers,
        .progress_callback = taskProgressWrapper,
        .progress_context = @ptrCast(&progress_ctx),
    };

    const result = downloader.downloadFileWithClient(
        mgr.allocator,
        &mgr.client,
        task.url,
        task.temp_path,
        opts,
    ) catch |err| {
        const err_msg = std.fmt.allocPrint(
            mgr.allocator,
            "Download failed: {} - {s}",
            .{ err, task.url },
        ) catch "Unknown error";
        defer if (err != error.OutOfMemory) mgr.allocator.free(err_msg);

        logger.err("Task {d} download failed: {s}", .{ task_index, err_msg });
        task.setError(mgr.allocator, err_msg) catch {};
        _ = mgr.failed_counter.fetchAdd(1, .seq_cst);
        mgr.notifyDisplay(task_index, 0, 0);
        return;
    };
    defer {
        var mut_result = result;
        mut_result.deinit(mgr.allocator);
    }

    // Verify checksum if provided
    if (task.checksum) |expected_checksum| {
        downloader.verifyChecksum(mgr.allocator, task.temp_path, expected_checksum) catch |err| {
            const err_msg = std.fmt.allocPrint(
                mgr.allocator,
                "Checksum verification failed: {}",
                .{err},
            ) catch "Checksum mismatch";
            defer if (err != error.OutOfMemory) mgr.allocator.free(err_msg);

            logger.err("Task {d} checksum failed: {s}", .{ task_index, err_msg });
            task.setError(mgr.allocator, err_msg) catch {};
            _ = mgr.failed_counter.fetchAdd(1, .seq_cst);
            mgr.notifyDisplay(task_index, 0, 0);
            return;
        };
    }

    // Don't move or chmod here - let the resource handle that
    // Manager's job is just to download to temp_path
    // The resource will move from temp_path to final_path and apply attributes

    // Success
    task.status.store(.completed, .release);
    _ = mgr.completed_counter.fetchAdd(1, .seq_cst);

    // Final progress update
    const progress = task.getProgress();
    mgr.notifyDisplay(task_index, progress.downloaded, progress.total);

    logger.debug("Task {d} completed: {s}", .{ task_index, task.display_name });
}

// Tests
const testing = @import("std").testing;

test "Manager task queue operations" {
    const allocator = testing.allocator;
    const cfg = Manager.Config{};
    var manager = try Manager.init(allocator, cfg);
    defer manager.deinit();

    // Add multiple tasks
    for (0..3) |i| {
        const task = try Task.init(
            allocator,
            try std.fmt.allocPrint(allocator, "task-{d}", .{i}),
            "https://example.com/file.zip",
            "file.zip",
            "/tmp/file.zip.tmp",
            "/home/user/file.zip",
        );
        try manager.addTask(task);
    }

    // Verify queue ordering
    var next = manager.getNextTask();
    try testing.expect(next != null);
    try testing.expectEqualStrings("task-0", next.?.id);

    next = manager.getNextTask();
    try testing.expectEqualStrings("task-1", next.?.id);

    // Find specific task
    const found = manager.getTask("task-2");
    try testing.expect(found != null);
    try testing.expectEqualStrings("task-2", found.?.id);
}

test "Manager thread-local storage" {
    const allocator = testing.allocator;
    const cfg = Manager.Config{};
    var manager = try Manager.init(allocator, cfg);
    defer manager.deinit();

    try testing.expect(Manager.getCurrent() == null);

    manager.setCurrent();
    try testing.expect(Manager.getCurrent() == &manager);

    Manager.clearCurrent();
    try testing.expect(Manager.getCurrent() == null);
}

test "Manager atomic counters" {
    const allocator = testing.allocator;
    const cfg = Manager.Config{};
    var manager = try Manager.init(allocator, cfg);
    defer manager.deinit();

    // Simulate concurrent counter updates
    _ = manager.completed_counter.fetchAdd(1, .acq_rel);
    _ = manager.completed_counter.fetchAdd(2, .acq_rel);
    try testing.expectEqual(@as(usize, 3), manager.completed_counter.load(.acquire));

    _ = manager.failed_counter.fetchAdd(1, .acq_rel);
    try testing.expectEqual(@as(usize, 1), manager.failed_counter.load(.acquire));
}
