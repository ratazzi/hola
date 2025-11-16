const std = @import("std");

/// Simple glob pattern matching
/// Supports:
///   - * matches any sequence of characters (except /)
///   - ** matches any sequence of characters (including /)
///   - ? matches any single character (except /)
///   - [abc] matches any character in the set
///   - [!abc] matches any character not in the set
pub fn match(pattern: []const u8, text: []const u8) bool {
    return matchRecursive(pattern, text);
}

fn matchRecursive(pattern: []const u8, text: []const u8) bool {
    var pattern_idx: usize = 0;
    var text_idx: usize = 0;

    while (pattern_idx < pattern.len or text_idx < text.len) {
        if (pattern_idx >= pattern.len) {
            return text_idx >= text.len;
        }

        const pattern_char = pattern[pattern_idx];

        // Handle ** (matches any sequence including /)
        if (pattern_idx + 1 < pattern.len and pattern[pattern_idx] == '*' and pattern[pattern_idx + 1] == '*') {
            pattern_idx += 2;

            // ** at the end matches everything
            if (pattern_idx >= pattern.len) {
                return true;
            }

            // Try matching the rest of the pattern at each position
            while (text_idx <= text.len) {
                if (matchRecursive(pattern[pattern_idx..], text[text_idx..])) {
                    return true;
                }
                text_idx += 1;
            }
            return false;
        }

        // Handle * (matches any sequence except /)
        if (pattern_char == '*') {
            pattern_idx += 1;

            // * at the end matches everything except /
            if (pattern_idx >= pattern.len) {
                return std.mem.indexOfScalar(u8, text[text_idx..], '/') == null;
            }

            // Try matching the rest of the pattern at each position
            while (text_idx < text.len) {
                if (text[text_idx] == '/') break;
                if (matchRecursive(pattern[pattern_idx..], text[text_idx..])) {
                    return true;
                }
                text_idx += 1;
            }
            return false;
        }

        // Handle ? (matches any single character except /)
        if (pattern_char == '?') {
            pattern_idx += 1;
            if (text_idx >= text.len or text[text_idx] == '/') {
                return false;
            }
            text_idx += 1;
            continue;
        }

        // Handle character class [abc] or [!abc]
        if (pattern_char == '[') {
            const class_end = std.mem.indexOfScalar(u8, pattern[pattern_idx + 1..], ']') orelse {
                // Invalid pattern, treat as literal [
                if (text_idx >= text.len or text[text_idx] != '[') {
                    return false;
                }
                pattern_idx += 1;
                text_idx += 1;
                continue;
            };

            const class_start = pattern_idx + 1;
            const class_end_abs = pattern_idx + 1 + class_end;
            const negated = pattern_idx + 1 < pattern.len and pattern[pattern_idx + 1] == '!';
            const class_pattern = pattern[class_start + @intFromBool(negated)..class_end_abs];

            if (text_idx >= text.len) {
                return false;
            }

            const text_char = text[text_idx];
            var matched = false;

            var i: usize = 0;
            while (i < class_pattern.len) {
                if (i + 2 < class_pattern.len and class_pattern[i + 1] == '-') {
                    // Range: [a-z]
                    const start = class_pattern[i];
                    const end = class_pattern[i + 2];
                    if (text_char >= start and text_char <= end) {
                        matched = true;
                        break;
                    }
                    i += 3;
                } else {
                    // Single character
                    if (text_char == class_pattern[i]) {
                        matched = true;
                        break;
                    }
                    i += 1;
                }
            }

            if (matched == negated) {
                return false;
            }

            pattern_idx = class_end_abs + 1;
            text_idx += 1;
            continue;
        }

        // Literal character match
        if (text_idx >= text.len or text[text_idx] != pattern_char) {
            return false;
        }

        pattern_idx += 1;
        text_idx += 1;
    }

    return pattern_idx >= pattern.len and text_idx >= text.len;
}

test "glob matching" {
    try std.testing.expect(match("*.txt", "file.txt"));
    try std.testing.expect(match("*.txt", "test.txt"));
    try std.testing.expect(!match("*.txt", "file.log"));
    try std.testing.expect(!match("*.txt", "dir/file.txt"));

    try std.testing.expect(match("**/*.txt", "dir/file.txt"));
    try std.testing.expect(match("**/*.txt", "a/b/c/file.txt"));
    try std.testing.expect(match("**", "any/path/here"));

    try std.testing.expect(match("file?.txt", "file1.txt"));
    try std.testing.expect(match("file?.txt", "fileA.txt"));
    try std.testing.expect(!match("file?.txt", "file.txt"));

    try std.testing.expect(match("[abc].txt", "a.txt"));
    try std.testing.expect(match("[abc].txt", "b.txt"));
    try std.testing.expect(!match("[abc].txt", "d.txt"));

    try std.testing.expect(match("[!abc].txt", "d.txt"));
    try std.testing.expect(!match("[!abc].txt", "a.txt"));

    try std.testing.expect(match("[a-z].txt", "m.txt"));
    try std.testing.expect(!match("[a-z].txt", "0.txt"));

    try std.testing.expect(match(".git*", ".git"));
    try std.testing.expect(match(".git*", ".gitignore"));
    try std.testing.expect(match(".git*", ".github"));
}

