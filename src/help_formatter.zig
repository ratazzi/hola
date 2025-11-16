const std = @import("std");
const ansi = @import("ansi_constants.zig");
const ANSI = ansi.ANSI;

/// Help formatter with Bun-style layout using simple alignment
pub const HelpFormatter = struct {
    const Self = @This();

    /// Command item structure for consistent formatting
    pub const CommandItem = struct {
        command: []const u8,
        description: []const u8,
    };

    /// Example item structure for consistent formatting
    pub const ExampleItem = struct {
        prefix: []const u8,
        command: []const u8,
    };

    /// Print a section header in Bun style (bold black label with colon and newline)
    pub fn sectionHeader(label: []const u8) void {
        std.debug.print("{s}{s}:{s}\n", .{ ANSI.BOLD, label, ANSI.RESET });
    }

    /// Print usage header without newline (for Usage section)
    pub fn usageHeader() void {
        std.debug.print("{s}Usage:", .{ANSI.BOLD});
    }

    /// Print a table for commands/flags with simple alignment
    pub fn printCommandTable(items: []const CommandItem) void {
        // Find the longest command for alignment
        var max_command_len: usize = 0;
        for (items) |item| {
            if (item.command.len > max_command_len) {
                max_command_len = item.command.len;
            }
        }

        for (items) |item| {
            const padding = if (item.command.len < max_command_len) max_command_len - item.command.len else 0;
            // Bun style: bright blue commands with normal descriptions
            std.debug.print("  {s}{s}{s}", .{ ANSI.BOLD, ANSI.BLUE, item.command });
            var i: usize = 0;
            while (i < padding) : (i += 1) {
                std.debug.print(" ", .{});
            }
            std.debug.print("{s}  {s}\n", .{ ANSI.RESET, item.description });
        }
    }

    /// Print usage line in Bun style (on same line as Usage:)
    pub fn printUsage(command: []const u8, args: []const u8) void {
        std.debug.print(" {s} {s}{s}\n", .{ command, args, ANSI.RESET });
    }

    /// Print examples with proper indentation and formatting
    pub fn printExamples(items: []const ExampleItem) void {
        // Find the longest prefix for alignment
        var max_prefix_len: usize = 0;
        for (items) |item| {
            if (item.prefix.len > max_prefix_len) {
                max_prefix_len = item.prefix.len;
            }
        }

        for (items) |item| {
            const padding = if (item.prefix.len < max_prefix_len) max_prefix_len - item.prefix.len else 0;
            std.debug.print("  {s}{s}{s}", .{ ANSI.DIM, item.prefix, ANSI.RESET });
            var i: usize = 0;
            while (i < padding) : (i += 1) {
                std.debug.print(" ", .{});
            }
            std.debug.print(" {s}{s}{s}\n", .{ ANSI.DIM, item.command, ANSI.RESET });
        }
    }

    /// Print error message in Bun style
    pub fn printError(text: []const u8) void {
        std.debug.print("{s}error:{s} {s}\n", .{ ANSI.RED, ANSI.RESET, text });
    }

    /// Print the main header
    pub fn printHeader(name: []const u8, tagline: []const u8) void {
        // Hola style: purple name with normal description on same line
        std.debug.print("{s}{s}{s}{s}: {s}\n", .{ ANSI.BOLD, ANSI.MAGENTA, name, ANSI.RESET, tagline });
    }

    /// Print a note/hint (Bun style: normal white)
    pub fn printNote(text: []const u8) void {
        std.debug.print("{s}\n", .{text});
    }

    /// Print a simple line break
    pub fn newline() void {
        std.debug.print("\n", .{});
    }
};
