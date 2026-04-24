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

    /// Maximum total timeout in seconds for the entire request
    /// Set to 0 to disable total timeout (default, relies on low_speed_limit protection)
    /// Primary timeout mechanism is low_speed_limit + low_speed_time
    /// Only set this if you need a hard deadline regardless of download speed
    max_timeout_s: u32 = 0,

    /// Low speed limit in bytes/second (abort if speed drops below this)
    /// Set to 0 to disable low speed detection
    /// Default: 10KB/s - protects against stalled connections while allowing slow networks
    low_speed_limit: u32 = 10240,

    /// Low speed time in seconds (abort if speed stays below limit for this long)
    /// Must maintain at least low_speed_limit bytes/sec for this duration
    /// Default: 30s - detects stalled connections while allowing brief slowdowns
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

    /// Client certificate for mTLS (PEM file path)
    client_cert: ?[]const u8 = null,

    /// Client private key for mTLS (PEM file path)
    client_key: ?[]const u8 = null,

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

/// Pre-flight check that mTLS client cert / key files are readable. libcurl's
/// diagnostic for an unreadable key is the generic "unable to set private key
/// file: ... type PEM" — it does not surface the underlying errno. Opening
/// the files ourselves first lets us report the specific OS reason
/// (FileNotFound / AccessDenied) before handing the path to libcurl.
pub fn validateClientAuthFiles(cert: ?[]const u8, key: ?[]const u8) error{InvalidClientAuth}!void {
    if (cert) |path| try ensureReadable(path, "client certificate");
    if (key) |path| try ensureReadable(path, "client private key");
}

fn ensureReadable(path: []const u8, label: []const u8) error{InvalidClientAuth}!void {
    var file = std.fs.cwd().openFile(path, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => std.debug.print("Error: {s} file not found: {s}\n", .{ label, path }),
            error.AccessDenied => std.debug.print("Error: {s} file is not readable (permission denied): {s}\n", .{ label, path }),
            else => std.debug.print("Error: cannot open {s} file '{s}': {}\n", .{ label, path, err }),
        }
        return error.InvalidClientAuth;
    };
    file.close();
}

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
