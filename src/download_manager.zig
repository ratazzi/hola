const std = @import("std");
const modern_display = @import("modern_provision_display.zig");
const http_utils = @import("http_utils.zig");
const base_resource = @import("base_resource.zig");
const http_client = @import("http_client.zig");
const logger = @import("logger.zig");

// Thread-local storage for current DownloadManager
threadlocal var current_manager: ?*DownloadManager = null;

/// Download task for a remote file
pub const DownloadTask = struct {
    url: []const u8,
    temp_path: []const u8,
    final_path: []const u8,
    mode: ?[]const u8,
    checksum: ?[]const u8,
    backup: ?[]const u8,
    headers: ?[]const u8, // JSON-encoded HTTP headers
    resource_id: []const u8,
    display_name: []const u8, // Short name for display
    board_line_id: ?usize = null,
    status: std.atomic.Value(u8) = std.atomic.Value(u8).init(0), // 0=queued, 1=completed, 2=failed
    bytes_downloaded: usize = 0,
    total_bytes: usize = 0,
    error_message: std.atomic.Value(?[*:0]u8) = std.atomic.Value(?[*:0]u8).init(null),

    pub fn deinit(self: *DownloadTask, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.temp_path);
        allocator.free(self.final_path);
        if (self.mode) |mode| allocator.free(mode);
        if (self.checksum) |checksum| allocator.free(checksum);
        if (self.backup) |backup| allocator.free(backup);
        if (self.headers) |headers| allocator.free(headers);
        allocator.free(self.resource_id);
        allocator.free(self.display_name);
        if (self.error_message.load(.acquire)) |msg_ptr| {
            allocator.free(std.mem.span(msg_ptr));
        }
    }
};

/// Download manager with worker pool and queue
pub const DownloadManager = struct {
    const Self = @This();

    tasks: std.ArrayList(DownloadTask),
    temp_dir: []const u8,
    allocator: std.mem.Allocator,
    show_progress: bool,
    display: ?*modern_display.ModernProvisionDisplay = null,

    // Worker pool
    workers: []std.Thread,
    max_concurrent: usize,
    mutex: std.Thread.Mutex,
    condition: std.Thread.Condition,
    shutdown: bool,
    next_task_index: usize, // Index of next task to process
    completed_counter: std.atomic.Value(usize),
    failed_counter: std.atomic.Value(usize),

    pub const Config = struct {
        max_concurrent: usize = 5,
    };

    pub fn init(allocator: std.mem.Allocator, show_progress: bool) !Self {
        const xdg = @import("xdg.zig").XDG.init(allocator);
        const temp_dir_path = try xdg.getDownloadsDir();
        errdefer allocator.free(temp_dir_path);

        try std.fs.cwd().makePath(temp_dir_path);

        return Self{
            .tasks = std.ArrayList(DownloadTask).empty,
            .temp_dir = temp_dir_path,
            .allocator = allocator,
            .show_progress = show_progress,
            .workers = &.{},
            .max_concurrent = 5,
            .mutex = .{},
            .condition = .{},
            .shutdown = false,
            .next_task_index = 0,
            .completed_counter = std.atomic.Value(usize).init(0),
            .failed_counter = std.atomic.Value(usize).init(0),
        };
    }

    pub fn setDisplay(self: *Self, display: *modern_display.ModernProvisionDisplay) void {
        self.display = display;
    }

    pub fn getDownloadTempDir(allocator: std.mem.Allocator) ![]const u8 {
        const xdg = @import("xdg.zig").XDG.init(allocator);
        return try xdg.getDownloadsDir();
    }

    pub fn deinit(self: *Self) void {
        for (self.tasks.items) |*task| {
            task.deinit(self.allocator);
        }
        self.tasks.deinit(self.allocator);
        self.allocator.free(self.temp_dir);
        self.allocator.free(self.workers);
    }

    pub fn addTask(self: *Self, task: DownloadTask) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.tasks.append(self.allocator, task);
    }

    /// Get current thread's DownloadManager
    pub fn getCurrent() ?*DownloadManager {
        return current_manager;
    }

    fn updateDownloadProgress(self: *Self, task_index: usize, bytes_downloaded: usize, total_bytes: usize, status: u8) void {
        self.mutex.lock();
        const display = self.display;

        if (task_index >= self.tasks.items.len) {
            self.mutex.unlock();
            return;
        }

        var task = &self.tasks.items[task_index];
        const previous_status = task.status.load(.acquire);
        const previous_total_bytes = task.total_bytes;
        const display_name = task.display_name;
        task.status.store(status, .release);
        task.bytes_downloaded = bytes_downloaded;
        task.total_bytes = total_bytes;
        self.mutex.unlock();

        if (display) |disp| {
            if (status == 0 and previous_status == 0 and bytes_downloaded == 0) {
                disp.addDownload(display_name, total_bytes) catch {};
            } else if (status == 0) {
                if (total_bytes > 0 and previous_total_bytes == 0) {
                    disp.addDownload(display_name, total_bytes) catch {};
                }
                disp.updateDownload(display_name, bytes_downloaded) catch {};
            } else if (status == 1 and previous_status != 1) {
                disp.finishDownload(display_name, true) catch {};
            } else if (status == 2 and previous_status != 2) {
                disp.finishDownload(display_name, false) catch {};
            }
        }
    }

    /// Start parallel downloads
    pub fn startParallelDownloads(self: *Self) !DownloadSession {
        if (self.tasks.items.len == 0) {
            self.completed_counter.store(0, .seq_cst);
            self.failed_counter.store(0, .seq_cst);
            return DownloadSession{
                .threads = &[_]std.Thread{},
                .thread_count = 0,
                .completed = &self.completed_counter,
                .failed = &self.failed_counter,
                .is_active = false,
                .allocator = self.allocator,
                .download_mgr = self,
            };
        }

        // Set as current manager
        current_manager = self;

        // Start worker threads
        const worker_count = @min(self.max_concurrent, self.tasks.items.len);
        self.workers = try self.allocator.alloc(std.Thread, worker_count);

        self.completed_counter.store(0, .seq_cst);
        self.failed_counter.store(0, .seq_cst);

        for (self.workers, 0..) |*worker, i| {
            const context = WorkerContext{
                .worker_id = i,
                .completed = &self.completed_counter,
                .failed = &self.failed_counter,
                .download_mgr = self,
            };
            worker.* = try std.Thread.spawn(.{}, workerLoop, .{context});
        }

        return DownloadSession{
            .threads = self.workers,
            .thread_count = worker_count,
            .completed = &self.completed_counter,
            .failed = &self.failed_counter,
            .is_active = true,
            .allocator = self.allocator,
            .download_mgr = self,
        };
    }

    const WorkerContext = struct {
        worker_id: usize,
        completed: *std.atomic.Value(usize),
        failed: *std.atomic.Value(usize),
        download_mgr: *DownloadManager,
    };

    fn workerLoop(context: WorkerContext) void {
        while (true) {
            context.download_mgr.mutex.lock();

            if (context.download_mgr.shutdown) {
                context.download_mgr.mutex.unlock();
                break;
            }

            // Get next task
            const task_index = context.download_mgr.next_task_index;
            if (task_index >= context.download_mgr.tasks.items.len) {
                context.download_mgr.mutex.unlock();
                break;
            }

            context.download_mgr.next_task_index += 1;
            context.download_mgr.mutex.unlock();

            // Get task data with lock
            context.download_mgr.updateDownloadProgress(task_index, 0, 0, 0);

            context.download_mgr.mutex.lock();
            const task = context.download_mgr.tasks.items[task_index];
            context.download_mgr.mutex.unlock();
            downloadWithProgress(task, context.download_mgr.allocator, context.download_mgr, task_index) catch |err| {
                const error_name = @errorName(err);
                const error_msg_with_url = std.fmt.allocPrint(context.download_mgr.allocator, "{s}: {s}", .{ error_name, task.url }) catch {
                    context.download_mgr.updateDownloadProgress(task_index, 0, 0, 2);
                    _ = context.failed.fetchAdd(1, .seq_cst);
                    continue;
                };
                const error_msg_z = context.download_mgr.allocator.allocSentinel(u8, error_msg_with_url.len, 0) catch {
                    context.download_mgr.allocator.free(error_msg_with_url);
                    context.download_mgr.updateDownloadProgress(task_index, 0, 0, 2);
                    _ = context.failed.fetchAdd(1, .seq_cst);
                    continue;
                };
                @memcpy(error_msg_z, error_msg_with_url);
                context.download_mgr.allocator.free(error_msg_with_url);

                context.download_mgr.mutex.lock();
                if (task_index < context.download_mgr.tasks.items.len) {
                    context.download_mgr.tasks.items[task_index].error_message.store(error_msg_z, .release);
                }
                context.download_mgr.mutex.unlock();

                context.download_mgr.updateDownloadProgress(task_index, 0, 0, 2);
                _ = context.failed.fetchAdd(1, .seq_cst);
                continue;
            };

            context.download_mgr.updateDownloadProgress(task_index, 100, 100, 1);
            _ = context.completed.fetchAdd(1, .seq_cst);
        }
    }

    fn downloadWithProgress(task: DownloadTask, allocator: std.mem.Allocator, download_mgr: *DownloadManager, task_index: usize) !void {
        var client = std.http.Client{ .allocator = allocator };
        defer client.deinit();

        const uri = try std.Uri.parse(task.url);

        // Parse headers if provided
        var headers_list = std.ArrayList(std.http.Header).empty;
        defer {
            for (headers_list.items) |header| {
                allocator.free(header.name);
                allocator.free(header.value);
            }
            headers_list.deinit(allocator);
        }

        if (task.headers) |headers_json| {
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, headers_json, .{}) catch |err| {
                logger.warn("Failed to parse headers JSON: {}", .{err});
                return err;
            };
            defer parsed.deinit();

            if (parsed.value == .object) {
                var it = parsed.value.object.iterator();
                while (it.next()) |entry| {
                    const name_copy = try allocator.dupe(u8, entry.key_ptr.*);
                    const value_str = if (entry.value_ptr.* == .string) entry.value_ptr.*.string else "";
                    const value_copy = try allocator.dupe(u8, value_str);

                    const header = std.http.Header{
                        .name = name_copy,
                        .value = value_copy,
                    };
                    try headers_list.append(allocator, header);
                }
            }
        }

        var req = try client.request(.GET, uri, .{
            .redirect_behavior = @enumFromInt(5),
            .extra_headers = headers_list.items,
        });
        defer req.deinit();

        // Set User-Agent header
        const user_agent = try http_client.getUserAgent(allocator);
        defer allocator.free(user_agent);
        req.headers.user_agent = .{ .override = user_agent };

        try req.sendBodiless();

        var redirect_buffer: [8192]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);

        if (response.head.status.class() != .success) {
            return error.HttpError;
        }

        const content_length = response.head.content_length;
        const initial_total = content_length orelse 0;
        download_mgr.updateDownloadProgress(task_index, 0, initial_total, 0);

        const temp_file = try std.fs.cwd().createFile(task.temp_path, .{ .truncate = true });
        defer temp_file.close();

        // Use readerDecompressing to automatically handle gzip/deflate
        var transfer_buffer: [64 * 1024]u8 = undefined;
        var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        var body_reader = response.readerDecompressing(&transfer_buffer, &decompress, &decompress_buffer);

        var buffer: [64 * 1024]u8 = undefined;
        var total_bytes_downloaded: usize = 0;
        var last_update_time: i128 = std.time.nanoTimestamp();
        const update_interval_ns: i128 = 100_000_000; // 100ms

        while (true) {
            const bytes_read = try body_reader.readSliceShort(&buffer);
            if (bytes_read == 0) break;

            try temp_file.writeAll(buffer[0..bytes_read]);
            total_bytes_downloaded += bytes_read;

            const current_time = std.time.nanoTimestamp();
            const display_total = if (content_length) |cl| cl else total_bytes_downloaded;
            const should_update = current_time - last_update_time >= update_interval_ns or
                (content_length != null and total_bytes_downloaded == content_length.?) or
                (content_length == null and total_bytes_downloaded > 0);
            if (should_update) {
                download_mgr.updateDownloadProgress(task_index, total_bytes_downloaded, display_total, 0);
                last_update_time = current_time;
            }

            // `readSliceShort` only returns fewer bytes when EOF is reached,
            // so exit to avoid calling back into the reader after the body ends.
            if (bytes_read < buffer.len) break;
        }

        const final_size = if (content_length) |cl| cl else total_bytes_downloaded;
        download_mgr.updateDownloadProgress(task_index, total_bytes_downloaded, final_size, 1);

        if (task.checksum) |expected_checksum| {
            const actual_checksum = try http_utils.calculateSha256(allocator, task.temp_path);
            defer allocator.free(actual_checksum);
            if (!std.mem.eql(u8, actual_checksum, expected_checksum)) {
                return error.ChecksumMismatch;
            }
        }
    }

    /// Session handle for parallel downloads
    pub const DownloadSession = struct {
        threads: []std.Thread,
        thread_count: usize,
        completed: *std.atomic.Value(usize),
        failed: *std.atomic.Value(usize),
        is_active: bool,
        allocator: std.mem.Allocator,
        download_mgr: *DownloadManager,

        /// Thread-safe access to task status
        pub fn getTaskStatus(self: *DownloadSession, task_index: usize) !u8 {
            self.download_mgr.mutex.lock();
            defer self.download_mgr.mutex.unlock();

            if (task_index >= self.download_mgr.tasks.items.len) {
                return error.InvalidTaskIndex;
            }
            return self.download_mgr.tasks.items[task_index].status.load(.acquire);
        }

        pub fn deinit(_: *DownloadSession) void {
            // Threads are owned by download_mgr, don't free here
        }

        pub fn waitForCompletion(self: *DownloadSession, allocator: std.mem.Allocator) !struct {
            completed: usize,
            failed: usize,
        } {
            _ = allocator;
            if (!self.is_active) {
                return .{ .completed = 0, .failed = 0 };
            }

            for (self.threads[0..self.thread_count]) |thread| {
                thread.join();
            }

            const completed_count = self.completed.load(.seq_cst);
            const failed_count = self.failed.load(.seq_cst);

            self.is_active = false;
            current_manager = null;

            return .{ .completed = completed_count, .failed = failed_count };
        }

        pub fn showFinalStatus(self: *DownloadSession, allocator: std.mem.Allocator) !void {
            if (!self.is_active) return;

            const result = try self.waitForCompletion(allocator);

            if (self.download_mgr.display) |display| {
                if (result.failed > 0) {
                    const failed_msg = try std.fmt.allocPrint(allocator, "{d} downloads failed", .{result.failed});
                    defer allocator.free(failed_msg);
                    try display.showInfo(failed_msg);
                } else {
                    const success_msg = try std.fmt.allocPrint(allocator, "All {d} downloads completed successfully", .{result.completed});
                    defer allocator.free(success_msg);
                    try display.showInfo(success_msg);
                }
            }
        }
    };

    pub fn applyDownload(self: Self, task: DownloadTask) !void {
        if (task.backup) |backup_ext| {
            try base_resource.createBackup(self.allocator, task.final_path, backup_ext);
        }

        if (std.fs.path.dirname(task.final_path)) |dir| {
            try std.fs.cwd().makePath(dir);
        }

        try std.fs.cwd().rename(task.temp_path, task.final_path);

        if (task.mode) |mode_str| {
            const mode = try std.fmt.parseInt(u32, mode_str, 8);
            base_resource.setFileMode(task.final_path, mode);
        }
    }
};
