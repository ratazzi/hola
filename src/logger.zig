const std = @import("std");
const builtin = @import("builtin");
const zeit = @import("zeit");

/// Log levels (similar to std.log)
pub const Level = enum {
    err,
    warn,
    info,
    debug,

    /// Parse level from string
    pub fn fromString(s: []const u8) ?Level {
        if (std.mem.eql(u8, s, "err") or std.mem.eql(u8, s, "error")) return .err;
        if (std.mem.eql(u8, s, "warn") or std.mem.eql(u8, s, "warning")) return .warn;
        if (std.mem.eql(u8, s, "info")) return .info;
        if (std.mem.eql(u8, s, "debug")) return .debug;
        return null;
    }

    /// Check if this level should be logged given the current threshold
    pub fn shouldLog(self: Level, threshold: Level) bool {
        return @intFromEnum(self) <= @intFromEnum(threshold);
    }

    /// Get prefix for log messages
    pub fn prefix(self: Level) []const u8 {
        return switch (self) {
            .err => "[ERROR] ",
            .warn => "[WARN]  ",
            .info => "[INFO]  ",
            .debug => "[DEBUG] ",
        };
    }
};

/// Logger for recording external command outputs and operations
pub const Logger = struct {
    allocator: std.mem.Allocator,
    log_file: ?std.fs.File = null,
    log_dir: []const u8,
    log_path: ?[]const u8 = null, // Full path to current log file
    enabled: bool = true,
    level: Level = .debug, // Default log level (debug for development)

    const Self = @This();

    /// Initialize logger with log directory
    pub fn init(allocator: std.mem.Allocator, log_dir: []const u8) !Self {
        // Create log directory recursively if it doesn't exist
        try std.fs.cwd().makePath(log_dir);

        // Read log level from environment variable HOLA_LOG_LEVEL
        const log_level = if (std.process.getEnvVarOwned(allocator, "HOLA_LOG_LEVEL")) |level_str| blk: {
            defer allocator.free(level_str);
            break :blk Level.fromString(level_str) orelse .debug;
        } else |_| .debug;

        return Self{
            .allocator = allocator,
            .log_dir = try allocator.dupe(u8, log_dir),
            .enabled = true,
            .level = log_level,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.log_file) |file| {
            file.close();
        }
        if (self.log_path) |path| {
            self.allocator.free(path);
        }
        self.allocator.free(self.log_dir);
    }

    /// Open log file for current session (one file per day)
    pub fn openLogFile(self: *Self) !void {
        if (!self.enabled) return;

        // Get current date in YYYYMMDD format (local timezone)
        const tz = zeit.local(self.allocator, null) catch zeit.utc;
        defer if (!std.meta.eql(tz, zeit.utc)) tz.deinit();
        const now = try zeit.instant(.{});
        const now_local = now.in(&tz);
        const dt = now_local.time();

        var date_buf: [9]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&date_buf);
        dt.strftime(fbs.writer(), "%Y%m%d") catch return error.DateFormatFailed;
        const date_str = fbs.getWritten();

        var log_filename_buf: [128]u8 = undefined;
        const log_filename = try std.fmt.bufPrint(&log_filename_buf, "hola-{s}.log", .{date_str});

        const log_path = try std.fs.path.join(self.allocator, &.{ self.log_dir, log_filename });
        self.log_path = log_path; // Store for later retrieval

        // Open file in append mode (create if doesn't exist)
        self.log_file = try std.fs.createFileAbsolute(log_path, .{ .truncate = false });
        try self.log_file.?.seekFromEnd(0);

        // Write session header with timestamp
        var header_buf: [256]u8 = undefined;
        var header_fbs = std.io.fixedBufferStream(&header_buf);
        header_fbs.writer().writeAll("\n=== Session started at ") catch {};
        dt.strftime(header_fbs.writer(), "%Y-%m-%d %H:%M:%S %Z") catch {};
        header_fbs.writer().writeAll(" ===\n\n") catch {};
        try self.log_file.?.writeAll(header_fbs.getWritten());
    }

    /// Get the current log file path
    pub fn getLogPath(self: *const Self) ?[]const u8 {
        return self.log_path;
    }

    /// Write to log file
    pub fn write(self: *Self, data: []const u8) !void {
        if (!self.enabled) return;
        if (self.log_file) |file| {
            try file.writeAll(data);
        }
    }

    /// Write formatted message to log file
    pub fn writeFmt(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        if (!self.enabled) return;
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(msg);
        try self.write(msg);
    }

    /// Write log message with level and timestamp
    pub fn log(self: *Self, level: Level, comptime fmt: []const u8, args: anytype) !void {
        if (!self.enabled) return;
        if (!level.shouldLog(self.level)) return;

        // Get current timestamp with microsecond precision
        const timestamp_ns = std.time.nanoTimestamp();
        const timestamp_us = @divFloor(timestamp_ns, 1000); // Convert to microseconds
        const timestamp_s = @divFloor(timestamp_us, 1_000_000); // Convert to seconds
        const microseconds: i64 = @intCast(@mod(timestamp_us, 1_000_000));

        // Calculate time components
        const seconds_today: i64 = @intCast(@mod(timestamp_s, 86400));
        const hours: i64 = @divFloor(seconds_today, 3600);
        const minutes: i64 = @divFloor(@mod(seconds_today, 3600), 60);
        const seconds: i64 = @mod(seconds_today, 60);

        const prefix_str = level.prefix();
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(msg);

        // Format: [HH:MM:SS.uuuuuu] [LEVEL] message
        var time_buf: [32]u8 = undefined;
        const time_str = try std.fmt.bufPrint(&time_buf, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}", .{
            @abs(hours), @abs(minutes), @abs(seconds), @abs(microseconds)
        });

        const full_msg = try std.fmt.allocPrint(
            self.allocator,
            "[{s}] {s}{s}",
            .{ time_str, prefix_str, msg },
        );
        defer self.allocator.free(full_msg);

        try self.write(full_msg);
    }

    /// Log command execution with output
    pub fn logCommand(self: *Self, command: []const u8, stdout: []const u8, stderr: []const u8, exit_code: ?i32) !void {
        if (!self.enabled) return;

        // Log the command execution at info level
        const level = if (exit_code) |code| blk: {
            break :blk if (code == 0) Level.info else Level.err;
        } else Level.info;

        const exit_msg = if (exit_code) |code| blk: {
            const msg = try std.fmt.allocPrint(self.allocator, " (exit: {d})", .{code});
            break :blk msg;
        } else try self.allocator.dupe(u8, "");
        defer self.allocator.free(exit_msg);

        try self.log(level, "Command: {s}{s}\n", .{ command, exit_msg });

        // Log stdout if present
        if (stdout.len > 0) {
            const stdout_trimmed = std.mem.trim(u8, stdout, &std.ascii.whitespace);
            if (stdout_trimmed.len > 0) {
                try self.log(.debug, "  stdout: {s}\n", .{stdout_trimmed});
            }
        }

        // Log stderr if present (always at warn/error level)
        if (stderr.len > 0) {
            const stderr_trimmed = std.mem.trim(u8, stderr, &std.ascii.whitespace);
            if (stderr_trimmed.len > 0) {
                try self.log(.warn, "  stderr: {s}\n", .{stderr_trimmed});
            }
        }
    }

    /// Get default log directory (XDG: ~/.local/state/hola/logs)
    pub fn getDefaultLogDir(allocator: std.mem.Allocator) ![]const u8 {
        const xdg = @import("xdg.zig").XDG.init(allocator);
        return try xdg.getLogsDir();
    }
};

/// Global logger instance
var g_logger: ?Logger = null;

/// Initialize global logger
pub fn initGlobal(allocator: std.mem.Allocator, log_dir: ?[]const u8) !void {
    const dir = log_dir orelse try Logger.getDefaultLogDir(allocator);
    defer if (log_dir == null) allocator.free(dir);

    g_logger = try Logger.init(allocator, dir);
    try g_logger.?.openLogFile();
}

/// Deinitialize global logger
pub fn deinitGlobal() void {
    if (g_logger) |*logger| {
        logger.deinit();
        g_logger = null;
    }
}

/// Get global logger instance
pub fn getLogger() ?*Logger {
    return if (g_logger) |*logger| logger else null;
}

/// Write to global logger
pub fn write(data: []const u8) void {
    if (getLogger()) |logger| {
        logger.write(data) catch {};
    }
}

/// Write formatted message to global logger
pub fn writeFmt(comptime fmt: []const u8, args: anytype) void {
    if (getLogger()) |logger| {
        logger.writeFmt(fmt, args) catch {};
    }
}

/// Log message with level to global logger
pub fn log(level: Level, comptime fmt: []const u8, args: anytype) void {
    if (getLogger()) |logger| {
        logger.log(level, fmt, args) catch {};
    }
}

/// Convenience functions for each log level
pub fn err(comptime fmt: []const u8, args: anytype) void {
    log(.err, fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    log(.warn, fmt, args);
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    log(.info, fmt, args);
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    log(.debug, fmt, args);
}

/// Log command execution
pub fn logCommand(command: []const u8, stdout: []const u8, stderr: []const u8, exit_code: ?i32) void {
    if (getLogger()) |logger| {
        logger.logCommand(command, stdout, stderr, exit_code) catch {};
    }
}

/// Get current log file path from global logger
pub fn getLogPath() ?[]const u8 {
    if (getLogger()) |logger| {
        return logger.getLogPath();
    }
    return null;
}

