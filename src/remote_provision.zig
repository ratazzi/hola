//! Upload a provision workspace and run the existing engine on one SSH host.
const std = @import("std");
const builtin = @import("builtin");
const global_io = @import("global_io.zig");
const ssh = @import("ssh.zig");
const protocol = @import("remote_protocol.zig");
const display = @import("modern_provision_display.zig");
const http = @import("http.zig");
const xdg = @import("xdg.zig");
const ssh_config = @import("ssh_config.zig");
const build_options = @import("build_options");

/// Release assets are published as hola-{os}-{arch} under a v{version} tag.
pub const RELEASE_BASE_URL = "https://github.com/ratazzi/hola/releases/download";

pub const Options = struct {
    host: []const u8,
    /// Null means the ssh_config value, then 22.
    port: ?u16 = null,
    identity: ?[]const u8 = null,
    known_hosts: ?[]const u8 = null,
    binary: ?[]const u8 = null,
    bundle: ?[]const u8 = null,
    sudo: bool = false,
    script: []const u8,
    phase: ?[]const u8 = null,
    output_mode: display.OutputMode = .normal,
    params_json: ?[]const u8 = null,
    secrets_json: ?[]const u8 = null,
};

/// The `[user@]host` argument as typed; `host` is the alias looked up in ssh_config.
const Target = struct {
    user: ?[]const u8,
    host: []const u8,

    fn parse(value: []const u8) !Target {
        const at = std.mem.indexOfScalar(u8, value, '@');
        const user: ?[]const u8 = if (at) |index| value[0..index] else null;
        var host = if (at) |index| value[index + 1 ..] else value;
        if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') host = host[1 .. host.len - 1];
        if (user) |name| if (name.len == 0 or std.mem.indexOfAny(u8, name, "\x00\r\n\t @/") != null) return error.InvalidSshTarget;
        if (host.len == 0 or host[0] == '-' or std.mem.indexOfAny(u8, host, "\x00\r\n\t @/[]") != null) return error.InvalidSshTarget;
        return .{ .user = user, .host = host };
    }
};

/// Everything needed to open the connection, after ssh_config and the command line are merged.
const Connection = struct {
    user: []const u8,
    host: []const u8,
    port: u16,
    known_hosts: []const u8,
    config: ssh_config.HostConfig,

    /// Command-line values win over ~/.ssh/config, which wins over the defaults.
    fn resolve(allocator: std.mem.Allocator, io: std.Io, opts: Options) !Connection {
        const target = try Target.parse(opts.host);
        if (opts.port) |port| if (port == 0) return error.InvalidSshPort;
        const home = global_io.getEnv("HOME") orelse return error.HomeNotFound;
        const local_user = global_io.getEnv("USER") orelse global_io.getEnv("LOGNAME");
        const config_path = try std.fs.path.join(allocator, &.{ home, ".ssh", "config" });
        const config = ssh_config.load(allocator, io, config_path, target.host, .{ .home = home, .local_user = local_user orelse "" }) catch |err| {
            std.debug.print("[ssh] Cannot read {s}: {s}\n", .{ config_path, @errorName(err) });
            return err;
        };
        if (config.proxy_jump) |jump| {
            std.debug.print("[ssh] {s} sets ProxyJump {s} for {s}; Hola cannot hop through jump hosts, connect to the target directly\n", .{ config_path, jump, target.host });
            return error.ProxyJumpUnsupported;
        }
        const connection = Connection{
            .user = target.user orelse config.user orelse local_user orelse return error.SshUserRequired,
            .host = config.host_name orelse target.host,
            .port = opts.port orelse config.port orelse 22,
            .known_hosts = opts.known_hosts orelse config.user_known_hosts_file orelse try std.fs.path.join(allocator, &.{ home, ".ssh", "known_hosts" }),
            .config = config,
        };
        const applied = config.host_name != null or config.user != null or config.port != null or config.identity_agent != null or config.identity_files.len > 0;
        if (applied) {
            const agent = config.identity_agent orelse (if (config.agent_disabled) "disabled" else "default");
            std.debug.print("[ssh] Applying {s} for {s}: {s}@{s}:{d}, {d} identity file(s), agent {s}\n", .{ config_path, target.host, connection.user, connection.host, connection.port, config.identity_files.len, agent });
        }
        return connection;
    }
};

const Platform = struct {
    os: std.Target.Os.Tag,
    arch: std.Target.Cpu.Arch,

    fn parse(output: []const u8) !Platform {
        var lines = std.mem.tokenizeAny(u8, output, "\r\n");
        const os_name = lines.next() orelse return error.UnsupportedRemotePlatform;
        const arch_name = lines.next() orelse return error.UnsupportedRemotePlatform;
        if (lines.next() != null) return error.UnsupportedRemotePlatform;
        const os: std.Target.Os.Tag = if (std.mem.eql(u8, os_name, "Linux")) .linux else if (std.mem.eql(u8, os_name, "Darwin")) .macos else return error.UnsupportedRemotePlatform;
        const arch: std.Target.Cpu.Arch = if (std.mem.eql(u8, arch_name, "x86_64")) .x86_64 else if (std.mem.eql(u8, arch_name, "aarch64") or std.mem.eql(u8, arch_name, "arm64")) .aarch64 else return error.UnsupportedRemotePlatform;
        return .{ .os = os, .arch = arch };
    }

    fn matchesBinary(self: Platform, bytes: []const u8) bool {
        if (bytes.len < 20) return false;
        if (self.os == .linux) {
            if (!std.mem.eql(u8, bytes[0..4], "\x7fELF") or bytes[4] != 2 or bytes[5] != 1) return false;
            const machine = std.mem.readInt(u16, bytes[18..20], .little);
            return machine == @as(u16, if (self.arch == .aarch64) 183 else 62);
        }
        if (!std.mem.eql(u8, bytes[0..4], "\xcf\xfa\xed\xfe")) return false;
        const cpu = std.mem.readInt(u32, bytes[4..8], .little);
        return cpu == @as(u32, if (self.arch == .aarch64) 0x0100000c else 0x01000007);
    }
};

pub fn run(allocator: std.mem.Allocator, opts: Options) !void {
    // All temporary strings share the lifetime of this single-host operation.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const io = global_io.io();
    const connection = try Connection.resolve(aa, io, opts);
    if (std.mem.startsWith(u8, opts.script, "http://") or std.mem.startsWith(u8, opts.script, "https://"))
        return error.RemoteProvisionRequiresLocalScript;
    const script = try std.Io.Dir.cwd().realPathFileAlloc(io, opts.script, aa);
    const bundle = if (opts.bundle) |path| try std.Io.Dir.cwd().realPathFileAlloc(io, path, aa) else null;
    const entry = if (bundle) |root| try bundleEntry(root, script) else std.fs.path.basename(script);
    if (bundle) |root| try validateBundle(aa, root);

    std.debug.print("[ssh] Connecting to {s}@{s}:{d}\n", .{ connection.user, connection.host, connection.port });
    var client = try ssh.Client.connect(allocator, .{
        .host = connection.host,
        .user = connection.user,
        .port = connection.port,
        .identity = opts.identity,
        .identity_files = connection.config.identity_files,
        .identity_agent = connection.config.identity_agent,
        .agent_disabled = connection.config.agent_disabled,
        .known_hosts = connection.known_hosts,
    });
    defer client.deinit();
    const platform_output = try checkedExec(&client, "uname -s && uname -m");
    defer allocator.free(platform_output);
    const platform = try Platform.parse(platform_output);
    const binary = opts.binary orelse blk: {
        if (platform.os == builtin.os.tag and platform.arch == builtin.cpu.arch)
            break :blk try std.process.executablePathAlloc(io, aa);
        break :blk try downloadRelease(aa, platform);
    };
    const digest = binaryDigest(binary, platform) catch |err| {
        std.debug.print("[ssh] Cannot use local binary {s}: {s}\n", .{ binary, @errorName(err) });
        return err;
    };
    const workspace_output = try checkedExec(&client, "umask 077; mktemp -d /tmp/hola-XXXXXXXXXXXX");
    defer allocator.free(workspace_output);
    const workspace = std.mem.trim(u8, workspace_output, "\r\n");
    if (!validWorkspace(workspace)) return error.InvalidRemoteWorkspace;
    const quoted_workspace = try ssh.shellQuote(aa, workspace);
    const cleanup = try std.fmt.allocPrint(aa, "{s}rm -rf -- {s}", .{ if (opts.sudo) "sudo -n -- " else "", quoted_workspace });
    var cleanup_workspace = true;
    defer {
        if (cleanup_workspace) {
            const result = client.exec(cleanup, "", false) catch null;
            if (result) |value| {
                if (value.exit_code != 0) std.debug.print("[ssh] Could not clean remote workspace: {s}\n", .{workspace});
                value.deinit(allocator);
            } else std.debug.print("[ssh] Could not clean remote workspace: {s}\n", .{workspace});
        } else std.debug.print("[ssh] Workspace retained for inspection: {s}\n", .{workspace});
    }

    const cached_binary = try installBinary(aa, &client, binary, &digest, workspace);
    const remote_bundle = try std.fmt.allocPrint(aa, "{s}/bundle", .{workspace});
    try client.mkdir(remote_bundle);
    if (bundle) |root| {
        try uploadBundle(aa, &client, root, remote_bundle);
    } else {
        try client.upload(script, try std.fmt.allocPrint(aa, "{s}/{s}", .{ remote_bundle, entry }), 0o600);
    }
    const result_path = try std.fmt.allocPrint(aa, "{s}/result.json", .{workspace});
    const quoted_result = try ssh.shellQuote(aa, result_path);
    // Pre-create as the SSH user so it remains readable after a sudo worker writes it.
    const create_result = try checkedExec(&client, try std.fmt.allocPrint(aa, "umask 077; : > {s}", .{quoted_result}));
    allocator.free(create_result);
    const request = try std.fmt.allocPrint(aa, "{f}", .{std.json.fmt(protocol.Request{
        .script_path = try std.fmt.allocPrint(aa, "./{s}", .{entry}),
        .result_path = result_path,
        .phase = opts.phase,
        .output_mode = opts.output_mode,
        .params_json = opts.params_json,
        .secrets_json = opts.secrets_json,
    }, .{})});
    if (request.len > protocol.MAX_REQUEST_BYTES) return error.RemoteRequestTooLarge;
    const command = try std.fmt.allocPrint(aa, "cd {s} && exec {s}{s} provision --request-stdin", .{
        try ssh.shellQuote(aa, remote_bundle),
        if (opts.sudo) "sudo -n -- " else "",
        try ssh.shellQuote(aa, cached_binary),
    });
    std.debug.print("[ssh] Running provision on {s}\n", .{opts.host});
    const execution = client.exec(command, request, true) catch |err| {
        // The worker may still be running. Removing its inputs would change its outcome.
        cleanup_workspace = false;
        std.debug.print("[ssh] Execution interrupted ({s}); remote outcome is unknown. The script was not retried.\n", .{@errorName(err)});
        return error.RemoteOutcomeUnknown;
    };
    defer execution.deinit(allocator);
    const result_json = checkedExec(&client, try std.fmt.allocPrint(aa, "cat -- {s}", .{quoted_result})) catch {
        cleanup_workspace = false;
        return error.RemoteOutcomeUnknown;
    };
    defer allocator.free(result_json);
    if (result_json.len == 0) {
        cleanup_workspace = false;
        std.debug.print("[ssh] No completion record (exit {d}); remote outcome is unknown. A remote binary older than the remote protocol also ends here.\n", .{execution.exit_code});
        return error.RemoteOutcomeUnknown;
    }
    const completion = std.json.parseFromSlice(protocol.Completion, allocator, result_json, .{}) catch {
        cleanup_workspace = false;
        return error.RemoteOutcomeUnknown;
    };
    defer completion.deinit();
    if (completion.value.version != protocol.VERSION) return error.RemoteProtocolMismatch;
    if (!completion.value.success or execution.exit_code != 0) {
        if (completion.value.error_name) |name| std.debug.print("[ssh] Provision failed: {s}\n", .{name});
        return error.RemoteProvisionFailed;
    }
}

fn checkedExec(client: *ssh.Client, command: []const u8) ![]u8 {
    const result = try client.exec(command, "", false);
    if (result.exit_code != 0) {
        result.deinit(client.allocator);
        return error.RemoteCommandFailed;
    }
    return result.stdout;
}

fn binaryDigest(path: []const u8, platform: Platform) ![64]u8 {
    const io = global_io.io();
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [32 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    var header: [64]u8 = undefined;
    const header_len = try reader.interface.readSliceShort(&header);
    if (!platform.matchesBinary(header[0..header_len])) return error.RemoteBinaryPlatformMismatch;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(header[0..header_len]);
    var chunk: [32 * 1024]u8 = undefined;
    while (true) {
        const count = try reader.interface.readSliceShort(&chunk);
        if (count == 0) break;
        hash.update(chunk[0..count]);
    }
    return std.fmt.bytesToHex(hash.finalResult(), .lower);
}

fn releaseUrl(allocator: std.mem.Allocator, platform: Platform, tag: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}/hola-{s}-{s}", .{ RELEASE_BASE_URL, tag, @tagName(platform.os), @tagName(platform.arch) });
}

/// Fetch a Hola build for the remote platform into the local cache: the controller's
/// own release, or the nightly build when that version has no release asset.
fn downloadRelease(allocator: std.mem.Allocator, platform: Platform) ![]const u8 {
    const cache_home = try xdg.XDG.init(allocator).getCacheHome();
    const cache_dir = try std.fs.path.join(allocator, &.{ cache_home, "remote" });
    try std.Io.Dir.cwd().createDirPath(global_io.io(), cache_dir);
    if (!build_options.is_nightly) {
        const tag = try std.fmt.allocPrint(allocator, "v{s}", .{build_options.version});
        if (try fetchAsset(allocator, platform, cache_dir, tag, false)) |path| return path;
        std.debug.print("[ssh] No release asset for {s}; falling back to the nightly build.\n", .{tag});
    }
    return (try fetchAsset(allocator, platform, cache_dir, "nightly", true)) orelse error.RemoteBinaryDownloadFailed;
}

/// Download one release asset into the cache; null means the asset does not exist.
/// Verified downloads are kept; a bad or partial download never becomes a cache entry.
/// Moving tags are revalidated with the stored ETag so an unchanged build is not re-downloaded.
fn fetchAsset(allocator: std.mem.Allocator, platform: Platform, cache_dir: []const u8, tag: []const u8, revalidate: bool) !?[]const u8 {
    const io = global_io.io();
    const cwd = std.Io.Dir.cwd();
    const cached = try std.fmt.allocPrint(allocator, "{s}/hola-{s}-{s}-{s}", .{ cache_dir, @tagName(platform.os), @tagName(platform.arch), tag });
    const etag_path = try std.fmt.allocPrint(allocator, "{s}.etag", .{cached});
    const exists = if (cwd.access(io, cached, .{})) |_| true else |_| false;
    if (exists and !revalidate) return cached;
    const previous_etag: ?[]const u8 = if (exists) cwd.readFileAlloc(io, etag_path, allocator, .unlimited) catch null else null;

    const url = try releaseUrl(allocator, platform, tag);
    std.debug.print("[ssh] {s} {s}\n", .{ if (previous_etag != null) "Checking" else "Downloading", url });
    const partial = try std.fmt.allocPrint(allocator, "{s}.part", .{cached});
    var result = http.downloadFile(allocator, url, partial, .{ .if_none_match = previous_etag }) catch |err| {
        const detail = http.download.downloader.getLastDownloadError();
        if (detail != null and std.mem.endsWith(u8, detail.?, "HTTP status 404")) return null;
        if (detail) |text| std.debug.print("[ssh] {s}\n", .{text});
        if (exists) {
            std.debug.print("[ssh] Using cached {s} ({s})\n", .{ cached, @errorName(err) });
            return cached;
        }
        std.debug.print("[ssh] Could not download {s} ({s}); pass --remote-binary with a local build.\n", .{ url, @errorName(err) });
        return error.RemoteBinaryDownloadFailed;
    };
    defer result.deinit(allocator);
    if (result.status == .not_modified) {
        cwd.deleteFile(io, partial) catch {};
        return cached;
    }
    _ = binaryDigest(partial, platform) catch |err| {
        cwd.deleteFile(io, partial) catch {};
        return err;
    };
    try cwd.rename(partial, cwd, cached, io);
    if (result.etag) |etag| try cwd.writeFile(io, .{ .sub_path = etag_path, .data = etag }) else cwd.deleteFile(io, etag_path) catch {};
    return cached;
}

fn installBinary(allocator: std.mem.Allocator, client: *ssh.Client, binary: []const u8, digest: []const u8, workspace: []const u8) ![]const u8 {
    const cache_output = try checkedExec(client, "umask 077; mkdir -p \"$HOME/.cache/hola/remote\" && printf '%s' \"$HOME/.cache/hola/remote\"");
    defer client.allocator.free(cache_output);
    if (!std.fs.path.isAbsolute(cache_output)) return error.InvalidRemoteCache;
    const cached = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cache_output, digest });
    const quoted = try ssh.shellQuote(allocator, cached);
    const probe = try client.exec(try std.fmt.allocPrint(allocator, "test -x {s}", .{quoted}), "", false);
    defer probe.deinit(client.allocator);
    if (probe.exit_code == 0) return cached;
    std.debug.print("[ssh] Uploading Hola binary\n", .{});
    const staged = try std.fmt.allocPrint(allocator, "{s}/hola", .{workspace});
    try client.upload(binary, staged, 0o700);
    // The cache is keyed by the local digest, so a short upload must never be promoted.
    const local_size = (try std.Io.Dir.cwd().statFile(global_io.io(), binary, .{})).size;
    const size_output = try checkedExec(client, try std.fmt.allocPrint(allocator, "wc -c < {s}", .{try ssh.shellQuote(allocator, staged)}));
    defer client.allocator.free(size_output);
    const remote_size = std.fmt.parseInt(u64, std.mem.trim(u8, size_output, " \r\n"), 10) catch return error.RemoteUploadIncomplete;
    if (remote_size != local_size) return error.RemoteUploadIncomplete;
    // Copy to a unique sibling before rename, since /tmp and HOME can be separate filesystems.
    const temporary = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ cached, std.fs.path.basename(workspace) });
    const promote = try checkedExec(client, try std.fmt.allocPrint(allocator, "umask 077; cp {s} {s} && chmod 700 {s} && mv -f {s} {s}", .{
        try ssh.shellQuote(allocator, staged),
        try ssh.shellQuote(allocator, temporary),
        try ssh.shellQuote(allocator, temporary),
        try ssh.shellQuote(allocator, temporary),
        quoted,
    }));
    client.allocator.free(promote);
    return cached;
}

fn bundleEntry(root: []const u8, script: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, script, root)) return error.ScriptOutsideBundle;
    const offset = if (std.mem.endsWith(u8, root, "/")) root.len else root.len + 1;
    if (script.len <= offset or (offset > root.len and script[root.len] != '/')) return error.ScriptOutsideBundle;
    return script[offset..];
}

fn validWorkspace(path: []const u8) bool {
    const prefix = "/tmp/hola-";
    if (!std.mem.startsWith(u8, path, prefix) or path.len != prefix.len + 12) return false;
    for (path[prefix.len..]) |byte| if (!std.ascii.isAlphanumeric(byte)) return false;
    return true;
}

fn validateBundle(allocator: std.mem.Allocator, path: []const u8) !void {
    const io = global_io.io();
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file and entry.kind != .directory) return error.UnsupportedBundleEntry;
    }
}

fn uploadBundle(allocator: std.mem.Allocator, client: *ssh.Client, local: []const u8, remote: []const u8) !void {
    const io = global_io.io();
    var dir = try std.Io.Dir.cwd().openDir(io, local, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        const destination = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ remote, entry.path });
        switch (entry.kind) {
            .directory => try client.mkdir(destination),
            .file => {
                const source = try std.fs.path.join(allocator, &.{ local, entry.path });
                const stat = try std.Io.Dir.cwd().statFile(io, source, .{ .follow_symlinks = false });
                if (stat.kind != .file) return error.UnsupportedBundleEntry;
                const executable = stat.permissions.toMode() & 0o111 != 0;
                try client.upload(source, destination, if (executable) 0o700 else 0o600);
            },
            else => return error.UnsupportedBundleEntry,
        }
    }
}

test "SSH targets support explicit users and bracketed IPv6" {
    const target = try Target.parse("deploy@[::1]");
    try std.testing.expectEqualStrings("deploy", target.user.?);
    try std.testing.expectEqualStrings("::1", target.host);
    try std.testing.expect((try Target.parse("example.com")).user == null);
    try std.testing.expectError(error.InvalidSshTarget, Target.parse("a@b@c"));
    try std.testing.expectError(error.InvalidSshTarget, Target.parse("@host"));
    try std.testing.expectError(error.InvalidSshTarget, Target.parse("-host"));
    try std.testing.expectError(error.InvalidSshTarget, Target.parse("host/path"));
}

test "bundle entry enforces directory boundaries" {
    try std.testing.expectEqualStrings("nested/main.rb", try bundleEntry("/work", "/work/nested/main.rb"));
    try std.testing.expectEqualStrings("main.rb", try bundleEntry("/", "/main.rb"));
    try std.testing.expectError(error.ScriptOutsideBundle, bundleEntry("/work", "/work-other/main.rb"));
    try std.testing.expectError(error.ScriptOutsideBundle, bundleEntry("/work", "/work"));
    try std.testing.expect(validWorkspace("/tmp/hola-abcdef123456"));
    try std.testing.expect(!validWorkspace("/tmp/hola-../../oops"));
}

test "release URL follows the published asset naming" {
    const url = try releaseUrl(std.testing.allocator, .{ .os = .linux, .arch = .x86_64 }, "nightly");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://github.com/ratazzi/hola/releases/download/nightly/hola-linux-x86_64", url);
}

test "remote platform must match binary format and architecture" {
    const linux = try Platform.parse("Linux\nx86_64\n");
    const mac = try Platform.parse("Darwin\narm64\n");
    var header = [_]u8{0} ** 64;
    @memcpy(header[0..6], "\x7fELF\x02\x01");
    std.mem.writeInt(u16, header[18..20], 62, .little);
    try std.testing.expect(linux.matchesBinary(&header));
    try std.testing.expect(!mac.matchesBinary(&header));
    std.mem.writeInt(u16, header[18..20], 183, .little);
    try std.testing.expect(!linux.matchesBinary(&header));
    @memcpy(header[0..4], "\xcf\xfa\xed\xfe");
    std.mem.writeInt(u32, header[4..8], 0x0100000c, .little);
    try std.testing.expect(mac.matchesBinary(&header));
    try std.testing.expectError(error.UnsupportedRemotePlatform, Platform.parse("FreeBSD\nx86_64\n"));
}
