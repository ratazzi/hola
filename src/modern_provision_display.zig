const std = @import("std");
const indicatif = @import("indicatif.zig");
const ansi = @import("ansi_term");
const ansi_constants = @import("ansi_constants.zig");
const ANSI = ansi_constants.ANSI;
const http_utils = @import("http_utils.zig");

const AnsiStyle = ansi.style.Style;
const AnsiColor = ansi.style.Color;
const STATUS_PENDING = "[DL] pending";
const STATUS_DOWNLOADING = "[DL] downloading";
const STATUS_DONE = "[DL] done";
const STATUS_FAILED = "[DL] failed";

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
    download_spinners_mutex: std.Thread.Mutex = .{},
    download_finished_messages: std.ArrayList([]const u8), // Keep finished messages allocated
    section_messages: std.ArrayList([]const u8), // Keep section header messages allocated
    download_section_spinner: ?*indicatif.ProgressBar = null, // Static section header for downloads
    resource_section_spinner: ?*indicatif.ProgressBar = null, // Static section header for resources
    resource_spinner: ?*indicatif.ProgressBar = null,
    resource_message: ?[]const u8 = null, // Keep message allocated
    show_progress: bool,
    total_resources: usize = 0,
    executed_count: usize = 0,
    updated_count: usize = 0,
    skipped_count: usize = 0,
    failed_count: usize = 0,
    timer_spinner: ?*indicatif.ProgressBar = null,
    timer_message: ?[]u8 = null,
    start_time: i128 = 0,

    pub fn init(allocator: std.mem.Allocator, show_progress: bool) !Self {
        return .{
            .allocator = allocator,
            .mp = indicatif.MultiProgress.init(allocator),
            .download_spinners = std.StringHashMap(DownloadEntry).init(allocator),
            .download_finished_messages = std.ArrayList([]const u8).empty,
            .section_messages = std.ArrayList([]const u8).empty,
            .show_progress = show_progress,
        };
    }

    pub fn deinit(self: *Self) void {

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

    /// Start the timer spinner
    pub fn startTimer(self: *Self, start_time: i128) !void {
        self.start_time = start_time;
        if (!self.show_progress) return;

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
        if (!self.show_progress) return;
        if (self.timer_spinner == null) return;

        const current_time = std.time.nanoTimestamp();
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
    pub fn finishTimer(self: *Self) !void {
        if (!self.show_progress) return;
        if (self.timer_spinner == null) return;

        const current_time = std.time.nanoTimestamp();
        const elapsed_ns = current_time - self.start_time;
        const elapsed_ms = @divTrunc(elapsed_ns, std.time.ns_per_ms);
        const elapsed_s = @divTrunc(elapsed_ms, 1000);
        const elapsed_ms_part = @rem(elapsed_ms, 1000);

        if (self.timer_message) |old_msg| {
            self.allocator.free(old_msg);
        }

        const base_msg = try std.fmt.allocPrint(
            self.allocator,
            "✓ Completed in {d}.{d:0>3}s - {d} updated, {d} skipped",
            .{ elapsed_s, @as(u64, @intCast(elapsed_ms_part)), self.updated_count, self.skipped_count },
        );
        defer self.allocator.free(base_msg);

        const colored_msg = try self.makeColoredMessage(.Green, true, base_msg);
        try self.download_finished_messages.append(self.allocator, colored_msg);

        if (self.timer_spinner) |spinner| {
            const finished_style = try indicatif.ProgressStyle.withTemplate(self.allocator, "{msg}");
            spinner.setStyle(finished_style);
            spinner.setMessage(colored_msg);
            spinner.state.finish();
        }

        self.timer_message = null;
    }

    /// Show section header (default level 2 = ##)
    pub fn showSection(self: *Self, header: []const u8) !void {
        try self.showSectionWithLevel(header, 2);
    }

    /// Show section header with custom level (2 = ##, 3 = ###, 4 = ####)
    pub fn showSectionWithLevel(self: *Self, header: []const u8, level: u8) !void {
        // Use markdown-style prefixes but optimized for terminal
        // Level 2: ## with bold
        // Level 3: ### without bold
        // Level 4: #### without bold

        const prefix = switch (level) {
            2 => "##",
            3 => "###",
            4 => "####",
            else => "##",
        };

        if (!self.show_progress) {
            if (level == 2) {
                std.debug.print("\n{s}{s} {s}{s}\n", .{ ANSI.BOLD, prefix, header, ANSI.RESET });
            } else {
                std.debug.print("{s} {s}\n", .{ prefix, header });
            }
            return;
        }

        // Check if this section already exists
        const is_download_section = std.mem.indexOf(u8, header, "Download") != null;
        const is_resource_section = std.mem.indexOf(u8, header, "Executing") != null or std.mem.indexOf(u8, header, "Resource") != null;

        if (is_download_section and self.download_section_spinner != null) {
            // Section already exists, don't create duplicate
            return;
        }
        if (is_resource_section and self.resource_section_spinner != null) {
            // Section already exists, don't create duplicate
            return;
        }

        // Add an empty line before section (except for the first section)
        if (self.download_section_spinner != null or self.resource_section_spinner != null) {
            const empty_spinner = try self.mp.addSpinner();
            const empty_msg = try self.allocator.dupe(u8, "");
            const empty_style = try indicatif.ProgressStyle.withTemplate(self.allocator, "{msg}");
            empty_spinner.setStyle(empty_style);
            empty_spinner.setMessage(empty_msg);
            empty_spinner.finish();
            try self.section_messages.append(self.allocator, empty_msg);
        }

        // Create a static section header spinner
        const spinner = try self.mp.addSpinner();
        const msg = if (level == 2)
            try std.fmt.allocPrint(self.allocator, "{s}{s} {s}{s}", .{ ANSI.BOLD, prefix, header, ANSI.RESET })
        else
            try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ prefix, header });

        const style = try indicatif.ProgressStyle.withTemplate(self.allocator, "{msg}");
        spinner.setStyle(style);
        spinner.setMessage(msg);
        spinner.finish(); // Make it static (no spinning)

        // Keep track of section message for cleanup
        try self.section_messages.append(self.allocator, msg);

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

    /// Show info message
    pub fn showInfo(self: *Self, message: []const u8) !void {
        if (!self.show_progress) {
            std.debug.print("\x1b[34mℹ\x1b[0m {s}\n", .{message});
        }
    }

    /// Pre-create download spinners so they always occupy the top rows
    pub fn reserveDownloadSlots(self: *Self, names: [][]const u8) !void {
        if (!self.show_progress) return;

        for (names) |name| {
            self.download_spinners_mutex.lock();
            const already_exists = self.download_spinners.contains(name);
            self.download_spinners_mutex.unlock();
            if (already_exists) continue;

            const spinner = try self.mp.addSpinner();
            var style = try indicatif.ProgressStyle.withTemplate(self.allocator, "{prefix} {spinner} {msg}");
            style.tick_chars = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏";
            spinner.setStyle(style);

            const name_copy = try self.allocator.dupe(u8, name);
            const label = try self.makeDownloadLabel(name_copy);
            spinner.setMessage(label);
            spinner.setPrefix(STATUS_PENDING);

            self.download_spinners_mutex.lock();
            try self.download_spinners.put(name_copy, .{ .spinner = spinner, .label = label });
            self.download_spinners_mutex.unlock();
        }
    }

    /// Add/update a download spinner
    pub fn addDownload(self: *Self, name: []const u8, total_bytes: u64) !void {
        if (!self.show_progress) {
            std.debug.print(" Downloading {s}...\n", .{name});
            return;
        }

        self.download_spinners_mutex.lock();
        defer self.download_spinners_mutex.unlock();

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
        if (!self.show_progress) return;

        self.download_spinners_mutex.lock();
        defer self.download_spinners_mutex.unlock();

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
        return http_utils.formatSize(self.allocator, bytes);
    }

    /// Finish a download
    pub fn finishDownload(self: *Self, name: []const u8, success: bool) !void {
        if (!self.show_progress) {
            if (success) {
                std.debug.print("✓ {s}\n", .{name});
            } else {
                std.debug.print("✗ {s} failed\n", .{name});
            }
            return;
        }

        self.download_spinners_mutex.lock();
        if (self.download_spinners.getPtr(name)) |entry| {
            self.download_spinners_mutex.unlock();

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
            self.download_spinners_mutex.unlock();
        }
    }

    /// Start a resource execution
    pub fn startResource(self: *Self, resource_type: []const u8, resource_name: []const u8) !void {
        self.executed_count += 1;

        if (!self.show_progress) {
            std.debug.print("Processing {s}[{s}]...\n", .{ resource_type, resource_name });
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

        var style = try indicatif.ProgressStyle.withTemplate(self.allocator, "{spinner} {msg}");
        style.tick_chars = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏";
        spinner.setStyle(style);
        spinner.setMessage(msg);

        self.resource_spinner = spinner;
        self.resource_message = msg; // Keep message allocated

        // Move timer spinner to the end if it exists
        if (self.timer_spinner) |timer| {
            self.mp.moveToEnd(timer);
        }
    }

    /// Mark resource as updated
    /// Mark resource as updated (or up to date)
    pub fn resourceUpdated(self: *Self, resource_type: []const u8, resource_name: []const u8, action: []const u8, skip_reason: ?[]const u8) !void {
        _ = skip_reason; // Always show "up to date" for updated resources
        self.updated_count += 1;

        if (!self.show_progress) {
            std.debug.print("\x1b[32m✓\x1b[0m {s}[{s}] action {s} (up to date)\n", .{ resource_type, resource_name, action });
            return;
        }

        if (self.resource_spinner) |spinner| {
            if (self.resource_message) |old_msg| {
                self.allocator.free(old_msg);
            }

            const base = try self.buildResourceMessage(resource_type, resource_name, "");
            defer self.allocator.free(base);
            const message = try std.fmt.allocPrint(self.allocator, "{s} action {s} (up to date)", .{ base, action });
            defer self.allocator.free(message);
            // Add checkmark icon before the message for alignment
            const base_with_checkmark = try std.fmt.allocPrint(self.allocator, "✓ {s}", .{message});
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

        if (!self.show_progress) {
            const reason = skip_reason orelse "up to date";
            std.debug.print("\x1b[90m○\x1b[0m {s}[{s}] action {s} ({s})\n", .{ resource_type, resource_name, action, reason });
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
            // Add skip icon (hollow circle) before the message for alignment
            // Use gray color (ANSI Bright Black, code 90) for modern terminals
            const base_with_icon = try std.fmt.allocPrint(self.allocator, "\x1b[90m○ {s}\x1b[0m", .{message});
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
    pub fn resourceError(self: *Self, resource_type: []const u8, resource_name: []const u8, error_msg: []const u8) !void {
        self.failed_count += 1;

        if (!self.show_progress) {
            std.debug.print("\x1b[31m✗\x1b[0m {s}[{s}]: {s}\n", .{ resource_type, resource_name, error_msg });
            return;
        }

        if (self.resource_spinner) |spinner| {
            if (self.resource_message) |old_msg| {
                self.allocator.free(old_msg);
            }

            const suffix = try std.fmt.allocPrint(self.allocator, ": {s}", .{error_msg});
            defer self.allocator.free(suffix);
            const base = try self.buildResourceMessage(resource_type, resource_name, suffix);
            defer self.allocator.free(base);
            // Add error icon before the message for alignment
            const base_with_icon = try std.fmt.allocPrint(self.allocator, "✗ {s}", .{base});
            defer self.allocator.free(base_with_icon);

            const msg = try self.makeColoredMessage(.Red, true, base_with_icon);
            try self.download_finished_messages.append(self.allocator, msg);

            const finished_style = try indicatif.ProgressStyle.withTemplate(self.allocator, "{msg}");
            spinner.setStyle(finished_style);
            spinner.setMessage(msg);
            spinner.state.finish();

            self.resource_spinner = null;
            self.resource_message = null;
        }
    }

    /// Show notification
    pub fn showNotification(self: *Self, source_id: []const u8, target: []const u8, action: []const u8) !void {
        if (!self.show_progress) {
            std.debug.print("\x1b[36m🔔\x1b[0m {s} -> {s} ({s})\n", .{ source_id, target, action });
        }
    }

    /// Show final summary
    pub fn showSummary(self: *Self) !void {
        // Don't clear - we want to keep the finished resource list visible
        // if (self.show_progress) {
        //     try self.mp.clear();
        // }

        if (!self.show_progress) {
            std.debug.print("\n\x1b[1m\x1b[36m--- Execution Summary ---\x1b[0m\n", .{});
            std.debug.print("Executed: {d} resources\n", .{self.executed_count});
            std.debug.print("Updated: \x1b[32m{d}\x1b[0m resources\n", .{self.updated_count});
            std.debug.print("Skipped: \x1b[2m{d}\x1b[0m resources\n", .{self.skipped_count});
            if (self.failed_count > 0) {
                std.debug.print("Failed: \x1b[31m{d}\x1b[0m resources\n", .{self.failed_count});
            }
            std.debug.print("\x1b[32m✓\x1b[0m Provisioning completed successfully!\n", .{});
        }
    }

    /// Show final summary with duration
    pub fn showSummaryWithDuration(self: *Self, duration_s: i64, duration_ms_part: i64) !void {
        _ = duration_s;
        _ = duration_ms_part;

        if (!self.show_progress) {
            std.debug.print("\n\x1b[1m\x1b[36m--- Execution Summary ---\x1b[0m\n", .{});
            std.debug.print("Executed: {d} resources\n", .{self.executed_count});
            std.debug.print("Updated: \x1b[32m{d}\x1b[0m resources\n", .{self.updated_count});
            std.debug.print("Skipped: \x1b[2m{d}\x1b[0m resources\n", .{self.skipped_count});
            if (self.failed_count > 0) {
                std.debug.print("Failed: \x1b[31m{d}\x1b[0m resources\n", .{self.failed_count});
            }

            const current_time = std.time.nanoTimestamp();
            const elapsed_ns = current_time - self.start_time;
            const elapsed_ms = @divTrunc(elapsed_ns, std.time.ns_per_ms);
            const elapsed_s = @divTrunc(elapsed_ms, 1000);
            const elapsed_ms_part = @rem(elapsed_ms, 1000);
            std.debug.print("Duration: \x1b[36m{d}.{d:0>3}s\x1b[0m\n", .{ elapsed_s, elapsed_ms_part });
            std.debug.print("\x1b[32m✓\x1b[0m Provisioning completed successfully!\n", .{});
        } else {
            // Finish the timer spinner with final message
            try self.finishTimer();

            // Draw the final state
            try self.mp.draw();
        }
    }

    /// Update display (for continuous rendering)
    pub fn update(self: *Self) !void {
        if (!self.show_progress) return;

        // Update timer message
        try self.updateTimer();

        // Tick all ACTIVE spinners to animate them (only those still in the HashMap)
        self.download_spinners_mutex.lock();
        var iter = self.download_spinners.valueIterator();
        while (iter.next()) |entry_ptr| {
            const entry = entry_ptr.*;
            if (!entry.spinner.state.isFinished()) {
                entry.spinner.tickNoDraw();
            }
        }
        self.download_spinners_mutex.unlock();

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
        var buffer = std.ArrayList(u8){};
        errdefer buffer.deinit(self.allocator);
        const style = AnsiStyle{
            .foreground = color,
            .font_style = if (bold) .{ .bold = true } else .{},
        };
        var writer = buffer.writer(self.allocator);
        try ansi.format.updateStyle(writer, style, null);
        try writer.writeAll(text);
        try ansi.format.resetStyle(writer);
        return try buffer.toOwnedSlice(self.allocator);
    }

    fn buildResourceMessage(self: *Self, resource_type: []const u8, resource_name: []const u8, suffix: []const u8) ![]u8 {
        const total_digits = if (self.total_resources > 0)
            std.math.log10_int(self.total_resources) + 1
        else
            1;
        const current_digits = std.math.log10_int(self.executed_count) + 1;
        const padding = if (total_digits > current_digits)
            total_digits - current_digits
        else
            0;

        var padding_str: [16]u8 = undefined;
        var i: usize = 0;
        while (i < padding) : (i += 1) {
            padding_str[i] = ' ';
        }

        return std.fmt.allocPrint(self.allocator, "[{s}{d}/{d}]  {s}[{s}]{s}", .{
            padding_str[0..padding],
            self.executed_count,
            self.total_resources,
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
