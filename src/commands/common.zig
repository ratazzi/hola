const std = @import("std");
const http = @import("../http.zig");
const global_io = @import("../global_io.zig");
const logger = @import("../logger.zig");
const modern_display = @import("../modern_provision_display.zig");

pub const TlsClientAuth = struct {
    cert: ?[]const u8 = null,
    key: ?[]const u8 = null,
};

pub const PROVISION_FETCH_TIMEOUT_S: u32 = 300;

pub const BagArgs = struct {
    data_bag: ?[]const u8 = null,
    data_bag_url: ?[]const u8 = null,
    secrets_bag: ?[]const u8 = null,
    secrets_bag_url: ?[]const u8 = null,
    client_cert: ?[]const u8 = null,
    client_key: ?[]const u8 = null,
};

pub const ResolvedBags = struct {
    allocator: std.mem.Allocator,
    data_bag: ?[]const u8,
    secrets_bag: ?[]const u8,
    tls_auth: TlsClientAuth,
    owned_data_bag: ?[]const u8 = null,
    owned_secrets_bag: ?[]const u8 = null,

    pub fn deinit(self: *ResolvedBags) void {
        if (self.owned_data_bag) |value| self.allocator.free(value);
        if (self.owned_secrets_bag) |value| self.allocator.free(value);
        self.* = undefined;
    }
};

pub fn parseOutputMode(output_mode: ?[]const u8) !modern_display.OutputMode {
    if (output_mode) |mode| {
        if (std.mem.eql(u8, mode, "normal") or std.mem.eql(u8, mode, "plain")) return .normal;
        if (std.mem.eql(u8, mode, "compact") or std.mem.eql(u8, mode, "pretty")) return .compact;
        std.debug.print("Invalid output mode: {s}\nValid modes: normal, compact\n", .{mode});
        return error.InvalidOutputMode;
    }
    return .normal;
}

/// Fetch JSON content from a URL, using optional mTLS credentials.
/// Returns an owned response body.
pub fn fetchJsonFromUrl(allocator: std.mem.Allocator, url: []const u8, tls_auth: TlsClientAuth) ![]const u8 {
    _ = std.Uri.parse(url) catch |err| {
        std.debug.print("Error: Invalid URL: {}\n", .{err});
        return error.FetchFailed;
    };

    var url_buf: [512]u8 = undefined;
    const display_url = http.maskUrlPassword(url, &url_buf);
    std.debug.print("[fetch] Fetching JSON from {s}\n", .{display_url});

    const config = http.Config{
        .max_timeout_s = PROVISION_FETCH_TIMEOUT_S,
        .client_cert = tls_auth.cert,
        .client_key = tls_auth.key,
    };
    var client = http.Client.init(allocator, config) catch |err| {
        std.debug.print("\nError: Failed to initialize HTTP client: {}\n", .{err});
        return error.FetchFailed;
    };
    defer client.deinit();

    const response = client.get(url, null) catch |err| {
        std.debug.print("\nError: Failed to fetch JSON from URL: {}\n", .{err});
        if (http.getLastError()) |detail| {
            var detail_buf: [1024]u8 = undefined;
            std.debug.print("  {s}\n", .{http.redactPassword(url, detail, &detail_buf)});
        }
        std.debug.print("URL: {s}\n", .{display_url});
        return error.FetchFailed;
    };
    defer {
        var mutable_response = response;
        mutable_response.deinit();
    }

    if (response.status < 200 or response.status >= 300) {
        std.debug.print("\nError: HTTP {d} when fetching JSON from {s}\n", .{ response.status, display_url });
        return error.FetchFailed;
    }
    return allocator.dupe(u8, response.body) catch return error.FetchFailed;
}

pub fn resolveBags(allocator: std.mem.Allocator, args: BagArgs) !ResolvedBags {
    if (args.data_bag != null and args.data_bag_url != null) {
        std.debug.print("Error: --data-bag and --data-bag-url are mutually exclusive\n", .{});
        return error.InvalidArguments;
    }
    if (args.secrets_bag != null and args.secrets_bag_url != null) {
        std.debug.print("Error: --secrets-bag and --secrets-bag-url are mutually exclusive\n", .{});
        return error.InvalidArguments;
    }

    const tls_auth = TlsClientAuth{ .cert = args.client_cert, .key = args.client_key };
    try http.validateClientAuthFiles(tls_auth.cert, tls_auth.key);

    var owned_data_bag: ?[]const u8 = null;
    errdefer if (owned_data_bag) |value| allocator.free(value);
    if (args.data_bag_url) |url| {
        owned_data_bag = fetchJsonFromUrl(allocator, url, tls_auth) catch |err| {
            std.debug.print("Failed to fetch data_bag from URL\n", .{});
            if (logger.getLogPath()) |log_path| std.debug.print("Log file: {s}\n", .{log_path});
            return err;
        };
    }

    var owned_secrets_bag: ?[]const u8 = null;
    errdefer if (owned_secrets_bag) |value| allocator.free(value);
    if (args.secrets_bag_url) |url| {
        owned_secrets_bag = fetchJsonFromUrl(allocator, url, tls_auth) catch |err| {
            std.debug.print("Failed to fetch secrets_bag from URL\n", .{});
            if (logger.getLogPath()) |log_path| std.debug.print("Log file: {s}\n", .{log_path});
            return err;
        };
    }

    return .{
        .allocator = allocator,
        .data_bag = owned_data_bag orelse args.data_bag,
        .secrets_bag = owned_secrets_bag orelse args.secrets_bag,
        .tls_auth = tls_auth,
        .owned_data_bag = owned_data_bag,
        .owned_secrets_bag = owned_secrets_bag,
    };
}

test "output mode defaults to normal and keeps legacy aliases" {
    try std.testing.expectEqual(modern_display.OutputMode.normal, try parseOutputMode(null));
    try std.testing.expectEqual(modern_display.OutputMode.normal, try parseOutputMode("normal"));
    try std.testing.expectEqual(modern_display.OutputMode.normal, try parseOutputMode("plain"));
    try std.testing.expectEqual(modern_display.OutputMode.compact, try parseOutputMode("compact"));
    try std.testing.expectEqual(modern_display.OutputMode.compact, try parseOutputMode("pretty"));
    try std.testing.expectError(error.InvalidOutputMode, parseOutputMode("verbose"));
}
