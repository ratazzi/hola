const std = @import("std");
const global_io = @import("global_io.zig");
const mruby = @import("mruby.zig");
const mruby_module = @import("mruby_module.zig");
const resources = @import("resources.zig");
const modern_display = @import("modern_provision_display.zig");
const logger = @import("logger.zig");
const http = @import("http.zig");
const resolv = @import("resolv.zig");
const json = @import("json.zig");
const base64 = @import("base64.zig");
const hola_logger = @import("hola_logger.zig");
const node_info = @import("node_info.zig");
const env_access = @import("env_access.zig");
const file_ext = @import("file_ext.zig");
const base = @import("base_resource.zig");
const builtin = @import("builtin");
const is_macos = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;
const AsyncExecutor = @import("async_executor.zig").AsyncExecutor;
const output_channel = @import("output_channel.zig");
const glob = @import("glob.zig");

pub const Options = struct {
    script_path: []const u8,
    use_pretty_output: bool = true, // Default to pretty output
    params_json: ?[]const u8 = null, // JSON string for data_bag injection
    secrets_json: ?[]const u8 = null, // JSON string for secrets_bag injection
};

pub const ResourceResult = struct {
    type_name: []const u8,
    name: []const u8,
    action: []const u8,
    was_updated: bool,
    skipped: bool,
    skip_reason: ?[]const u8,
    error_name: ?[]const u8,
    error_message: ?[]const u8 = null,
    output: ?[]const u8,
};

pub const ProvisionResult = struct {
    executed_count: usize,
    updated_count: usize,
    skipped_count: usize,
    failed_count: usize,
    duration_ms: i64,
    resource_results: std.ArrayList(ResourceResult),

    pub fn deinit(self: *ProvisionResult, allocator: std.mem.Allocator) void {
        freeResourceResults(allocator, &self.resource_results);
    }
};

fn freeResourceResults(allocator: std.mem.Allocator, results: *std.ArrayList(ResourceResult)) void {
    for (results.items) |rr| {
        allocator.free(rr.type_name);
        allocator.free(rr.name);
        allocator.free(rr.action);
        if (rr.skip_reason) |sr| allocator.free(sr);
        if (rr.error_name) |en| allocator.free(en);
        if (rr.error_message) |em| allocator.free(em);
        if (rr.output) |o| allocator.free(o);
    }
    results.deinit(allocator);
    results.* = .empty;
}

pub const SessionOptions = struct {
    params_json: ?[]const u8 = null,
    secrets_json: ?[]const u8 = null,
    mode: SessionMode = .provision,
};

pub const SessionMode = enum {
    provision,
    task,
};

pub const ProvisionRunner = struct {
    allocator: std.mem.Allocator,
    resources: std.ArrayList(resources.ResourceWithMetadata),
    display: ?*modern_display.ModernProvisionDisplay = null,
    download_mgr: ?*http.download.Manager = null,
    resource_results: std.ArrayList(ResourceResult) = .empty,
    delayed_notifications: std.ArrayList(PendingNotification) = .empty,
    converged_index: usize = 0,
    converging: bool = false,
    last_failed_index: ?usize = null,
    start_time: i128 = 0,
    output: output_channel.LineChannel,

    fn init(allocator: std.mem.Allocator) ProvisionRunner {
        return .{
            .allocator = allocator,
            .resources = std.ArrayList(resources.ResourceWithMetadata).empty,
            .output = output_channel.LineChannel.init(allocator),
        };
    }

    fn deinit(self: *ProvisionRunner) void {
        freeResourceResults(self.allocator, &self.resource_results);
        for (self.delayed_notifications.items) |pending| {
            self.allocator.free(pending.source_id);
        }
        self.delayed_notifications.deinit(self.allocator);
        self.output.deinit();
        for (self.resources.items) |*res| {
            res.deinit(self.allocator);
        }
        self.resources.deinit(self.allocator);
    }

    pub fn attachDisplay(self: *ProvisionRunner, display: *modern_display.ModernProvisionDisplay) void {
        self.display = display;
        output_channel.setCurrent(&self.output);
        AsyncExecutor.setPollCallback(pollDisplayUpdate);
    }

    pub fn detachDisplay(self: *ProvisionRunner) void {
        AsyncExecutor.setPollCallback(null);
        output_channel.setCurrent(null);
        self.display = null;
    }

    pub fn takeResults(self: *ProvisionRunner) std.ArrayList(ResourceResult) {
        const results = self.resource_results;
        self.resource_results = .empty;
        return results;
    }

    const ResultFields = struct {
        action: []const u8 = "",
        was_updated: bool = false,
        skipped: bool = false,
        skip_reason: ?[]const u8 = null,
        error_name: ?[]const u8 = null,
        error_message: ?[]const u8 = null,
        output: ?[]const u8 = null,
    };

    fn recordResult(self: *ProvisionRunner, id: resources.ResourceId, fields: ResultFields) !void {
        const type_name = try self.allocator.dupe(u8, id.type_name);
        errdefer self.allocator.free(type_name);
        const name = try self.allocator.dupe(u8, id.name);
        errdefer self.allocator.free(name);
        const action = try self.allocator.dupe(u8, fields.action);
        errdefer self.allocator.free(action);
        const skip_reason = if (fields.skip_reason) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (skip_reason) |value| self.allocator.free(value);
        const error_name = if (fields.error_name) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (error_name) |value| self.allocator.free(value);
        const error_message = if (fields.error_message) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (error_message) |value| self.allocator.free(value);
        const output = if (fields.output) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (output) |value| self.allocator.free(value);

        try self.resource_results.append(self.allocator, .{
            .type_name = type_name,
            .name = name,
            .action = action,
            .was_updated = fields.was_updated,
            .skipped = fields.skipped,
            .skip_reason = skip_reason,
            .error_name = error_name,
            .error_message = error_message,
            .output = output,
        });
    }

    fn waitForDownload(self: *ProvisionRunner, index: usize) !void {
        const download_mgr = self.download_mgr orelse return;
        const display = self.display orelse return error.DisplayNotAttached;
        const res = &self.resources.items[index];
        if (res.resource != .remote_file) return;

        const resource_id = try std.fmt.allocPrint(self.allocator, "{s}[{s}]", .{ res.id.type_name, res.id.name });
        defer self.allocator.free(resource_id);

        const task = download_mgr.getTask(resource_id) orelse return;
        const initial_status = task.status.load(.acquire);
        if (initial_status == .queued or initial_status == .downloading) {
            var max_wait_iterations: usize = 3000;
            while (max_wait_iterations > 0) : (max_wait_iterations -= 1) {
                const status = task.status.load(.acquire);
                if (status != .queued and status != .downloading) break;

                try display.update();
                std.Thread.yield() catch {};
                global_io.io().sleep(.fromNanoseconds(10 * std.time.ns_per_ms), .awake) catch {};
            }
        }

        if (task.status.load(.acquire) == .failed) {
            const err_msg_owned = task.getError(self.allocator);
            defer if (err_msg_owned) |msg| self.allocator.free(msg);
            const err_msg = err_msg_owned orelse "Unknown error";
            const msg = try std.fmt.allocPrint(self.allocator, "Download failed for {s}: {s}", .{ resource_id, err_msg });
            defer self.allocator.free(msg);
            base.recordProvisionErrorDetailSlice(msg);
            return error.DownloadFailed;
        }
    }

    fn applyOne(self: *ProvisionRunner, index: usize, immediate: *std.ArrayList(PendingNotification)) !void {
        const display = self.display orelse return error.DisplayNotAttached;
        base.clearProvisionErrorDetail();
        self.last_failed_index = null;

        try display.startResource(self.resources.items[index].id.type_name, self.resources.items[index].id.name);
        try display.update();
        self.waitForDownload(index) catch |err| {
            const res = &self.resources.items[index];
            const detail_msg = base.getProvisionErrorDetail();
            const error_display = detail_msg orelse @errorName(err);
            try display.resourceError(res.id.type_name, res.id.name, error_display);
            try display.update();
            try self.recordResult(res.id, .{
                .error_name = @errorName(err),
                .error_message = detail_msg,
            });
            self.last_failed_index = index;
            return err;
        };

        const result = self.resources.items[index].resource.apply() catch |err| {
            const res = &self.resources.items[index];
            const detail_msg = base.getProvisionErrorDetail();
            const error_display = detail_msg orelse @errorName(err);
            try display.resourceError(res.id.type_name, res.id.name, error_display);
            try display.update();
            try self.recordResult(res.id, .{
                .error_name = @errorName(err),
                .error_message = detail_msg,
            });

            if (res.resource.shouldIgnoreFailure()) return;
            self.last_failed_index = index;
            return err;
        };
        defer if (result.output) |output| std.heap.c_allocator.free(output);

        // Applying a ruby_block may append resources and reallocate the list.
        // Always reacquire the pointer after apply() before reading metadata.
        const res = &self.resources.items[index];
        res.was_updated = result.was_updated;

        if (result.was_updated) {
            try display.resourceUpdated(res.id.type_name, res.id.name, result.action, result.skip_reason);
            try display.update();
            try self.recordResult(res.id, .{
                .action = result.action,
                .was_updated = true,
                .skip_reason = result.skip_reason,
                .output = result.output,
            });

            if (result.skip_reason == null or !std.mem.eql(u8, result.skip_reason.?, "up to date")) {
                for (res.notifications.items) |notification| {
                    const source_id = try res.id.toString(self.allocator);
                    const pending = PendingNotification{
                        .notification = notification,
                        .source_id = source_id,
                    };
                    if (notification.timing == .immediate) {
                        immediate.append(self.allocator, pending) catch |err| {
                            self.allocator.free(source_id);
                            return err;
                        };
                    } else {
                        self.delayed_notifications.append(self.allocator, pending) catch |err| {
                            self.allocator.free(source_id);
                            return err;
                        };
                    }
                }
            }
            return;
        }

        try display.resourceSkipped(res.id.type_name, res.id.name, result.action, result.skip_reason);
        try display.update();
        try self.recordResult(res.id, .{
            .action = result.action,
            .skipped = true,
            .skip_reason = result.skip_reason,
        });
    }

    pub fn convergeFrom(self: *ProvisionRunner, from_index: usize) !void {
        const display = self.display orelse return error.DisplayNotAttached;
        const start_index = @max(from_index, self.converged_index);
        if (start_index >= self.resources.items.len) return;

        self.converging = true;
        defer self.converging = false;

        // Convert subscriptions on newly declared resources to reverse notifications.
        var subscriber_index = start_index;
        while (subscriber_index < self.resources.items.len) : (subscriber_index += 1) {
            const common = self.resources.items[subscriber_index].resource.getCommonProps();
            for (common.subscriptions.items) |subscription| {
                const source_id = base.notification.ResourceId.parse(self.allocator, subscription.target_resource_id) catch continue;
                defer source_id.deinit(self.allocator);

                for (self.resources.items) |*source_res| {
                    if (!std.mem.eql(u8, source_res.id.type_name, source_id.type_name) or
                        !std.mem.eql(u8, source_res.id.name, source_id.name)) continue;

                    const subscriber_id = try self.resources.items[subscriber_index].id.toString(self.allocator);
                    const action_name = self.allocator.dupe(u8, subscription.action.action_name) catch |err| {
                        self.allocator.free(subscriber_id);
                        return err;
                    };
                    source_res.resource.getCommonProps().notifications.append(self.allocator, .{
                        .target_resource_id = subscriber_id,
                        .action = .{ .action_name = action_name },
                        .timing = subscription.timing,
                    }) catch |err| {
                        self.allocator.free(subscriber_id);
                        self.allocator.free(action_name);
                        return err;
                    };
                    break;
                }
            }
        }

        var immediate_notifications = std.ArrayList(PendingNotification).empty;
        defer {
            for (immediate_notifications.items) |pending| self.allocator.free(pending.source_id);
            immediate_notifications.deinit(self.allocator);
        }

        var index = start_index;
        while (index < self.resources.items.len) : (index += 1) {
            // Advance before apply so a failed resource is never retried by a
            // later incremental converge call.
            self.converged_index = index + 1;
            try self.applyOne(index, &immediate_notifications);
        }

        if (immediate_notifications.items.len > 0) {
            try display.showSectionWithLevel("Processing Immediate Notifications", 3);
            for (immediate_notifications.items) |pending| {
                try processNotification(self.allocator, pending, display);
            }
        }
    }

    pub fn flushDelayed(self: *ProvisionRunner) !void {
        if (self.delayed_notifications.items.len == 0) return;
        const display = self.display orelse return error.DisplayNotAttached;
        try display.showSectionWithLevel("Processing Delayed Notifications", 3);
        for (self.delayed_notifications.items) |pending| {
            try processNotification(self.allocator, pending, display);
        }
        for (self.delayed_notifications.items) |pending| {
            self.allocator.free(pending.source_id);
        }
        self.delayed_notifications.clearRetainingCapacity();
    }
};

threadlocal var current_runner: ?*ProvisionRunner = null;

fn requireRunner() *ProvisionRunner {
    return current_runner orelse @panic("provision runner is not initialized");
}

// Poll callback for async executor
fn pollDisplayUpdate() !void {
    if (current_runner) |runner| {
        if (runner.display) |display| {
            var batch = try runner.output.take();
            defer runner.allocator.free(batch.bytes);
            var index: usize = 0;
            while (index < batch.bytes.len) {
                const stream: output_channel.Stream = switch (batch.bytes[index]) {
                    @intFromEnum(output_channel.Stream.stdout) => .stdout,
                    @intFromEnum(output_channel.Stream.stderr) => .stderr,
                    else => break,
                };
                const line_start = index + 1;
                const relative_end = std.mem.indexOfScalar(u8, batch.bytes[line_start..], '\n') orelse break;
                const line_end = line_start + relative_end;
                try display.printCommandLine(stream, batch.bytes[line_start..line_end]);
                index = line_end + 1;
            }
            if (batch.dropped > 0) {
                var message_buf: [128]u8 = undefined;
                const message = try std.fmt.bufPrint(&message_buf, "   [hola] dropped {d} live output lines", .{batch.dropped});
                try display.printLine(message);
            }
            try display.update();
        }
    }
}

fn currentRunnerOrNilValue() ?*ProvisionRunner {
    return current_runner;
}

// Pending notification wrapper
const PendingNotification = struct {
    notification: resources.Notification,
    source_id: []const u8,
};

/// A reusable mruby provisioning session. The value is heap allocated so the
/// threadlocal runner pointer remains stable while resource callbacks execute.
pub const Session = struct {
    allocator: std.mem.Allocator,
    mrb: mruby.State,
    runner: ProvisionRunner,

    pub fn open(allocator: std.mem.Allocator, opts: SessionOptions) !*Session {
        base.clearProvisionErrorDetail();

        var mrb_state = try mruby.State.init();
        const self = allocator.create(Session) catch |err| {
            mrb_state.deinit();
            return err;
        };
        self.* = .{
            .allocator = allocator,
            .mrb = mrb_state,
            .runner = ProvisionRunner.init(allocator),
        };
        current_runner = &self.runner;

        self.initialize(opts) catch |err| {
            self.close();
            return err;
        };
        return self;
    }

    fn initialize(self: *Session, opts: SessionOptions) !void {
        const mrb_ptr = self.mrb.mrb orelse return error.MRubyNotInitialized;
        const zig_module = mruby.mrb_define_module(mrb_ptr, "ZigBackend");
        registerResourceBindings(mrb_ptr, zig_module);

        const api_modules = [_]mruby_module.MRubyModule{
            file_ext.mruby_module_def,
            json.mruby_module_def,
            http.mruby_module_def,
            base64.mruby_module_def,
            hola_logger.mruby_module_def,
            node_info.mruby_module_def,
            env_access.mruby_module_def,
            resolv.mruby_module_def,
        };
        for (api_modules) |module| {
            try mruby_module.registerModule(mrb_ptr, zig_module, self.allocator, module, &self.mrb);
        }

        file_ext.setupFileExtensions(mrb_ptr);
        try self.mrb.evalString(@embedFile("ruby_prelude/open_struct.rb"));
        try self.mrb.evalString(@embedFile("ruby_prelude/time_parse.rb"));

        try self.mrb.evalString(resources.file.ruby_prelude);
        try self.mrb.evalString(resources.execute.ruby_prelude);
        try self.mrb.evalString(resources.remote_file.ruby_prelude);
        try self.mrb.evalString(resources.template.ruby_prelude);
        try self.mrb.evalString(resources.macos_dock.ruby_prelude);
        try self.mrb.evalString(resources.macos_defaults.ruby_prelude);
        try self.mrb.evalString(resources.directory.ruby_prelude);
        try self.mrb.evalString(resources.link.ruby_prelude);
        try self.mrb.evalString(resources.route.ruby_prelude);
        try self.mrb.evalString(resources.apt_repository.ruby_prelude);
        try self.mrb.evalString(resources.systemd_unit.ruby_prelude);
        try self.mrb.evalString(resources.mount_res.ruby_prelude);
        try self.mrb.evalString(resources.package.ruby_prelude);
        try self.mrb.evalString(resources.homebrew_package.ruby_prelude);
        try self.mrb.evalString(resources.apt_package.ruby_prelude);
        try self.mrb.evalString(resources.ruby_block.ruby_prelude);
        try self.mrb.evalString(resources.git.ruby_prelude);
        try self.mrb.evalString(resources.user.ruby_prelude);
        try self.mrb.evalString(resources.group.ruby_prelude);
        try self.mrb.evalString(resources.aws_kms.ruby_prelude);
        try self.mrb.evalString(resources.file_edit.ruby_prelude);
        try self.mrb.evalString(resources.extract.ruby_prelude);
        try self.mrb.evalString(@embedFile("resources/apt_update_resource.rb"));

        // `file` and `directory` are standard Rake task constructors. Keep the
        // provision resource classes available for the explicit
        // Hola::Resources namespace, but remove their top-level methods before
        // a Rakefile is evaluated.
        if (opts.mode == .task) {
            try self.mrb.evalString(
                \\Object.send(:remove_method, :file)
                \\Object.send(:remove_method, :directory)
            );
        }

        try self.mrb.evalString(@embedFile("ruby_prelude/data_bag.rb"));
        try self.mrb.evalString(@embedFile("ruby_prelude/secrets_bag.rb"));

        if (opts.params_json) |params_json| try injectParams(mrb_ptr, params_json);
        if (opts.secrets_json) |secrets_json| try injectSecrets(mrb_ptr, secrets_json);
        if (builtin.mode == .Debug) {
            try self.mrb.evalString(@embedFile("ruby_prelude/test_helper.rb"));
        }
    }

    pub fn close(self: *Session) void {
        if (self.runner.display != null) self.runner.detachDisplay();
        if (current_runner) |runner| {
            if (runner == &self.runner) current_runner = null;
        }
        // Resource teardown unregisters mruby guard values, so it must happen
        // before the interpreter is closed.
        self.runner.deinit();
        self.mrb.deinit();
        self.allocator.destroy(self);
    }

    pub fn evalScript(self: *Session, path: []const u8) !void {
        self.mrb.evalFile(path) catch |err| {
            if (err == error.MRubyException) {
                const mrb_ptr = self.mrb.mrb orelse return error.MRubyNotInitialized;
                const exc = mruby.mrb_get_exception(mrb_ptr);
                if (mruby.mrb_test(exc)) {
                    base.recordProvisionException(mrb_ptr, exc, "script raised");
                }
            }
            return err;
        };
    }

    pub fn evalString(self: *Session, code: []const u8) !void {
        try self.mrb.evalString(code);
    }

    pub fn loadTaskPrelude(self: *Session) !void {
        try self.mrb.evalString(@embedFile("ruby_prelude/tasks.rb"));
    }
};

fn cloneNotificationsFromCommon(
    allocator: std.mem.Allocator,
    common: *const base.CommonProps,
) !std.ArrayList(resources.Notification) {
    var notifications = std.ArrayList(resources.Notification).empty;
    for (common.notifications.items) |notif| {
        const target_id = try allocator.dupe(u8, notif.target_resource_id);
        const action_name = try allocator.dupe(u8, notif.action.action_name);

        const notif_copy = resources.Notification{
            .target_resource_id = target_id,
            .action = .{ .action_name = action_name },
            .timing = notif.timing,
        };
        try notifications.append(allocator, notif_copy);
    }
    return notifications;
}

fn makeResourceId(
    allocator: std.mem.Allocator,
    type_name: []const u8,
    name: []const u8,
) !resources.ResourceId {
    return resources.ResourceId{
        .type_name = try allocator.dupe(u8, type_name),
        .name = try allocator.dupe(u8, name),
    };
}

fn addResourceWithMetadata(
    comptime T: type,
    mrb: *mruby.mrb_state,
    self: mruby.mrb_value,
    add_fn: fn (*mruby.mrb_state, mruby.mrb_value, *std.ArrayList(T), std.mem.Allocator) mruby.mrb_value,
    build_id: fn (std.mem.Allocator, *const T) anyerror!resources.ResourceId,
    wrap: fn (T) resources.Resource,
    get_common_props: fn (*const T) *const base.CommonProps,
) mruby.mrb_value {
    const runner = currentRunnerOrNilValue() orelse return mruby.mrb_nil_value();
    const allocator = runner.allocator;

    // Create a temporary ArrayList for this resource type
    var tmp_resources = std.ArrayList(T).empty;
    defer tmp_resources.deinit(allocator);

    // Call the resource-specific Zig add function
    const result = add_fn(mrb, self, &tmp_resources, allocator);

    // If nothing was added, just return the result from the resource handler
    if (tmp_resources.items.len == 0) return result;

    // Process all resources in tmp_resources (some resources like systemd_unit create multiple)
    for (tmp_resources.items) |res| {
        // Build ResourceId
        const id = build_id(allocator, &res) catch return mruby.mrb_nil_value();

        // Copy notifications from common props into metadata
        const common_ref = get_common_props(&res);
        const notifications = cloneNotificationsFromCommon(allocator, common_ref) catch return mruby.mrb_nil_value();

        // Wrap into unified Resource enum
        const res_with_meta = resources.ResourceWithMetadata{
            .resource = wrap(res),
            .id = id,
            .notifications = notifications,
        };

        runner.resources.append(allocator, res_with_meta) catch return mruby.mrb_nil_value();
    }

    return result;
}

fn addSimpleResourceWithMetadata(
    comptime T: type,
    comptime type_name: []const u8,
    comptime id_field: []const u8,
    comptime union_field: []const u8,
    comptime common_field: []const u8,
    mrb: *mruby.mrb_state,
    self: mruby.mrb_value,
    add_fn: fn (*mruby.mrb_state, mruby.mrb_value, *std.ArrayList(T), std.mem.Allocator) mruby.mrb_value,
) mruby.mrb_value {
    const Adapters = struct {
        fn buildId(allocator: std.mem.Allocator, res: *const T) !resources.ResourceId {
            return makeResourceId(allocator, type_name, @field(res.*, id_field));
        }
        fn wrap(res: T) resources.Resource {
            return @unionInit(resources.Resource, union_field, res);
        }
        fn getCommonProps(res: *const T) *const base.CommonProps {
            return &@field(res.*, common_field);
        }
    };
    return addResourceWithMetadata(
        T,
        mrb,
        self,
        add_fn,
        Adapters.buildId,
        Adapters.wrap,
        Adapters.getCommonProps,
    );
}

fn addFixedIdResourceWithMetadata(
    comptime T: type,
    comptime type_name: []const u8,
    comptime fixed_name: []const u8,
    comptime union_field: []const u8,
    comptime common_field: []const u8,
    mrb: *mruby.mrb_state,
    self: mruby.mrb_value,
    add_fn: fn (*mruby.mrb_state, mruby.mrb_value, *std.ArrayList(T), std.mem.Allocator) mruby.mrb_value,
) mruby.mrb_value {
    const Adapters = struct {
        fn buildId(allocator: std.mem.Allocator, res: *const T) !resources.ResourceId {
            _ = res;
            return makeResourceId(allocator, type_name, fixed_name);
        }
        fn wrap(res: T) resources.Resource {
            return @unionInit(resources.Resource, union_field, res);
        }
        fn getCommonProps(res: *const T) *const base.CommonProps {
            return &@field(res.*, common_field);
        }
    };
    return addResourceWithMetadata(
        T,
        mrb,
        self,
        add_fn,
        Adapters.buildId,
        Adapters.wrap,
        Adapters.getCommonProps,
    );
}

fn addDisplayNameResourceWithMetadata(
    comptime T: type,
    comptime type_name: []const u8,
    comptime union_field: []const u8,
    comptime common_field: []const u8,
    mrb: *mruby.mrb_state,
    self: mruby.mrb_value,
    add_fn: fn (*mruby.mrb_state, mruby.mrb_value, *std.ArrayList(T), std.mem.Allocator) mruby.mrb_value,
) mruby.mrb_value {
    const Adapters = struct {
        fn buildId(allocator: std.mem.Allocator, res: *const T) !resources.ResourceId {
            return makeResourceId(allocator, type_name, res.displayName());
        }
        fn wrap(res: T) resources.Resource {
            return @unionInit(resources.Resource, union_field, res);
        }
        fn getCommonProps(res: *const T) *const base.CommonProps {
            return &@field(res.*, common_field);
        }
    };
    return addResourceWithMetadata(
        T,
        mrb,
        self,
        add_fn,
        Adapters.buildId,
        Adapters.wrap,
        Adapters.getCommonProps,
    );
}

fn addMacosDefaultsResourceWithMetadata(
    mrb: *mruby.mrb_state,
    self: mruby.mrb_value,
) mruby.mrb_value {
    const T = resources.macos_defaults.Resource;
    const Adapters = struct {
        fn buildId(allocator: std.mem.Allocator, res: *const T) !resources.ResourceId {
            const id_str = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ res.domain, res.key });
            defer allocator.free(id_str);
            return makeResourceId(allocator, "macos_defaults", id_str);
        }
        fn wrap(res: T) resources.Resource {
            return .{ .macos_defaults = res };
        }
        fn getCommonProps(res: *const T) *const base.CommonProps {
            return &res.common;
        }
    };
    return addResourceWithMetadata(
        T,
        mrb,
        self,
        resources.macos_defaults.zigAddResource,
        Adapters.buildId,
        Adapters.wrap,
        Adapters.getCommonProps,
    );
}

fn addPackageResourceWithMetadata(
    mrb: *mruby.mrb_state,
    self: mruby.mrb_value,
) mruby.mrb_value {
    const T = resources.package.Resource;
    const Adapters = struct {
        fn buildId(allocator: std.mem.Allocator, res: *const T) !resources.ResourceId {
            return makeResourceId(allocator, "package", res.displayName());
        }
        fn wrap(res: T) resources.Resource {
            return .{ .package = res };
        }
        fn getCommonProps(res: *const T) *const base.CommonProps {
            if (is_macos) {
                return switch (res.backend) {
                    .homebrew => |*hb| &hb.common_props,
                };
            } else if (is_linux) {
                return switch (res.backend) {
                    .apt => |*apt| &apt.common_props,
                };
            } else {
                unreachable;
            }
        }
    };
    return addResourceWithMetadata(
        T,
        mrb,
        self,
        resources.package.zigAddResource,
        Adapters.buildId,
        Adapters.wrap,
        Adapters.getCommonProps,
    );
}

/// Get a short filename from URL for display
fn getShortFileNameFromUrl(url: []const u8) []const u8 {
    if (std.mem.lastIndexOf(u8, url, "/")) |last_slash| {
        return url[last_slash + 1 ..];
    }
    return url;
}

/// Process a notification by finding the target resource and triggering the action
fn processNotification(allocator: std.mem.Allocator, pending: PendingNotification, display: *modern_display.ModernProvisionDisplay) !void {
    const runner = requireRunner();
    const notif = pending.notification;

    // Parse target resource ID
    const target_id = resources.ResourceId.parse(allocator, notif.target_resource_id) catch |err| {
        const error_msg = try std.fmt.allocPrint(allocator, "Invalid target resource ID '{s}': {}", .{ notif.target_resource_id, err });
        defer allocator.free(error_msg);
        try display.showInfo(error_msg);
        return;
    };
    defer target_id.deinit(allocator);

    // Find target resource
    var found = false;
    for (runner.resources.items) |*target_res| {
        if (std.mem.eql(u8, target_res.id.type_name, target_id.type_name) and
            std.mem.eql(u8, target_res.id.name, target_id.name))
        {
            found = true;
            const target_desc = try std.fmt.allocPrint(allocator, "{s}[{s}]", .{ target_res.id.type_name, target_res.id.name });
            defer allocator.free(target_desc);
            try display.showNotification(pending.source_id, target_desc, notif.action.action_name);

            // TODO: For now, just log. In the future, resources will have an "actions" map
            // that allows triggering specific actions like "restart", "reload", etc.
            break;
        }
    }

    if (!found) {
        const error_msg = try std.fmt.allocPrint(allocator, "Target resource '{s}' not found", .{notif.target_resource_id});
        defer allocator.free(error_msg);
        try display.showInfo(error_msg);
    }
}

// Zig callback for execute resource
export fn zig_add_execute_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    return addSimpleResourceWithMetadata(
        resources.execute.Resource,
        "execute",
        "name",
        "execute",
        "common",
        mrb,
        self,
        resources.execute.zigAddResource,
    );
}

// Zig callback for file resource
export fn zig_add_file_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    return addSimpleResourceWithMetadata(
        resources.file.Resource,
        "file",
        "path",
        "file",
        "common",
        mrb,
        self,
        resources.file.zigAddResource,
    );
}

// Zig callback for remote_file resource
export fn zig_add_remote_file_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    return addSimpleResourceWithMetadata(
        resources.remote_file.Resource,
        "remote_file",
        "path",
        "remote_file",
        "common",
        mrb,
        self,
        resources.remote_file.zigAddResource,
    );
}

// Zig callback for template resource
export fn zig_add_template_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    return addSimpleResourceWithMetadata(
        resources.template.Resource,
        "template",
        "path",
        "template",
        "common",
        mrb,
        self,
        resources.template.zigAddResource,
    );
}

// Zig callback for macos_dock resource (macOS only)
export fn zig_add_macos_dock_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    if (!is_macos) {
        return mruby.mrb_nil_value();
    }

    return addFixedIdResourceWithMetadata(
        resources.macos_dock.Resource,
        "macos_dock",
        "Dock",
        "macos_dock",
        "common",
        mrb,
        self,
        resources.macos_dock.zigAddResource,
    );
}

// Zig callback for directory resource
export fn zig_add_directory_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    return addSimpleResourceWithMetadata(
        resources.directory.Resource,
        "directory",
        "path",
        "directory",
        "common",
        mrb,
        self,
        resources.directory.zigAddResource,
    );
}

// Zig callback for link resource
export fn zig_add_link_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    return addSimpleResourceWithMetadata(
        resources.link.Resource,
        "link",
        "path",
        "link",
        "common",
        mrb,
        self,
        resources.link.zigAddResource,
    );
}

// Zig callback for route resource
export fn zig_add_route_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    return addSimpleResourceWithMetadata(
        resources.route.Resource,
        "route",
        "target",
        "route",
        "common",
        mrb,
        self,
        resources.route.zigAddResource,
    );
}

// Zig callback for macos_defaults resource (macOS only)
export fn zig_add_macos_defaults_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    if (!is_macos) {
        return mruby.mrb_nil_value();
    }

    return addMacosDefaultsResourceWithMetadata(mrb, self);
}

// Zig callback for apt_repository resource (Linux only)
export fn zig_add_apt_repository_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    if (!is_linux) {
        return mruby.mrb_nil_value();
    }

    return addSimpleResourceWithMetadata(
        resources.apt_repository.Resource,
        "apt_repository",
        "name",
        "apt_repository",
        "common",
        mrb,
        self,
        resources.apt_repository.zigAddResource,
    );
}

// Zig callback for systemd_unit resource (Linux-only)
export fn zig_add_systemd_unit_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    if (!is_linux) {
        return mruby.mrb_nil_value();
    }

    return addSimpleResourceWithMetadata(
        resources.systemd_unit.Resource,
        "systemd_unit",
        "name",
        "systemd_unit",
        "common",
        mrb,
        self,
        resources.systemd_unit.zigAddResource,
    );
}

// Zig callback for mount resource (Linux-only)
export fn zig_add_mount_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    if (!is_linux) {
        return mruby.mrb_nil_value();
    }

    return addSimpleResourceWithMetadata(
        resources.mount_res.Resource,
        "mount",
        "mount_point",
        "mount_res",
        "common",
        mrb,
        self,
        resources.mount_res.zigAddResource,
    );
}

// Zig callback for package resource (cross-platform)
export fn zig_add_package_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    return addPackageResourceWithMetadata(mrb, self);
}

// Zig callback for homebrew_package resource (macOS only)
export fn zig_add_homebrew_package_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    if (builtin.os.tag != .macos) {
        logger.err("homebrew_package resource is only available on macOS", .{});
        return mruby.mrb_nil_value();
    }
    return addDisplayNameResourceWithMetadata(
        resources.homebrew_package.Resource,
        "homebrew_package",
        "homebrew_package",
        "common_props",
        mrb,
        self,
        resources.homebrew_package.zigAddResource,
    );
}

// Zig callback for apt_package resource (Linux only)
export fn zig_add_apt_package_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    if (builtin.os.tag != .linux) {
        logger.err("apt_package resource is only available on Linux", .{});
        return mruby.mrb_nil_value();
    }
    return addDisplayNameResourceWithMetadata(
        resources.apt_package.Resource,
        "apt_package",
        "apt_package",
        "common_props",
        mrb,
        self,
        resources.apt_package.zigAddResource,
    );
}

// Zig callback for ruby_block resource (cross-platform)
export fn zig_add_ruby_block_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    return addSimpleResourceWithMetadata(
        resources.ruby_block.Resource,
        "ruby_block",
        "name",
        "ruby_block",
        "common",
        mrb,
        self,
        resources.ruby_block.zigAddResource,
    );
}

// Zig callback for git resource (cross-platform)
export fn zig_add_git_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    return addSimpleResourceWithMetadata(
        resources.git.Resource,
        "git",
        "destination",
        "git",
        "common",
        mrb,
        self,
        resources.git.zigAddResource,
    );
}

// Zig callback for user resource (cross-platform)
export fn zig_add_user_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    return addSimpleResourceWithMetadata(
        resources.user.Resource,
        "user",
        "username",
        "user",
        "common",
        mrb,
        self,
        resources.user.zigAddResource,
    );
}

// Zig callback for group resource (cross-platform)
export fn zig_add_group_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    return addSimpleResourceWithMetadata(
        resources.group.Resource,
        "group",
        "group_name",
        "group",
        "common",
        mrb,
        self,
        resources.group.zigAddResource,
    );
}

// Zig callback for aws_kms resource (cross-platform)
export fn zig_add_aws_kms_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    return addSimpleResourceWithMetadata(
        resources.aws_kms.Resource,
        "aws_kms",
        "name",
        "aws_kms",
        "common",
        mrb,
        self,
        resources.aws_kms.zigAddResource,
    );
}

// Zig callback for file_edit resource (cross-platform)
export fn zig_add_file_edit_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    return addSimpleResourceWithMetadata(
        resources.file_edit.Resource,
        "file_edit",
        "path",
        "file_edit",
        "common",
        mrb,
        self,
        resources.file_edit.zigAddResource,
    );
}

// Zig callback for extract resource (cross-platform)
export fn zig_add_extract_resource(mrb: *mruby.mrb_state, self: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    return addSimpleResourceWithMetadata(
        resources.extract.Resource,
        "extract",
        "destination",
        "extract",
        "common",
        mrb,
        self,
        resources.extract.zigAddResource,
    );
}

const ResourcePlatform = enum {
    all,
    macos,
    linux,

    fn isSupported(self: ResourcePlatform) bool {
        return switch (self) {
            .all => true,
            .macos => is_macos,
            .linux => is_linux,
        };
    }
};

const ResourceBinding = struct {
    name: [*:0]const u8,
    handler: mruby.mrb_func_t,
    args_spec: mruby.mrb_aspec,
    platform: ResourcePlatform = .all,
};

fn statusPair(mrb: *mruby.mrb_state, ok: bool, message: ?[]const u8) mruby.mrb_value {
    const pair = mruby.mrb_ary_new_capa(mrb, 2);
    mruby.mrb_ary_push(mrb, pair, if (ok) mruby.zig_mrb_true_value() else mruby.zig_mrb_false_value());
    if (message) |text| {
        mruby.mrb_ary_push(mrb, pair, mruby.mrb_str_new(mrb, text.ptr, @intCast(text.len)));
    } else {
        mruby.mrb_ary_push(mrb, pair, mruby.mrb_nil_value());
    }
    return pair;
}

export fn zig_converge(mrb: *mruby.mrb_state, self_value: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    _ = self_value;
    const runner = currentRunnerOrNilValue() orelse return statusPair(mrb, false, "provision runner is not initialized");
    if (runner.display == null) return statusPair(mrb, false, "provision display is not attached");
    if (runner.converging or runner.converged_index >= runner.resources.items.len) {
        return statusPair(mrb, true, null);
    }

    const arena_index = mruby.zig_mrb_gc_arena_save(mrb);
    const converge_error: ?anyerror = blk: {
        runner.convergeFrom(runner.converged_index) catch |err| break :blk err;
        break :blk null;
    };
    mruby.zig_mrb_gc_arena_restore(mrb, arena_index);

    if (converge_error) |err| {
        const detail = base.getProvisionErrorDetail() orelse @errorName(err);
        if (runner.last_failed_index) |index| {
            if (index < runner.resources.items.len) {
                const id = runner.resources.items[index].id;
                const message = std.fmt.allocPrint(runner.allocator, "{s}[{s}]: {s}", .{ id.type_name, id.name, detail }) catch {
                    return statusPair(mrb, false, detail);
                };
                defer runner.allocator.free(message);
                return statusPair(mrb, false, message);
            }
        }
        return statusPair(mrb, false, detail);
    }
    return statusPair(mrb, true, null);
}

export fn zig_flush_delayed(mrb: *mruby.mrb_state, self_value: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    _ = self_value;
    const runner = currentRunnerOrNilValue() orelse return statusPair(mrb, false, "provision runner is not initialized");
    if (runner.display == null) return statusPair(mrb, false, "provision display is not attached");
    runner.flushDelayed() catch |err| {
        return statusPair(mrb, false, base.getProvisionErrorDetail() orelse @errorName(err));
    };
    return statusPair(mrb, true, null);
}

export fn zig_display_section(mrb: *mruby.mrb_state, self_value: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    _ = self_value;
    var name_value: mruby.mrb_value = undefined;
    if (mruby.mrb_get_args(mrb, "S", &name_value) != 1) {
        return statusPair(mrb, false, "display_section expects one task name");
    }
    const runner = currentRunnerOrNilValue() orelse return statusPair(mrb, false, "provision runner is not initialized");
    const display = runner.display orelse return statusPair(mrb, false, "provision display is not attached");
    const name = std.mem.span(mruby.mrb_str_to_cstr(mrb, name_value));
    display.showTaskSection(name) catch |err| return statusPair(mrb, false, @errorName(err));
    return statusPair(mrb, true, null);
}

export fn zig_print_line(mrb: *mruby.mrb_state, self_value: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    _ = self_value;
    var text_value: mruby.mrb_value = undefined;
    if (mruby.mrb_get_args(mrb, "S", &text_value) != 1) {
        return statusPair(mrb, false, "print_line expects one string");
    }
    const runner = currentRunnerOrNilValue() orelse return statusPair(mrb, false, "provision runner is not initialized");
    const display = runner.display orelse return statusPair(mrb, false, "provision display is not attached");
    const line = std.mem.span(mruby.mrb_str_to_cstr(mrb, text_value));
    display.printLine(line) catch |err| return statusPair(mrb, false, @errorName(err));
    return statusPair(mrb, true, null);
}

export fn zig_glob(mrb: *mruby.mrb_state, self_value: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    _ = self_value;
    var pattern_value: mruby.mrb_value = undefined;
    if (mruby.mrb_get_args(mrb, "S", &pattern_value) != 1) return mruby.mrb_ary_new_capa(mrb, 0);
    const runner = currentRunnerOrNilValue() orelse return mruby.mrb_ary_new_capa(mrb, 0);
    const pattern = std.mem.span(mruby.mrb_str_to_cstr(mrb, pattern_value));
    var matches = glob.expand(runner.allocator, global_io.io(), pattern) catch return mruby.mrb_ary_new_capa(mrb, 0);
    defer glob.freeMatches(runner.allocator, &matches);

    const result = mruby.mrb_ary_new_capa(mrb, @intCast(matches.items.len));
    for (matches.items) |path| {
        mruby.mrb_ary_push(mrb, result, mruby.mrb_str_new(mrb, path.ptr, @intCast(path.len)));
    }
    return result;
}

export fn zig_load_file(mrb: *mruby.mrb_state, self_value: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    _ = self_value;
    var path_value: mruby.mrb_value = undefined;
    if (mruby.mrb_get_args(mrb, "S", &path_value) != 1) return statusPair(mrb, false, "load_file expects one path");
    const runner = currentRunnerOrNilValue() orelse return statusPair(mrb, false, "provision runner is not initialized");
    const path = std.mem.span(mruby.mrb_str_to_cstr(mrb, path_value));
    const source = std.Io.Dir.cwd().readFileAlloc(global_io.io(), path, runner.allocator, .unlimited) catch |err| {
        const message = std.fmt.allocPrint(runner.allocator, "cannot load {s}: {s}", .{ path, @errorName(err) }) catch return statusPair(mrb, false, @errorName(err));
        defer runner.allocator.free(message);
        return statusPair(mrb, false, message);
    };
    defer runner.allocator.free(source);
    const path_z = runner.allocator.dupeZ(u8, path) catch return statusPair(mrb, false, "out of memory loading Ruby file");
    defer runner.allocator.free(path_z);

    return switch (mruby.loadStringProtected(mrb, source, path_z)) {
        .ok => statusPair(mrb, true, null),
        .raised => |exc| blk: {
            var summary: [1024]u8 = undefined;
            mruby.zig_mrb_exc_summary(mrb, exc, &summary, summary.len);
            break :blk statusPair(mrb, false, std.mem.sliceTo(&summary, 0));
        },
    };
}

fn registerResourceBindings(mrb_ptr: *mruby.mrb_state, zig_module: *mruby.RClass) void {
    const bindings = [_]ResourceBinding{
        .{ .name = "converge", .handler = zig_converge, .args_spec = mruby.MRB_ARGS_NONE() },
        .{ .name = "flush_delayed", .handler = zig_flush_delayed, .args_spec = mruby.MRB_ARGS_NONE() },
        .{ .name = "display_section", .handler = zig_display_section, .args_spec = mruby.MRB_ARGS_REQ(1) },
        .{ .name = "print_line", .handler = zig_print_line, .args_spec = mruby.MRB_ARGS_REQ(1) },
        .{ .name = "glob", .handler = zig_glob, .args_spec = mruby.MRB_ARGS_REQ(1) },
        .{ .name = "load_file", .handler = zig_load_file, .args_spec = mruby.MRB_ARGS_REQ(1) },
        .{ .name = "add_file", .handler = zig_add_file_resource, .args_spec = mruby.MRB_ARGS_REQ(6) | mruby.MRB_ARGS_OPT(5) },
        .{ .name = "add_execute", .handler = zig_add_execute_resource, .args_spec = mruby.MRB_ARGS_REQ(10) | mruby.MRB_ARGS_OPT(5) },
        .{ .name = "add_remote_file", .handler = zig_add_remote_file_resource, .args_spec = mruby.MRB_ARGS_REQ(12) | mruby.MRB_ARGS_OPT(15) },
        .{ .name = "add_template", .handler = zig_add_template_resource, .args_spec = mruby.MRB_ARGS_REQ(7) | mruby.MRB_ARGS_OPT(5) },
        .{ .name = "add_macos_dock", .handler = zig_add_macos_dock_resource, .args_spec = mruby.MRB_ARGS_REQ(1) | mruby.MRB_ARGS_OPT(10), .platform = .macos },
        .{ .name = "add_directory", .handler = zig_add_directory_resource, .args_spec = mruby.MRB_ARGS_REQ(6) | mruby.MRB_ARGS_OPT(5) },
        .{ .name = "add_link", .handler = zig_add_link_resource, .args_spec = mruby.MRB_ARGS_REQ(4) | mruby.MRB_ARGS_OPT(6) },
        .{ .name = "add_route", .handler = zig_add_route_resource, .args_spec = mruby.MRB_ARGS_REQ(5) | mruby.MRB_ARGS_OPT(5) },
        .{ .name = "add_macos_defaults", .handler = zig_add_macos_defaults_resource, .args_spec = mruby.MRB_ARGS_REQ(2) | mruby.MRB_ARGS_OPT(9), .platform = .macos },
        .{ .name = "add_apt_repository", .handler = zig_add_apt_repository_resource, .args_spec = mruby.MRB_ARGS_REQ(10) | mruby.MRB_ARGS_OPT(5), .platform = .linux },
        .{ .name = "add_systemd_unit", .handler = zig_add_systemd_unit_resource, .args_spec = mruby.MRB_ARGS_REQ(3) | mruby.MRB_ARGS_OPT(5), .platform = .linux },
        .{ .name = "add_mount", .handler = zig_add_mount_resource, .args_spec = mruby.MRB_ARGS_REQ(9) | mruby.MRB_ARGS_OPT(5), .platform = .linux },
        .{ .name = "add_package", .handler = zig_add_package_resource, .args_spec = mruby.MRB_ARGS_REQ(4) | mruby.MRB_ARGS_OPT(6) },
        .{ .name = "add_homebrew_package", .handler = zig_add_homebrew_package_resource, .args_spec = mruby.MRB_ARGS_REQ(4) | mruby.MRB_ARGS_OPT(5), .platform = .macos },
        .{ .name = "add_apt_package", .handler = zig_add_apt_package_resource, .args_spec = mruby.MRB_ARGS_REQ(4) | mruby.MRB_ARGS_OPT(5), .platform = .linux },
        .{ .name = "add_ruby_block", .handler = zig_add_ruby_block_resource, .args_spec = mruby.MRB_ARGS_REQ(4) | mruby.MRB_ARGS_OPT(5) },
        .{ .name = "add_git", .handler = zig_add_git_resource, .args_spec = mruby.MRB_ARGS_REQ(14) | mruby.MRB_ARGS_OPT(5) },
        .{ .name = "add_user", .handler = zig_add_user_resource, .args_spec = mruby.MRB_ARGS_REQ(11) | mruby.MRB_ARGS_OPT(5) },
        .{ .name = "add_group", .handler = zig_add_group_resource, .args_spec = mruby.MRB_ARGS_REQ(9) | mruby.MRB_ARGS_OPT(5) },
        .{ .name = "add_aws_kms", .handler = zig_add_aws_kms_resource, .args_spec = mruby.MRB_ARGS_REQ(15) | mruby.MRB_ARGS_OPT(5) },
        .{ .name = "add_file_edit", .handler = zig_add_file_edit_resource, .args_spec = mruby.MRB_ARGS_REQ(6) | mruby.MRB_ARGS_OPT(5) },
        .{ .name = "add_extract", .handler = zig_add_extract_resource, .args_spec = mruby.MRB_ARGS_REQ(8) | mruby.MRB_ARGS_OPT(5) },
    };

    inline for (bindings) |binding| {
        if (binding.platform.isSupported()) {
            mruby.mrb_define_module_function(
                mrb_ptr,
                zig_module,
                binding.name,
                binding.handler,
                binding.args_spec,
            );
        }
    }
}

/// Inject a JSON string into mruby as a global variable via JSON.parse.
fn injectJsonGlobal(mrb: *mruby.mrb_state, global_name: []const u8, json_str: []const u8) !void {
    var escaped_len: usize = 0;
    for (json_str) |ch| {
        escaped_len += if (ch == '\'' or ch == '\\') @as(usize, 2) else 1;
    }

    const allocator = std.heap.c_allocator;
    const buf = try allocator.alloc(u8, global_name.len + escaped_len + 64 + 1);
    defer allocator.free(buf);

    var pos: usize = 0;
    @memcpy(buf[pos .. pos + global_name.len], global_name);
    pos += global_name.len;
    const assign = " = JSON.parse('";
    @memcpy(buf[pos .. pos + assign.len], assign);
    pos += assign.len;

    for (json_str) |ch| {
        if (ch == '\'' or ch == '\\') {
            buf[pos] = '\\';
            pos += 1;
        }
        buf[pos] = ch;
        pos += 1;
    }

    const suffix = "')";
    @memcpy(buf[pos .. pos + suffix.len], suffix);
    pos += suffix.len;

    buf[pos] = 0;
    _ = mruby.mrb_load_string(mrb, buf.ptr);

    const exc = mruby.mrb_get_exception(mrb);
    if (mruby.mrb_test(exc)) {
        mruby.mrb_print_error(mrb);
        return error.MRubyException;
    }
}

/// Inject params JSON into mruby as $_hola_params global variable.
fn injectParams(mrb: *mruby.mrb_state, params_json: []const u8) !void {
    try injectJsonGlobal(mrb, "$_hola_params", params_json);
}

/// Inject secrets JSON into mruby as $_hola_secrets global variable.
fn injectSecrets(mrb: *mruby.mrb_state, secrets_json: []const u8) !void {
    try injectJsonGlobal(mrb, "$_hola_secrets", secrets_json);
}

pub fn run(allocator: std.mem.Allocator, opts: Options) !ProvisionResult {
    const session = try Session.open(allocator, .{
        .params_json = opts.params_json,
        .secrets_json = opts.secrets_json,
    });
    defer session.close();
    try session.evalScript(opts.script_path);

    const runner = &session.runner;
    runner.start_time = std.Io.Timestamp.now(global_io.io(), .real).toNanoseconds();

    // Initialize modern display with the specified output mode
    var display = try modern_display.ModernProvisionDisplay.init(allocator, opts.use_pretty_output);
    defer display.deinit();

    runner.attachDisplay(&display);
    defer runner.detachDisplay();

    // Show section header
    try display.showSection("Applying Configuration");

    // Set total number of resources for progress display
    display.setTotalResources(runner.resources.items.len);

    // Phase 0: Start parallel downloads for remote files
    // Initialize download manager with the specified output mode
    const download_config = http.download.Manager.Config{
        .max_concurrent = 5,
        .http_config = .{},
    };
    var download_mgr = try http.download.Manager.init(allocator, download_config);
    defer download_mgr.deinit();

    // Set up progress callback for display
    const ProgressContext = struct {
        display: *modern_display.ModernProvisionDisplay,
        allocator: std.mem.Allocator,
        tasks: *std.ArrayList(http.download.Task),
        mutex: *std.Io.Mutex,
        initialized: [256]std.atomic.Value(bool), // Fixed size array with atomic values

        fn callback(ctx_ptr: *anyopaque, task_index: usize, downloaded: usize, total: usize) void {
            const ctx: *@This() = @ptrCast(@alignCast(ctx_ptr));

            ctx.mutex.lockUncancelable(global_io.io());
            defer ctx.mutex.unlock(global_io.io());

            if (task_index >= ctx.tasks.items.len or task_index >= 256) return;

            const task = &ctx.tasks.items[task_index];
            const display_name = task.display_name;

            // Check if we've initialized the display for this task
            const is_initialized = ctx.initialized[task_index].load(.acquire);

            if (total > 0) {
                if (!is_initialized) {
                    // First time seeing total > 0, initialize download display
                    ctx.display.addDownload(display_name, total) catch {};
                    ctx.initialized[task_index].store(true, .release);
                } else if (downloaded > 0) {
                    // Subsequent updates with progress
                    ctx.display.updateDownload(display_name, downloaded) catch {};
                }
            }

            // Mark as complete
            if (downloaded >= total and total > 0) {
                ctx.display.finishDownload(display_name, true) catch {};
            }
        }
    };

    var progress_mutex: std.Io.Mutex = .init;
    const progress_ctx = try allocator.create(ProgressContext);
    defer allocator.destroy(progress_ctx);
    progress_ctx.* = .{
        .display = &display,
        .allocator = allocator,
        .tasks = &download_mgr.tasks,
        .mutex = &progress_mutex,
        .initialized = undefined, // Will initialize below
    };
    // Initialize all atomic values to false
    for (&progress_ctx.initialized) |*init| {
        init.* = std.atomic.Value(bool).init(false);
    }

    download_mgr.setDisplay(@ptrCast(progress_ctx), ProgressContext.callback);

    // Collect all remote_file resources for parallel download
    // Only pre-download simple files (no conditions like only_if/not_if, and action is :create)
    for (runner.resources.items) |*res| {
        if (res.resource == .remote_file) {
            const remote_res = &res.resource.remote_file;

            // Skip files with conditions - they will be downloaded when executed
            if (remote_res.common.only_if_block != null or remote_res.common.not_if_block != null) {
                continue;
            }

            // Skip non-create actions (create_if_missing needs to check file existence first)
            if (remote_res.action != .create) {
                continue;
            }

            // Skip conditional downloads; they are fetched on-demand to honor conditional requests
            if (remote_res.use_etag or remote_res.use_last_modified) {
                continue;
            }

            // Generate slugified version of the final path for unique temp filename
            const path_slug = try http.slugifyPath(allocator, remote_res.path);
            defer allocator.free(path_slug);

            // Get temp dir from xdg
            const xdg_instance = @import("xdg.zig").XDG.init(allocator);
            const temp_dir = try xdg_instance.getDownloadsDir();
            defer allocator.free(temp_dir);

            // Generate temporary file path with slugified path
            const temp_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ temp_dir, path_slug });
            defer allocator.free(temp_path);

            // Use full destination path for display
            const display_name = remote_res.path;
            const resource_id = try std.fmt.allocPrint(allocator, "{s}[{s}]", .{ res.id.type_name, res.id.name });
            defer allocator.free(resource_id);

            // Create download task using new API
            var task = try http.download.Task.init(
                allocator,
                resource_id,
                remote_res.source,
                display_name,
                temp_path,
                remote_res.path,
            );

            // Set optional fields
            task.mode = if (remote_res.attrs.mode) |mode| try std.fmt.allocPrint(allocator, "{o}", .{mode}) else null;
            task.checksum = if (remote_res.checksum) |checksum| try allocator.dupe(u8, checksum) else null;
            task.backup = if (remote_res.backup) |backup| try allocator.dupe(u8, backup) else null;

            // Parse JSON headers to StringHashMap
            if (remote_res.headers) |headers_json| {
                var headers_map = std.StringHashMap([]const u8).init(allocator);
                errdefer headers_map.deinit();

                const parsed = try std.json.parseFromSlice(std.json.Value, allocator, headers_json, .{});
                defer parsed.deinit();

                if (parsed.value == .object) {
                    var it = parsed.value.object.iterator();
                    while (it.next()) |entry| {
                        const key = try allocator.dupe(u8, entry.key_ptr.*);
                        errdefer allocator.free(key);
                        const value_str = if (entry.value_ptr.* == .string) entry.value_ptr.*.string else "";
                        const value = try allocator.dupe(u8, value_str);
                        errdefer allocator.free(value);
                        try headers_map.put(key, value);
                    }
                }

                task.headers = headers_map;
            }

            try download_mgr.addTask(task);
        }
    }

    if (download_mgr.tasks.items.len > 0) {
        // Show download section header
        try display.showSectionWithLevel("Downloading Remote Files", 3);

        const download_names = try allocator.alloc([]const u8, download_mgr.tasks.items.len);
        defer allocator.free(download_names);
        for (download_mgr.tasks.items, 0..) |task, idx| {
            download_names[idx] = task.display_name;
        }
        try display.reserveDownloadSlots(download_names);
    }

    // Start background download processing if we have tasks
    var download_thread: ?std.Thread = null;
    defer if (download_thread) |thread| thread.join();
    if (download_mgr.tasks.items.len > 0) {
        const DownloadThread = struct {
            fn run(mgr: *http.download.Manager) void {
                mgr.processAll() catch |err| {
                    logger.err("Download processing failed: {}", .{err});
                };
            }
        };
        download_thread = try std.Thread.spawn(.{}, DownloadThread.run, .{&download_mgr});
    }
    runner.download_mgr = &download_mgr;
    defer runner.download_mgr = null;

    // Start resource execution phase
    try display.showSectionWithLevel("Executing Resources", 3);

    // Start the real-time timer spinner (after all download spinners are created)
    try display.startTimer(runner.start_time);
    try runner.convergeFrom(0);
    try runner.flushDelayed();

    // Wait for download thread to complete
    if (download_thread) |thread| {
        try display.showInfo("Waiting for remaining downloads to complete...");
        thread.join();
        download_thread = null;

        // Show final stats
        const stats = download_mgr.getStats();
        if (stats.failed > 0) {
            const msg = try std.fmt.allocPrint(allocator, "{d} downloads failed", .{stats.failed});
            defer allocator.free(msg);
            try display.showInfo(msg);
        }
    }

    // Show execution summary with duration
    try display.showSummaryWithDuration(0, 0);

    // Compute duration
    const end_time: i128 = std.Io.Timestamp.now(global_io.io(), .real).toNanoseconds();
    const elapsed_ms = @divTrunc(end_time - runner.start_time, std.time.ns_per_ms);

    return ProvisionResult{
        .executed_count = display.executed_count,
        .updated_count = display.updated_count,
        .skipped_count = display.skipped_count,
        .failed_count = display.failed_count,
        .duration_ms = @intCast(elapsed_ms),
        .resource_results = runner.takeResults(),
    };
}

test "Session.open collects resources without applying" {
    const allocator = std.testing.allocator;
    json.setAllocator(allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(global_io.io(), ".", allocator);
    defer allocator.free(root);
    const target = try std.fs.path.join(allocator, &.{ root, "not-applied.txt" });
    defer allocator.free(target);

    const session = try Session.open(allocator, .{});
    defer session.close();
    const script = try std.fmt.allocPrint(allocator, "file '{s}' do\n  content 'x'\nend", .{target});
    defer allocator.free(script);
    try session.evalString(script);

    try std.testing.expectEqual(@as(usize, 1), session.runner.resources.items.len);
    try std.testing.expectEqual(@as(usize, 0), session.runner.converged_index);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(global_io.io(), target, .{}));
}

test "convergeFrom applies and records results once" {
    const allocator = std.testing.allocator;
    json.setAllocator(allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(global_io.io(), ".", allocator);
    defer allocator.free(root);
    const target = try std.fs.path.join(allocator, &.{ root, "applied.txt" });
    defer allocator.free(target);

    const session = try Session.open(allocator, .{});
    defer session.close();
    const script = try std.fmt.allocPrint(allocator, "file '{s}' do\n  content 'x'\nend", .{target});
    defer allocator.free(script);
    try session.evalString(script);

    var display = try modern_display.ModernProvisionDisplay.init(allocator, false);
    defer display.deinit();
    session.runner.attachDisplay(&display);
    defer session.runner.detachDisplay();
    display.setTotalResources(1);

    try session.runner.convergeFrom(0);
    try std.testing.expectEqual(@as(usize, 1), session.runner.resource_results.items.len);
    try std.testing.expectEqual(@as(usize, 1), session.runner.converged_index);
    try std.Io.Dir.cwd().access(global_io.io(), target, .{});

    try session.runner.convergeFrom(1);
    try std.testing.expectEqual(@as(usize, 1), session.runner.resource_results.items.len);
}

test "task prelude supports common Rake task semantics" {
    var mrb_state = try mruby.State.init();
    defer mrb_state.deinit();
    const mrb_ptr = mrb_state.mrb orelse return error.MRubyNotInitialized;

    try mrb_state.evalString(
        \\module ZigBackend
        \\  def self.converge; [true, nil]; end
        \\  def self.flush_delayed; [true, nil]; end
        \\  def self.display_section(name); ($sections ||= []) << name; [true, nil]; end
        \\end
        \\module ENV
        \\  @values = {}
        \\  def self.[](key); @values[key]; end
        \\  def self.[]=(key, value); @values[key] = value; end
        \\end
    );
    try mrb_state.evalString(@embedFile("ruby_prelude/tasks.rb"));
    try mrb_state.evalString(
        \\$events = []
        \\task(:a) { $events << :a }
        \\task(:b => :a) { $events << :b }
        \\task(:c => [:a, :b]) { $events << :c }
        \\task :greet, [:name] do |task, args|
        \\  args.with_defaults(:name => 'world')
        \\  $events << args.name
        \\end
        \\namespace :db do
        \\  task :prepare do
        \\    $events << :db_prepare
        \\  end
        \\  namespace :admin do
        \\    task :reset => 'prepare' do
        \\      $events << :admin_reset
        \\    end
        \\  end
        \\  task :reset do
        \\    $events << :reset
        \\  end
        \\end
        \\task(:merged) { $events << :first }
        \\task(:merged) { $events << :second }
        \\file 'standard-file-task'
        \\file_task 'legacy-file-task'
        \\directory 'standard-directory-task'
        \\task :cycle_a => :cycle_b
        \\task :cycle_b => :cycle_a
        \\class ExampleTaskLib < Rake::TaskLib
        \\  def initialize
        \\    task(:from_tasklib) { $events << :tasklib }
        \\  end
        \\end
        \\ExampleTaskLib.new
        \\require 'rake/clean'
        \\Hola::Rake.application.run(['HOLA_TASK_ENV=present', 'c', 'greet[bob]', 'db:reset', 'db:admin:reset', 'from_tasklib'])
        \\$dependency_result = ($events == [:a, :b, :c, 'bob', :reset, :db_prepare, :admin_reset, :tasklib])
        \\$dependency_result = $dependency_result && (ENV['HOLA_TASK_ENV'] == 'present')
        \\Rake::Task[:merged].invoke
        \\Rake::Task[:merged].invoke
        \\Rake::Task[:merged].reenable
        \\Rake::Task[:merged].invoke
        \\$enhance_result = ($events[-4, 4] == [:first, :second, :first, :second])
        \\begin
        \\  Rake::Task[:cycle_a].invoke
        \\rescue => error
        \\  $cycle_result = error.message.include?('Circular dependency detected: cycle_a => cycle_b => cycle_a')
        \\end
        \\begin
        \\  Rake::Task[:missing]
        \\rescue => error
        \\  $missing_result = (error.message == "Don't know how to build task 'missing'")
        \\end
        \\$parse_result = [
        \\  Hola::Rake.application.parse_task_string('a'),
        \\  Hola::Rake.application.parse_task_string('a[]'),
        \\  Hola::Rake.application.parse_task_string('a[1, 2]'),
        \\  Hola::Rake.application.parse_task_string('ns:a[x]'),
        \\]
        \\$parse_test_result = ($parse_result == [['a', []], ['a', []], ['a', ['1', '2']], ['ns:a', ['x']]])
        \\$tasklib_result = Rake::Task.task_defined?(:from_tasklib) && Rake::Task.task_defined?(:clean) && Rake::Task.task_defined?(:clobber)
        \\$file_dsl_result = Rake::Task[:'standard-file-task'].is_a?(Rake::FileTask) && Rake::Task[:'legacy-file-task'].is_a?(Rake::FileTask) && Rake::Task[:'standard-directory-task'].is_a?(Rake::FileTask)
    );

    const result_names = [_][*:0]const u8{
        "$dependency_result",
        "$enhance_result",
        "$cycle_result",
        "$missing_result",
        "$parse_test_result",
        "$tasklib_result",
        "$file_dsl_result",
    };
    for (result_names) |name| {
        const result = mruby.mrb_gv_get(mrb_ptr, mruby.mrb_intern_cstr(mrb_ptr, name));
        try std.testing.expect(mruby.mrb_test(result));
    }
}

test "task prelude immediate wrapper converges resource declarations" {
    var mrb_state = try mruby.State.init();
    defer mrb_state.deinit();
    const mrb_ptr = mrb_state.mrb orelse return error.MRubyNotInitialized;

    try mrb_state.evalString(
        \\$converge_calls = 0
        \\module ZigBackend
        \\  def self.converge; $converge_calls += 1; [true, nil]; end
        \\  def self.flush_delayed; [true, nil]; end
        \\  def self.display_section(name); [true, nil]; end
        \\end
        \\def execute(name, &block); name; end
    );
    try mrb_state.evalString(@embedFile("ruby_prelude/tasks.rb"));
    try mrb_state.evalString("$hola_run_immediate = true; execute('command'); $immediate_result = ($converge_calls == 1)");
    const result = mruby.mrb_gv_get(mrb_ptr, mruby.mrb_intern_cstr(mrb_ptr, "$immediate_result"));
    try std.testing.expect(mruby.mrb_test(result));
}

test "task command-line assignments use the environment bridge" {
    const allocator = std.testing.allocator;
    json.setAllocator(allocator);
    const session = try Session.open(allocator, .{ .mode = .task });
    defer session.close();
    defer session.evalString("ENV.delete('HOLA_TASK_TEST_ENV')") catch {};

    var display = try modern_display.ModernProvisionDisplay.init(allocator, false);
    defer display.deinit();
    session.runner.attachDisplay(&display);
    defer session.runner.detachDisplay();
    session.runner.start_time = std.Io.Timestamp.now(global_io.io(), .real).toNanoseconds();
    try display.startTimer(session.runner.start_time);

    try session.loadTaskPrelude();
    try session.evalString(
        \\file 'standard-task-file'
        \\task(:check_env) { $env_seen = ENV['HOLA_TASK_TEST_ENV'] }
        \\$hola_run_argv = ['HOLA_TASK_TEST_ENV=present', 'check_env']
        \\Hola::Rake.main
        \\$env_bridge_result = ($hola_run_status == 0 && $env_seen == 'present')
    );
    const result = session.mrb.getGlobal("$env_bridge_result");
    try std.testing.expect(mruby.mrb_test(result));
    try std.testing.expectEqual(@as(usize, 0), session.runner.resources.items.len);
}

test "protected ruby_block failure returns a converge status and session remains usable" {
    const allocator = std.testing.allocator;
    json.setAllocator(allocator);
    const session = try Session.open(allocator, .{});
    defer session.close();

    var display = try modern_display.ModernProvisionDisplay.init(allocator, false);
    defer display.deinit();
    session.runner.attachDisplay(&display);
    defer session.runner.detachDisplay();

    try session.evalString("ruby_block('boom') { block { raise 'kaboom' } }; $r = ZigBackend.converge");
    try session.evalString("$protected_failure = (!$r[0] && $r[1].include?('ruby_block[boom]') && $r[1].include?('kaboom'))");
    const failure_result = mruby.mrb_gv_get(session.mrb.mrb.?, mruby.mrb_intern_cstr(session.mrb.mrb.?, "$protected_failure"));
    try std.testing.expect(mruby.mrb_test(failure_result));

    try session.evalString("ruby_block('ok') { block { true } }; $r2 = ZigBackend.converge; $protected_recovery = ($r2 == [true, nil])");
    const recovery_result = mruby.mrb_gv_get(session.mrb.mrb.?, mruby.mrb_intern_cstr(session.mrb.mrb.?, "$protected_recovery"));
    try std.testing.expect(mruby.mrb_test(recovery_result));
}

test "injectSecrets and secrets_bag reads values correctly" {
    var mrb = try mruby.State.init();
    defer mrb.deinit();

    const mrb_ptr = mrb.mrb orelse return error.MRubyNotInitialized;

    // Register ZigBackend module with JSON functions
    const zig_module = mruby.mrb_define_module(mrb_ptr, "ZigBackend");
    json.setAllocator(std.testing.allocator);
    for (json.mruby_module_def.getFunctions()) |func| {
        mruby.mrb_define_module_function(mrb_ptr, zig_module, func.name.ptr, func.func, func.args);
    }
    try mrb.evalString(json.ruby_prelude);

    // Load secrets_bag prelude
    try mrb.evalString(@embedFile("ruby_prelude/secrets_bag.rb"));

    // Inject secrets
    try injectSecrets(mrb_ptr, "{\"api_key\":\"sk-123\",\"nested\":{\"token\":\"abc\"}}");

    // Note: mruby's `$_xxx` is the special `$_` variable family — assignments
    // silently no-op. Use plain `$result1` / `$result2` / `$result3` instead.

    // Test simple key access
    try mrb.evalString("$result1 = secrets_bag('api_key')");
    const sym = mruby.mrb_intern_cstr(mrb_ptr, "$result1");
    const result = mruby.mrb_gv_get(mrb_ptr, sym);
    try std.testing.expect(mruby.zig_mrb_string_p(result) != 0);
    const cstr = mruby.mrb_str_to_cstr(mrb_ptr, result);
    try std.testing.expectEqualStrings("sk-123", std.mem.span(cstr));

    // Test nested key access
    try mrb.evalString("$result2 = secrets_bag('nested', 'token')");
    const sym2 = mruby.mrb_intern_cstr(mrb_ptr, "$result2");
    const result2 = mruby.mrb_gv_get(mrb_ptr, sym2);
    try std.testing.expect(mruby.zig_mrb_string_p(result2) != 0);
    const cstr2 = mruby.mrb_str_to_cstr(mrb_ptr, result2);
    try std.testing.expectEqualStrings("abc", std.mem.span(cstr2));

    // Test missing key returns nil
    try mrb.evalString("$result3 = secrets_bag('nonexistent')");
    const sym3 = mruby.mrb_intern_cstr(mrb_ptr, "$result3");
    const result3 = mruby.mrb_gv_get(mrb_ptr, sym3);
    try std.testing.expect(!mruby.mrb_test(result3));
}

test "Time.parse handles ISO 8601 / RFC 3339" {
    var mrb = try mruby.State.init();
    defer mrb.deinit();
    const mrb_ptr = mrb.mrb orelse return error.MRubyNotInitialized;

    try mrb.evalString(@embedFile("ruby_prelude/time_parse.rb"));

    // Note: mruby treats `$_xxx` as the special `$_` variable family — assignments
    // to `$_t` etc. silently no-op. Use plain `$t` / `$e` names instead.

    // 2026-05-09T08:41:20 UTC == epoch 1778316080
    const utc_epoch: i64 = 1778316080;
    const cases = [_]struct { src: []const u8, expected_to_i: i64 }{
        .{ .src = "Time.parse(\"2026-05-09T08:41:20Z\").to_i", .expected_to_i = utc_epoch },
        .{ .src = "Time.parse(\"2026-05-09T08:41:20.123Z\").to_i", .expected_to_i = utc_epoch },
        .{ .src = "Time.parse(\"2026-05-09 08:41:20\").to_i", .expected_to_i = utc_epoch },
        .{ .src = "Time.parse(\"2026-05-09T16:41:20+08:00\").to_i", .expected_to_i = utc_epoch },
        .{ .src = "Time.parse(\"2026-05-09T16:41:20+0800\").to_i", .expected_to_i = utc_epoch },
        .{ .src = "Time.parse(\"2026-05-09T03:41:20-05:00\").to_i", .expected_to_i = utc_epoch },
        // Date-only is midnight UTC == 2026-05-09 00:00:00 UTC
        .{ .src = "Time.parse(\"2026-05-09\").to_i", .expected_to_i = 1778284800 },
    };

    for (cases) |c| {
        const ruby = try std.fmt.allocPrint(std.testing.allocator, "$t = {s}", .{c.src});
        defer std.testing.allocator.free(ruby);
        try mrb.evalString(ruby);

        const sym = mruby.mrb_intern_cstr(mrb_ptr, "$t");
        const got = mruby.mrb_gv_get(mrb_ptr, sym);
        const got_int = mruby.zig_mrb_fixnum(mrb_ptr, got);
        std.testing.expectEqual(c.expected_to_i, got_int) catch |err| {
            std.debug.print("Time.parse case failed: {s} (got {d}, want {d})\n", .{ c.src, got_int, c.expected_to_i });
            return err;
        };
    }

    // Bad inputs raise ArgumentError. (mruby has no $! / inline `rescue` modifier,
    // so use the explicit begin/rescue form.)
    const bad_inputs = [_][]const u8{
        "",
        "not a date",
        "2026/05/09",
        "2026-05-09T08:41:20+9",
    };
    for (bad_inputs) |bad| {
        const ruby = try std.fmt.allocPrint(std.testing.allocator, "$e = \"none\"; begin; Time.parse(\"{s}\"); rescue => err; $e = err.class.to_s; end", .{bad});
        defer std.testing.allocator.free(ruby);
        try mrb.evalString(ruby);

        const got = mruby.mrb_gv_get(mrb_ptr, mruby.mrb_intern_cstr(mrb_ptr, "$e"));
        try std.testing.expect(mruby.zig_mrb_string_p(got) != 0);
        try std.testing.expectEqualStrings("ArgumentError", std.mem.span(mruby.mrb_str_to_cstr(mrb_ptr, got)));
    }
}
