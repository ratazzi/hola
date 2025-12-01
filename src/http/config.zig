const std = @import("std");
const builtin = @import("builtin");
const build_options = if (@hasDecl(@import("root"), "build_options")) @import("build_options") else struct {
    pub const version = "0.1.0";
    pub const is_nightly = false;
};

/// HTTP Client Configuration
pub const Config = struct {
    /// Connection timeout in milliseconds (for initial connection only)
    timeout_ms: u32 = 30000,

    /// Maximum total timeout in seconds for the entire request (fallback protection)
    /// Primary timeout mechanism is low_speed_limit + low_speed_time
    /// This guards against edge cases where server accepts connection but never responds
    /// Set to 0 to disable (not recommended - may cause indefinite hangs)
    max_timeout_s: u32 = 600,

    /// Low speed limit in bytes/second (abort if speed drops below this)
    /// Set to 0 to disable low speed detection
    low_speed_limit: u32 = 1024,

    /// Low speed time in seconds (abort if speed stays below limit for this long)
    low_speed_time: u32 = 30,

    /// Follow HTTP redirects
    follow_redirects: bool = true,

    /// Maximum number of redirects to follow
    max_redirects: u32 = 10,

    /// User-Agent string (null for auto-generate)
    user_agent: ?[]const u8 = null,

    /// Verify SSL certificates
    verify_ssl: bool = true,

    /// HTTP proxy URL (e.g., "http://proxy.example.com:8080")
    proxy: ?[]const u8 = null,

    /// Retry configuration
    retry: RetryConfig = .{},

    pub const RetryConfig = struct {
        /// Maximum number of attempts (including initial request)
        /// Must be >= 1. Value of 1 = no retry, 3 = initial + 2 retries
        max_attempts: u32 = 3,

        /// Initial backoff delay in milliseconds
        initial_backoff_ms: u32 = 1000,

        /// Backoff multiplier for exponential backoff
        backoff_multiplier: f32 = 2.0,

        /// Maximum backoff delay in milliseconds
        max_backoff_ms: u32 = 30000,

        /// Whether to retry on network errors
        retry_on_network_error: bool = true,

        /// Whether to retry on 5xx server errors
        retry_on_server_error: bool = true,
    };
};

/// Version string for User-Agent from build.zig.zon
const VERSION = if (@hasDecl(build_options, "version")) build_options.version else "0.1.0";
const IS_NIGHTLY = if (@hasDecl(build_options, "is_nightly")) build_options.is_nightly else false;

/// Generate default User-Agent string: Hola/version (platform; arch; zig version)
pub fn getUserAgent(allocator: std.mem.Allocator) ![]const u8 {
    const platform = switch (builtin.os.tag) {
        .macos => "macOS",
        .linux => "Linux",
        .windows => "Windows",
        else => "Unknown",
    };

    const arch = switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "x86_64",
        else => "unknown",
    };

    const zig_version = builtin.zig_version_string;
    const nightly_suffix = if (IS_NIGHTLY) "-nightly" else "";

    return std.fmt.allocPrint(allocator, "Hola/{s}{s} ({s}; {s}; Zig {s})", .{
        VERSION,
        nightly_suffix,
        platform,
        arch,
        zig_version,
    });
}

// Tests
const testing = @import("std").testing;

test "getUserAgent format and memory management" {
    const allocator = testing.allocator;
    const user_agent = try getUserAgent(allocator);
    defer allocator.free(user_agent);

    // Verify format: Hola/version (platform; arch; Zig version)
    try testing.expect(std.mem.startsWith(u8, user_agent, "Hola/"));
    try testing.expect(std.mem.indexOf(u8, user_agent, "(") != null);
    try testing.expect(std.mem.indexOf(u8, user_agent, ")") != null);
    try testing.expect(std.mem.indexOf(u8, user_agent, "Zig") != null);

    // Verify nightly suffix handling
    const has_nightly = std.mem.indexOf(u8, user_agent, "-nightly") != null;
    try testing.expectEqual(IS_NIGHTLY, has_nightly);
}
