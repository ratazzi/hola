/// PCRE2-based regular expression support
/// Provides a high-level Zig wrapper around PCRE2's POSIX API
const std = @import("std");

const c = @cImport({
    @cInclude("pcre2posix.h");
});

pub const RegexError = error{
    CompileError,
    NoMatch,
    OutOfMemory,
};

/// Compiled regular expression pattern
pub const Regex = struct {
    regex: c.regex_t,
    allocator: std.mem.Allocator,

    /// Compile a regular expression pattern
    pub fn compile(allocator: std.mem.Allocator, pattern: []const u8, flags: Flags) !Regex {
        // Create null-terminated pattern
        const pattern_z = try allocator.dupeZ(u8, pattern);
        defer allocator.free(pattern_z);

        var regex: c.regex_t = undefined;
        const result = c.pcre2_regcomp(&regex, pattern_z.ptr, flags.toInt());
        if (result != 0) {
            return RegexError.CompileError;
        }

        return Regex{
            .regex = regex,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Regex) void {
        c.pcre2_regfree(&self.regex);
    }

    /// Check if text matches the pattern
    pub fn isMatch(self: *const Regex, text: []const u8) bool {
        const text_z = self.allocator.dupeZ(u8, text) catch return false;
        defer self.allocator.free(text_z);

        const result = c.pcre2_regexec(&self.regex, text_z.ptr, 0, null, 0);
        return result == 0;
    }

    /// Find the first match in text, returns start and end offsets
    pub fn find(self: *const Regex, text: []const u8) ?Match {
        const text_z = self.allocator.dupeZ(u8, text) catch return null;
        defer self.allocator.free(text_z);

        var matches: [1]c.regmatch_t = undefined;
        const result = c.pcre2_regexec(&self.regex, text_z.ptr, 1, &matches, 0);
        if (result != 0) return null;

        return Match{
            .start = @intCast(matches[0].rm_so),
            .end = @intCast(matches[0].rm_eo),
        };
    }

    /// Find all matches in text
    pub fn findAll(self: *const Regex, allocator: std.mem.Allocator, text: []const u8) ![]Match {
        var results = std.ArrayList(Match).initCapacity(allocator, 8) catch std.ArrayList(Match).empty;
        errdefer results.deinit(allocator);

        const text_z = try allocator.dupeZ(u8, text);
        defer allocator.free(text_z);

        var offset: usize = 0;
        while (offset < text.len) {
            var matches: [1]c.regmatch_t = undefined;
            const result = c.pcre2_regexec(&self.regex, text_z.ptr + offset, 1, &matches, 0);
            if (result != 0) break;

            const match_start = offset + @as(usize, @intCast(matches[0].rm_so));
            const match_end = offset + @as(usize, @intCast(matches[0].rm_eo));

            try results.append(allocator, .{
                .start = match_start,
                .end = match_end,
            });

            // Move past this match
            offset = match_end;
            if (match_start == match_end) offset += 1; // Avoid infinite loop on empty match
        }

        return results.toOwnedSlice(allocator);
    }

    /// Replace first occurrence of pattern in text
    pub fn replaceFirst(self: *const Regex, allocator: std.mem.Allocator, text: []const u8, replacement: []const u8) ![]u8 {
        const match = self.find(text) orelse {
            return try allocator.dupe(u8, text);
        };

        var result = std.ArrayList(u8).initCapacity(allocator, text.len) catch std.ArrayList(u8).empty;
        errdefer result.deinit(allocator);

        try result.appendSlice(allocator, text[0..match.start]);
        try result.appendSlice(allocator, replacement);
        try result.appendSlice(allocator, text[match.end..]);

        return result.toOwnedSlice(allocator);
    }

    /// Replace all occurrences of pattern in text
    pub fn replaceAll(self: *const Regex, allocator: std.mem.Allocator, text: []const u8, replacement: []const u8) ![]u8 {
        const matches = try self.findAll(allocator, text);
        defer allocator.free(matches);

        if (matches.len == 0) {
            return try allocator.dupe(u8, text);
        }

        var result = std.ArrayList(u8).initCapacity(allocator, text.len) catch std.ArrayList(u8).empty;
        errdefer result.deinit(allocator);

        var last_end: usize = 0;
        for (matches) |match| {
            try result.appendSlice(allocator, text[last_end..match.start]);
            try result.appendSlice(allocator, replacement);
            last_end = match.end;
        }
        try result.appendSlice(allocator, text[last_end..]);

        return result.toOwnedSlice(allocator);
    }
};

pub const Match = struct {
    start: usize,
    end: usize,
};

pub const Flags = struct {
    case_insensitive: bool = false,
    multiline: bool = false,
    dotall: bool = false,

    pub fn toInt(self: Flags) c_int {
        var flags: c_int = 0;
        if (self.case_insensitive) flags |= c.REG_ICASE;
        if (self.multiline) flags |= c.REG_NEWLINE;
        if (self.dotall) flags |= c.REG_DOTALL;
        return flags;
    }
};

// Tests
test "regex basic match" {
    const allocator = std.testing.allocator;

    var regex = try Regex.compile(allocator, "hello", .{});
    defer regex.deinit();

    try std.testing.expect(regex.isMatch("hello world"));
    try std.testing.expect(!regex.isMatch("goodbye world"));
}

test "regex case insensitive" {
    const allocator = std.testing.allocator;

    var regex = try Regex.compile(allocator, "hello", .{ .case_insensitive = true });
    defer regex.deinit();

    try std.testing.expect(regex.isMatch("HELLO"));
    try std.testing.expect(regex.isMatch("Hello"));
}

test "regex anchor" {
    const allocator = std.testing.allocator;

    var regex = try Regex.compile(allocator, "^#?PermitRootLogin", .{});
    defer regex.deinit();

    try std.testing.expect(regex.isMatch("#PermitRootLogin yes"));
    try std.testing.expect(regex.isMatch("PermitRootLogin no"));
    try std.testing.expect(!regex.isMatch("  PermitRootLogin"));
}

test "regex replace" {
    const allocator = std.testing.allocator;

    var regex = try Regex.compile(allocator, "foo", .{});
    defer regex.deinit();

    const result = try regex.replaceAll(allocator, "foo bar foo", "baz");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("baz bar baz", result);
}
