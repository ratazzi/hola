const std = @import("std");
const curl = @import("../curl.zig");
const types = @import("types.zig");
const config_mod = @import("config.zig");
const logger = @import("../logger.zig");

const Request = types.Request;
const Response = types.Response;
const Method = types.Method;
const Config = config_mod.Config;

/// HTTP Client based on libcurl
pub const Client = struct {
    allocator: std.mem.Allocator,
    config: Config,
    user_agent: []const u8,

    pub fn init(allocator: std.mem.Allocator, cfg: Config) !Client {
        const user_agent = cfg.user_agent orelse try config_mod.getUserAgent(allocator);
        return .{
            .allocator = allocator,
            .config = cfg,
            .user_agent = user_agent,
        };
    }

    pub fn deinit(self: *Client) void {
        if (self.config.user_agent == null) {
            self.allocator.free(self.user_agent);
        }
    }

    /// Perform HTTP request
    pub fn request(self: *Client, req: Request) !Response {
        var attempt: u32 = 0;
        const max_attempts = @max(1, self.config.retry.max_attempts); // Ensure at least 1 attempt

        while (attempt < max_attempts) : (attempt += 1) {
            const result = self.executeRequest(req) catch |err| {
                if (attempt + 1 >= max_attempts) {
                    return err;
                }

                // Check if we should retry
                const should_retry = switch (err) {
                    error.ConnectionFailed, error.Timeout, error.DNSResolutionFailed => self.config.retry.retry_on_network_error,
                    error.ServerError => self.config.retry.retry_on_server_error,
                    else => false,
                };

                if (!should_retry) {
                    return err;
                }

                // Calculate backoff delay
                const backoff_ms = self.calculateBackoff(attempt);
                logger.debug("Request failed (attempt {d}/{d}), retrying in {d}ms: {}", .{ attempt + 1, max_attempts, backoff_ms, err });
                std.Thread.sleep(backoff_ms * std.time.ns_per_ms);
                continue;
            };

            if (result.status >= 500 and self.config.retry.retry_on_server_error and attempt + 1 < max_attempts) {
                const backoff_ms = self.calculateBackoff(attempt);
                logger.debug("Server error {d} (attempt {d}/{d}), retrying in {d}ms", .{ result.status, attempt + 1, max_attempts, backoff_ms });
                var owned = result;
                owned.deinit();
                std.Thread.sleep(backoff_ms * std.time.ns_per_ms);
                continue;
            }

            return result;
        }

        return error.Unknown;
    }

    /// Setup common curl handle options (URL, method, headers, timeout, SSL, etc.)
    /// Returns header_list that must be freed by caller with curl_slist_free_all
    fn setupCurlHandle(
        self: *Client,
        handle: *curl.CURL,
        req: Request,
    ) !?*curl.curl_slist {
        // URL transformation for S3 protocol
        // Convert s3://bucket/path to https://endpoint/bucket/path
        const protocol = types.Protocol.fromUrl(req.url);
        const actual_url = if (protocol == .S3 and req.auth != null and req.auth.?.aws_endpoint != null) blk: {
            // Extract bucket and path from s3://bucket/path
            const s3_prefix = "s3://";
            if (std.mem.startsWith(u8, req.url, s3_prefix)) {
                const path = req.url[s3_prefix.len..];
                const endpoint = req.auth.?.aws_endpoint.?;
                // Build full URL: endpoint/bucket/path
                break :blk try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ endpoint, path });
            }
            break :blk try self.allocator.dupe(u8, req.url);
        } else blk: {
            break :blk try self.allocator.dupe(u8, req.url);
        };
        defer self.allocator.free(actual_url);

        // URL (must be null-terminated)
        const url_z = try self.allocator.dupeZ(u8, actual_url);
        defer self.allocator.free(url_z);
        _ = curl.curl_easy_setopt(handle, .CURLOPT_URL, url_z.ptr);

        // Method
        switch (req.method) {
            .GET => {},
            .POST => _ = curl.curl_easy_setopt(handle, .CURLOPT_POST, @as(c_long, 1)),
            .HEAD => {
                // Use CURLOPT_NOBODY to ensure no body is downloaded (proper HEAD semantics)
                _ = curl.curl_easy_setopt(handle, .CURLOPT_NOBODY, @as(c_long, 1));
            },
            .PUT, .DELETE, .PATCH, .OPTIONS => {
                const method_str = req.method.toString();
                const method_z = try self.allocator.dupeZ(u8, method_str);
                defer self.allocator.free(method_z);
                _ = curl.curl_easy_setopt(handle, .CURLOPT_CUSTOMREQUEST, method_z.ptr);
            },
        }

        // Body
        if (req.body) |body| {
            _ = curl.curl_easy_setopt(handle, .CURLOPT_POSTFIELDS, body.ptr);
            _ = curl.curl_easy_setopt(handle, .CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(body.len)));
        }

        // Headers
        var header_list: ?*curl.curl_slist = null;
        if (req.headers) |headers| {
            var it = headers.iterator();
            while (it.next()) |entry| {
                const header_str = try std.fmt.allocPrint(self.allocator, "{s}: {s}\x00", .{ entry.key_ptr.*, entry.value_ptr.* });
                defer self.allocator.free(header_str);
                const header_z: [*:0]const u8 = @ptrCast(header_str.ptr);
                header_list = curl.curl_slist_append(header_list, header_z);
            }
        }

        if (header_list) |list| {
            _ = curl.curl_easy_setopt(handle, .CURLOPT_HTTPHEADER, list);
        }

        // User-Agent
        const ua_z = try self.allocator.dupeZ(u8, self.user_agent);
        defer self.allocator.free(ua_z);
        _ = curl.curl_easy_setopt(handle, .CURLOPT_USERAGENT, ua_z.ptr);

        // Timeout
        const timeout = req.timeout_ms orelse self.config.timeout_ms;
        const timeout_s: c_long = if (timeout == 0) 0 else @intCast((timeout + 999) / 1000);

        // Use connection timeout for initial connection
        _ = curl.curl_easy_setopt(handle, .CURLOPT_CONNECTTIMEOUT, timeout_s);

        // Maximum total timeout (fallback protection against completely hung connections)
        _ = curl.curl_easy_setopt(handle, .CURLOPT_TIMEOUT, @as(c_long, @intCast(self.config.max_timeout_s)));

        // Low speed limit: abort if speed drops below threshold for specified time
        if (self.config.low_speed_limit > 0) {
            _ = curl.curl_easy_setopt(handle, .CURLOPT_LOW_SPEED_LIMIT, @as(c_long, @intCast(self.config.low_speed_limit)));
            _ = curl.curl_easy_setopt(handle, .CURLOPT_LOW_SPEED_TIME, @as(c_long, @intCast(self.config.low_speed_time)));
        }

        // Redirects
        const follow = if (req.follow_redirects) @as(c_long, 1) else @as(c_long, 0);
        _ = curl.curl_easy_setopt(handle, .CURLOPT_FOLLOWLOCATION, follow);
        _ = curl.curl_easy_setopt(handle, .CURLOPT_MAXREDIRS, @as(c_long, @intCast(req.max_redirects)));

        // SSL verification
        // CURLOPT_SSL_VERIFYPEER: 1 = verify certificate, 0 = don't verify
        // CURLOPT_SSL_VERIFYHOST: 2 = strict hostname check, 0 = no check
        // Note: VERIFYHOST must be 2 (not 1) for proper hostname verification
        const verify_peer = if (self.config.verify_ssl) @as(c_long, 1) else @as(c_long, 0);
        const verify_host = if (self.config.verify_ssl) @as(c_long, 2) else @as(c_long, 0);
        _ = curl.curl_easy_setopt(handle, .CURLOPT_SSL_VERIFYPEER, verify_peer);
        _ = curl.curl_easy_setopt(handle, .CURLOPT_SSL_VERIFYHOST, verify_host);

        // Protocol-specific configuration (reuse protocol variable from URL transformation above)
        switch (protocol) {
            .SFTP, .SCP => {
                // Both SFTP and SCP use SSH authentication (same configuration)
                if (req.auth) |auth| {
                    // Username/password for SFTP/SCP
                    if (auth.username) |username| {
                        const userpwd_str = if (auth.password) |password|
                            try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ username, password })
                        else
                            try std.fmt.allocPrint(self.allocator, "{s}:", .{username});
                        defer self.allocator.free(userpwd_str);
                        const userpwd_z = try self.allocator.dupeZ(u8, userpwd_str);
                        defer self.allocator.free(userpwd_z);
                        _ = curl.curl_easy_setopt(handle, .CURLOPT_USERPWD, userpwd_z.ptr);
                    }

                    // SSH private key
                    if (auth.ssh_private_key) |key_path| {
                        const key_z = try self.allocator.dupeZ(u8, key_path);
                        defer self.allocator.free(key_z);
                        _ = curl.curl_easy_setopt(handle, .CURLOPT_SSH_PRIVATE_KEYFILE, key_z.ptr);
                    }

                    // SSH public key
                    if (auth.ssh_public_key) |key_path| {
                        const key_z = try self.allocator.dupeZ(u8, key_path);
                        defer self.allocator.free(key_z);
                        _ = curl.curl_easy_setopt(handle, .CURLOPT_SSH_PUBLIC_KEYFILE, key_z.ptr);
                    }

                    // SSH known hosts
                    if (auth.ssh_known_hosts) |hosts_path| {
                        const hosts_z = try self.allocator.dupeZ(u8, hosts_path);
                        defer self.allocator.free(hosts_z);
                        _ = curl.curl_easy_setopt(handle, .CURLOPT_SSH_KNOWNHOSTS, hosts_z.ptr);
                    }
                }
            },
            .S3 => {
                if (req.auth) |auth| {
                    // AWS credentials for S3
                    if (auth.aws_access_key_id) |access_key| {
                        if (auth.aws_secret_access_key) |secret_key| {
                            const userpwd_str = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ access_key, secret_key });
                            defer self.allocator.free(userpwd_str);
                            const userpwd_z = try self.allocator.dupeZ(u8, userpwd_str);
                            defer self.allocator.free(userpwd_z);
                            _ = curl.curl_easy_setopt(handle, .CURLOPT_USERPWD, userpwd_z.ptr);

                            // Enable AWS SigV4 signing
                            const aws_sig_str = try std.fmt.allocPrint(self.allocator, "aws:amz:{s}:s3", .{auth.aws_region});
                            defer self.allocator.free(aws_sig_str);
                            const aws_sig_z = try self.allocator.dupeZ(u8, aws_sig_str);
                            defer self.allocator.free(aws_sig_z);
                            _ = curl.curl_easy_setopt(handle, .CURLOPT_AWS_SIGV4, aws_sig_z.ptr);
                        }
                    }
                }
            },
            .HTTP, .HTTPS => {
                // HTTP/HTTPS use default settings (already configured above)
            },
        }

        // Proxy
        if (self.config.proxy) |proxy| {
            const proxy_z = try self.allocator.dupeZ(u8, proxy);
            defer self.allocator.free(proxy_z);
            _ = curl.curl_easy_setopt(handle, .CURLOPT_PROXY, proxy_z.ptr);
        }

        return header_list;
    }

    /// Execute single HTTP request without retry
    fn executeRequest(self: *Client, req: Request) !Response {
        const handle = curl.curl_easy_init() orelse return error.ConnectionFailed;
        defer curl.curl_easy_cleanup(handle);

        // Setup common curl options
        const header_list = try self.setupCurlHandle(handle, req);
        defer if (header_list) |list| curl.curl_slist_free_all(list);

        // Response body
        var body_ctx = BodyContext{
            .allocator = self.allocator,
            .data = std.ArrayList(u8).empty,
        };
        defer body_ctx.data.deinit(self.allocator);

        _ = curl.curl_easy_setopt(handle, .CURLOPT_WRITEFUNCTION, @as(*const fn ([*]const u8, usize, usize, *anyopaque) callconv(.c) usize, @ptrCast(&bodyWriteCallback)));
        _ = curl.curl_easy_setopt(handle, .CURLOPT_WRITEDATA, @as(*anyopaque, @ptrCast(&body_ctx)));

        // Response headers
        var header_ctx = HeaderContext{
            .allocator = self.allocator,
            .headers = std.StringHashMap([]const u8).init(self.allocator),
        };
        // We'll transfer ownership to Response on success, but need to clean up on error
        errdefer {
            var it = header_ctx.headers.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            header_ctx.headers.deinit();
        }

        _ = curl.curl_easy_setopt(handle, .CURLOPT_HEADERFUNCTION, @as(*const fn ([*]const u8, usize, usize, *anyopaque) callconv(.c) usize, @ptrCast(&headerCallback)));
        _ = curl.curl_easy_setopt(handle, .CURLOPT_HEADERDATA, @as(*anyopaque, @ptrCast(&header_ctx)));

        // Perform request
        const res = curl.curl_easy_perform(handle);
        if (res != .CURLE_OK) {
            return curlErrorToZig(res);
        }

        // Get status code
        var status: c_long = 0;
        _ = curl.curl_easy_getinfo(handle, .CURLINFO_RESPONSE_CODE, &status);

        // Transfer ownership
        const body_owned = try body_ctx.data.toOwnedSlice(self.allocator);

        // Transfer ownership of headers directly - they were already allocated with self.allocator
        const headers_owned = header_ctx.headers;

        return Response{
            .status = @intCast(status),
            .headers = headers_owned,
            .body = body_owned,
            .allocator = self.allocator,
        };
    }

    /// Stream response to callback (for large downloads)
    /// Returns response headers
    pub const StreamResult = struct {
        status: u16,
        headers: std.StringHashMap([]const u8),
    };

    pub fn stream(
        self: *Client,
        req: Request,
        callback: types.StreamCallback,
        context: *anyopaque,
        progress_callback: ?types.ProgressCallback,
        progress_context: ?*anyopaque,
    ) !StreamResult {
        const handle = curl.curl_easy_init() orelse return error.ConnectionFailed;
        defer curl.curl_easy_cleanup(handle);

        // Setup common curl options
        const header_list = try self.setupCurlHandle(handle, req);
        defer if (header_list) |list| curl.curl_slist_free_all(list);

        // Stream context
        var stream_ctx = StreamContext{
            .callback = callback,
            .user_context = context,
        };

        _ = curl.curl_easy_setopt(handle, .CURLOPT_WRITEFUNCTION, @as(*const fn ([*]const u8, usize, usize, *anyopaque) callconv(.c) usize, @ptrCast(&streamWriteCallback)));
        _ = curl.curl_easy_setopt(handle, .CURLOPT_WRITEDATA, @as(*anyopaque, @ptrCast(&stream_ctx)));

        // Progress callback (if provided)
        var progress_ctx: ProgressContext = undefined;
        if (progress_callback) |prog_cb| {
            if (progress_context) |prog_ctx| {
                progress_ctx = ProgressContext{
                    .callback = prog_cb,
                    .user_context = prog_ctx,
                };
                _ = curl.curl_easy_setopt(handle, .CURLOPT_NOPROGRESS, @as(c_long, 0));
                _ = curl.curl_easy_setopt(handle, .CURLOPT_XFERINFOFUNCTION, @as(*const fn (*anyopaque, curl.curl_off_t, curl.curl_off_t, curl.curl_off_t, curl.curl_off_t) callconv(.c) c_int, @ptrCast(&progressCallback)));
                _ = curl.curl_easy_setopt(handle, .CURLOPT_XFERINFODATA, @as(*anyopaque, @ptrCast(&progress_ctx)));
            }
        }

        // Response headers
        var header_ctx = HeaderContext{
            .allocator = self.allocator,
            .headers = std.StringHashMap([]const u8).init(self.allocator),
        };
        // We'll transfer ownership to StreamResult on success, but need to clean up on error
        errdefer {
            var it = header_ctx.headers.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            header_ctx.headers.deinit();
        }

        _ = curl.curl_easy_setopt(handle, .CURLOPT_HEADERFUNCTION, @as(*const fn ([*]const u8, usize, usize, *anyopaque) callconv(.c) usize, @ptrCast(&headerCallback)));
        _ = curl.curl_easy_setopt(handle, .CURLOPT_HEADERDATA, @as(*anyopaque, @ptrCast(&header_ctx)));

        // Perform
        const res = curl.curl_easy_perform(handle);
        if (res != .CURLE_OK) {
            return curlErrorToZig(res);
        }

        // Get status code
        var status: c_long = 0;
        _ = curl.curl_easy_getinfo(handle, .CURLINFO_RESPONSE_CODE, &status);

        // Return status and headers (caller owns them)
        return StreamResult{
            .status = @intCast(status),
            .headers = header_ctx.headers,
        };
    }

    /// Calculate exponential backoff delay
    fn calculateBackoff(self: *Client, attempt: u32) u32 {
        const retry_cfg = self.config.retry;

        // Always use exponential backoff
        const delay = @as(f32, @floatFromInt(retry_cfg.initial_backoff_ms)) *
            std.math.pow(f32, retry_cfg.backoff_multiplier, @as(f32, @floatFromInt(attempt)));

        return @min(@as(u32, @intFromFloat(delay)), retry_cfg.max_backoff_ms);
    }

    /// Simple request methods
    pub fn get(self: *Client, url: []const u8, opts: anytype) !Response {
        var req = try Request.build(self.allocator, .GET, url, opts);
        defer req.deinit();
        return self.request(req);
    }

    pub fn post(self: *Client, url: []const u8, opts: anytype) !Response {
        var req = try Request.build(self.allocator, .POST, url, opts);
        defer req.deinit();
        return self.request(req);
    }

    pub fn put(self: *Client, url: []const u8, opts: anytype) !Response {
        var req = try Request.build(self.allocator, .PUT, url, opts);
        defer req.deinit();
        return self.request(req);
    }

    pub fn delete(self: *Client, url: []const u8, opts: anytype) !Response {
        var req = try Request.build(self.allocator, .DELETE, url, opts);
        defer req.deinit();
        return self.request(req);
    }
};

// Callback contexts
const BodyContext = struct {
    allocator: std.mem.Allocator,
    data: std.ArrayList(u8),
};

const HeaderContext = struct {
    allocator: std.mem.Allocator,
    headers: std.StringHashMap([]const u8),
};

const StreamContext = struct {
    callback: types.StreamCallback,
    user_context: *anyopaque,
};

const ProgressContext = struct {
    callback: types.ProgressCallback,
    user_context: *anyopaque,
};

// Callbacks
fn progressCallback(userdata: *anyopaque, dltotal: curl.curl_off_t, dlnow: curl.curl_off_t, _: curl.curl_off_t, _: curl.curl_off_t) callconv(.c) c_int {
    const ctx: *ProgressContext = @ptrCast(@alignCast(userdata));
    const total: usize = if (dltotal > 0) @intCast(dltotal) else 0;
    const downloaded: usize = if (dlnow > 0) @intCast(dlnow) else 0;
    // Note: Logging disabled here to avoid log spam on large files (called very frequently)
    // Uncomment only for debugging: logger.debug("Progress: {d}/{d}", .{ downloaded, total });
    ctx.callback(downloaded, total, ctx.user_context);
    return 0; // Return 0 to continue
}

fn bodyWriteCallback(ptr: [*]const u8, size: usize, nmemb: usize, userdata: *anyopaque) callconv(.c) usize {
    const ctx: *BodyContext = @ptrCast(@alignCast(userdata));
    const total_size = size * nmemb;
    ctx.data.appendSlice(ctx.allocator, ptr[0..total_size]) catch return 0;
    return total_size;
}

fn headerCallback(ptr: [*]const u8, size: usize, nmemb: usize, userdata: *anyopaque) callconv(.c) usize {
    const ctx: *HeaderContext = @ptrCast(@alignCast(userdata));
    const total_size = size * nmemb;
    const header = ptr[0..total_size];

    if (std.mem.indexOf(u8, header, ":")) |colon_pos| {
        const name = std.mem.trim(u8, header[0..colon_pos], &std.ascii.whitespace);
        const value = std.mem.trim(u8, header[colon_pos + 1 ..], &std.ascii.whitespace);

        if (name.len > 0 and value.len > 0) {
            // Allocate new key and value
            const key = ctx.allocator.dupe(u8, name) catch return total_size;
            const val = ctx.allocator.dupe(u8, value) catch {
                ctx.allocator.free(key);
                return total_size;
            };

            // Check if key already exists and get the old entry
            const gop = ctx.headers.getOrPut(key) catch {
                ctx.allocator.free(key);
                ctx.allocator.free(val);
                return total_size;
            };

            if (gop.found_existing) {
                // Key exists, free the new key (we'll reuse the existing one)
                // and free the old value
                ctx.allocator.free(key);
                ctx.allocator.free(gop.value_ptr.*);
                gop.value_ptr.* = val;
            } else {
                // New entry, use both new key and value
                gop.key_ptr.* = key;
                gop.value_ptr.* = val;
            }
        }
    }

    return total_size;
}

fn streamWriteCallback(ptr: [*]const u8, size: usize, nmemb: usize, userdata: *anyopaque) callconv(.c) usize {
    const ctx: *StreamContext = @ptrCast(@alignCast(userdata));
    const total_size = size * nmemb;
    const data = ptr[0..total_size];

    const written = ctx.callback(data, ctx.user_context) catch return 0;
    return written;
}

/// Convert curl error to Zig error
fn curlErrorToZig(code: curl.CURLcode) types.Error {
    return switch (code) {
        .CURLE_OK => unreachable,
        .CURLE_COULDNT_CONNECT, .CURLE_COULDNT_RESOLVE_HOST => error.ConnectionFailed,
        .CURLE_OPERATION_TIMEDOUT => error.Timeout,
        .CURLE_URL_MALFORMAT => error.InvalidUrl,
        .CURLE_COULDNT_RESOLVE_PROXY => error.DNSResolutionFailed,
        .CURLE_SSL_CONNECT_ERROR, .CURLE_PEER_FAILED_VERIFICATION => error.TLSError,
        else => error.Unknown,
    };
}

// Tests
test "exponential backoff calculation" {
    const allocator = std.testing.allocator;
    const cfg = Config{
        .retry = .{
            .initial_backoff_ms = 100,
            .backoff_multiplier = 2.0,
            .max_backoff_ms = 1000,
        },
    };
    var client = try Client.init(allocator, cfg);
    defer client.deinit();

    // Verify exponential growth with cap
    try std.testing.expectEqual(@as(u32, 100), client.calculateBackoff(0));
    try std.testing.expectEqual(@as(u32, 200), client.calculateBackoff(1));
    try std.testing.expectEqual(@as(u32, 400), client.calculateBackoff(2));
    try std.testing.expectEqual(@as(u32, 800), client.calculateBackoff(3));
    try std.testing.expectEqual(@as(u32, 1000), client.calculateBackoff(4)); // capped
    try std.testing.expectEqual(@as(u32, 1000), client.calculateBackoff(10)); // still capped
}

test "curl error mapping" {
    try std.testing.expectEqual(types.Error.ConnectionFailed, curlErrorToZig(.CURLE_COULDNT_CONNECT));
    try std.testing.expectEqual(types.Error.InvalidUrl, curlErrorToZig(.CURLE_URL_MALFORMAT));
    try std.testing.expectEqual(types.Error.DNSResolutionFailed, curlErrorToZig(.CURLE_COULDNT_RESOLVE_PROXY));
    try std.testing.expectEqual(types.Error.Timeout, curlErrorToZig(.CURLE_OPERATION_TIMEDOUT));
}

test "header parsing with edge cases" {
    const allocator = std.testing.allocator;

    var ctx = HeaderContext{
        .allocator = allocator,
        .headers = std.StringHashMap([]const u8).init(allocator),
    };
    defer {
        var it = ctx.headers.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        ctx.headers.deinit();
    }

    // Test header with extra spaces
    const header = "Content-Type:   application/json  \r\n";
    _ = headerCallback(header.ptr, 1, header.len, &ctx);
    try std.testing.expectEqualStrings("application/json", ctx.headers.get("Content-Type").?);

    // Test header replacement
    const replacement = "Content-Type: text/plain\r\n";
    _ = headerCallback(replacement.ptr, 1, replacement.len, &ctx);
    try std.testing.expectEqualStrings("text/plain", ctx.headers.get("Content-Type").?);
}
