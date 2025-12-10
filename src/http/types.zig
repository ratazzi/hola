const std = @import("std");

/// Supported protocols (detected from URL scheme)
pub const Protocol = enum {
    HTTP,
    HTTPS,
    SFTP,
    SCP,
    S3,

    /// Detect protocol from URL
    pub fn fromUrl(url: []const u8) Protocol {
        if (std.mem.startsWith(u8, url, "https://")) return .HTTPS;
        if (std.mem.startsWith(u8, url, "http://")) return .HTTP;
        if (std.mem.startsWith(u8, url, "sftp://")) return .SFTP;
        if (std.mem.startsWith(u8, url, "scp://")) return .SCP;
        if (std.mem.startsWith(u8, url, "s3://")) return .S3;
        // Default to HTTPS if no scheme
        return .HTTPS;
    }
};

/// Authentication configuration for different protocols
pub const AuthConfig = struct {
    /// SSH private key path for SFTP
    ssh_private_key: ?[]const u8 = null,
    /// SSH public key path for SFTP
    ssh_public_key: ?[]const u8 = null,
    /// SSH known hosts file path
    ssh_known_hosts: ?[]const u8 = null,
    /// Username for SFTP
    username: ?[]const u8 = null,
    /// Password for SFTP
    password: ?[]const u8 = null,

    /// AWS Access Key ID for S3
    aws_access_key_id: ?[]const u8 = null,
    /// AWS Secret Access Key for S3
    aws_secret_access_key: ?[]const u8 = null,
    /// AWS region for S3 (default: "auto")
    aws_region: []const u8 = "auto",
    /// AWS S3 endpoint URL (e.g., "https://s3.us-west-2.amazonaws.com" or custom endpoint for S3-compatible services)
    aws_endpoint: ?[]const u8 = null,
};

/// HTTP methods
pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
    HEAD,
    OPTIONS,

    pub fn toString(self: Method) []const u8 {
        return switch (self) {
            .GET => "GET",
            .POST => "POST",
            .PUT => "PUT",
            .DELETE => "DELETE",
            .PATCH => "PATCH",
            .HEAD => "HEAD",
            .OPTIONS => "OPTIONS",
        };
    }
};

/// HTTP Request
pub const Request = struct {
    method: Method,
    url: []const u8,
    headers: ?std.StringHashMap([]const u8) = null,
    headers_owned: bool = false,
    body: ?[]const u8 = null,
    timeout_ms: ?u32 = null,
    follow_redirects: bool = true,
    max_redirects: u32 = 10,
    auth: ?AuthConfig = null,

    pub fn init(method: Method, url: []const u8) Request {
        return .{
            .method = method,
            .url = url,
        };
    }

    pub fn deinit(self: *Request) void {
        if (self.headers_owned) {
            if (self.headers) |*headers| {
                var it = headers.iterator();
                while (it.next()) |entry| {
                    headers.allocator.free(entry.key_ptr.*);
                    headers.allocator.free(entry.value_ptr.*);
                }
                headers.deinit();
                self.headers = null;
            }
        }
    }

    /// Build request with anonymous struct options
    pub fn build(allocator: std.mem.Allocator, method: Method, url: []const u8, opts: anytype) !Request {
        var req = Request{
            .method = method,
            .url = url,
        };

        const T = @TypeOf(opts);
        if (T == @TypeOf(null)) return req;

        const info = @typeInfo(T);
        if (info != .Struct) return req;

        // Handle body
        if (@hasField(T, "body")) {
            req.body = opts.body;
        }

        // Handle headers as anonymous struct
        if (@hasField(T, "headers")) {
            const headers_info = @typeInfo(@TypeOf(opts.headers));
            if (headers_info == .Struct) {
                req.headers = std.StringHashMap([]const u8).init(allocator);
                req.headers_owned = true;
                inline for (headers_info.Struct.fields) |field| {
                    try req.headers.?.put(try allocator.dupe(u8, field.name), try allocator.dupe(u8, @field(opts.headers, field.name)));
                }
            }
        }

        // Handle other options
        if (@hasField(T, "timeout_ms")) req.timeout_ms = opts.timeout_ms;
        if (@hasField(T, "follow_redirects")) req.follow_redirects = opts.follow_redirects;
        if (@hasField(T, "max_redirects")) req.max_redirects = opts.max_redirects;

        return req;
    }
};

/// HTTP Response
pub const Response = struct {
    status: u16,
    headers: std.StringHashMap([]const u8),
    body: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Response) void {
        var it = self.headers.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.headers.deinit();
        self.allocator.free(self.body);
    }

    pub fn getHeader(self: *const Response, name: []const u8) ?[]const u8 {
        return self.headers.get(name);
    }
};

/// HTTP errors
pub const Error = error{
    // Network errors
    ConnectionFailed,
    Timeout,
    DNSResolutionFailed,
    TLSError,

    // Protocol errors
    InvalidUrl,
    InvalidResponse,
    TooManyRedirects,

    // HTTP errors
    BadRequest,
    Unauthorized,
    Forbidden,
    NotFound,
    ServerError,

    // Other
    OutOfMemory,
    Unknown,
};

/// Stream callback for downloading large files
/// Returns number of bytes processed, or error to abort
pub const StreamCallback = *const fn (data: []const u8, context: *anyopaque) anyerror!usize;

/// Progress callback for tracking download/upload progress
pub const ProgressCallback = *const fn (
    downloaded: usize,
    total: usize,
    context: *anyopaque,
) void;

// Tests
const testing = std.testing;

test "Response lifecycle and memory management" {
    const allocator = testing.allocator;

    // Create response with headers
    var headers = std.StringHashMap([]const u8).init(allocator);
    try headers.put(try allocator.dupe(u8, "Content-Type"), try allocator.dupe(u8, "text/plain"));
    try headers.put(try allocator.dupe(u8, "Content-Length"), try allocator.dupe(u8, "13"));

    var resp = Response{
        .status = 200,
        .headers = headers,
        .body = try allocator.dupe(u8, "Hello, World!"),
        .allocator = allocator,
    };

    // Test getHeader
    try testing.expectEqualStrings("text/plain", resp.getHeader("Content-Type").?);
    try testing.expect(resp.getHeader("X-Missing") == null);

    // Clean up - verify no memory leaks
    resp.deinit();
}
