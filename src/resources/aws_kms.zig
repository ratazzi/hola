const std = @import("std");
const mruby = @import("../mruby.zig");
const base = @import("../base_resource.zig");
const kms = @import("../kms_client.zig");
const logger = @import("../logger.zig");

pub const Resource = struct {
    name: []const u8,
    region: []const u8,
    access_key_id: ?[]const u8,
    secret_access_key: ?[]const u8,
    session_token: ?[]const u8, // AWS_SESSION_TOKEN for temporary credentials
    key_id: []const u8,
    algorithm: []const u8,
    source: []const u8, // file path or "inline:base64data"
    source_encoding: Encoding,
    target_encoding: Encoding,
    path: []const u8, // target path
    mode: ?u32,
    owner: ?[]const u8,
    group: ?[]const u8,
    action: Action,
    common: base.CommonProps,

    pub const Action = enum {
        encrypt,
        decrypt,
    };

    pub const Encoding = enum {
        binary,
        base64,
    };

    pub fn deinit(self: Resource, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.region);
        if (self.access_key_id) |k| allocator.free(k);
        if (self.secret_access_key) |k| allocator.free(k);
        if (self.session_token) |t| allocator.free(t);
        allocator.free(self.key_id);
        allocator.free(self.algorithm);
        allocator.free(self.source);
        allocator.free(self.path);
        if (self.owner) |o| allocator.free(o);
        if (self.group) |g| allocator.free(g);

        var common = self.common;
        common.deinit(allocator);
    }

    pub fn apply(self: Resource) !base.ApplyResult {
        const skip_reason = try self.common.shouldRun(self.owner, self.group);
        if (skip_reason) |reason| {
            return base.ApplyResult{
                .was_updated = false,
                .action = @tagName(self.action),
                .skip_reason = reason,
            };
        }

        const was_updated = switch (self.action) {
            .encrypt => try self.applyEncrypt(),
            .decrypt => try self.applyDecrypt(),
        };

        return base.ApplyResult{
            .was_updated = was_updated,
            .action = @tagName(self.action),
            .skip_reason = if (was_updated) null else "up to date",
        };
    }

    fn applyEncrypt(self: Resource) !bool {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        // Validate required fields
        if (self.region.len == 0) {
            logger.err("aws_kms: region is required", .{});
            return error.MissingRegion;
        }
        if (self.key_id.len == 0) {
            logger.err("aws_kms: key_id is required", .{});
            return error.MissingKeyId;
        }
        if (self.source.len == 0) {
            logger.err("aws_kms: source is required", .{});
            return error.MissingSource;
        }
        if (self.path.len == 0) {
            logger.err("aws_kms: path is required", .{});
            return error.MissingPath;
        }

        // Get credentials from env if not provided
        const access_key = self.access_key_id orelse
            std.process.getEnvVarOwned(allocator, "AWS_ACCESS_KEY_ID") catch {
            logger.err("aws_kms: AWS_ACCESS_KEY_ID not set and no access_key_id provided", .{});
            return error.MissingCredentials;
        };
        defer if (self.access_key_id == null) allocator.free(access_key);

        const secret_key = self.secret_access_key orelse
            std.process.getEnvVarOwned(allocator, "AWS_SECRET_ACCESS_KEY") catch {
            logger.err("aws_kms: AWS_SECRET_ACCESS_KEY not set and no secret_access_key provided", .{});
            return error.MissingCredentials;
        };
        defer if (self.secret_access_key == null) allocator.free(secret_key);

        // Get optional session token for temporary credentials
        const session_token = self.session_token orelse
            std.process.getEnvVarOwned(allocator, "AWS_SESSION_TOKEN") catch null;
        defer if (self.session_token == null and session_token != null) allocator.free(session_token.?);

        // Read input data and decode based on source_encoding
        const raw_data = try self.readSource(allocator);
        defer allocator.free(raw_data);

        // Decode source if needed - for encrypt, we need binary plaintext
        const plaintext = if (self.source_encoding == .base64) blk: {
            // Source is base64 encoded, decode to binary
            // First strip whitespace (newlines, spaces, tabs) for compatibility with multi-line base64
            var stripped = std.ArrayList(u8).initCapacity(allocator, raw_data.len) catch std.ArrayList(u8).empty;
            defer stripped.deinit(allocator);
            for (raw_data) |c| {
                if (c != '\n' and c != '\r' and c != ' ' and c != '\t') {
                    stripped.append(allocator, c) catch {
                        logger.err("aws_kms: out of memory while processing base64", .{});
                        return error.OutOfMemory;
                    };
                }
            }
            const cleaned_data = stripped.items;

            const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(cleaned_data) catch {
                logger.err("aws_kms: invalid base64 in source", .{});
                return error.InvalidBase64;
            };
            const decoded = try allocator.alloc(u8, decoded_len);
            std.base64.standard.Decoder.decode(decoded, cleaned_data) catch {
                allocator.free(decoded);
                logger.err("aws_kms: failed to decode base64 source", .{});
                return error.InvalidBase64;
            };
            break :blk decoded;
        } else blk: {
            // Source is already binary
            break :blk try allocator.dupe(u8, raw_data);
        };
        defer allocator.free(plaintext);

        // Initialize KMS client
        var client = try kms.KMSClient.init(allocator, .{
            .access_key = access_key,
            .secret_key = secret_key,
            .session_token = session_token,
            .region = self.region,
        });
        defer client.deinit();

        // Encrypt
        var result = try client.encrypt(
            self.key_id,
            plaintext,
            null, // encryption_context
            if (self.algorithm.len > 0) self.algorithm else null,
        );
        defer result.deinit();

        // Check if output already exists with same content (idempotency)
        if (try self.outputUpToDate(allocator, result.ciphertext_blob)) {
            // Content is up to date, but still ensure file attributes are correct
            self.ensureFileAttributes();
            return false;
        }

        // Write output with target encoding
        try self.writeOutput(allocator, result.ciphertext_blob);

        return true;
    }

    fn applyDecrypt(self: Resource) !bool {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        // Validate required fields
        if (self.region.len == 0) {
            logger.err("aws_kms: region is required", .{});
            return error.MissingRegion;
        }
        if (self.source.len == 0) {
            logger.err("aws_kms: source is required", .{});
            return error.MissingSource;
        }
        if (self.path.len == 0) {
            logger.err("aws_kms: path is required", .{});
            return error.MissingPath;
        }

        // Get credentials from env if not provided
        const access_key = self.access_key_id orelse
            std.process.getEnvVarOwned(allocator, "AWS_ACCESS_KEY_ID") catch {
            logger.err("aws_kms: AWS_ACCESS_KEY_ID not set and no access_key_id provided", .{});
            return error.MissingCredentials;
        };
        defer if (self.access_key_id == null) allocator.free(access_key);

        const secret_key = self.secret_access_key orelse
            std.process.getEnvVarOwned(allocator, "AWS_SECRET_ACCESS_KEY") catch {
            logger.err("aws_kms: AWS_SECRET_ACCESS_KEY not set and no secret_access_key provided", .{});
            return error.MissingCredentials;
        };
        defer if (self.secret_access_key == null) allocator.free(secret_key);

        // Get optional session token for temporary credentials
        const session_token = self.session_token orelse
            std.process.getEnvVarOwned(allocator, "AWS_SESSION_TOKEN") catch null;
        defer if (self.session_token == null and session_token != null) allocator.free(session_token.?);

        // Read ciphertext
        const ciphertext = try self.readSource(allocator);
        defer allocator.free(ciphertext);

        // Initialize KMS client
        var client = try kms.KMSClient.init(allocator, .{
            .access_key = access_key,
            .secret_key = secret_key,
            .session_token = session_token,
            .region = self.region,
        });
        defer client.deinit();

        // Decrypt - pass source_encoding to indicate if input is already base64
        var result = try client.decrypt(
            ciphertext,
            null, // encryption_context
            if (self.algorithm.len > 0) self.algorithm else null,
            self.source_encoding == .base64,
        );
        defer result.deinit();

        // Check if output already exists with same content (idempotency)
        if (try self.outputUpToDate(allocator, result.plaintext)) {
            // Content is up to date, but still ensure file attributes are correct
            self.ensureFileAttributes();
            return false;
        }

        // Write output with target encoding
        try self.writeOutput(allocator, result.plaintext);

        return true;
    }

    /// Read source data - handles file paths and inline base64
    fn readSource(self: Resource, allocator: std.mem.Allocator) ![]u8 {
        // Check for inline base64 data
        if (std.mem.startsWith(u8, self.source, "inline:")) {
            const inline_data = self.source["inline:".len..];
            return try allocator.dupe(u8, inline_data);
        }

        // Read from file
        const file = std.fs.openFileAbsolute(self.source, .{}) catch |err| {
            logger.err("aws_kms: failed to open source file '{s}': {}", .{ self.source, err });
            return err;
        };
        defer file.close();
        return try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    }

    /// Check if output file exists and has the same content
    fn outputUpToDate(self: Resource, allocator: std.mem.Allocator, new_data: []const u8) !bool {
        // Try to read existing file
        const file = std.fs.openFileAbsolute(self.path, .{}) catch {
            // File doesn't exist, not up to date
            return false;
        };
        defer file.close();

        const existing_data = file.readToEndAlloc(allocator, std.math.maxInt(usize)) catch {
            return false;
        };
        defer allocator.free(existing_data);

        // Encode new_data with target encoding to compare
        const encoded_new_data = if (self.target_encoding == .base64) blk: {
            const encoded_len = std.base64.standard.Encoder.calcSize(new_data.len);
            const encoded = try allocator.alloc(u8, encoded_len);
            _ = std.base64.standard.Encoder.encode(encoded, new_data);
            break :blk encoded;
        } else blk: {
            break :blk try allocator.dupe(u8, new_data);
        };
        defer allocator.free(encoded_new_data);

        // Compare content
        return std.mem.eql(u8, existing_data, encoded_new_data);
    }

    /// Ensure file attributes (mode/owner/group) are correct even when content is up to date
    fn ensureFileAttributes(self: Resource) void {
        base.applyFileAttributes(self.path, .{
            .mode = self.mode,
            .owner = self.owner,
            .group = self.group,
        }) catch |err| {
            logger.warn("Failed to apply file attributes for {s}: {}", .{ self.path, err });
        };
    }

    fn writeOutput(self: Resource, allocator: std.mem.Allocator, data: []const u8) !void {
        // Ensure parent directory exists
        try base.ensureParentDir(self.path);

        // Encode output if needed
        const output_data = if (self.target_encoding == .base64) blk: {
            const encoded_len = std.base64.standard.Encoder.calcSize(data.len);
            const encoded = try allocator.alloc(u8, encoded_len);
            _ = std.base64.standard.Encoder.encode(encoded, data);
            break :blk encoded;
        } else blk: {
            break :blk try allocator.dupe(u8, data);
        };
        defer allocator.free(output_data);

        // Write to temp file first
        const dir_path = std.fs.path.dirname(self.path);
        const timestamp = std.time.nanoTimestamp();
        const pid = std.c.getpid();

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const temp_allocator = arena.allocator();

        const temp_name = try std.fmt.allocPrint(temp_allocator, ".hola-kms-{d}-{d}", .{ timestamp, pid });
        const temp_path = if (dir_path) |d|
            try std.fs.path.join(temp_allocator, &.{ d, temp_name })
        else
            temp_name;

        var temp_file = try std.fs.createFileAbsolute(temp_path, .{ .truncate = true, .exclusive = true });
        errdefer std.fs.deleteFileAbsolute(temp_path) catch {};

        try temp_file.writeAll(output_data);
        try temp_file.sync();
        temp_file.close();

        // Atomic rename
        try std.fs.renameAbsolute(temp_path, self.path);

        // Apply file attributes
        base.applyFileAttributes(self.path, .{
            .mode = self.mode,
            .owner = self.owner,
            .group = self.group,
        }) catch |err| {
            logger.warn("Failed to apply file attributes for {s}: {}", .{ self.path, err });
        };
    }
};

pub const ruby_prelude = @embedFile("aws_kms_resource.rb");

pub fn zigAddResource(
    mrb: *mruby.mrb_state,
    self_val: mruby.mrb_value,
    resources: *std.ArrayList(Resource),
    allocator: std.mem.Allocator,
) mruby.mrb_value {
    _ = self_val;

    var name_val: mruby.mrb_value = undefined;
    var region_val: mruby.mrb_value = undefined;
    var access_key_val: mruby.mrb_value = undefined;
    var secret_key_val: mruby.mrb_value = undefined;
    var session_token_val: mruby.mrb_value = undefined;
    var key_id_val: mruby.mrb_value = undefined;
    var algorithm_val: mruby.mrb_value = undefined;
    var source_val: mruby.mrb_value = undefined;
    var source_encoding_val: mruby.mrb_value = undefined;
    var target_encoding_val: mruby.mrb_value = undefined;
    var path_val: mruby.mrb_value = undefined;
    var mode_val: mruby.mrb_value = undefined;
    var owner_val: mruby.mrb_value = undefined;
    var group_val: mruby.mrb_value = undefined;
    var action_val: mruby.mrb_value = undefined;
    var only_if_val: mruby.mrb_value = undefined;
    var not_if_val: mruby.mrb_value = undefined;
    var ignore_failure_val: mruby.mrb_value = undefined;
    var notifications_val: mruby.mrb_value = undefined;
    var subscriptions_val: mruby.mrb_value = undefined;

    _ = mruby.mrb_get_args(mrb, "SSSSSSSSSSSSSSS|oooAA", &name_val, &region_val, &access_key_val, &secret_key_val, &session_token_val, &key_id_val, &algorithm_val, &source_val, &source_encoding_val, &target_encoding_val, &path_val, &mode_val, &owner_val, &group_val, &action_val, &only_if_val, &not_if_val, &ignore_failure_val, &notifications_val, &subscriptions_val);

    const name = allocator.dupe(u8, std.mem.span(mruby.mrb_str_to_cstr(mrb, name_val))) catch return mruby.mrb_nil_value();
    const region = allocator.dupe(u8, std.mem.span(mruby.mrb_str_to_cstr(mrb, region_val))) catch return mruby.mrb_nil_value();
    const key_id = allocator.dupe(u8, std.mem.span(mruby.mrb_str_to_cstr(mrb, key_id_val))) catch return mruby.mrb_nil_value();
    const algorithm = allocator.dupe(u8, std.mem.span(mruby.mrb_str_to_cstr(mrb, algorithm_val))) catch return mruby.mrb_nil_value();
    const source = allocator.dupe(u8, std.mem.span(mruby.mrb_str_to_cstr(mrb, source_val))) catch return mruby.mrb_nil_value();
    const path = allocator.dupe(u8, std.mem.span(mruby.mrb_str_to_cstr(mrb, path_val))) catch return mruby.mrb_nil_value();

    const access_key_str = std.mem.span(mruby.mrb_str_to_cstr(mrb, access_key_val));
    const access_key_id: ?[]const u8 = if (access_key_str.len > 0)
        allocator.dupe(u8, access_key_str) catch return mruby.mrb_nil_value()
    else
        null;

    const secret_key_str = std.mem.span(mruby.mrb_str_to_cstr(mrb, secret_key_val));
    const secret_access_key: ?[]const u8 = if (secret_key_str.len > 0)
        allocator.dupe(u8, secret_key_str) catch return mruby.mrb_nil_value()
    else
        null;

    const session_token_str = std.mem.span(mruby.mrb_str_to_cstr(mrb, session_token_val));
    const session_token: ?[]const u8 = if (session_token_str.len > 0)
        allocator.dupe(u8, session_token_str) catch return mruby.mrb_nil_value()
    else
        null;

    const mode_str = std.mem.span(mruby.mrb_str_to_cstr(mrb, mode_val));
    const mode: ?u32 = if (mode_str.len > 0)
        std.fmt.parseInt(u32, mode_str, 8) catch null
    else
        null;

    const owner_str = std.mem.span(mruby.mrb_str_to_cstr(mrb, owner_val));
    const owner: ?[]const u8 = if (owner_str.len > 0)
        allocator.dupe(u8, owner_str) catch return mruby.mrb_nil_value()
    else
        null;

    const group_str = std.mem.span(mruby.mrb_str_to_cstr(mrb, group_val));
    const group: ?[]const u8 = if (group_str.len > 0)
        allocator.dupe(u8, group_str) catch return mruby.mrb_nil_value()
    else
        null;

    const action_str = std.mem.span(mruby.mrb_str_to_cstr(mrb, action_val));
    const action: Resource.Action = if (std.mem.eql(u8, action_str, "decrypt"))
        .decrypt
    else
        .encrypt;

    const source_encoding_str = std.mem.span(mruby.mrb_str_to_cstr(mrb, source_encoding_val));
    const source_encoding: Resource.Encoding = if (std.mem.eql(u8, source_encoding_str, "binary"))
        .binary
    else
        .base64;

    const target_encoding_str = std.mem.span(mruby.mrb_str_to_cstr(mrb, target_encoding_val));
    const target_encoding: Resource.Encoding = if (std.mem.eql(u8, target_encoding_str, "base64"))
        .base64
    else
        .binary;

    var common = base.CommonProps.init(allocator);
    base.fillCommonFromRuby(&common, mrb, only_if_val, not_if_val, ignore_failure_val, notifications_val, subscriptions_val, allocator);

    resources.append(allocator, .{
        .name = name,
        .region = region,
        .access_key_id = access_key_id,
        .secret_access_key = secret_access_key,
        .session_token = session_token,
        .key_id = key_id,
        .algorithm = algorithm,
        .source = source,
        .source_encoding = source_encoding,
        .target_encoding = target_encoding,
        .path = path,
        .mode = mode,
        .owner = owner,
        .group = group,
        .action = action,
        .common = common,
    }) catch return mruby.mrb_nil_value();

    return mruby.mrb_nil_value();
}
