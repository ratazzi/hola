/// AWS KMS Client - Key Management Service for encrypt/decrypt operations
/// Uses libcurl with AWS Signature V4 authentication
const std = @import("std");
const curl = @import("curl.zig");

/// Encode binary data to base64 string
fn encodeBase64(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const encoded_len = std.base64.standard.Encoder.calcSize(data.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    _ = std.base64.standard.Encoder.encode(encoded, data);
    return encoded;
}

/// Decode base64 string to binary data
fn decodeBase64(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return error.Base64DecodeError;
    const decoded = try allocator.alloc(u8, decoded_len);
    std.base64.standard.Decoder.decode(decoded, encoded) catch return error.Base64DecodeError;
    return decoded;
}

pub const KMSError = error{
    CurlInitFailed,
    CurlHandleFailed,
    CurlPerformFailed,
    InvalidResponse,
    MissingCredentials,
    InvalidKeyId,
    JsonParseError,
    Base64DecodeError,
    OutOfMemory,
};

pub const KMSConfig = struct {
    access_key: []const u8,
    secret_key: []const u8,
    session_token: ?[]const u8 = null, // AWS_SESSION_TOKEN for temporary credentials (STS/IRSA)
    region: []const u8 = "us-east-1",
    endpoint: ?[]const u8 = null,
    verbose: bool = false,
};

pub const EncryptResult = struct {
    ciphertext_blob: []u8,
    key_id: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *EncryptResult) void {
        self.allocator.free(self.ciphertext_blob);
        self.allocator.free(self.key_id);
    }
};

pub const DecryptResult = struct {
    plaintext: []u8,
    key_id: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *DecryptResult) void {
        self.allocator.free(self.plaintext);
        self.allocator.free(self.key_id);
    }
};

/// JSON request structure for KMS Encrypt API
const EncryptRequest = struct {
    KeyId: []const u8,
    Plaintext: []const u8,
    EncryptionAlgorithm: ?[]const u8 = null,
    EncryptionContext: ?std.json.ArrayHashMap([]const u8) = null,
};

/// JSON request structure for KMS Decrypt API
const DecryptRequest = struct {
    CiphertextBlob: []const u8,
    EncryptionAlgorithm: ?[]const u8 = null,
    EncryptionContext: ?std.json.ArrayHashMap([]const u8) = null,
};

/// JSON response structure for KMS Encrypt API
const EncryptResponse = struct {
    CiphertextBlob: []const u8,
    KeyId: []const u8,
};

/// JSON response structure for KMS Decrypt API
const DecryptResponse = struct {
    Plaintext: []const u8,
    KeyId: []const u8,
};

pub const KMSClient = struct {
    allocator: std.mem.Allocator,
    config: KMSConfig,

    pub fn init(allocator: std.mem.Allocator, config: KMSConfig) !KMSClient {
        const init_result = curl.curl_global_init(0x03);
        if (init_result != .CURLE_OK) {
            return KMSError.CurlInitFailed;
        }

        return KMSClient{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *KMSClient) void {
        _ = self;
        curl.curl_global_cleanup();
    }

    /// Encrypt plaintext using a KMS key
    pub fn encrypt(
        self: *KMSClient,
        key_id: []const u8,
        plaintext: []const u8,
        encryption_context: ?std.StringHashMap([]const u8),
        algorithm: ?[]const u8,
    ) !EncryptResult {
        // Base64 encode the plaintext
        const plaintext_b64 = try encodeBase64(self.allocator, plaintext);
        defer self.allocator.free(plaintext_b64);

        // Convert encryption context if provided
        var ctx_map: ?std.json.ArrayHashMap([]const u8) = null;
        if (encryption_context) |ctx| {
            var map = std.json.ArrayHashMap([]const u8){};
            var it = ctx.iterator();
            while (it.next()) |entry| {
                try map.map.put(self.allocator, entry.key_ptr.*, entry.value_ptr.*);
            }
            ctx_map = map;
        }
        defer if (ctx_map) |*m| m.map.deinit(self.allocator);

        const request = EncryptRequest{
            .KeyId = key_id,
            .Plaintext = plaintext_b64,
            .EncryptionAlgorithm = algorithm,
            .EncryptionContext = ctx_map,
        };

        const json_body = try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(request, .{})});
        defer self.allocator.free(json_body);

        const response = try self.makeRequest("TrentService.Encrypt", json_body);
        defer self.allocator.free(response);

        return try self.parseEncryptResponse(response);
    }

    /// Decrypt ciphertext using KMS
    /// If input_is_base64 is true, ciphertext_blob is already base64 encoded
    pub fn decrypt(
        self: *KMSClient,
        ciphertext_blob: []const u8,
        encryption_context: ?std.StringHashMap([]const u8),
        algorithm: ?[]const u8,
        input_is_base64: bool,
    ) !DecryptResult {
        // Prepare ciphertext as base64
        var ciphertext_b64: []const u8 = undefined;
        var should_free_ciphertext = false;

        if (input_is_base64) {
            // Strip whitespace from base64 input
            var stripped = std.ArrayList(u8).initCapacity(self.allocator, ciphertext_blob.len) catch std.ArrayList(u8).empty;
            defer stripped.deinit(self.allocator);
            for (ciphertext_blob) |c| {
                if (c != '\n' and c != '\r' and c != ' ' and c != '\t') {
                    try stripped.append(self.allocator, c);
                }
            }
            ciphertext_b64 = try stripped.toOwnedSlice(self.allocator);
            should_free_ciphertext = true;
        } else {
            // Binary input, need to base64 encode
            ciphertext_b64 = try encodeBase64(self.allocator, ciphertext_blob);
            should_free_ciphertext = true;
        }
        defer if (should_free_ciphertext) self.allocator.free(ciphertext_b64);

        // Convert encryption context if provided
        var ctx_map: ?std.json.ArrayHashMap([]const u8) = null;
        if (encryption_context) |ctx| {
            var map = std.json.ArrayHashMap([]const u8){};
            var it = ctx.iterator();
            while (it.next()) |entry| {
                try map.map.put(self.allocator, entry.key_ptr.*, entry.value_ptr.*);
            }
            ctx_map = map;
        }
        defer if (ctx_map) |*m| m.map.deinit(self.allocator);

        const request = DecryptRequest{
            .CiphertextBlob = ciphertext_b64,
            .EncryptionAlgorithm = algorithm,
            .EncryptionContext = ctx_map,
        };

        const json_body = try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(request, .{})});
        defer self.allocator.free(json_body);

        const response = try self.makeRequest("TrentService.Decrypt", json_body);
        defer self.allocator.free(response);

        return try self.parseDecryptResponse(response);
    }

    fn makeRequest(self: *KMSClient, target: []const u8, body: []const u8) ![]u8 {
        const handle = curl.curl_easy_init() orelse {
            return KMSError.CurlHandleFailed;
        };
        defer curl.curl_easy_cleanup(handle);

        // Build URL
        const endpoint = self.config.endpoint orelse blk: {
            const default_endpoint = try std.fmt.allocPrint(self.allocator, "https://kms.{s}.amazonaws.com", .{self.config.region});
            break :blk default_endpoint;
        };
        const should_free_endpoint = self.config.endpoint == null;
        defer if (should_free_endpoint) self.allocator.free(endpoint);

        const url_z = try self.allocator.dupeZ(u8, endpoint);
        defer self.allocator.free(url_z);
        _ = curl.curl_easy_setopt(handle, .CURLOPT_URL, url_z.ptr);

        // Set AWS credentials
        const userpwd = try std.fmt.allocPrint(self.allocator, "{s}:{s}\x00", .{ self.config.access_key, self.config.secret_key });
        defer self.allocator.free(userpwd);
        _ = curl.curl_easy_setopt(handle, .CURLOPT_USERPWD, userpwd.ptr);

        // Enable AWS SigV4 signing for KMS
        const aws_sig = try std.fmt.allocPrint(self.allocator, "aws:amz:{s}:kms\x00", .{self.config.region});
        defer self.allocator.free(aws_sig);
        _ = curl.curl_easy_setopt(handle, .CURLOPT_AWS_SIGV4, aws_sig.ptr);

        // POST request
        _ = curl.curl_easy_setopt(handle, .CURLOPT_POST, @as(c_long, 1));
        _ = curl.curl_easy_setopt(handle, .CURLOPT_POSTFIELDS, body.ptr);
        _ = curl.curl_easy_setopt(handle, .CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(body.len)));

        // Set headers
        var headers: ?*curl.curl_slist = null;
        defer if (headers) |h| curl.curl_slist_free_all(h);

        headers = curl.curl_slist_append(headers, "Content-Type: application/x-amz-json-1.1");

        const target_header_str = try std.fmt.allocPrint(self.allocator, "X-Amz-Target: {s}", .{target});
        defer self.allocator.free(target_header_str);
        const target_header = try self.allocator.dupeZ(u8, target_header_str);
        defer self.allocator.free(target_header);
        headers = curl.curl_slist_append(headers, target_header.ptr);

        // Add security token header for temporary credentials (STS/IRSA)
        var session_token_header: ?[:0]u8 = null;
        if (self.config.session_token) |token| {
            const token_header_str = try std.fmt.allocPrint(self.allocator, "X-Amz-Security-Token: {s}", .{token});
            defer self.allocator.free(token_header_str);
            session_token_header = try self.allocator.dupeZ(u8, token_header_str);
            headers = curl.curl_slist_append(headers, session_token_header.?.ptr);
        }
        defer if (session_token_header) |h| self.allocator.free(h);

        _ = curl.curl_easy_setopt(handle, .CURLOPT_HTTPHEADER, headers);

        // Response buffer
        const BodyContext = struct {
            allocator: std.mem.Allocator,
            data: std.ArrayList(u8),
        };

        var body_ctx = BodyContext{
            .allocator = self.allocator,
            .data = std.ArrayList(u8).empty,
        };
        defer body_ctx.data.deinit(self.allocator);

        const writeCallback = struct {
            fn callback(ptr: [*]const u8, size: usize, nmemb: usize, userdata: *anyopaque) callconv(.c) usize {
                const ctx: *BodyContext = @ptrCast(@alignCast(userdata));
                const total_size = size * nmemb;
                ctx.data.appendSlice(ctx.allocator, ptr[0..total_size]) catch return 0;
                return total_size;
            }
        }.callback;

        _ = curl.curl_easy_setopt(handle, .CURLOPT_WRITEFUNCTION, writeCallback);
        _ = curl.curl_easy_setopt(handle, .CURLOPT_WRITEDATA, &body_ctx);

        if (self.config.verbose) {
            _ = curl.curl_easy_setopt(handle, .CURLOPT_VERBOSE, @as(c_long, 1));
        }

        const perform_result = curl.curl_easy_perform(handle);
        if (perform_result != .CURLE_OK) {
            return KMSError.CurlPerformFailed;
        }

        var response_code: c_long = 0;
        _ = curl.curl_easy_getinfo(handle, .CURLINFO_RESPONSE_CODE, &response_code);

        if (response_code < 200 or response_code >= 300) {
            // Log the error response for debugging
            const logger = @import("logger.zig");
            if (body_ctx.data.items.len > 0) {
                logger.err("KMS API error (HTTP {d}): {s}", .{ response_code, body_ctx.data.items });
            } else {
                logger.err("KMS API error: HTTP {d}", .{response_code});
            }
            return KMSError.InvalidResponse;
        }

        return try body_ctx.data.toOwnedSlice(self.allocator);
    }

    fn parseEncryptResponse(self: *KMSClient, json: []const u8) !EncryptResult {
        const parsed = std.json.parseFromSlice(EncryptResponse, self.allocator, json, .{ .ignore_unknown_fields = true }) catch {
            return KMSError.JsonParseError;
        };
        defer parsed.deinit();

        const ciphertext = try decodeBase64(self.allocator, parsed.value.CiphertextBlob);
        const key_id = try self.allocator.dupe(u8, parsed.value.KeyId);

        return EncryptResult{
            .ciphertext_blob = ciphertext,
            .key_id = key_id,
            .allocator = self.allocator,
        };
    }

    fn parseDecryptResponse(self: *KMSClient, json: []const u8) !DecryptResult {
        const parsed = std.json.parseFromSlice(DecryptResponse, self.allocator, json, .{ .ignore_unknown_fields = true }) catch {
            return KMSError.JsonParseError;
        };
        defer parsed.deinit();

        const plaintext = try decodeBase64(self.allocator, parsed.value.Plaintext);
        const key_id = try self.allocator.dupe(u8, parsed.value.KeyId);

        return DecryptResult{
            .plaintext = plaintext,
            .key_id = key_id,
            .allocator = self.allocator,
        };
    }
};
