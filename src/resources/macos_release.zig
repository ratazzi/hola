const std = @import("std");
const builtin = @import("builtin");
const mruby = @import("../mruby.zig");
const base = @import("../base_resource.zig");
const global_io = @import("../global_io.zig");
const logger = @import("../logger.zig");

comptime {
    if (builtin.os.tag != .macos) {
        @compileError("macOS release resources are only available on macOS");
    }
}

const COMMAND_OUTPUT_LIMIT = 64 * 1024 * 1024;

const Captured = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
    allocator: std.mem.Allocator,

    fn deinit(self: *Captured) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }

    fn succeeded(self: Captured) bool {
        return switch (self.term) {
            .exited => |code| code == 0,
            else => false,
        };
    }
};

fn runCapture(allocator: std.mem.Allocator, argv: []const []const u8) !Captured {
    const result = try std.process.run(allocator, global_io.io(), .{
        .argv = argv,
        .stdout_limit = .limited(COMMAND_OUTPUT_LIMIT),
        .stderr_limit = .limited(COMMAND_OUTPUT_LIMIT),
    });
    return .{
        .term = result.term,
        .stdout = result.stdout,
        .stderr = result.stderr,
        .allocator = allocator,
    };
}

fn commandFailureDetail(context: []const u8, result: Captured) void {
    const stderr = std.mem.trim(u8, result.stderr, &std.ascii.whitespace);
    const stdout = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
    const detail = if (stderr.len > 0) stderr else if (stdout.len > 0) stdout else "command failed without output";
    base.recordProvisionErrorDetail("{s}: {s}", .{ context, detail });
}

fn runChecked(allocator: std.mem.Allocator, argv: []const []const u8, context: []const u8) !void {
    var result = try runCapture(allocator, argv);
    defer result.deinit();
    if (result.succeeded()) return;
    commandFailureDetail(context, result);
    return error.CommandFailed;
}

fn commandSucceeds(allocator: std.mem.Allocator, argv: []const []const u8) bool {
    var result = runCapture(allocator, argv) catch return false;
    defer result.deinit();
    return result.succeeded();
}

fn pathExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(global_io.io(), path, .{}) catch return false;
    return true;
}

fn deletePath(path: []const u8) !bool {
    if (!pathExists(path)) return false;
    const io = global_io.io();
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    if (stat.kind == .directory) {
        try std.Io.Dir.cwd().deleteTree(io, path);
    } else {
        try std.Io.Dir.cwd().deleteFile(io, path);
    }
    return true;
}

fn ensureParent(path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    try std.Io.Dir.cwd().createDirPath(global_io.io(), parent);
}

const StringPair = struct {
    key: []const u8,
    value: []const u8,

    fn deinit(self: StringPair, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.value);
    }
};

const IconPosition = struct {
    name: []const u8,
    x: i64,
    y: i64,

    fn deinit(self: IconPosition, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

fn payloadValue(mrb: *mruby.mrb_state, payload: mruby.mrb_value, index: usize) mruby.mrb_value {
    return mruby.mrb_ary_ref(mrb, payload, @intCast(index));
}

fn requirePayloadLength(mrb: *mruby.mrb_state, payload: mruby.mrb_value, minimum: usize) !void {
    if (mruby.mrb_ary_len(mrb, payload) < @as(mruby.mrb_int, @intCast(minimum))) return error.InvalidResourcePayload;
}

fn dupeStringAt(allocator: std.mem.Allocator, mrb: *mruby.mrb_state, payload: mruby.mrb_value, index: usize) ![]const u8 {
    const value = payloadValue(mrb, payload, index);
    return allocator.dupe(u8, std.mem.span(mruby.mrb_str_to_cstr(mrb, value)));
}

fn dupeOptionalStringAt(allocator: std.mem.Allocator, mrb: *mruby.mrb_state, payload: mruby.mrb_value, index: usize) !?[]const u8 {
    const value = payloadValue(mrb, payload, index);
    const string = std.mem.span(mruby.mrb_str_to_cstr(mrb, value));
    if (string.len == 0) return null;
    return try allocator.dupe(u8, string);
}

fn boolAt(mrb: *mruby.mrb_state, payload: mruby.mrb_value, index: usize) bool {
    return mruby.mrb_test(payloadValue(mrb, payload, index));
}

fn intAt(mrb: *mruby.mrb_state, payload: mruby.mrb_value, index: usize) i64 {
    return mruby.mrb_fixnum(mrb, payloadValue(mrb, payload, index));
}

fn parseStringArray(allocator: std.mem.Allocator, mrb: *mruby.mrb_state, value: mruby.mrb_value) !std.ArrayList([]const u8) {
    var result = std.ArrayList([]const u8).empty;
    errdefer {
        for (result.items) |item| allocator.free(item);
        result.deinit(allocator);
    }
    const len = mruby.mrb_ary_len(mrb, value);
    for (0..@intCast(len)) |index| {
        const item = mruby.mrb_ary_ref(mrb, value, @intCast(index));
        try result.append(allocator, try allocator.dupe(u8, std.mem.span(mruby.mrb_str_to_cstr(mrb, item))));
    }
    return result;
}

fn parsePairs(allocator: std.mem.Allocator, mrb: *mruby.mrb_state, value: mruby.mrb_value) !std.ArrayList(StringPair) {
    var result = std.ArrayList(StringPair).empty;
    errdefer {
        for (result.items) |item| item.deinit(allocator);
        result.deinit(allocator);
    }
    const len = mruby.mrb_ary_len(mrb, value);
    for (0..@intCast(len)) |index| {
        const pair = mruby.mrb_ary_ref(mrb, value, @intCast(index));
        if (mruby.mrb_ary_len(mrb, pair) < 2) continue;
        const key_value = mruby.mrb_ary_ref(mrb, pair, 0);
        const item_value = mruby.mrb_ary_ref(mrb, pair, 1);
        const key = try allocator.dupe(u8, std.mem.span(mruby.mrb_str_to_cstr(mrb, key_value)));
        errdefer allocator.free(key);
        const item = try allocator.dupe(u8, std.mem.span(mruby.mrb_str_to_cstr(mrb, item_value)));
        try result.append(allocator, .{ .key = key, .value = item });
    }
    return result;
}

fn parseIconPositions(allocator: std.mem.Allocator, mrb: *mruby.mrb_state, value: mruby.mrb_value) !std.ArrayList(IconPosition) {
    var result = std.ArrayList(IconPosition).empty;
    errdefer {
        for (result.items) |item| item.deinit(allocator);
        result.deinit(allocator);
    }
    const len = mruby.mrb_ary_len(mrb, value);
    for (0..@intCast(len)) |index| {
        const position = mruby.mrb_ary_ref(mrb, value, @intCast(index));
        if (mruby.mrb_ary_len(mrb, position) < 3) continue;
        const name_value = mruby.mrb_ary_ref(mrb, position, 0);
        const name = try allocator.dupe(u8, std.mem.span(mruby.mrb_str_to_cstr(mrb, name_value)));
        try result.append(allocator, .{
            .name = name,
            .x = mruby.mrb_fixnum(mrb, mruby.mrb_ary_ref(mrb, position, 1)),
            .y = mruby.mrb_fixnum(mrb, mruby.mrb_ary_ref(mrb, position, 2)),
        });
    }
    return result;
}

fn parseIntArray(allocator: std.mem.Allocator, mrb: *mruby.mrb_state, value: mruby.mrb_value) !std.ArrayList(i64) {
    var result = std.ArrayList(i64).empty;
    errdefer result.deinit(allocator);
    const len = mruby.mrb_ary_len(mrb, value);
    for (0..@intCast(len)) |index| {
        try result.append(allocator, mruby.mrb_fixnum(mrb, mruby.mrb_ary_ref(mrb, value, @intCast(index))));
    }
    return result;
}

fn commonFromPayload(
    allocator: std.mem.Allocator,
    mrb: *mruby.mrb_state,
    payload: mruby.mrb_value,
    start: usize,
) base.CommonProps {
    var common = base.CommonProps.init(allocator);
    base.fillCommonFromRuby(
        &common,
        mrb,
        payloadValue(mrb, payload, start),
        payloadValue(mrb, payload, start + 1),
        payloadValue(mrb, payload, start + 2),
        payloadValue(mrb, payload, start + 3),
        payloadValue(mrb, payload, start + 4),
        allocator,
    );
    return common;
}

fn deinitStringList(list: *std.ArrayList([]const u8), allocator: std.mem.Allocator) void {
    for (list.items) |item| allocator.free(item);
    list.deinit(allocator);
}

fn deinitPairs(list: *std.ArrayList(StringPair), allocator: std.mem.Allocator) void {
    for (list.items) |item| item.deinit(allocator);
    list.deinit(allocator);
}

pub const XcodeBuild = struct {
    name: []const u8,
    workspace: ?[]const u8,
    project: ?[]const u8,
    scheme: ?[]const u8,
    configuration: []const u8,
    derived_data_path: ?[]const u8,
    sdk: ?[]const u8,
    destination: ?[]const u8,
    archive_path: ?[]const u8,
    action: Action,
    settings: std.ArrayList(StringPair),
    extra_args: std.ArrayList([]const u8),
    creates: ?[]const u8,
    clean: bool,
    allow_provisioning_updates: bool,
    common: base.CommonProps,

    pub const Action = enum { build, archive, @"test", analyze };

    pub fn deinit(self: XcodeBuild, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.workspace) |value| allocator.free(value);
        if (self.project) |value| allocator.free(value);
        if (self.scheme) |value| allocator.free(value);
        allocator.free(self.configuration);
        if (self.derived_data_path) |value| allocator.free(value);
        if (self.sdk) |value| allocator.free(value);
        if (self.destination) |value| allocator.free(value);
        if (self.archive_path) |value| allocator.free(value);
        if (self.creates) |value| allocator.free(value);
        var settings = self.settings;
        deinitPairs(&settings, allocator);
        var extra_args = self.extra_args;
        deinitStringList(&extra_args, allocator);
        var common = self.common;
        common.deinit(allocator);
    }

    pub fn apply(self: XcodeBuild) !base.ApplyResult {
        if (try self.common.shouldRun(null, null)) |reason| {
            return .{ .was_updated = false, .action = @tagName(self.action), .skip_reason = reason };
        }
        if (self.creates) |creates| {
            if (pathExists(creates)) return .{ .was_updated = false, .action = @tagName(self.action), .skip_reason = "up to date" };
        }

        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(allocator);
        try self.appendArgv(&argv, allocator);
        try runChecked(allocator, argv.items, "xcodebuild failed");
        if (self.creates) |creates| {
            if (!pathExists(creates)) {
                base.recordProvisionErrorDetail("xcodebuild succeeded but did not create {s}", .{creates});
                return error.ExpectedOutputMissing;
            }
        }
        return .{ .was_updated = true, .action = @tagName(self.action) };
    }

    fn appendArgv(self: XcodeBuild, argv: *std.ArrayList([]const u8), allocator: std.mem.Allocator) !void {
        try argv.append(allocator, "xcodebuild");
        if (self.workspace) |value| try argv.appendSlice(allocator, &.{ "-workspace", value });
        if (self.project) |value| try argv.appendSlice(allocator, &.{ "-project", value });
        if (self.scheme) |value| try argv.appendSlice(allocator, &.{ "-scheme", value });
        if (self.configuration.len > 0) try argv.appendSlice(allocator, &.{ "-configuration", self.configuration });
        if (self.derived_data_path) |value| try argv.appendSlice(allocator, &.{ "-derivedDataPath", value });
        if (self.sdk) |value| try argv.appendSlice(allocator, &.{ "-sdk", value });
        if (self.destination) |value| try argv.appendSlice(allocator, &.{ "-destination", value });
        if (self.archive_path) |value| try argv.appendSlice(allocator, &.{ "-archivePath", value });
        if (self.allow_provisioning_updates) try argv.append(allocator, "-allowProvisioningUpdates");
        if (self.clean) try argv.append(allocator, "clean");
        try argv.append(allocator, @tagName(self.action));
        for (self.settings.items) |setting| {
            try argv.append(allocator, try std.fmt.allocPrint(allocator, "{s}={s}", .{ setting.key, setting.value }));
        }
        try argv.appendSlice(allocator, self.extra_args.items);
    }
};

pub const SigningCertificate = struct {
    identity: []const u8,
    certificate_base64: ?[]const u8,
    certificate_path: ?[]const u8,
    password: []const u8,
    keychain: []const u8,
    keychain_password: []const u8,
    make_default: bool,
    action: Action,
    common: base.CommonProps,

    pub const Action = enum { import, delete };

    pub fn deinit(self: SigningCertificate, allocator: std.mem.Allocator) void {
        allocator.free(self.identity);
        if (self.certificate_base64) |value| allocator.free(value);
        if (self.certificate_path) |value| allocator.free(value);
        allocator.free(self.password);
        allocator.free(self.keychain);
        allocator.free(self.keychain_password);
        var common = self.common;
        common.deinit(allocator);
    }

    pub fn apply(self: SigningCertificate) !base.ApplyResult {
        if (try self.common.shouldRun(null, null)) |reason| {
            return .{ .was_updated = false, .action = @tagName(self.action), .skip_reason = reason };
        }
        return switch (self.action) {
            .delete => self.applyDelete(),
            .import => self.applyImport(),
        };
    }

    fn applyDelete(self: SigningCertificate) !base.ApplyResult {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        if (!commandSucceeds(allocator, &.{ "security", "show-keychain-info", self.keychain })) {
            return .{ .was_updated = false, .action = "delete", .skip_reason = "up to date" };
        }
        try runChecked(allocator, &.{ "security", "delete-keychain", self.keychain }, "failed to delete signing keychain");
        return .{ .was_updated = true, .action = "delete" };
    }

    fn applyImport(self: SigningCertificate) !base.ApplyResult {
        if (self.certificate_base64 == null and self.certificate_path == null) {
            base.recordProvisionErrorDetailSlice("macos_signing_certificate requires certificate or certificate_base64");
            return error.CertificateMissing;
        }

        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var updated = false;

        if (!commandSucceeds(allocator, &.{ "security", "show-keychain-info", self.keychain })) {
            try ensureParent(self.keychain);
            try runChecked(allocator, &.{ "security", "create-keychain", "-p", self.keychain_password, self.keychain }, "failed to create signing keychain");
            updated = true;
        }
        try runChecked(allocator, &.{ "security", "unlock-keychain", "-p", self.keychain_password, self.keychain }, "failed to unlock signing keychain");

        if (!try self.identityInstalled(allocator)) {
            const certificate = try self.materializeCertificate(allocator);
            defer if (self.certificate_base64 != null) std.Io.Dir.cwd().deleteFile(global_io.io(), certificate) catch {};
            try runChecked(allocator, &.{
                "security",    "import",      certificate,
                "-k",          self.keychain, "-P",
                self.password, "-T",          "/usr/bin/codesign",
            }, "failed to import signing certificate");
            try runChecked(allocator, &.{
                "security",             "set-key-partition-list",
                "-S",                   "apple-tool:,apple:",
                "-s",                   "-k",
                self.keychain_password, self.keychain,
            }, "failed to configure signing key access");
            updated = true;
        }

        if (self.make_default) {
            var current = try runCapture(allocator, &.{ "security", "default-keychain", "-d", "user" });
            defer current.deinit();
            if (!current.succeeded() or std.mem.indexOf(u8, current.stdout, self.keychain) == null) {
                try runChecked(allocator, &.{ "security", "default-keychain", "-d", "user", "-s", self.keychain }, "failed to select signing keychain");
                updated = true;
            }
        }

        if (!try self.identityInstalled(allocator)) {
            base.recordProvisionErrorDetail("signing identity not found after import: {s}", .{self.identity});
            return error.SigningIdentityMissing;
        }
        return .{ .was_updated = updated, .action = "import", .skip_reason = if (updated) null else "up to date" };
    }

    fn identityInstalled(self: SigningCertificate, allocator: std.mem.Allocator) !bool {
        var result = try runCapture(allocator, &.{ "security", "find-identity", "-v", "-p", "codesigning", self.keychain });
        defer result.deinit();
        return result.succeeded() and std.mem.indexOf(u8, result.stdout, self.identity) != null;
    }

    fn materializeCertificate(self: SigningCertificate, allocator: std.mem.Allocator) ![]const u8 {
        if (self.certificate_path) |path| {
            if (!pathExists(path)) return error.CertificateMissing;
            return path;
        }
        const encoded = self.certificate_base64.?;
        var cleaned = std.ArrayList(u8).empty;
        defer cleaned.deinit(allocator);
        for (encoded) |byte| {
            if (!std.ascii.isWhitespace(byte)) try cleaned.append(allocator, byte);
        }
        const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(cleaned.items) catch return error.InvalidCertificateBase64;
        const decoded = try allocator.alloc(u8, decoded_len);
        std.base64.standard.Decoder.decode(decoded, cleaned.items) catch return error.InvalidCertificateBase64;
        const path = try std.fmt.allocPrint(allocator, "/tmp/hola-signing-{d}.p12", .{std.Io.Timestamp.now(global_io.io(), .real).toNanoseconds()});
        try std.Io.Dir.cwd().writeFile(global_io.io(), .{ .sub_path = path, .data = decoded });
        try base.applyFileAttributes(path, .{ .mode = 0o600 });
        return path;
    }
};

pub const Codesign = struct {
    path: []const u8,
    identity: []const u8,
    identifier: ?[]const u8,
    entitlements: ?[]const u8,
    requirements: ?[]const u8,
    library_constraint: ?[]const u8,
    options: std.ArrayList([]const u8),
    timestamp: Timestamp,
    keychain: ?[]const u8,
    nested: bool,
    verify: bool,
    action: Action,
    common: base.CommonProps,

    pub const Timestamp = enum { auto, enabled, disabled };
    pub const Action = enum { sign, verify };

    pub fn deinit(self: Codesign, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.identity);
        if (self.identifier) |value| allocator.free(value);
        if (self.entitlements) |value| allocator.free(value);
        if (self.requirements) |value| allocator.free(value);
        if (self.library_constraint) |value| allocator.free(value);
        if (self.keychain) |value| allocator.free(value);
        var options = self.options;
        deinitStringList(&options, allocator);
        var common = self.common;
        common.deinit(allocator);
    }

    pub fn apply(self: Codesign) !base.ApplyResult {
        if (try self.common.shouldRun(null, null)) |reason| {
            return .{ .was_updated = false, .action = @tagName(self.action), .skip_reason = reason };
        }
        if (!pathExists(self.path)) {
            base.recordProvisionErrorDetail("code signing target does not exist: {s}", .{self.path});
            return error.SigningTargetMissing;
        }

        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        if (self.action == .verify) {
            try self.verifySignature(allocator);
            return .{ .was_updated = false, .action = "verify", .skip_reason = "signature valid" };
        }
        if (try self.isCurrent(allocator)) {
            return .{ .was_updated = false, .action = "sign", .skip_reason = "up to date" };
        }
        if (self.nested) try self.signNested(allocator);
        try self.signOne(allocator, self.path, true);
        if (self.verify) try self.verifySignature(allocator);
        return .{ .was_updated = true, .action = "sign" };
    }

    fn appendSigningOptions(self: Codesign, argv: *std.ArrayList([]const u8), allocator: std.mem.Allocator, target: []const u8, root: bool) !void {
        try argv.appendSlice(allocator, &.{ "--force", "--sign", self.identity });
        if (self.options.items.len > 0 and supportsCodeOptions(target)) {
            try argv.appendSlice(allocator, &.{ "--options", try std.mem.join(allocator, ",", self.options.items) });
        }
        if (!std.mem.eql(u8, self.identity, "-")) {
            switch (self.timestamp) {
                .auto, .enabled => try argv.append(allocator, "--timestamp"),
                .disabled => try argv.append(allocator, "--timestamp=none"),
            }
        }
        if (self.keychain) |value| try argv.appendSlice(allocator, &.{ "--keychain", value });
        if (!root) return;
        if (self.identifier) |value| try argv.appendSlice(allocator, &.{ "--identifier", value });
        if (self.entitlements) |value| try argv.appendSlice(allocator, &.{ "--entitlements", value });
        if (self.requirements) |value| try argv.appendSlice(allocator, &.{ "--requirements", value });
        if (self.library_constraint) |value| {
            try argv.appendSlice(allocator, &.{ "--library-constraint", value, "--enforce-constraint-validity" });
        }
    }

    fn signOne(self: Codesign, allocator: std.mem.Allocator, target: []const u8, root: bool) !void {
        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(allocator);
        try argv.append(allocator, "codesign");
        try self.appendSigningOptions(&argv, allocator, target, root);
        try argv.append(allocator, target);
        try runChecked(allocator, argv.items, "codesign failed");
    }

    fn verifySignature(self: Codesign, allocator: std.mem.Allocator) !void {
        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(allocator);
        try argv.appendSlice(allocator, &.{ "codesign", "--verify", "--strict" });
        if (self.nested) try argv.append(allocator, "--deep");
        try argv.append(allocator, self.path);
        try runChecked(allocator, argv.items, "code signature verification failed");
    }

    fn isCurrent(self: Codesign, allocator: std.mem.Allocator) !bool {
        var verify_argv = std.ArrayList([]const u8).empty;
        defer verify_argv.deinit(allocator);
        try verify_argv.appendSlice(allocator, &.{ "codesign", "--verify", "--strict" });
        if (self.nested) try verify_argv.append(allocator, "--deep");
        try verify_argv.append(allocator, self.path);
        if (!commandSucceeds(allocator, verify_argv.items)) return false;

        var display = try runCapture(allocator, &.{ "codesign", "--display", "--verbose=4", self.path });
        defer display.deinit();
        if (!display.succeeded()) return false;
        const metadata = display.stderr;
        if (std.mem.eql(u8, self.identity, "-")) {
            if (std.mem.indexOf(u8, metadata, "Signature=adhoc") == null) return false;
        } else if (self.identity.len != 40) {
            const authority = try std.fmt.allocPrint(allocator, "Authority={s}", .{self.identity});
            if (std.mem.indexOf(u8, metadata, authority) == null) return false;
        }
        if (self.identifier) |identifier| {
            const expected = try std.fmt.allocPrint(allocator, "Identifier={s}", .{identifier});
            if (std.mem.indexOf(u8, metadata, expected) == null) return false;
        }
        if (self.options.items.len > 0 and supportsCodeOptions(self.path) and std.mem.indexOf(u8, metadata, "runtime") == null) return false;
        if (!std.mem.eql(u8, self.identity, "-") and self.timestamp != .disabled and std.mem.indexOf(u8, metadata, "Timestamp=") == null) return false;
        if (self.entitlements) |path| if (try inputNewerThanSignature(path, self.path)) return false;
        if (self.library_constraint) |path| if (try inputNewerThanSignature(path, self.path)) return false;
        if (self.requirements) |requirements| {
            var requirement_result = try runCapture(allocator, &.{ "codesign", "--display", "-r-", self.path });
            defer requirement_result.deinit();
            if (!requirement_result.succeeded() or std.mem.indexOf(u8, requirement_result.stderr, requirements) == null) return false;
        }
        return true;
    }

    fn signNested(self: Codesign, allocator: std.mem.Allocator) !void {
        const stat = try std.Io.Dir.cwd().statFile(global_io.io(), self.path, .{});
        if (stat.kind != .directory) return;
        var dir = if (std.fs.path.isAbsolute(self.path))
            try std.Io.Dir.openDirAbsolute(global_io.io(), self.path, .{ .iterate = true })
        else
            try std.Io.Dir.cwd().openDir(global_io.io(), self.path, .{ .iterate = true });
        defer dir.close(global_io.io());

        var candidates = std.ArrayList([]const u8).empty;
        defer candidates.deinit(allocator);
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next(global_io.io())) |entry| {
            const full = try std.fs.path.join(allocator, &.{ self.path, entry.path });
            if (entry.kind == .file and isMachO(full)) {
                try candidates.append(allocator, full);
            } else if (entry.kind == .directory and isCodeBundle(full)) {
                try candidates.append(allocator, full);
            }
        }
        const Sort = struct {
            fn lessThan(_: void, left: []const u8, right: []const u8) bool {
                if (left.len == right.len) return std.mem.order(u8, left, right) == .gt;
                return left.len > right.len;
            }
        };
        std.mem.sort([]const u8, candidates.items, {}, Sort.lessThan);
        for (candidates.items) |candidate| try self.signOne(allocator, candidate, false);
    }
};

fn isCodeBundle(path: []const u8) bool {
    const extensions = [_][]const u8{ ".app", ".appex", ".xpc", ".framework", ".plugin", ".bundle" };
    for (extensions) |extension| if (std.mem.endsWith(u8, path, extension)) return true;
    return false;
}

fn supportsCodeOptions(path: []const u8) bool {
    return !std.mem.endsWith(u8, path, ".dmg") and !std.mem.endsWith(u8, path, ".pkg");
}

fn isMachO(path: []const u8) bool {
    const io = global_io.io();
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    defer file.close(io);
    var bytes: [4]u8 = undefined;
    const count = file.readStreaming(io, &.{&bytes}) catch return false;
    if (count != bytes.len) return false;
    const magic = std.mem.readInt(u32, &bytes, .big);
    return switch (magic) {
        0xfeedface,
        0xfeedfacf,
        0xcefaedfe,
        0xcffaedfe,
        0xcafebabe,
        0xcafebabf,
        0xbebafeca,
        0xbfbafeca,
        => true,
        else => false,
    };
}

fn inputNewerThanSignature(input: []const u8, target: []const u8) !bool {
    const io = global_io.io();
    const input_stat = try std.Io.Dir.cwd().statFile(io, input, .{});
    const signature_path = if ((try std.Io.Dir.cwd().statFile(io, target, .{})).kind == .directory)
        try std.fs.path.join(std.heap.c_allocator, &.{ target, "Contents/_CodeSignature/CodeResources" })
    else
        try std.heap.c_allocator.dupe(u8, target);
    defer std.heap.c_allocator.free(signature_path);
    const signature_stat = std.Io.Dir.cwd().statFile(io, signature_path, .{}) catch return true;
    return input_stat.mtime.toNanoseconds() > signature_stat.mtime.toNanoseconds();
}

pub const Dmg = struct {
    path: []const u8,
    source: []const u8,
    volume_name: []const u8,
    format: []const u8,
    filesystem: []const u8,
    applications_link: bool,
    background: ?[]const u8,
    icon_size: i64,
    window_bounds: std.ArrayList(i64),
    icon_positions: std.ArrayList(IconPosition),
    force: bool,
    verify: bool,
    action: Action,
    common: base.CommonProps,

    pub const Action = enum { create, delete };

    pub fn deinit(self: Dmg, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.source);
        allocator.free(self.volume_name);
        allocator.free(self.format);
        allocator.free(self.filesystem);
        if (self.background) |value| allocator.free(value);
        var bounds = self.window_bounds;
        bounds.deinit(allocator);
        var positions = self.icon_positions;
        for (positions.items) |position| position.deinit(allocator);
        positions.deinit(allocator);
        var common = self.common;
        common.deinit(allocator);
    }

    pub fn apply(self: Dmg) !base.ApplyResult {
        if (try self.common.shouldRun(null, null)) |reason| {
            return .{ .was_updated = false, .action = @tagName(self.action), .skip_reason = reason };
        }
        if (self.action == .delete) {
            const updated = try deletePath(self.path);
            return .{ .was_updated = updated, .action = "delete", .skip_reason = if (updated) null else "up to date" };
        }
        if (!pathExists(self.source)) {
            base.recordProvisionErrorDetail("DMG source does not exist: {s}", .{self.source});
            return error.DmgSourceMissing;
        }
        if (!self.force and try self.isCurrent()) {
            return .{ .was_updated = false, .action = "create", .skip_reason = "up to date" };
        }
        try self.create();
        return .{ .was_updated = true, .action = "create" };
    }

    fn isCurrent(self: Dmg) !bool {
        if (!pathExists(self.path)) return false;
        const io = global_io.io();
        const output_stat = try std.Io.Dir.cwd().statFile(io, self.path, .{});
        var newest_input = try latestMtime(self.source);
        if (self.background) |background| newest_input = @max(newest_input, try latestMtime(background));
        if (output_stat.mtime.toNanoseconds() < newest_input) return false;
        if (!self.verify) return true;
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer arena.deinit();
        return commandSucceeds(arena.allocator(), &.{ "hdiutil", "verify", self.path });
    }

    fn create(self: Dmg) !void {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const io = global_io.io();
        try ensureParent(self.path);

        const timestamp = std.Io.Timestamp.now(io, .real).toNanoseconds();
        const stage = try std.fmt.allocPrint(allocator, "/tmp/hola-dmg-stage-{d}", .{timestamp});
        const mount = try std.fmt.allocPrint(allocator, "/tmp/hola-dmg-mount-{d}", .{timestamp});
        const parent = std.fs.path.dirname(self.path) orelse ".";
        const basename = std.fs.path.basename(self.path);
        const partial = try std.fs.path.join(allocator, &.{ parent, try std.fmt.allocPrint(allocator, ".{s}.hola-{d}.dmg", .{ basename, timestamp }) });
        const writable = try std.fs.path.join(allocator, &.{ parent, try std.fmt.allocPrint(allocator, ".{s}.hola-{d}.writable.dmg", .{ basename, timestamp }) });
        try std.Io.Dir.cwd().createDirPath(io, stage);
        try std.Io.Dir.cwd().createDirPath(io, mount);
        defer std.Io.Dir.cwd().deleteTree(io, stage) catch {};
        defer std.Io.Dir.cwd().deleteTree(io, mount) catch {};
        defer std.Io.Dir.cwd().deleteFile(io, partial) catch {};
        defer std.Io.Dir.cwd().deleteFile(io, writable) catch {};

        const staged_source = try std.fs.path.join(allocator, &.{ stage, std.fs.path.basename(self.source) });
        try runChecked(allocator, &.{ "ditto", self.source, staged_source }, "failed to stage DMG source");
        if (self.applications_link) {
            const applications = try std.fs.path.join(allocator, &.{ stage, "Applications" });
            try std.Io.Dir.cwd().symLink(io, "/Applications", applications, .{});
        }
        if (self.background) |background| {
            const background_dir = try std.fs.path.join(allocator, &.{ stage, ".background" });
            try std.Io.Dir.cwd().createDirPath(io, background_dir);
            const destination = try std.fs.path.join(allocator, &.{ background_dir, std.fs.path.basename(background) });
            try runChecked(allocator, &.{ "ditto", background, destination }, "failed to stage DMG background");
        }

        const needs_layout = self.background != null or self.icon_positions.items.len > 0 or self.window_bounds.items.len == 4;
        if (needs_layout) {
            try runChecked(allocator, &.{
                "hdiutil",    "create",        "-volname", self.volume_name,
                "-srcfolder", stage,           "-format",  "UDRW",
                "-fs",        self.filesystem, "-ov",      writable,
            }, "failed to create writable DMG");
            var mounted = false;
            defer if (mounted) {
                _ = commandSucceeds(allocator, &.{ "hdiutil", "detach", mount, "-quiet" });
            };
            try runChecked(allocator, &.{
                "hdiutil",     "attach", "-readwrite", "-noverify", "-noautoopen",
                "-mountpoint", mount,    writable,
            }, "failed to mount writable DMG");
            mounted = true;
            const script = try self.finderScript(allocator, std.fs.path.basename(mount));
            try runFinderLayout(allocator, script);
            try runChecked(allocator, &.{"sync"}, "failed to sync DMG layout");
            try runChecked(allocator, &.{ "hdiutil", "detach", mount, "-quiet" }, "failed to detach writable DMG");
            mounted = false;
            try runChecked(allocator, &.{
                "hdiutil",   "convert",      writable, "-format", self.format,
                "-imagekey", "zlib-level=9", "-o",     partial,
            }, "failed to compress DMG");
        } else {
            try runChecked(allocator, &.{
                "hdiutil",    "create",        "-volname", self.volume_name,
                "-srcfolder", stage,           "-format",  self.format,
                "-fs",        self.filesystem, "-ov",      partial,
            }, "failed to create DMG");
        }
        if (self.verify) try runChecked(allocator, &.{ "hdiutil", "verify", partial }, "DMG verification failed");
        if (pathExists(self.path)) try std.Io.Dir.cwd().deleteFile(io, self.path);
        try std.Io.Dir.cwd().rename(partial, std.Io.Dir.cwd(), self.path, io);
    }

    fn finderScript(self: Dmg, allocator: std.mem.Allocator, disk_name: []const u8) ![]const u8 {
        var script = std.ArrayList(u8).empty;
        try script.appendSlice(allocator, "tell application \"Finder\"\n  tell disk ");
        try appendAppleScriptString(&script, allocator, disk_name);
        try script.appendSlice(allocator, "\n    open\n    set current view of container window to icon view\n    set toolbar visible of container window to false\n    set statusbar visible of container window to false\n");
        if (self.window_bounds.items.len == 4) {
            try appendFormatted(&script, allocator, "    set bounds of container window to {{{d}, {d}, {d}, {d}}}\n", .{
                self.window_bounds.items[0], self.window_bounds.items[1], self.window_bounds.items[2], self.window_bounds.items[3],
            });
        }
        try script.appendSlice(allocator, "    set arrangement of icon view options of container window to not arranged\n");
        try appendFormatted(&script, allocator, "    set icon size of icon view options of container window to {d}\n", .{self.icon_size});
        if (self.background) |background| {
            try script.appendSlice(allocator, "    set background picture of icon view options of container window to file ");
            var finder_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const finder_path = try std.fmt.bufPrint(&finder_path_buffer, ".background:{s}", .{std.fs.path.basename(background)});
            try appendAppleScriptString(&script, allocator, finder_path);
            try script.append(allocator, '\n');
        }
        for (self.icon_positions.items) |position| {
            try script.appendSlice(allocator, "    set position of item ");
            try appendAppleScriptString(&script, allocator, position.name);
            try appendFormatted(&script, allocator, " of container window to {{{d}, {d}}}\n", .{ position.x, position.y });
        }
        try script.appendSlice(allocator, "    close\n    open\n    update without registering applications\n    delay 2\n  end tell\nend tell\n");
        return script.toOwnedSlice(allocator);
    }
};

fn appendFormatted(
    buffer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    comptime format: []const u8,
    args: anytype,
) !void {
    var formatted_buffer: [512]u8 = undefined;
    const formatted = try std.fmt.bufPrint(&formatted_buffer, format, args);
    try buffer.appendSlice(allocator, formatted);
}

fn runFinderLayout(allocator: std.mem.Allocator, script: []const u8) !void {
    const io = global_io.io();
    const deadline = std.Io.Timestamp.now(io, .real).toMilliseconds() + 10_000;
    while (true) {
        var result = try runCapture(allocator, &.{ "osascript", "-e", script });
        const succeeded = result.succeeded();
        if (succeeded) {
            result.deinit();
            return;
        }
        if (std.Io.Timestamp.now(io, .real).toMilliseconds() >= deadline) {
            commandFailureDetail("failed to configure DMG Finder layout", result);
            result.deinit();
            return error.CommandFailed;
        }
        result.deinit();
        io.sleep(.fromNanoseconds(250 * std.time.ns_per_ms), .awake) catch {};
    }
}

fn appendAppleScriptString(buffer: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try buffer.append(allocator, '"');
    for (value) |byte| {
        if (byte == '"' or byte == '\\') try buffer.append(allocator, '\\');
        try buffer.append(allocator, byte);
    }
    try buffer.append(allocator, '"');
}

fn latestMtime(path: []const u8) !i128 {
    const io = global_io.io();
    const root_stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    var latest = root_stat.mtime.toNanoseconds();
    if (root_stat.kind != .directory) return latest;
    var dir = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true })
    else
        try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(std.heap.c_allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        const stat = dir.statFile(io, entry.path, .{}) catch continue;
        latest = @max(latest, stat.mtime.toNanoseconds());
    }
    return latest;
}

pub const Notarize = struct {
    path: []const u8,
    keychain_profile: ?[]const u8,
    apple_id: ?[]const u8,
    team_id: ?[]const u8,
    password: ?[]const u8,
    key: ?[]const u8,
    key_id: ?[]const u8,
    issuer: ?[]const u8,
    staple: bool,
    validate: bool,
    assess: bool,
    action: Action,
    common: base.CommonProps,

    pub const Action = enum { submit, validate };

    pub fn deinit(self: Notarize, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.keychain_profile) |value| allocator.free(value);
        if (self.apple_id) |value| allocator.free(value);
        if (self.team_id) |value| allocator.free(value);
        if (self.password) |value| allocator.free(value);
        if (self.key) |value| allocator.free(value);
        if (self.key_id) |value| allocator.free(value);
        if (self.issuer) |value| allocator.free(value);
        var common = self.common;
        common.deinit(allocator);
    }

    pub fn apply(self: Notarize) !base.ApplyResult {
        if (try self.common.shouldRun(null, null)) |reason| {
            return .{ .was_updated = false, .action = @tagName(self.action), .skip_reason = reason };
        }
        if (!pathExists(self.path)) {
            base.recordProvisionErrorDetail("notarization target does not exist: {s}", .{self.path});
            return error.NotarizationTargetMissing;
        }
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        if (self.action == .validate) {
            try self.validateArtifact(allocator);
            return .{ .was_updated = false, .action = "validate", .skip_reason = "ticket valid" };
        }
        if (self.staple and self.isCurrent(allocator)) {
            return .{ .was_updated = false, .action = "submit", .skip_reason = "up to date" };
        }
        try self.submit(allocator);
        if (self.staple) try runChecked(allocator, &.{ "xcrun", "stapler", "staple", self.path }, "failed to staple notarization ticket");
        if (self.validate) try self.validateArtifact(allocator);
        return .{ .was_updated = true, .action = "submit" };
    }

    fn appendCredentials(self: Notarize, argv: *std.ArrayList([]const u8), allocator: std.mem.Allocator) !void {
        if (self.keychain_profile) |profile| {
            try argv.appendSlice(allocator, &.{ "--keychain-profile", profile });
            return;
        }
        if (self.key) |key| {
            const key_id = self.key_id orelse return error.NotaryCredentialsMissing;
            const issuer = self.issuer orelse return error.NotaryCredentialsMissing;
            try argv.appendSlice(allocator, &.{ "--key", key, "--key-id", key_id, "--issuer", issuer });
            return;
        }
        const apple_id = self.apple_id orelse return error.NotaryCredentialsMissing;
        const team_id = self.team_id orelse return error.NotaryCredentialsMissing;
        const password = self.password orelse return error.NotaryCredentialsMissing;
        try argv.appendSlice(allocator, &.{ "--apple-id", apple_id, "--team-id", team_id, "--password", password });
    }

    fn submit(self: Notarize, allocator: std.mem.Allocator) !void {
        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(allocator);
        try argv.appendSlice(allocator, &.{ "xcrun", "notarytool", "submit", self.path });
        try self.appendCredentials(&argv, allocator);
        try argv.appendSlice(allocator, &.{ "--wait", "--output-format", "json" });
        var result = try runCapture(allocator, argv.items);
        defer result.deinit();
        if (!result.succeeded()) {
            commandFailureDetail("notarytool submit failed", result);
            return error.NotarizationFailed;
        }
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{}) catch {
            base.recordProvisionErrorDetailSlice("notarytool returned invalid JSON");
            return error.InvalidNotaryResponse;
        };
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidNotaryResponse;
        const status_value = parsed.value.object.get("status") orelse return error.InvalidNotaryResponse;
        if (status_value != .string) return error.InvalidNotaryResponse;
        if (std.mem.eql(u8, status_value.string, "Accepted")) return;

        const id_value = parsed.value.object.get("id");
        if (id_value != null and id_value.? == .string) {
            var log_argv = std.ArrayList([]const u8).empty;
            defer log_argv.deinit(allocator);
            try log_argv.appendSlice(allocator, &.{ "xcrun", "notarytool", "log", id_value.?.string });
            try self.appendCredentials(&log_argv, allocator);
            var log_result = try runCapture(allocator, log_argv.items);
            defer log_result.deinit();
            const log = if (log_result.stdout.len > 0) log_result.stdout else log_result.stderr;
            base.recordProvisionErrorDetail("notarization status {s}: {s}", .{ status_value.string, log });
        } else {
            base.recordProvisionErrorDetail("notarization status {s}", .{status_value.string});
        }
        return error.NotarizationRejected;
    }

    fn isCurrent(self: Notarize, allocator: std.mem.Allocator) bool {
        if (!commandSucceeds(allocator, &.{ "xcrun", "stapler", "validate", self.path })) return false;
        if (!self.assess) return true;
        return self.assessmentSucceeds(allocator);
    }

    fn validateArtifact(self: Notarize, allocator: std.mem.Allocator) !void {
        if (self.validate or self.staple) {
            try runChecked(allocator, &.{ "xcrun", "stapler", "validate", self.path }, "stapled ticket validation failed");
        }
        if (self.assess) try self.assessArtifact(allocator);
    }

    fn assessmentSucceeds(self: Notarize, allocator: std.mem.Allocator) bool {
        if (std.mem.endsWith(u8, self.path, ".pkg")) {
            return commandSucceeds(allocator, &.{ "spctl", "--assess", "--type", "install", "--verbose=2", self.path });
        }
        if (std.mem.endsWith(u8, self.path, ".dmg")) {
            return commandSucceeds(allocator, &.{ "spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=2", self.path });
        }
        return commandSucceeds(allocator, &.{ "spctl", "--assess", "--type", "execute", "--verbose=2", self.path });
    }

    fn assessArtifact(self: Notarize, allocator: std.mem.Allocator) !void {
        if (std.mem.endsWith(u8, self.path, ".pkg")) {
            return runChecked(allocator, &.{ "spctl", "--assess", "--type", "install", "--verbose=2", self.path }, "Gatekeeper assessment failed");
        }
        if (std.mem.endsWith(u8, self.path, ".dmg")) {
            return runChecked(allocator, &.{ "spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=2", self.path }, "Gatekeeper assessment failed");
        }
        return runChecked(allocator, &.{ "spctl", "--assess", "--type", "execute", "--verbose=2", self.path }, "Gatekeeper assessment failed");
    }
};

fn parseXcodeAction(value: []const u8) XcodeBuild.Action {
    if (std.mem.eql(u8, value, "archive")) return .archive;
    if (std.mem.eql(u8, value, "test")) return .@"test";
    if (std.mem.eql(u8, value, "analyze")) return .analyze;
    return .build;
}

fn parseTimestamp(value: []const u8) Codesign.Timestamp {
    if (std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "disabled")) return .disabled;
    if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "enabled")) return .enabled;
    return .auto;
}

fn parseXcodeBuild(allocator: std.mem.Allocator, mrb: *mruby.mrb_state, payload: mruby.mrb_value) !XcodeBuild {
    try requirePayloadLength(mrb, payload, 20);
    const action_string = std.mem.span(mruby.mrb_str_to_cstr(mrb, payloadValue(mrb, payload, 9)));
    return .{
        .name = try dupeStringAt(allocator, mrb, payload, 0),
        .workspace = try dupeOptionalStringAt(allocator, mrb, payload, 1),
        .project = try dupeOptionalStringAt(allocator, mrb, payload, 2),
        .scheme = try dupeOptionalStringAt(allocator, mrb, payload, 3),
        .configuration = try dupeStringAt(allocator, mrb, payload, 4),
        .derived_data_path = try dupeOptionalStringAt(allocator, mrb, payload, 5),
        .sdk = try dupeOptionalStringAt(allocator, mrb, payload, 6),
        .destination = try dupeOptionalStringAt(allocator, mrb, payload, 7),
        .archive_path = try dupeOptionalStringAt(allocator, mrb, payload, 8),
        .action = parseXcodeAction(action_string),
        .settings = try parsePairs(allocator, mrb, payloadValue(mrb, payload, 10)),
        .extra_args = try parseStringArray(allocator, mrb, payloadValue(mrb, payload, 11)),
        .creates = try dupeOptionalStringAt(allocator, mrb, payload, 12),
        .clean = boolAt(mrb, payload, 13),
        .allow_provisioning_updates = boolAt(mrb, payload, 14),
        .common = commonFromPayload(allocator, mrb, payload, 15),
    };
}

fn parseSigningCertificate(allocator: std.mem.Allocator, mrb: *mruby.mrb_state, payload: mruby.mrb_value) !SigningCertificate {
    try requirePayloadLength(mrb, payload, 13);
    const action = std.mem.span(mruby.mrb_str_to_cstr(mrb, payloadValue(mrb, payload, 7)));
    return .{
        .identity = try dupeStringAt(allocator, mrb, payload, 0),
        .certificate_base64 = try dupeOptionalStringAt(allocator, mrb, payload, 1),
        .certificate_path = try dupeOptionalStringAt(allocator, mrb, payload, 2),
        .password = try dupeStringAt(allocator, mrb, payload, 3),
        .keychain = try dupeStringAt(allocator, mrb, payload, 4),
        .keychain_password = try dupeStringAt(allocator, mrb, payload, 5),
        .make_default = boolAt(mrb, payload, 6),
        .action = if (std.mem.eql(u8, action, "delete")) .delete else .import,
        .common = commonFromPayload(allocator, mrb, payload, 8),
    };
}

fn parseCodesign(allocator: std.mem.Allocator, mrb: *mruby.mrb_state, payload: mruby.mrb_value) !Codesign {
    try requirePayloadLength(mrb, payload, 17);
    const timestamp = std.mem.span(mruby.mrb_str_to_cstr(mrb, payloadValue(mrb, payload, 7)));
    const action = std.mem.span(mruby.mrb_str_to_cstr(mrb, payloadValue(mrb, payload, 11)));
    return .{
        .path = try dupeStringAt(allocator, mrb, payload, 0),
        .identity = try dupeStringAt(allocator, mrb, payload, 1),
        .identifier = try dupeOptionalStringAt(allocator, mrb, payload, 2),
        .entitlements = try dupeOptionalStringAt(allocator, mrb, payload, 3),
        .requirements = try dupeOptionalStringAt(allocator, mrb, payload, 4),
        .library_constraint = try dupeOptionalStringAt(allocator, mrb, payload, 5),
        .options = try parseStringArray(allocator, mrb, payloadValue(mrb, payload, 6)),
        .timestamp = parseTimestamp(timestamp),
        .keychain = try dupeOptionalStringAt(allocator, mrb, payload, 8),
        .nested = boolAt(mrb, payload, 9),
        .verify = boolAt(mrb, payload, 10),
        .action = if (std.mem.eql(u8, action, "verify")) .verify else .sign,
        .common = commonFromPayload(allocator, mrb, payload, 12),
    };
}

fn parseDmg(allocator: std.mem.Allocator, mrb: *mruby.mrb_state, payload: mruby.mrb_value) !Dmg {
    try requirePayloadLength(mrb, payload, 18);
    const action = std.mem.span(mruby.mrb_str_to_cstr(mrb, payloadValue(mrb, payload, 12)));
    return .{
        .path = try dupeStringAt(allocator, mrb, payload, 0),
        .source = try dupeStringAt(allocator, mrb, payload, 1),
        .volume_name = try dupeStringAt(allocator, mrb, payload, 2),
        .format = try dupeStringAt(allocator, mrb, payload, 3),
        .filesystem = try dupeStringAt(allocator, mrb, payload, 4),
        .applications_link = boolAt(mrb, payload, 5),
        .background = try dupeOptionalStringAt(allocator, mrb, payload, 6),
        .icon_size = intAt(mrb, payload, 7),
        .window_bounds = try parseIntArray(allocator, mrb, payloadValue(mrb, payload, 8)),
        .icon_positions = try parseIconPositions(allocator, mrb, payloadValue(mrb, payload, 9)),
        .force = boolAt(mrb, payload, 10),
        .verify = boolAt(mrb, payload, 11),
        .action = if (std.mem.eql(u8, action, "delete")) .delete else .create,
        .common = commonFromPayload(allocator, mrb, payload, 13),
    };
}

fn parseNotarize(allocator: std.mem.Allocator, mrb: *mruby.mrb_state, payload: mruby.mrb_value) !Notarize {
    try requirePayloadLength(mrb, payload, 17);
    const action = std.mem.span(mruby.mrb_str_to_cstr(mrb, payloadValue(mrb, payload, 11)));
    return .{
        .path = try dupeStringAt(allocator, mrb, payload, 0),
        .keychain_profile = try dupeOptionalStringAt(allocator, mrb, payload, 1),
        .apple_id = try dupeOptionalStringAt(allocator, mrb, payload, 2),
        .team_id = try dupeOptionalStringAt(allocator, mrb, payload, 3),
        .password = try dupeOptionalStringAt(allocator, mrb, payload, 4),
        .key = try dupeOptionalStringAt(allocator, mrb, payload, 5),
        .key_id = try dupeOptionalStringAt(allocator, mrb, payload, 6),
        .issuer = try dupeOptionalStringAt(allocator, mrb, payload, 7),
        .staple = boolAt(mrb, payload, 8),
        .validate = boolAt(mrb, payload, 9),
        .assess = boolAt(mrb, payload, 10),
        .action = if (std.mem.eql(u8, action, "validate")) .validate else .submit,
        .common = commonFromPayload(allocator, mrb, payload, 12),
    };
}

fn addParsedResource(
    comptime T: type,
    mrb: *mruby.mrb_state,
    resource_list: *std.ArrayList(T),
    allocator: std.mem.Allocator,
    parser: fn (std.mem.Allocator, *mruby.mrb_state, mruby.mrb_value) anyerror!T,
) mruby.mrb_value {
    var payload: mruby.mrb_value = undefined;
    if (mruby.mrb_get_args(mrb, "A", &payload) != 1) return mruby.mrb_nil_value();
    const resource = parser(allocator, mrb, payload) catch |err| {
        logger.err("failed to parse macOS release resource: {}", .{err});
        return mruby.mrb_nil_value();
    };
    resource_list.append(allocator, resource) catch {
        resource.deinit(allocator);
        return mruby.mrb_nil_value();
    };
    return mruby.mrb_nil_value();
}

pub fn zigAddXcodeBuild(mrb: *mruby.mrb_state, _: mruby.mrb_value, list: *std.ArrayList(XcodeBuild), allocator: std.mem.Allocator) mruby.mrb_value {
    return addParsedResource(XcodeBuild, mrb, list, allocator, parseXcodeBuild);
}

pub fn zigAddSigningCertificate(mrb: *mruby.mrb_state, _: mruby.mrb_value, list: *std.ArrayList(SigningCertificate), allocator: std.mem.Allocator) mruby.mrb_value {
    return addParsedResource(SigningCertificate, mrb, list, allocator, parseSigningCertificate);
}

pub fn zigAddCodesign(mrb: *mruby.mrb_state, _: mruby.mrb_value, list: *std.ArrayList(Codesign), allocator: std.mem.Allocator) mruby.mrb_value {
    return addParsedResource(Codesign, mrb, list, allocator, parseCodesign);
}

pub fn zigAddDmg(mrb: *mruby.mrb_state, _: mruby.mrb_value, list: *std.ArrayList(Dmg), allocator: std.mem.Allocator) mruby.mrb_value {
    return addParsedResource(Dmg, mrb, list, allocator, parseDmg);
}

pub fn zigAddNotarize(mrb: *mruby.mrb_state, _: mruby.mrb_value, list: *std.ArrayList(Notarize), allocator: std.mem.Allocator) mruby.mrb_value {
    return addParsedResource(Notarize, mrb, list, allocator, parseNotarize);
}

pub const ruby_prelude = @embedFile("macos_release_resources.rb");

test "parseTimestamp supports automatic and explicit modes" {
    try std.testing.expectEqual(Codesign.Timestamp.auto, parseTimestamp("auto"));
    try std.testing.expectEqual(Codesign.Timestamp.enabled, parseTimestamp("true"));
    try std.testing.expectEqual(Codesign.Timestamp.disabled, parseTimestamp("false"));
}

test "Mach-O magic detection recognizes thin and fat binaries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = global_io.io();
    try tmp.dir.writeFile(io, .{ .sub_path = "thin", .data = &.{ 0xfe, 0xed, 0xfa, 0xcf } });
    try tmp.dir.writeFile(io, .{ .sub_path = "fat", .data = &.{ 0xca, 0xfe, 0xba, 0xbe } });
    try tmp.dir.writeFile(io, .{ .sub_path = "text", .data = "ruby" });
    const thin = try tmp.dir.realPathFileAlloc(io, "thin", std.testing.allocator);
    defer std.testing.allocator.free(thin);
    const fat = try tmp.dir.realPathFileAlloc(io, "fat", std.testing.allocator);
    defer std.testing.allocator.free(fat);
    const text = try tmp.dir.realPathFileAlloc(io, "text", std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(isMachO(thin));
    try std.testing.expect(isMachO(fat));
    try std.testing.expect(!isMachO(text));
}

test "xcodebuild argv keeps build settings as individual arguments" {
    const allocator = std.testing.allocator;
    var settings = std.ArrayList(StringPair).empty;
    defer settings.deinit(allocator);
    try settings.append(allocator, .{ .key = "MARKETING_VERSION", .value = "1.2.3" });
    var extra_args = std.ArrayList([]const u8).empty;
    defer extra_args.deinit(allocator);
    try extra_args.append(allocator, "-quiet");
    var common = base.CommonProps.init(allocator);
    defer common.deinit(allocator);
    const resource = XcodeBuild{
        .name = "fixture",
        .workspace = "/tmp/Fixture.xcworkspace",
        .project = null,
        .scheme = "Fixture",
        .configuration = "Release",
        .derived_data_path = "/tmp/DerivedData",
        .sdk = null,
        .destination = null,
        .archive_path = null,
        .action = .build,
        .settings = settings,
        .extra_args = extra_args,
        .creates = null,
        .clean = true,
        .allow_provisioning_updates = true,
        .common = common,
    };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(arena.allocator());
    try resource.appendArgv(&argv, arena.allocator());
    const expected = [_][]const u8{
        "xcodebuild",                "-workspace",       "/tmp/Fixture.xcworkspace",
        "-scheme",                   "Fixture",          "-configuration",
        "Release",                   "-derivedDataPath", "/tmp/DerivedData",
        "-allowProvisioningUpdates", "clean",            "build",
        "MARKETING_VERSION=1.2.3",   "-quiet",
    };
    try std.testing.expectEqual(expected.len, argv.items.len);
    for (expected, argv.items) |expected_arg, actual_arg| {
        try std.testing.expectEqualStrings(expected_arg, actual_arg);
    }
}

test "Finder layout quotes mount names and positions" {
    const allocator = std.testing.allocator;
    var bounds = std.ArrayList(i64).empty;
    defer bounds.deinit(allocator);
    try bounds.appendSlice(allocator, &.{ 100, 120, 700, 520 });
    var positions = std.ArrayList(IconPosition).empty;
    defer positions.deinit(allocator);
    try positions.append(allocator, .{ .name = "Fixture.app", .x = 180, .y = 235 });
    var common = base.CommonProps.init(allocator);
    defer common.deinit(allocator);
    const resource = Dmg{
        .path = "/tmp/Fixture.dmg",
        .source = "/tmp/Fixture.app",
        .volume_name = "Fixture",
        .format = "UDZO",
        .filesystem = "HFS+",
        .applications_link = true,
        .background = null,
        .icon_size = 96,
        .window_bounds = bounds,
        .icon_positions = positions,
        .force = false,
        .verify = true,
        .action = .create,
        .common = common,
    };
    const script = try resource.finderScript(allocator, "hola-dmg-mount-42");
    defer allocator.free(script);
    try std.testing.expect(std.mem.indexOf(u8, script, "tell disk \"hola-dmg-mount-42\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "set position of item \"Fixture.app\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "{100, 120, 700, 520}") != null);
}

test "code bundle detection covers common nested bundle types" {
    try std.testing.expect(isCodeBundle("Fixture.app"));
    try std.testing.expect(isCodeBundle("Frameworks/Sparkle.framework"));
    try std.testing.expect(isCodeBundle("XPCServices/Updater.xpc"));
    try std.testing.expect(isCodeBundle("PlugIns/Extension.appex"));
    try std.testing.expect(!isCodeBundle("Contents/MacOS/fixture"));
    try std.testing.expect(supportsCodeOptions("Fixture.app"));
    try std.testing.expect(!supportsCodeOptions("Fixture.dmg"));
    try std.testing.expect(!supportsCodeOptions("Fixture.pkg"));
}

test {
    std.testing.refAllDecls(@This());
}
