const std = @import("std");
const global_io = @import("global_io.zig");
const indicatif = @import("indicatif.zig");
const ansi = @import("ansi_term");
const ansi_constants = @import("ansi_constants.zig");
const ANSI = ansi_constants.ANSI;
const http = @import("http.zig");
const output_channel = @import("output_channel.zig");
const resources = @import("resources.zig");

const AnsiStyle = ansi.style.Style;
const AnsiColor = ansi.style.Color;
const STATUS_PENDING = "[DL] pending";
const STATUS_DOWNLOADING = "[DL] downloading";
const STATUS_DONE = "[DL] done";
const STATUS_FAILED = "[DL] failed";
const SECTION_MARKER = "›";

// Compact command, output, and resource status markers share one left gutter.
const INDENT_RESOURCE = "";

pub const ResourceFailure = struct {
    resource_type: []const u8,
    resource_name: []const u8,
    action: []const u8,
    depth: usize,
    error_name: []const u8,
    message: []const u8,
    command: ?[]const u8 = null,
    stdout: ?[]const u8 = null,
    stderr: ?[]const u8 = null,
    backtrace: ?[]const u8 = null,
};

/// Normal mode is an append-only, Chef-inspired execution log intended for
/// authoring and debugging. Compact mode is the animated spinner display for
/// established scripts where the operator mainly needs progress and a result.
pub const OutputMode = enum {
    normal,
    compact,
};

/// Modern provision display using indicatif
pub const ModernProvisionDisplay = struct {
    const DownloadEntry = struct {
        spinner: *indicatif.ProgressBar,
        label: ?[]u8,
        total_bytes: u64 = 0,
        bytes_downloaded: u64 = 0,
    };
    const Self = @This();

    allocator: std.mem.Allocator,
    mp: indicatif.MultiProgress,
    download_spinners: std.StringHashMap(DownloadEntry),
    download_spinners_mutex: std.Io.Mutex = .init,
    download_finished_messages: std.ArrayList([]const u8), // Keep finished messages allocated
    section_messages: std.ArrayList([]const u8), // Keep section header messages allocated
    download_section_spinner: ?*indicatif.ProgressBar = null, // Static section header for downloads
    resource_section_spinner: ?*indicatif.ProgressBar = null, // Static section header for resources
    resource_spinner: ?*indicatif.ProgressBar = null,
    resource_message: ?[]const u8 = null, // Keep message allocated
    mode: OutputMode,
    colorize: bool,
    compact_at_gap: bool = false,
    normal_at_gap: bool = false,
    normal_resource_line_open: bool = false,
    normal_resource_depth: usize = 0,
    normal_display_path: []const resources.DisplayScope = &.{},
    total_resources: usize = 0,
    executed_count: usize = 0,
    updated_count: usize = 0,
    skipped_count: usize = 0,
    failed_count: usize = 0,
    handled_failure_count: usize = 0,
    run_failed: bool = false,
    timer_spinner: ?*indicatif.ProgressBar = null,
    timer_message: ?[]u8 = null,
    start_time: i128 = 0,

    pub fn init(allocator: std.mem.Allocator, mode: OutputMode) !Self {
        return .{
            .allocator = allocator,
            .mp = indicatif.MultiProgress.init(allocator),
            .download_spinners = std.StringHashMap(DownloadEntry).init(allocator),
            .download_finished_messages = std.ArrayList([]const u8).empty,
            .section_messages = std.ArrayList([]const u8).empty,
            .mode = mode,
            .colorize = shouldColorizeNormal(),
        };
    }

    pub fn isCompact(self: *const Self) bool {
        return self.mode == .compact;
    }

    pub fn deinit(self: *Self) void {
        self.finishNormalResourceLine();
        if (self.isCompact() and self.timer_spinner != null) {
            self.addCompactGap() catch {};
            self.mp.draw() catch {};
        }

        // Clean up any remaining download spinners
        var key_iter = self.download_spinners.keyIterator();
        while (key_iter.next()) |key| {
            self.allocator.free(key.*);
        }
        var iter = self.download_spinners.valueIterator();
        while (iter.next()) |entry_ptr| {
            const entry = entry_ptr.*;
            if (entry.label) |lbl| {
                self.allocator.free(lbl);
            }
            self.mp.remove(entry.spinner);
            entry.spinner.deinit();
        }
        self.download_spinners.deinit();

        // Clean up finished messages
        for (self.download_finished_messages.items) |msg| {
            self.allocator.free(msg);
        }
        self.download_finished_messages.deinit(self.allocator);

        // Clean up section messages
        for (self.section_messages.items) |msg| {
            self.allocator.free(msg);
        }
        self.section_messages.deinit(self.allocator);

        if (self.resource_spinner) |spinner| {
            self.mp.remove(spinner);
            spinner.deinit();
        }

        if (self.resource_message) |msg| {
            self.allocator.free(msg);
        }

        if (self.timer_spinner) |spinner| {
            self.mp.remove(spinner);
            spinner.deinit();
        }

        if (self.timer_message) |msg| {
            self.allocator.free(msg);
        }

        if (self.download_section_spinner) |spinner| {
            self.mp.remove(spinner);
            spinner.deinit();
        }

        if (self.resource_section_spinner) |spinner| {
            self.mp.remove(spinner);
            spinner.deinit();
        }

        // Don't call mp.deinit() because it calls clear() which removes the display
        // The bars are already finished and we want to keep them visible
        // Memory cleanup: manually clean up the bars array
        for (self.mp.bars.items) |bar| {
            bar.deinit();
        }
        self.mp.bars.deinit(self.allocator);
    }

    /// Set total number of resources
    pub fn setTotalResources(self: *Self, total: usize) void {
        self.total_resources = total;
    }

    fn formatCounter(self: *Self, buffer: []u8) []const u8 {
        if (self.total_resources == 0) {
            return std.fmt.bufPrint(buffer, "[{d}]", .{self.executed_count}) catch "[?]";
        }

        const total_digits = std.math.log10_int(self.total_resources) + 1;
        const current_digits = std.math.log10_int(self.executed_count) + 1;
        const padding = if (total_digits > current_digits) total_digits - current_digits else 0;
        var padding_buffer: [32]u8 = undefined;
        @memset(padding_buffer[0..padding], ' ');
        return std.fmt.bufPrint(buffer, "[{s}{d}/{d}]", .{ padding_buffer[0..padding], self.executed_count, self.total_resources }) catch "[?]";
    }

    /// Start the timer spinner
    pub fn startTimer(self: *Self, start_time: i128) !void {
        self.start_time = start_time;
        if (!self.isCompact()) return;

        const spinner = try self.mp.addSpinner();
        var style = try indicatif.ProgressStyle.withTemplate(self.allocator, "{spinner} {msg}");
        style.tick_chars = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏";
        spinner.setStyle(style);

        const msg = try std.fmt.allocPrint(self.allocator, "⏱️ Elapsed: 0.000s", .{});
        spinner.setMessage(msg);
        self.timer_spinner = spinner;
        self.timer_message = msg;
    }

    /// Update the timer display
    fn updateTimer(self: *Self) !void {
        if (!self.isCompact()) return;
        if (self.timer_spinner == null) return;

        const io = global_io.io();
        const current_time: i128 = std.Io.Timestamp.now(io, .real).toNanoseconds();
        const elapsed_ns = current_time - self.start_time;
        const elapsed_ms = @divTrunc(elapsed_ns, std.time.ns_per_ms);
        const elapsed_s = @divTrunc(elapsed_ms, 1000);
        const elapsed_ms_part = @rem(elapsed_ms, 1000);

        if (self.timer_message) |old_msg| {
            self.allocator.free(old_msg);
        }

        const msg = try std.fmt.allocPrint(
            self.allocator,
            "⏱️ Elapsed: {d}.{d:0>3}s",
            .{ elapsed_s, @as(u64, @intCast(elapsed_ms_part)) },
        );

        if (self.timer_spinner) |spinner| {
            spinner.setMessage(msg);
        }
        self.timer_message = msg;
    }

    /// Finish the timer spinner
    pub fn finishTimer(self: *Self, label: []const u8) !void {
        if (!self.isCompact()) return;
        if (self.timer_spinner == null) return;

        const io = global_io.io();
        const current_time: i128 = std.Io.Timestamp.now(io, .real).toNanoseconds();
        const elapsed_ns = current_time - self.start_time;
        const elapsed_ms = @divTrunc(elapsed_ns, std.time.ns_per_ms);
        const elapsed_s = @divTrunc(elapsed_ms, 1000);
        const elapsed_ms_part = @rem(elapsed_ms, 1000);

        if (self.timer_message) |old_msg| {
            self.allocator.free(old_msg);
        }

        const succeeded = self.didSucceed();
        const summary = try self.formatSummaryMessage(label, elapsed_s, @intCast(elapsed_ms_part));
        defer self.allocator.free(summary);
        const base_msg = try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ if (succeeded) "✓" else "✗", summary });
        defer self.allocator.free(base_msg);

        const colored_msg = try self.makeColoredMessage(if (succeeded) .Green else .Red, true, base_msg);
        try self.download_finished_messages.append(self.allocator, colored_msg);

        if (self.timer_spinner) |spinner| {
            const finished_style = try indicatif.ProgressStyle.withTemplate(self.allocator, "{msg}");
            spinner.setStyle(finished_style);
            spinner.setMessage(colored_msg);
            spinner.state.finish();
        }

        self.timer_message = null;
    }

    fn didSucceed(self: *const Self) bool {
        return !self.run_failed and self.failed_count == 0;
    }

    fn formatSummaryMessage(self: *Self, label: []const u8, elapsed_s: i128, elapsed_ms_part: u64) ![]u8 {
        const outcome = if (self.didSucceed()) "complete" else "failed";
        if (self.failed_count > 0 and self.handled_failure_count > 0) {
            return std.fmt.allocPrint(
                self.allocator,
                "{s} {s} in {d}.{d:0>3}s - {d} updated, {d} skipped, {d} failed, {d} handled failure{s}",
                .{ label, outcome, elapsed_s, elapsed_ms_part, self.updated_count, self.skipped_count, self.failed_count, self.handled_failure_count, if (self.handled_failure_count == 1) "" else "s" },
            );
        }
        if (self.failed_count > 0) {
            return std.fmt.allocPrint(
                self.allocator,
                "{s} {s} in {d}.{d:0>3}s - {d} updated, {d} skipped, {d} failed",
                .{ label, outcome, elapsed_s, elapsed_ms_part, self.updated_count, self.skipped_count, self.failed_count },
            );
        }
        if (self.handled_failure_count > 0) {
            return std.fmt.allocPrint(
                self.allocator,
                "{s} {s} in {d}.{d:0>3}s - {d} updated, {d} skipped, {d} handled failure{s}",
                .{ label, outcome, elapsed_s, elapsed_ms_part, self.updated_count, self.skipped_count, self.handled_failure_count, if (self.handled_failure_count == 1) "" else "s" },
            );
        }
        return std.fmt.allocPrint(
            self.allocator,
            "{s} {s} in {d}.{d:0>3}s - {d} updated, {d} skipped",
            .{ label, outcome, elapsed_s, elapsed_ms_part, self.updated_count, self.skipped_count },
        );
    }

    fn shouldColorizeNormal() bool {
        if (global_io.getEnv("NO_COLOR") != null) return false;
        if (global_io.getEnv("TERM")) |term| {
            if (std.mem.eql(u8, term, "dumb")) return false;
        }
        return std.Io.File.stderr().isTty(global_io.io()) catch false;
    }

    fn normalStyle(self: *const Self, ansi_code: []const u8) []const u8 {
        return if (self.colorize) ansi_code else "";
    }

    fn finishNormalResourceLine(self: *Self) void {
        if (!self.normal_resource_line_open) return;
        std.debug.print("\n", .{});
        self.normal_resource_line_open = false;
    }

    fn ensureNormalGap(self: *Self) void {
        if (self.normal_at_gap) return;
        std.debug.print("\n", .{});
        self.normal_at_gap = true;
    }

    fn printNormalIndent(units: usize) void {
        for (0..units) |_| std.debug.print("  ", .{});
    }

    fn displayScopeEqual(a: resources.DisplayScope, b: resources.DisplayScope) bool {
        return std.mem.eql(u8, a.type_name, b.type_name) and
            std.mem.eql(u8, a.name, b.name) and
            std.mem.eql(u8, a.action, b.action);
    }

    fn syncNormalDisplayPath(self: *Self, path: []const resources.DisplayScope, resource_depth: usize) void {
        var shared: usize = 0;
        while (shared < self.normal_display_path.len and shared < path.len and
            displayScopeEqual(self.normal_display_path[shared], path[shared])) : (shared += 1)
        {}

        for (path[shared..], shared..) |scope, index| {
            const scope_depth = resource_depth - (path.len - index);
            printNormalIndent(scope_depth + 1);
            std.debug.print("* {s}[{s}] action {s}\n", .{ scope.type_name, scope.name, scope.action });
        }
        self.normal_display_path = path;
    }

    fn printNormalText(depth: usize, text: []const u8) void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            printNormalIndent(depth + 1);
            std.debug.print("{s}\n", .{line});
        }
    }

    fn isUnifiedDiff(text: []const u8) bool {
        return std.mem.startsWith(u8, text, "diff --git ") or
            (std.mem.startsWith(u8, text, "--- ") and std.mem.indexOf(u8, text, "\n+++ ") != null);
    }

    fn diffLineStyle(line: []const u8) []const u8 {
        if (std.mem.startsWith(u8, line, "diff --git ") or std.mem.startsWith(u8, line, "index ")) return ANSI.DIM;
        if (std.mem.startsWith(u8, line, "--- ") or std.mem.startsWith(u8, line, "-")) return ANSI.RED;
        if (std.mem.startsWith(u8, line, "+++ ") or std.mem.startsWith(u8, line, "+")) return ANSI.GREEN;
        if (std.mem.startsWith(u8, line, "@@")) return ANSI.CYAN;
        if (std.mem.startsWith(u8, line, "\\ No newline at end of file")) return ANSI.YELLOW;
        return "";
    }

    fn printNormalOutput(self: *Self, depth: usize, text: []const u8) void {
        if (!isUnifiedDiff(text)) {
            printNormalText(depth, text);
            return;
        }

        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const ansi_code = self.normalStyle(diffLineStyle(line));
            printNormalIndent(depth + 1);
            std.debug.print("{s}{s}{s}\n", .{
                ansi_code,
                line,
                if (ansi_code.len > 0) self.normalStyle(ANSI.RESET) else "",
            });
        }
    }

    /// Show a primary section header.
    pub fn showSection(self: *Self, header: []const u8) !void {
        try self.showSectionWithLevel(header, 2);
    }

    /// Show a section header with a visual hierarchy level.
    pub fn showSectionWithLevel(self: *Self, header: []const u8, level: u8) !void {
        try self.showSectionInternal(header, level, true, true);
    }

    /// Notification headings introduce an attached list, so unlike ordinary
    /// section headings they must not leave a blank line before their content.
    pub fn showNotificationSection(self: *Self, header: []const u8) !void {
        try self.showSectionInternal(header, 3, true, false);
    }

    /// Show a task header without interpreting task names as provision section
    /// categories (for example, a task named "download").
    pub fn showTaskSection(self: *Self, name: []const u8) !void {
        try self.showSectionInternal(name, 2, false, true);
    }

    fn showSectionInternal(self: *Self, header: []const u8, level: u8, deduplicate: bool, gap_after: bool) !void {
        if (!self.isCompact()) {
            self.finishNormalResourceLine();
            self.normal_display_path = &.{};
            self.ensureNormalGap();
            if (!deduplicate) {
                std.debug.print("{s}{s}{s} Task: {s}{s}\n", .{ self.normalStyle(ANSI.BOLD), self.normalStyle(ANSI.MAGENTA), SECTION_MARKER, header, self.normalStyle(ANSI.RESET) });
            } else if (level == 2) {
                std.debug.print("{s}{s}{s} {s}{s}\n", .{ self.normalStyle(ANSI.BOLD), self.normalStyle(ANSI.MAGENTA), SECTION_MARKER, header, self.normalStyle(ANSI.RESET) });
            } else {
                std.debug.print("{s}{s}{s} {s}:{s}\n", .{ self.normalStyle(ANSI.BOLD), self.normalStyle(ANSI.MAGENTA), SECTION_MARKER, header, self.normalStyle(ANSI.RESET) });
            }
            if (gap_after) std.debug.print("\n", .{});
            self.normal_at_gap = gap_after;
            return;
        }

        // Check if this section already exists
        const is_download_section = deduplicate and std.mem.indexOf(u8, header, "Download") != null;
        const is_resource_section = deduplicate and (std.mem.indexOf(u8, header, "Executing") != null or std.mem.indexOf(u8, header, "Resource") != null);

        if (is_download_section and self.download_section_spinner != null) {
            // Section already exists, don't create duplicate
            return;
        }
        if (is_resource_section and self.resource_section_spinner != null) {
            // Section already exists, don't create duplicate
            return;
        }

        // Separate a new section from preceding output. A trailing gap from the
        // previous section already satisfies this boundary.
        if (self.section_messages.items.len > 0) {
            try self.addCompactGap();
        }

        // Create a static section header spinner
        const spinner = try self.mp.addSpinner();
        const msg = if (!deduplicate)
            try std.fmt.allocPrint(self.allocator, "{s}{s}{s} Task: {s}{s}", .{ ANSI.BOLD, ANSI.MAGENTA, SECTION_MARKER, header, ANSI.RESET })
        else if (level == 2)
            try std.fmt.allocPrint(self.allocator, "{s}{s}{s} {s}{s}", .{ ANSI.BOLD, ANSI.MAGENTA, SECTION_MARKER, header, ANSI.RESET })
        else
            try std.fmt.allocPrint(self.allocator, "{s}{s}{s} {s}:{s}", .{ ANSI.BOLD, ANSI.MAGENTA, SECTION_MARKER, header, ANSI.RESET });

        const style = try indicatif.ProgressStyle.withTemplate(self.allocator, "{msg}");
        spinner.setStyle(style);
        spinner.setMessage(msg);
        spinner.finish(); // Make it static (no spinning)

        // Keep track of section message for cleanup
        try self.section_messages.append(self.allocator, msg);
        self.compact_at_gap = false;

        if (gap_after) try self.addCompactGap();

        // Store the section spinner based on the header text
        if (is_download_section) {
            self.download_section_spinner = spinner;
        } else if (is_resource_section) {
            self.resource_section_spinner = spinner;
        }

        // Move timer to end if it exists
        if (self.timer_spinner) |timer| {
            self.mp.moveToEnd(timer);
        }
    }

    fn addCompactGap(self: *Self) !void {
        if (!self.isCompact() or self.compact_at_gap) return;

        const spinner = try self.mp.addSpinner();
        errdefer {
            self.mp.remove(spinner);
            spinner.deinit();
        }
        const message = try self.allocator.dupe(u8, "");
        errdefer self.allocator.free(message);
        const style = try indicatif.ProgressStyle.withTemplate(self.allocator, "{msg}");
        spinner.setStyle(style);
        spinner.setMessage(message);
        spinner.finish();
        try self.section_messages.append(self.allocator, message);
        self.compact_at_gap = true;

        if (self.timer_spinner) |timer| {
            self.mp.moveToEnd(timer);
        }
    }

    /// Show info message
    pub fn showInfo(self: *Self, message: []const u8) !void {
        if (!self.isCompact()) {
            self.finishNormalResourceLine();
            std.debug.print("  - {s}\n", .{message});
            self.normal_at_gap = false;
        }
    }

    pub fn printLine(self: *Self, text: []const u8) !void {
        if (!self.isCompact()) {
            self.finishNormalResourceLine();
            std.debug.print("{s}\n", .{text});
            self.normal_at_gap = false;
            return;
        }
        try self.mp.println(text);
        self.compact_at_gap = false;
    }

    pub fn printCommandLine(self: *Self, stream: output_channel.Stream, line: []const u8) !void {
        // Compact mode drains live output without retaining it. On failure the
        // captured stdout/stderr is expanded by resourceError().
        if (self.isCompact()) return;

        self.finishNormalResourceLine();
        printNormalIndent(self.normal_resource_depth + 2);
        const stream_color = if (stream == .stdout) ANSI.DIM else ANSI.RED;
        std.debug.print("{s}[{s}] {s}{s}\n", .{
            self.normalStyle(stream_color),
            if (stream == .stdout) "stdout" else "stderr",
            line,
            self.normalStyle(ANSI.RESET),
        });
        self.normal_at_gap = false;
    }

    pub fn showCommand(self: *Self, command: []const u8) !void {
        if (!self.isCompact() or command.len == 0) return;
        const spinner = self.resource_spinner orelse return;

        const line_end = std.mem.indexOfScalar(u8, command, '\n') orelse command.len;
        const continuation = if (line_end < command.len) " …" else "";
        var counter_buffer: [64]u8 = undefined;
        const message = try std.fmt.allocPrint(
            self.allocator,
            "{s}  {s}$ {s}{s}{s}",
            .{ self.formatCounter(&counter_buffer), ANSI.DIM, command[0..line_end], continuation, ANSI.RESET },
        );
        const old_message = self.resource_message;
        spinner.setMessage(message);
        self.resource_message = message;
        if (old_message) |old_msg| self.allocator.free(old_msg);
    }

    fn addCompactOwnedLine(self: *Self, message: []u8) !void {
        errdefer self.allocator.free(message);
        const style = try indicatif.ProgressStyle.withTemplate(self.allocator, "{msg}");
        const spinner = try self.mp.addSpinner();
        errdefer {
            self.mp.remove(spinner);
            spinner.deinit();
        }
        try self.download_finished_messages.append(self.allocator, message);
        spinner.setStyle(style);
        spinner.setMessage(message);
        spinner.finish();
        self.compact_at_gap = false;
        if (self.timer_spinner) |timer| self.mp.moveToEnd(timer);
    }

    fn addCompactCommandDetails(self: *Self, command: []const u8) !void {
        var lines = std.mem.splitScalar(u8, command, '\n');
        var first = true;
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const message = try std.fmt.allocPrint(
                self.allocator,
                "{s}{s} {s}{s}",
                .{ ANSI.DIM, if (first) "$" else ">", line, ANSI.RESET },
            );
            try self.addCompactOwnedLine(message);
            first = false;
        }
    }

    fn addCompactOutputDetails(self: *Self, stream: output_channel.Stream, output: []const u8) !void {
        var lines = std.mem.splitScalar(u8, output, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const message = switch (stream) {
                .stdout => try std.fmt.allocPrint(self.allocator, "{s}│{s} {s}", .{ ANSI.DIM, ANSI.RESET, line }),
                .stderr => try std.fmt.allocPrint(self.allocator, "{s}│ {s}{s}", .{ ANSI.RED, line, ANSI.RESET }),
            };
            try self.addCompactOwnedLine(message);
        }
    }

    fn addCompactBacktrace(self: *Self, backtrace: []const u8) !void {
        const label = try std.fmt.allocPrint(self.allocator, "{s}Backtrace:{s}", .{ ANSI.DIM, ANSI.RESET });
        try self.addCompactOwnedLine(label);

        var lines = std.mem.splitScalar(u8, backtrace, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const message = try std.fmt.allocPrint(self.allocator, "{s}│ {s}{s}", .{ ANSI.DIM, line, ANSI.RESET });
            try self.addCompactOwnedLine(message);
        }
    }

    /// Pre-create download spinners so they always occupy the top rows
    pub fn reserveDownloadSlots(self: *Self, names: [][]const u8) !void {
        if (!self.isCompact()) return;

        for (names) |name| {
            self.download_spinners_mutex.lockUncancelable(global_io.io());
            const already_exists = self.download_spinners.contains(name);
            self.download_spinners_mutex.unlock(global_io.io());
            if (already_exists) continue;

            const spinner = try self.mp.addSpinner();
            var style = try indicatif.ProgressStyle.withTemplate(self.allocator, "{prefix} {spinner} {msg}");
            style.tick_chars = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏";
            spinner.setStyle(style);

            const name_copy = try self.allocator.dupe(u8, name);
            const label = try self.makeDownloadLabel(name_copy);
            spinner.setMessage(label);
            spinner.setPrefix(STATUS_PENDING);

            self.download_spinners_mutex.lockUncancelable(global_io.io());
            try self.download_spinners.put(name_copy, .{ .spinner = spinner, .label = label });
            self.download_spinners_mutex.unlock(global_io.io());
            self.compact_at_gap = false;
        }
    }

    /// Add/update a download spinner
    pub fn addDownload(self: *Self, name: []const u8, total_bytes: u64) !void {
        if (!self.isCompact()) {
            // In plain mode, don't output anything - wait for finishDownload
            return;
        }

        self.download_spinners_mutex.lockUncancelable(global_io.io());
        defer self.download_spinners_mutex.unlock(global_io.io());

        if (self.download_spinners.getPtr(name)) |entry| {
            // Update existing entry
            entry.total_bytes = total_bytes;
            entry.bytes_downloaded = 0;

            var style = try indicatif.ProgressStyle.withTemplate(self.allocator, "{prefix} {spinner} {msg}");
            style.tick_chars = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏";
            entry.spinner.setStyle(style);
            const label = try self.formatDownloadMessage(name, 0, total_bytes);
            if (entry.label) |old_label| {
                self.allocator.free(old_label);
            }
            entry.label = label;
            entry.spinner.setMessage(label);
            entry.spinner.setPrefix(STATUS_DOWNLOADING);
            return;
        }

        // Create new entry
        const spinner = try self.mp.addSpinner();
        var style = try indicatif.ProgressStyle.withTemplate(self.allocator, "{prefix} {spinner} {msg}");
        style.tick_chars = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏";
        spinner.setStyle(style);
        const name_copy = try self.allocator.dupe(u8, name);
        const label = try self.formatDownloadMessage(name_copy, 0, total_bytes);
        spinner.setMessage(label);
        spinner.setPrefix(STATUS_DOWNLOADING);
        try self.download_spinners.put(name_copy, .{
            .spinner = spinner,
            .label = label,
            .total_bytes = total_bytes,
            .bytes_downloaded = 0,
        });
    }

    /// Update download progress with percentage
    pub fn updateDownload(self: *Self, name: []const u8, bytes_downloaded: u64) !void {
        if (!self.isCompact()) return;

        self.download_spinners_mutex.lockUncancelable(global_io.io());
        defer self.download_spinners_mutex.unlock(global_io.io());

        if (self.download_spinners.getPtr(name)) |entry| {
            entry.bytes_downloaded = bytes_downloaded;

            // Update message with percentage and size
            const label = try self.formatDownloadMessage(name, bytes_downloaded, entry.total_bytes);
            if (entry.label) |old_label| {
                self.allocator.free(old_label);
            }
            entry.label = label;
            entry.spinner.setMessage(label);
        }
    }

    /// Format download message with percentage and size
    fn formatDownloadMessage(self: *Self, name: []const u8, bytes_downloaded: u64, total_bytes: u64) ![]u8 {
        if (total_bytes == 0) {
            // Unknown size - just show bytes downloaded
            const size_str = try self.formatSize(bytes_downloaded);
            defer self.allocator.free(size_str);
            return try std.fmt.allocPrint(self.allocator, "{s} ({s})", .{ name, size_str });
        }

        // Calculate percentage with one decimal place
        const percent = (@as(f64, @floatFromInt(bytes_downloaded)) * 100.0) / @as(f64, @floatFromInt(total_bytes));
        const percent_whole = @as(u64, @intFromFloat(percent));
        const percent_decimal = @as(u64, @intFromFloat((percent - @as(f64, @floatFromInt(percent_whole))) * 10));

        // Format size
        const downloaded_str = try self.formatSize(bytes_downloaded);
        defer self.allocator.free(downloaded_str);
        const total_str = try self.formatSize(total_bytes);
        defer self.allocator.free(total_str);

        return try std.fmt.allocPrint(self.allocator, "{s} {d}.{d}% ({s}/{s})", .{ name, percent_whole, percent_decimal, downloaded_str, total_str });
    }

    /// Format bytes to human-readable size
    fn formatSize(self: *Self, bytes: u64) ![]const u8 {
        return http.formatSize(self.allocator, bytes);
    }

    /// Finish a download
    pub fn finishDownload(self: *Self, name: []const u8, success: bool) !void {
        if (!self.isCompact()) {
            // In plain mode, downloads are silent - no output
            return;
        }

        self.download_spinners_mutex.lockUncancelable(global_io.io());
        if (self.download_spinners.getPtr(name)) |entry| {
            self.download_spinners_mutex.unlock(global_io.io());

            const status_text = if (success) "done" else "failed";
            const label_text = entry.label orelse name;
            const base = try std.fmt.allocPrint(self.allocator, "[DL {s}] {s}", .{ status_text, label_text });
            defer self.allocator.free(base);

            const msg = try self.makeColoredMessage(if (success) .Green else .Red, true, base);
            try self.download_finished_messages.append(self.allocator, msg);

            // Release old label; spinner will now own colored string through download_finished_messages.
            if (entry.label) |lbl| {
                self.allocator.free(lbl);
                entry.label = null;
            }

            // Update spinner style to static text
            const finished_style = try indicatif.ProgressStyle.withTemplate(self.allocator, "{msg}");
            entry.spinner.setStyle(finished_style);
            entry.spinner.setMessage(msg);
            entry.spinner.state.finish();
            entry.spinner.setPrefix(if (success) STATUS_DONE else STATUS_FAILED);
        } else {
            self.download_spinners_mutex.unlock(global_io.io());
        }
    }

    /// Start a resource execution
    pub fn startResource(
        self: *Self,
        resource_type: []const u8,
        resource_name: []const u8,
        action: []const u8,
        depth: usize,
        display_path: []const resources.DisplayScope,
    ) !void {
        self.executed_count += 1;

        if (!self.isCompact()) {
            self.finishNormalResourceLine();
            self.syncNormalDisplayPath(display_path, depth);
            self.normal_resource_depth = depth;
            printNormalIndent(depth + 1);
            std.debug.print("* {s}[{s}] action {s}", .{ resource_type, resource_name, action });
            self.normal_resource_line_open = true;
            self.normal_at_gap = false;
            return;
        }

        // Keep previous resource lines in place; only free message pointer.
        if (self.resource_message) |old_msg| {
            self.allocator.free(old_msg);
            self.resource_message = null;
        }

        // Create a new spinner for this resource
        const spinner = try self.mp.addSpinner();
        const msg = try self.buildResourceMessage(resource_type, resource_name, "");

        const template = try std.fmt.allocPrint(self.allocator, "{s}{{spinner}} {{msg}}", .{INDENT_RESOURCE});
        defer self.allocator.free(template);
        var style = try indicatif.ProgressStyle.withTemplate(self.allocator, template);
        style.tick_chars = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏";
        spinner.setStyle(style);
        spinner.setMessage(msg);

        self.resource_spinner = spinner;
        self.resource_message = msg; // Keep message allocated
        self.compact_at_gap = false;

        // Move timer spinner to the end if it exists
        if (self.timer_spinner) |timer| {
            self.mp.moveToEnd(timer);
        }
    }

    /// Mark resource as updated. When skip_reason is set (e.g. "up to date"),
    /// the action ran but did not change state; otherwise the resource was
    /// actually modified.
    pub fn resourceUpdated(
        self: *Self,
        resource_type: []const u8,
        resource_name: []const u8,
        action: []const u8,
        skip_reason: ?[]const u8,
        output: ?[]const u8,
    ) !void {
        self.updated_count += 1;

        const suffix: []const u8 = if (skip_reason) |reason|
            try std.fmt.allocPrint(self.allocator, " ({s})", .{reason})
        else
            "";
        defer if (skip_reason != null) self.allocator.free(suffix);

        if (!self.isCompact()) {
            if (self.normal_resource_line_open) {
                const status = skip_reason orelse "updated";
                std.debug.print(" {s}({s}){s}\n", .{ self.normalStyle(ANSI.GREEN), status, self.normalStyle(ANSI.RESET) });
                self.normal_resource_line_open = false;
            }
            if (output) |detail| {
                if (!std.mem.eql(u8, resource_type, "execute")) {
                    self.printNormalOutput(self.normal_resource_depth + 1, detail);
                }
            }
            return;
        }

        if (self.resource_spinner) |spinner| {
            if (self.resource_message) |old_msg| {
                self.allocator.free(old_msg);
            }

            const base = try self.buildResourceMessage(resource_type, resource_name, "");
            defer self.allocator.free(base);
            const message = try std.fmt.allocPrint(self.allocator, "{s} action {s}{s}", .{ base, action, suffix });
            defer self.allocator.free(message);
            // Add indentation and checkmark icon before the message
            const base_with_checkmark = try std.fmt.allocPrint(self.allocator, "{s}✓ {s}", .{ INDENT_RESOURCE, message });
            defer self.allocator.free(base_with_checkmark);
            const msg = try self.makeColoredMessage(.Green, true, base_with_checkmark);
            try self.download_finished_messages.append(self.allocator, msg);

            const finished_style = try indicatif.ProgressStyle.withTemplate(self.allocator, "{msg}");
            spinner.setStyle(finished_style);
            spinner.setMessage(msg);
            spinner.state.finish();

            self.resource_spinner = null;
            self.resource_message = null;
        }
    }

    /// Mark resource as skipped
    pub fn resourceSkipped(self: *Self, resource_type: []const u8, resource_name: []const u8, action: []const u8, skip_reason: ?[]const u8) !void {
        self.skipped_count += 1;

        if (!self.isCompact()) {
            const reason = skip_reason orelse "up to date";
            if (self.normal_resource_line_open) {
                std.debug.print(" {s}({s}){s}\n", .{ self.normalStyle(ANSI.CYAN), reason, self.normalStyle(ANSI.RESET) });
                self.normal_resource_line_open = false;
            }
            return;
        }

        if (self.resource_spinner) |spinner| {
            if (self.resource_message) |old_msg| {
                self.allocator.free(old_msg);
            }

            const base = try self.buildResourceMessage(resource_type, resource_name, "");
            defer self.allocator.free(base);
            const reason = skip_reason orelse "up to date";
            const message = try std.fmt.allocPrint(self.allocator, "{s} action {s} ({s})", .{ base, action, reason });
            defer self.allocator.free(message);
            // Add indentation and skip icon (hollow circle) before the message
            // Use gray color (ANSI Bright Black, code 90) for modern terminals
            const base_with_icon = try std.fmt.allocPrint(self.allocator, "{s}\x1b[90m○ {s}\x1b[0m", .{ INDENT_RESOURCE, message });
            // Don't free base_with_icon here - it's stored in download_finished_messages
            try self.download_finished_messages.append(self.allocator, base_with_icon);

            const finished_style = try indicatif.ProgressStyle.withTemplate(self.allocator, "{msg}");
            spinner.setStyle(finished_style);
            spinner.setMessage(base_with_icon);
            spinner.state.finish();

            self.resource_spinner = null;
            self.resource_message = null;
        }
    }

    /// Mark resource as failed
    pub fn resourceError(self: *Self, failure: ResourceFailure) !void {
        self.failed_count += 1;

        if (!self.isCompact()) {
            self.finishNormalResourceLine();
            const detail_indent = failure.depth + 2;
            const message = if (failure.stderr != null)
                failure.message[0 .. std.mem.indexOf(u8, failure.message, "; stderr:") orelse failure.message.len]
            else
                failure.message;
            const message_includes_title = std.mem.indexOf(u8, message, failure.error_name) != null;
            printNormalIndent(detail_indent);
            std.debug.print("{s}{s}Error: {s}{s}\n", .{
                self.normalStyle(ANSI.BOLD),
                self.normalStyle(ANSI.RED),
                if (message_includes_title) message else failure.error_name,
                self.normalStyle(ANSI.RESET),
            });
            if (!message_includes_title) printNormalText(failure.depth + 2, message);

            if (failure.command) |command| {
                printNormalIndent(detail_indent);
                std.debug.print("{s}Command:{s}\n", .{ self.normalStyle(ANSI.BOLD), self.normalStyle(ANSI.RESET) });
                printNormalText(failure.depth + 2, command);
            }

            if (failure.stdout != null or failure.stderr != null) {
                printNormalIndent(detail_indent);
                std.debug.print("{s}Output:{s}\n", .{ self.normalStyle(ANSI.BOLD), self.normalStyle(ANSI.RESET) });
                if (failure.stdout) |stdout| {
                    printNormalIndent(detail_indent + 1);
                    std.debug.print("{s}stdout:{s}\n", .{ self.normalStyle(ANSI.DIM), self.normalStyle(ANSI.RESET) });
                    printNormalText(failure.depth + 3, stdout);
                }
                if (failure.stderr) |stderr| {
                    printNormalIndent(detail_indent + 1);
                    std.debug.print("{s}stderr:{s}\n", .{ self.normalStyle(ANSI.RED), self.normalStyle(ANSI.RESET) });
                    printNormalText(failure.depth + 3, stderr);
                }
            }
            if (failure.backtrace) |backtrace| {
                printNormalIndent(detail_indent);
                std.debug.print("{s}Backtrace:{s}\n", .{ self.normalStyle(ANSI.BOLD), self.normalStyle(ANSI.RESET) });
                printNormalText(failure.depth + 2, backtrace);
            }
            return;
        }

        if (self.resource_spinner) |spinner| {
            if (self.resource_message) |old_msg| {
                self.allocator.free(old_msg);
            }

            const detail = if (failure.stderr != null)
                failure.message[0 .. std.mem.indexOf(u8, failure.message, "; stderr:") orelse failure.message.len]
            else
                failure.message;
            const suffix = try std.fmt.allocPrint(self.allocator, ": {s}", .{detail});
            defer self.allocator.free(suffix);
            const base = try self.buildResourceMessage(failure.resource_type, failure.resource_name, suffix);
            defer self.allocator.free(base);
            // Add indentation and error icon before the message
            const base_with_icon = try std.fmt.allocPrint(self.allocator, "{s}✗ {s}", .{ INDENT_RESOURCE, base });
            defer self.allocator.free(base_with_icon);

            const msg = try self.makeColoredMessage(.Red, true, base_with_icon);
            try self.download_finished_messages.append(self.allocator, msg);

            const finished_style = try indicatif.ProgressStyle.withTemplate(self.allocator, "{msg}");
            spinner.setStyle(finished_style);
            spinner.setMessage(msg);
            spinner.state.finish();

            self.resource_spinner = null;
            self.resource_message = null;

            if (failure.command) |command| try self.addCompactCommandDetails(command);
            if (failure.stdout) |stdout| try self.addCompactOutputDetails(.stdout, stdout);
            if (failure.stderr) |stderr| try self.addCompactOutputDetails(.stderr, stderr);
            if (failure.backtrace) |backtrace| try self.addCompactBacktrace(backtrace);
        }
    }

    /// Show notification
    pub fn showNotification(self: *Self, source_id: []const u8, target: []const u8, action: []const u8) !void {
        if (!self.isCompact()) {
            self.finishNormalResourceLine();
            printNormalIndent(1);
            std.debug.print("{s}- notify {s} -> {s} ({s}){s}\n", .{ self.normalStyle(ANSI.CYAN), source_id, target, action, self.normalStyle(ANSI.RESET) });
            self.normal_at_gap = false;
            return;
        }

        const message = try std.fmt.allocPrint(
            self.allocator,
            "{s}  - notify {s} -> {s} ({s}){s}",
            .{ ANSI.CYAN, source_id, target, action, ANSI.RESET },
        );
        try self.addCompactOwnedLine(message);
    }

    /// Show final summary
    pub fn showSummary(self: *Self) !void {
        // Don't clear - we want to keep the finished resource list visible
        // if (self.isCompact()) {
        //     try self.mp.clear();
        // }

        if (!self.isCompact()) {
            self.finishNormalResourceLine();
            const succeeded = !self.run_failed and self.failed_count == 0;
            std.debug.print("\n{s}Provisioning {s}, {d}/{d} resources updated", .{
                self.normalStyle(if (succeeded) ANSI.GREEN else ANSI.RED),
                if (succeeded) "complete" else "failed",
                self.updated_count,
                self.executed_count,
            });
            if (self.failed_count > 0) std.debug.print(", {d} failed", .{self.failed_count});
            if (self.handled_failure_count > 0) std.debug.print(", {d} handled failure{s}", .{ self.handled_failure_count, if (self.handled_failure_count == 1) "" else "s" });
            std.debug.print("{s}\n", .{self.normalStyle(ANSI.RESET)});
        }
    }

    /// Show final summary with duration
    pub fn showSummaryWithDuration(self: *Self, duration_s: i64, duration_ms_part: i64) !void {
        try self.showSummaryWithDurationLabel("Provisioning", duration_s, duration_ms_part);
    }

    pub fn showTaskSummaryWithDuration(self: *Self, duration_s: i64, duration_ms_part: i64) !void {
        try self.showSummaryWithDurationLabel("Task run", duration_s, duration_ms_part);
    }

    pub fn markRunFailed(self: *Self) void {
        self.run_failed = true;
    }

    pub fn failureCheckpoint(self: *const Self) usize {
        return self.failed_count;
    }

    /// Reclassify failures raised and handled inside a successful task action.
    /// The resource row remains visible as a failure, but it no longer makes the
    /// overall task run fail.
    pub fn handleFailuresSince(self: *Self, checkpoint: usize) void {
        if (self.failed_count <= checkpoint) return;
        self.handled_failure_count += self.failed_count - checkpoint;
        self.failed_count = checkpoint;
    }

    fn showSummaryWithDurationLabel(self: *Self, label: []const u8, duration_s: i64, duration_ms_part: i64) !void {
        _ = duration_s;
        _ = duration_ms_part;

        if (!self.isCompact()) {
            self.finishNormalResourceLine();
            const io = global_io.io();
            const current_time: i128 = std.Io.Timestamp.now(io, .real).toNanoseconds();
            const elapsed_ns = current_time - self.start_time;
            const elapsed_ms = @divTrunc(elapsed_ns, std.time.ns_per_ms);
            const elapsed_s = @divTrunc(elapsed_ms, 1000);
            const elapsed_ms_part = @rem(elapsed_ms, 1000);
            const summary = try self.formatSummaryMessage(label, elapsed_s, @intCast(@abs(elapsed_ms_part)));
            defer self.allocator.free(summary);
            std.debug.print("\n{s}{s}{s}\n", .{
                self.normalStyle(if (self.didSucceed()) ANSI.GREEN else ANSI.RED),
                summary,
                self.normalStyle(ANSI.RESET),
            });
        } else {
            try self.addCompactGap();

            // Finish the timer spinner with final message
            try self.finishTimer(label);

            // Draw the final state
            try self.mp.draw();
        }
    }

    /// Update display (for continuous rendering)
    pub fn update(self: *Self) !void {
        if (!self.isCompact()) return;

        // Update timer message
        try self.updateTimer();

        // Tick all ACTIVE spinners to animate them (only those still in the HashMap)
        self.download_spinners_mutex.lockUncancelable(global_io.io());
        var iter = self.download_spinners.valueIterator();
        while (iter.next()) |entry_ptr| {
            const entry = entry_ptr.*;
            if (!entry.spinner.state.isFinished()) {
                entry.spinner.tickNoDraw();
            }
        }
        self.download_spinners_mutex.unlock(global_io.io());

        if (self.resource_spinner) |spinner| {
            spinner.tickNoDraw();
        }

        if (self.timer_spinner) |spinner| {
            if (!spinner.state.isFinished()) {
                spinner.tickNoDraw();
            }
        }

        try self.mp.draw();
    }

    fn makeColoredMessage(self: *Self, color: AnsiColor, bold: bool, text: []const u8) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer aw.deinit();
        const style = AnsiStyle{
            .foreground = color,
            .font_style = if (bold) .{ .bold = true } else .{},
        };
        const writer = &aw.writer;
        try ansi.format.updateStyle(writer, style, null);
        try writer.writeAll(text);
        try ansi.format.resetStyle(writer);
        return try aw.toOwnedSlice();
    }

    fn buildResourceMessage(self: *Self, resource_type: []const u8, resource_name: []const u8, suffix: []const u8) ![]u8 {
        var counter_buffer: [64]u8 = undefined;
        return std.fmt.allocPrint(self.allocator, "{s}  {s}[{s}]{s}", .{
            self.formatCounter(&counter_buffer),
            resource_type,
            resource_name,
            suffix,
        });
    }
    fn makeDownloadLabel(self: *Self, text: []const u8) ![]u8 {
        const max_len: usize = 96;
        if (text.len <= max_len) {
            return try self.allocator.dupe(u8, text);
        }

        const keep_total = max_len - 3;
        const head_len = keep_total / 2;
        const tail_len = keep_total - head_len;
        const tail_start = text.len - tail_len;

        var result = try self.allocator.alloc(u8, head_len + 3 + tail_len);
        std.mem.copyForwards(u8, result[0..head_len], text[0..head_len]);
        std.mem.copyForwards(u8, result[head_len .. head_len + 3], "..."); // ASCII ellipsis
        std.mem.copyForwards(u8, result[result.len - tail_len ..], text[tail_start..]);
        return result;
    }
};

test "formatCounter supports known and unknown totals" {
    var display = try ModernProvisionDisplay.init(std.testing.allocator, .normal);
    defer display.deinit();
    var buffer: [64]u8 = undefined;

    display.executed_count = 3;
    display.setTotalResources(0);
    try std.testing.expectEqualStrings("[3]", display.formatCounter(&buffer));

    display.setTotalResources(9);
    try std.testing.expectEqualStrings("[3/9]", display.formatCounter(&buffer));

    display.setTotalResources(10);
    try std.testing.expectEqualStrings("[ 3/10]", display.formatCounter(&buffer));

    display.setTotalResources(100);
    try std.testing.expectEqualStrings("[  3/100]", display.formatCounter(&buffer));
}

test "unified diff lines use semantic terminal colors" {
    const diff =
        \\diff --git a/config b/config
        \\index 1111111..2222222 100644
        \\--- a/config
        \\+++ b/config
        \\@@ -1 +1 @@
        \\-old
        \\+new
    ;
    try std.testing.expect(ModernProvisionDisplay.isUnifiedDiff(diff));
    try std.testing.expectEqualStrings(ANSI.DIM, ModernProvisionDisplay.diffLineStyle("diff --git a/config b/config"));
    try std.testing.expectEqualStrings(ANSI.DIM, ModernProvisionDisplay.diffLineStyle("index 1111111..2222222 100644"));
    try std.testing.expectEqualStrings(ANSI.RED, ModernProvisionDisplay.diffLineStyle("--- a/config"));
    try std.testing.expectEqualStrings(ANSI.RED, ModernProvisionDisplay.diffLineStyle("-old"));
    try std.testing.expectEqualStrings(ANSI.GREEN, ModernProvisionDisplay.diffLineStyle("+++ b/config"));
    try std.testing.expectEqualStrings(ANSI.GREEN, ModernProvisionDisplay.diffLineStyle("+new"));
    try std.testing.expectEqualStrings(ANSI.CYAN, ModernProvisionDisplay.diffLineStyle("@@ -1 +1 @@"));
    try std.testing.expectEqualStrings("", ModernProvisionDisplay.diffLineStyle(" unchanged"));
}

test "notification heading stays attached to its compact list" {
    const allocator = std.testing.allocator;
    var display = try ModernProvisionDisplay.init(allocator, .compact);
    defer display.deinit();

    try display.showNotificationSection("Immediate notifications");
    try std.testing.expect(!display.compact_at_gap);
    try std.testing.expect(std.mem.indexOf(
        u8,
        display.section_messages.items[0],
        ANSI.MAGENTA ++ SECTION_MARKER ++ " Immediate notifications:",
    ) != null);

    try display.showNotification("file[/tmp/config]", "execute[reload]", "run");
    try std.testing.expectEqual(@as(usize, 1), display.download_finished_messages.items.len);
    try std.testing.expect(std.mem.indexOf(
        u8,
        display.download_finished_messages.items[0],
        "  - notify file[/tmp/config] -> execute[reload] (run)",
    ) != null);

    try display.showNotificationSection("Delayed notifications");
    try std.testing.expectEqual(@as(usize, 3), display.section_messages.items.len);
    try std.testing.expectEqualStrings("", display.section_messages.items[1]);
    try std.testing.expect(!display.compact_at_gap);
}

test "compact output collapses successful command details" {
    const allocator = std.testing.allocator;
    var display = try ModernProvisionDisplay.init(allocator, .compact);
    defer display.deinit();

    try display.startResource("execute", "build step", "run", 0, &.{});
    try display.showCommand("printf 'successful output\\n'");
    try std.testing.expect(std.mem.indexOf(u8, display.resource_message.?, "$ printf") != null);

    try display.printCommandLine(.stdout, "successful output");
    try display.resourceUpdated("execute", "build step", "run", null, "successful output\n");

    try std.testing.expectEqual(@as(usize, 1), display.download_finished_messages.items.len);
    const final_line = display.download_finished_messages.items[0];
    try std.testing.expect(std.mem.indexOf(u8, final_line, "execute[build step] action run") != null);
    try std.testing.expect(std.mem.indexOf(u8, final_line, "printf") == null);
    try std.testing.expect(std.mem.indexOf(u8, final_line, "successful output") == null);
}

test "compact output expands failed command diagnostics" {
    const allocator = std.testing.allocator;
    var display = try ModernProvisionDisplay.init(allocator, .compact);
    defer display.deinit();

    try display.startResource("execute", "compile", "run", 0, &.{});
    try display.showCommand("cc main.c");
    try display.resourceError(.{
        .resource_type = "execute",
        .resource_name = "compile",
        .action = "run",
        .depth = 0,
        .error_name = "Command failed",
        .message = "command exited with status 1; stderr: compile failed",
        .command = "cc main.c",
        .stdout = "compiling main.c\n",
        .stderr = "compile failed\n",
        .backtrace = "Holafile:12",
    });

    try std.testing.expectEqual(@as(usize, 6), display.download_finished_messages.items.len);
    const expected = [_][]const u8{
        "command exited with status 1",
        "$ cc main.c",
        "compiling main.c",
        "compile failed",
        "Backtrace:",
        "Holafile:12",
    };
    for (expected, display.download_finished_messages.items) |needle, line| {
        try std.testing.expect(std.mem.indexOf(u8, line, needle) != null);
    }
}
