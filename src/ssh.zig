//! Single-host SSH transport. Host verification always precedes authentication.
const std = @import("std");
const global_io = @import("global_io.zig");
const c = @cImport({
    @cInclude("libssh2.h");
    @cInclude("libssh2_sftp.h");
    @cInclude("sys/socket.h");
    @cInclude("netdb.h");
    @cInclude("poll.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});

const TIMEOUT_MS = 30_000;
const BUFFER_SIZE = 32 * 1024;
/// libssh2 pipelines SFTP writes only within one call, so throughput on a
/// high-latency link scales with the buffer handed to libssh2_sftp_write.
const UPLOAD_BUFFER_SIZE = 1024 * 1024;
const MAX_CAPTURE = 16 * 1024 * 1024;

pub const Options = struct {
    host: []const u8,
    user: []const u8,
    port: u16 = 22,
    /// An explicit key: used alone, nothing else is tried.
    identity: ?[]const u8 = null,
    /// Keys from ssh_config, tried after the agent; missing files are skipped.
    identity_files: []const []const u8 = &.{},
    /// Agent socket from ssh_config IdentityAgent; null means SSH_AUTH_SOCK.
    identity_agent: ?[]const u8 = null,
    agent_disabled: bool = false,
    known_hosts: []const u8,
};

pub const ExecResult = struct {
    exit_code: c_int,
    stdout: []u8,

    pub fn deinit(self: ExecResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    socket: c_int,
    session: *c.LIBSSH2_SESSION,
    sftp: ?*c.LIBSSH2_SFTP = null,

    pub fn connect(allocator: std.mem.Allocator, opts: Options) !Client {
        if (c.libssh2_init(0) != 0) return error.SshInitializationFailed;
        errdefer c.libssh2_exit();
        const socket = try connectSocket(allocator, opts.host, opts.port);
        errdefer _ = c.close(socket);
        const session = c.libssh2_session_init_ex(null, null, null, null) orelse return error.OutOfMemory;
        errdefer _ = c.libssh2_session_free(session);
        c.libssh2_session_set_blocking(session, 1);
        c.libssh2_session_set_timeout(session, TIMEOUT_MS);
        var client = Client{ .allocator = allocator, .socket = socket, .session = session };
        if (c.libssh2_session_handshake(session, socket) != 0) {
            std.debug.print("[ssh] Handshake with {s}:{d} failed\n", .{ opts.host, opts.port });
            return client.fail(error.SshHandshakeFailed);
        }
        try client.verifyHost(opts);
        try client.authenticate(opts);
        return client;
    }

    pub fn deinit(self: *Client) void {
        if (self.sftp) |sftp| _ = c.libssh2_sftp_shutdown(sftp);
        _ = c.libssh2_session_disconnect_ex(self.session, c.SSH_DISCONNECT_BY_APPLICATION, "done", "");
        _ = c.libssh2_session_free(self.session);
        _ = c.close(self.socket);
        c.libssh2_exit();
    }

    fn verifyHost(self: *Client, opts: Options) !void {
        const hosts = c.libssh2_knownhost_init(self.session) orelse return error.OutOfMemory;
        defer c.libssh2_knownhost_free(hosts);
        const path = try self.allocator.dupeZ(u8, opts.known_hosts);
        defer self.allocator.free(path);
        if (c.libssh2_knownhost_readfile(hosts, path, c.LIBSSH2_KNOWNHOST_FILE_OPENSSH) < 0) {
            std.debug.print("[ssh] Cannot read known_hosts file {s}\n", .{opts.known_hosts});
            return self.fail(error.KnownHostsUnreadable);
        }
        var key_len: usize = 0;
        var key_type: c_int = 0;
        const key = c.libssh2_session_hostkey(self.session, &key_len, &key_type) orelse return self.fail(error.SshHostKeyMissing);
        const key_mask: c_int = switch (key_type) {
            c.LIBSSH2_HOSTKEY_TYPE_RSA => c.LIBSSH2_KNOWNHOST_KEY_SSHRSA,
            c.LIBSSH2_HOSTKEY_TYPE_DSS => c.LIBSSH2_KNOWNHOST_KEY_SSHDSS,
            c.LIBSSH2_HOSTKEY_TYPE_ECDSA_256 => c.LIBSSH2_KNOWNHOST_KEY_ECDSA_256,
            c.LIBSSH2_HOSTKEY_TYPE_ECDSA_384 => c.LIBSSH2_KNOWNHOST_KEY_ECDSA_384,
            c.LIBSSH2_HOSTKEY_TYPE_ECDSA_521 => c.LIBSSH2_KNOWNHOST_KEY_ECDSA_521,
            c.LIBSSH2_HOSTKEY_TYPE_ED25519 => c.LIBSSH2_KNOWNHOST_KEY_ED25519,
            else => {
                std.debug.print("[ssh] Server {s}:{d} offered host key type {d}, which Hola cannot verify\n", .{ opts.host, opts.port, key_type });
                return error.UnsupportedHostKey;
            },
        };
        const host = try self.allocator.dupeZ(u8, opts.host);
        defer self.allocator.free(host);
        const check = c.libssh2_knownhost_checkp(hosts, host, opts.port, key, key_len, c.LIBSSH2_KNOWNHOST_TYPE_PLAIN | c.LIBSSH2_KNOWNHOST_KEYENC_RAW | key_mask, null);
        switch (check) {
            c.LIBSSH2_KNOWNHOST_CHECK_MATCH => {},
            c.LIBSSH2_KNOWNHOST_CHECK_MISMATCH => {
                std.debug.print("[ssh] Host key of {s}:{d} does not match the entry in {s}; verify the server before removing the stale entry\n", .{ opts.host, opts.port, opts.known_hosts });
                return error.HostKeyMismatch;
            },
            c.LIBSSH2_KNOWNHOST_CHECK_NOTFOUND => {
                std.debug.print("[ssh] No entry for {s}:{d} in {s}; connect once with OpenSSH to record the host key\n", .{ opts.host, opts.port, opts.known_hosts });
                return error.UnknownHostKey;
            },
            else => return self.fail(error.HostKeyCheckFailed),
        }
    }

    fn authenticate(self: *Client, opts: Options) !void {
        const user = try self.allocator.dupeZ(u8, opts.user);
        defer self.allocator.free(user);
        // Each method records why it failed; the notes are shown only if none succeeds.
        var notes: std.ArrayList(u8) = .empty;
        defer notes.deinit(self.allocator);
        var last_error: anyerror = error.SshAgentDisabled;
        if (opts.identity) |identity| {
            if (self.authenticateWithKey(user, identity, opts, &notes)) |_| return else |err| last_error = err;
        } else {
            // OpenSSH order: agent identities first, then configured key files.
            if (!opts.agent_disabled) {
                if (self.authenticateWithAgent(user, opts, &notes)) |_| return else |err| last_error = err;
            }
            var tried_file = false;
            for (opts.identity_files) |file| {
                std.Io.Dir.cwd().access(global_io.io(), file, .{}) catch continue;
                tried_file = true;
                if (self.authenticateWithKey(user, file, opts, &notes)) |_| return else |err| last_error = err;
            }
            if (opts.agent_disabled and !tried_file)
                try notes.appendSlice(self.allocator, "[ssh] ssh_config disables the agent and names no usable IdentityFile; pass --identity <key>\n");
        }
        std.debug.print("{s}", .{notes.items});
        return last_error;
    }

    fn authenticateWithKey(self: *Client, user: [:0]const u8, identity: []const u8, opts: Options, notes: *std.ArrayList(u8)) !void {
        const path = try self.allocator.dupeZ(u8, identity);
        defer self.allocator.free(path);
        if (c.libssh2_userauth_publickey_fromfile_ex(self.session, user, @intCast(user.len), null, path, null) != 0) {
            try notes.print(self.allocator, "[ssh] Key {s} was rejected for {s}@{s}: {s}; encrypted keys must be loaded into ssh-agent instead\n", .{ identity, opts.user, opts.host, self.lastErrorMessage() });
            return error.SshKeyAuthenticationFailed;
        }
    }

    fn authenticateWithAgent(self: *Client, user: [:0]const u8, opts: Options, notes: *std.ArrayList(u8)) !void {
        const agent = c.libssh2_agent_init(self.session) orelse return error.OutOfMemory;
        defer c.libssh2_agent_free(agent);
        const socket_path: ?[:0]u8 = if (opts.identity_agent) |path| try self.allocator.dupeZ(u8, path) else null;
        defer if (socket_path) |path| self.allocator.free(path);
        if (socket_path) |path| c.libssh2_agent_set_identity_path(agent, path);
        if (c.libssh2_agent_connect(agent) != 0) {
            try notes.print(self.allocator, "[ssh] Cannot reach ssh-agent at {s}: {s}; pass --identity <key> or start an agent\n", .{ opts.identity_agent orelse global_io.getEnv("SSH_AUTH_SOCK") orelse "unset SSH_AUTH_SOCK", self.lastErrorMessage() });
            return error.SshAgentUnavailable;
        }
        defer _ = c.libssh2_agent_disconnect(agent);
        if (c.libssh2_agent_list_identities(agent) != 0) {
            try notes.print(self.allocator, "[ssh] ssh-agent refused to list identities: {s}\n", .{self.lastErrorMessage()});
            return error.SshAgentUnavailable;
        }
        var tried: std.ArrayList(u8) = .empty;
        defer tried.deinit(self.allocator);
        var previous: ?*c.struct_libssh2_agent_publickey = null;
        while (true) {
            var identity: ?*c.struct_libssh2_agent_publickey = null;
            const rc = c.libssh2_agent_get_identity(agent, &identity, previous);
            if (rc == 1) break;
            if (rc != 0) {
                try notes.print(self.allocator, "[ssh] ssh-agent failed while listing identities: {s}\n", .{self.lastErrorMessage()});
                return error.SshAgentUnavailable;
            }
            if (c.libssh2_agent_userauth(agent, user, identity) == 0) return;
            const comment: [*c]const u8 = identity.?.comment;
            try tried.print(self.allocator, "{s}{s}", .{ if (tried.items.len == 0) "" else ", ", if (comment != null) std.mem.span(comment) else "(no comment)" });
            previous = identity;
        }
        if (tried.items.len == 0) {
            try notes.appendSlice(self.allocator, "[ssh] ssh-agent holds no identities; run ssh-add <key> or pass --identity <key>\n");
        } else {
            try notes.print(self.allocator, "[ssh] {s}@{s} rejected every ssh-agent identity ({s}); check the user name or pass --identity <key>\n", .{ opts.user, opts.host, tried.items });
        }
        return error.SshAgentAuthenticationFailed;
    }

    /// Pump stdin and both output streams together to avoid SSH window deadlocks.
    /// There is no execution timeout: a provision may legitimately be silent for hours.
    pub fn exec(self: *Client, command: []const u8, input: []const u8, stream: bool) !ExecResult {
        const channel = c.libssh2_channel_open_ex(self.session, "session", 7, c.LIBSSH2_CHANNEL_WINDOW_DEFAULT, c.LIBSSH2_CHANNEL_PACKET_DEFAULT, null, 0) orelse return error.SshChannelFailed;
        defer _ = c.libssh2_channel_free(channel);
        if (c.libssh2_channel_process_startup(channel, "exec", 4, command.ptr, @intCast(command.len)) != 0)
            return error.SshExecFailed;
        c.libssh2_session_set_blocking(self.session, 0);
        defer c.libssh2_session_set_blocking(self.session, 1);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);
        var written: usize = 0;
        var sent_eof = false;
        var buffer: [BUFFER_SIZE]u8 = undefined;
        while (true) {
            var progress = false;
            if (written < input.len) {
                const count = c.libssh2_channel_write_ex(channel, 0, input[written..].ptr, input.len - written);
                if (count < 0 and count != c.LIBSSH2_ERROR_EAGAIN) return error.SshConnectionLost;
                if (count > 0) {
                    written += @intCast(count);
                    progress = true;
                }
            } else if (!sent_eof) {
                const rc = c.libssh2_channel_send_eof(channel);
                if (rc != 0 and rc != c.LIBSSH2_ERROR_EAGAIN) return error.SshConnectionLost;
                sent_eof = rc == 0;
            }
            for ([_]c_int{ 0, c.SSH_EXTENDED_DATA_STDERR }) |stream_id| {
                const count = c.libssh2_channel_read_ex(channel, stream_id, &buffer, buffer.len);
                if (count < 0 and count != c.LIBSSH2_ERROR_EAGAIN) return error.SshConnectionLost;
                if (count > 0) {
                    progress = true;
                    const bytes = buffer[0..@intCast(count)];
                    if (stream or stream_id != 0) {
                        const file = if (stream_id == 0) std.Io.File.stdout() else std.Io.File.stderr();
                        try file.writeStreamingAll(global_io.io(), bytes);
                    } else {
                        if (output.items.len + bytes.len > MAX_CAPTURE) return error.SshOutputTooLarge;
                        try output.appendSlice(self.allocator, bytes);
                    }
                }
            }
            if (!progress and c.libssh2_channel_eof(channel) != 0) break;
            if (!progress) try self.waitSocket();
        }
        while (true) {
            const rc = c.libssh2_channel_close(channel);
            if (rc == 0) break;
            if (rc != c.LIBSSH2_ERROR_EAGAIN) return error.SshConnectionLost;
            try self.waitSocket();
        }
        var signal: [*c]u8 = null;
        if (c.libssh2_channel_get_exit_signal(channel, &signal, null, null, null, null, null) != 0)
            return error.SshConnectionLost;
        if (signal != null) {
            c.libssh2_free(self.session, signal);
            return error.RemoteProcessSignalled;
        }
        return .{ .exit_code = c.libssh2_channel_get_exit_status(channel), .stdout = try output.toOwnedSlice(self.allocator) };
    }

    fn waitSocket(self: *Client) !void {
        const directions = c.libssh2_session_block_directions(self.session);
        var fd = c.struct_pollfd{ .fd = self.socket, .events = 0, .revents = 0 };
        if (directions & c.LIBSSH2_SESSION_BLOCK_INBOUND != 0) fd.events |= c.POLLIN;
        if (directions & c.LIBSSH2_SESSION_BLOCK_OUTBOUND != 0) fd.events |= c.POLLOUT;
        if (fd.events == 0) fd.events = c.POLLIN;
        const rc = c.poll(&fd, 1, 1000);
        if (rc < 0) {
            if (std.posix.errno(rc) == .INTR) return;
            return error.SshConnectionLost;
        }
        if (fd.revents & (c.POLLERR | c.POLLNVAL) != 0) return error.SshConnectionLost;
        // HUP may have buffered data; let libssh2 drain it and report EOF/error.
    }

    /// libssh2's description of the most recent failure on this session.
    fn lastErrorMessage(self: *Client) []const u8 {
        var message: [*c]u8 = null;
        var length: c_int = 0;
        _ = c.libssh2_session_last_error(self.session, &message, &length, 0);
        if (message == null or length <= 0) return "no detail from libssh2";
        return message[0..@intCast(length)];
    }

    /// Report libssh2's own description of the last failure before returning a coarse error.
    fn fail(self: *Client, comptime err: anyerror) anyerror {
        std.debug.print("[ssh] {s}: {s}\n", .{ @errorName(err), self.lastErrorMessage() });
        return err;
    }

    fn getSftp(self: *Client) !*c.LIBSSH2_SFTP {
        if (self.sftp) |sftp| return sftp;
        self.sftp = c.libssh2_sftp_init(self.session) orelse return error.SftpInitializationFailed;
        return self.sftp.?;
    }

    pub fn mkdir(self: *Client, path: []const u8) !void {
        if (c.libssh2_sftp_mkdir_ex(try self.getSftp(), path.ptr, @intCast(path.len), 0o700) != 0)
            return self.fail(error.SftpMkdirFailed);
    }

    pub fn upload(self: *Client, local_path: []const u8, remote_path: []const u8, mode: c_long) !void {
        const file = try std.Io.Dir.cwd().openFile(global_io.io(), local_path, .{});
        defer file.close(global_io.io());
        const handle = c.libssh2_sftp_open_ex(try self.getSftp(), remote_path.ptr, @intCast(remote_path.len), c.LIBSSH2_FXF_WRITE | c.LIBSSH2_FXF_CREAT | c.LIBSSH2_FXF_EXCL, mode, c.LIBSSH2_SFTP_OPENFILE) orelse return self.fail(error.SftpOpenFailed);
        var closed = false;
        defer if (!closed) {
            _ = c.libssh2_sftp_close_handle(handle);
        };
        const buffer = try self.allocator.alloc(u8, UPLOAD_BUFFER_SIZE);
        defer self.allocator.free(buffer);
        while (true) {
            const count = file.readStreaming(global_io.io(), &.{buffer}) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            if (count == 0) break;
            var offset: usize = 0;
            while (offset < count) {
                const sent = c.libssh2_sftp_write(handle, buffer[offset..].ptr, count - offset);
                if (sent <= 0) return self.fail(error.SftpWriteFailed);
                offset += @intCast(sent);
            }
        }
        const rc = c.libssh2_sftp_close_handle(handle);
        closed = true;
        if (rc != 0) return self.fail(error.SftpWriteFailed);
    }
};

fn connectSocket(allocator: std.mem.Allocator, host: []const u8, port: u16) !c_int {
    const name = try allocator.dupeZ(u8, host);
    defer allocator.free(name);
    const service = try std.fmt.allocPrintSentinel(allocator, "{d}", .{port}, 0);
    defer allocator.free(service);
    var hints = std.mem.zeroes(c.struct_addrinfo);
    hints.ai_socktype = c.SOCK_STREAM;
    hints.ai_family = c.AF_UNSPEC;
    var addresses: ?*c.struct_addrinfo = null;
    const resolved = c.getaddrinfo(name, service, &hints, &addresses);
    if (resolved != 0) {
        std.debug.print("[ssh] Cannot resolve {s}: {s}\n", .{ host, std.mem.span(c.gai_strerror(resolved)) });
        return error.SshHostNotFound;
    }
    defer c.freeaddrinfo(addresses);
    var reason: []const u8 = "no usable address";
    var next = addresses;
    while (next) |address| : (next = address.ai_next) {
        const socket = c.socket(address.ai_family, address.ai_socktype, address.ai_protocol);
        if (socket < 0) continue;
        var connected = false;
        defer if (!connected) {
            _ = c.close(socket);
        };
        const flags = c.fcntl(socket, c.F_GETFL, @as(c_int, 0));
        if (flags < 0 or c.fcntl(socket, c.F_SETFL, flags | c.O_NONBLOCK) < 0) continue;
        const rc = c.connect(socket, address.ai_addr, address.ai_addrlen);
        if (rc != 0) {
            const err = std.posix.errno(rc);
            if (err != .INPROGRESS) {
                reason = @tagName(err);
                continue;
            }
            var poll_fd = c.struct_pollfd{ .fd = socket, .events = c.POLLOUT, .revents = 0 };
            if (c.poll(&poll_fd, 1, TIMEOUT_MS) <= 0) {
                reason = "connection timed out";
                continue;
            }
            var socket_error: c_int = 0;
            var size: c.socklen_t = @sizeOf(c_int);
            if (c.getsockopt(socket, c.SOL_SOCKET, c.SO_ERROR, &socket_error, &size) != 0 or socket_error != 0) {
                reason = @tagName(@as(std.posix.E, @enumFromInt(socket_error)));
                continue;
            }
        }
        if (c.fcntl(socket, c.F_SETFL, flags) < 0) continue;
        connected = true;
        return socket;
    }
    std.debug.print("[ssh] Cannot connect to {s}:{d}: {s}\n", .{ host, port, reason });
    return error.SshConnectionFailed;
}

/// Quote one POSIX shell argument. Never interpolate user input unquoted.
pub fn shellQuote(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidShellArgument;
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);
    try result.append(allocator, '\'');
    for (value) |byte| {
        if (byte == '\'') {
            try result.appendSlice(allocator, "'\\''");
        } else try result.append(allocator, byte);
    }
    try result.append(allocator, '\'');
    return result.toOwnedSlice(allocator);
}

test "shellQuote keeps metacharacters and apostrophes inside one argument" {
    const quoted = try shellQuote(std.testing.allocator, "a'b;$(touch nope)\n");
    defer std.testing.allocator.free(quoted);
    try std.testing.expectEqualStrings("'a'\\''b;$(touch nope)\n'", quoted);
    try std.testing.expectError(error.InvalidShellArgument, shellQuote(std.testing.allocator, "a\x00b"));
}
