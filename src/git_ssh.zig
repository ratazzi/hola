//! Apply ~/.ssh/config to git SSH remotes. libgit2 drives libssh2 directly and
//! never reads the file, so aliases, users, ports and keys are resolved here: the
//! rewritten URL and the credential candidates are what libgit2 gets to see.
const std = @import("std");
const ssh_config = @import("ssh_config.zig");
const global_io = @import("global_io.zig");
const git_credentials = @import("git_credentials.zig");
const libc = @cImport(@cInclude("stdlib.h"));

pub const Credentials = git_credentials.Credentials;
const AGENT_VARIABLE = "SSH_AUTH_SOCK";

/// Candidates for a resolved remote: an explicit key alone, otherwise the agent
/// (unless `IdentityAgent none`) and then the configured IdentityFile entries.
pub fn credentialsFromConfig(config: ssh_config.HostConfig, explicit_key: ?[:0]const u8) Credentials {
    return .{
        .explicit_key = explicit_key,
        .agent_allowed = !config.agent_disabled,
        .identity_files = config.identity_files,
        .home = global_io.getEnv("HOME"),
    };
}

/// The pieces of an SSH remote URL as git accepts them.
pub const Parsed = struct {
    user: ?[]const u8,
    /// The host as typed, brackets stripped; this is the ssh_config alias.
    host: []const u8,
    port: ?u16,
    /// For `ssh://` URLs the path including its leading slash; for scp form the text after the colon.
    path: []const u8,
    scp_form: bool,
};

/// Recognise `ssh://`, `git+ssh://`, `ssh+git://` and scp-style `[user@]host:path`.
/// Anything else (https, file, local paths) is not an SSH remote and yields null.
pub fn parseUrl(url: []const u8) ?Parsed {
    inline for (.{ "ssh://", "git+ssh://", "ssh+git://" }) |scheme| {
        if (std.ascii.startsWithIgnoreCase(url, scheme)) return parseAuthority(url[scheme.len..], false);
    }
    if (std.mem.indexOf(u8, url, "://") != null) return null;
    const first_colon = std.mem.indexOfScalar(u8, url, ':') orelse return null;
    const bracket = std.mem.indexOfScalar(u8, url, '[');
    // A bracketed IPv6 host contains colons of its own; the separator follows the bracket.
    const colon = if (bracket != null and bracket.? < first_colon) blk: {
        const close = std.mem.indexOfScalar(u8, url, ']') orelse return null;
        if (close + 1 >= url.len or url[close + 1] != ':') return null;
        break :blk close + 1;
    } else first_colon;
    const slash = std.mem.indexOfScalar(u8, url, '/');
    if (slash != null and slash.? < colon) return null;
    if (colon + 1 >= url.len) return null;
    var parsed = parseAuthority(url[0..colon], true) orelse return null;
    parsed.path = url[colon + 1 ..];
    return parsed;
}

fn parseAuthority(text: []const u8, scp_form: bool) ?Parsed {
    const end = if (scp_form) text.len else std.mem.indexOfScalar(u8, text, '/') orelse text.len;
    var authority = text[0..end];
    const user: ?[]const u8 = if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| blk: {
        defer authority = authority[at + 1 ..];
        break :blk authority[0..at];
    } else null;
    if (user != null and user.?.len == 0) return null;
    var host = authority;
    var port: ?u16 = null;
    if (host.len > 0 and host[0] == '[') {
        const close = std.mem.indexOfScalar(u8, host, ']') orelse return null;
        const rest = host[close + 1 ..];
        host = host[1..close];
        if (rest.len > 0) {
            if (rest[0] != ':') return null;
            port = std.fmt.parseInt(u16, rest[1..], 10) catch return null;
        }
    } else if (!scp_form) {
        if (std.mem.lastIndexOfScalar(u8, host, ':')) |colon| {
            port = std.fmt.parseInt(u16, host[colon + 1 ..], 10) catch return null;
            host = host[0..colon];
        }
    }
    if (host.len == 0 or port == 0) return null;
    return .{ .user = user, .host = host, .port = port, .path = text[end..], .scp_form = scp_form };
}

/// An SSH remote with ssh_config applied.
pub const Remote = struct {
    /// The URL to hand to libgit2: alias, user and port resolved.
    url: []const u8,
    config: ssh_config.HostConfig,

    pub fn deinit(self: *Remote, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        self.config.deinit(allocator);
    }
};

/// Resolve `url` through ~/.ssh/config; null when it is not an SSH remote.
pub fn resolve(allocator: std.mem.Allocator, io: std.Io, url: []const u8) !?Remote {
    const home = global_io.getEnv("HOME") orelse return error.HomeNotFound;
    const config_path = try std.fs.path.join(allocator, &.{ home, ".ssh", "config" });
    defer allocator.free(config_path);
    const local_user = global_io.getEnv("USER") orelse global_io.getEnv("LOGNAME") orelse "";
    return resolveWith(allocator, io, url, config_path, .{ .home = home, .local_user = local_user });
}

pub fn resolveWith(allocator: std.mem.Allocator, io: std.Io, url: []const u8, config_path: []const u8, env: ssh_config.Environment) !?Remote {
    const parsed = parseUrl(url) orelse return null;
    var config = try ssh_config.load(allocator, io, config_path, parsed.host, env);
    errdefer config.deinit(allocator);
    const rewritten = try rewriteUrl(allocator, parsed, config);
    return .{ .url = rewritten, .config = config };
}

/// Command-line-style precedence: what the URL states wins over the config.
fn rewriteUrl(allocator: std.mem.Allocator, parsed: Parsed, config: ssh_config.HostConfig) ![]const u8 {
    const user = parsed.user orelse config.user;
    const host = config.host_name orelse parsed.host;
    const port = parsed.port orelse config.port;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    if (parsed.scp_form and port == null) {
        // scp form cannot carry a port; otherwise keep the user's spelling.
        if (user) |name| try out.print(allocator, "{s}@", .{name});
        try out.print(allocator, "{s}:{s}", .{ host, parsed.path });
        return out.toOwnedSlice(allocator);
    }
    try out.appendSlice(allocator, "ssh://");
    if (user) |name| try out.print(allocator, "{s}@", .{name});
    if (std.mem.indexOfScalar(u8, host, ':') != null) try out.print(allocator, "[{s}]", .{host}) else try out.appendSlice(allocator, host);
    if (port) |number| try out.print(allocator, ":{d}", .{number});
    if (!parsed.scp_form) {
        try out.appendSlice(allocator, parsed.path);
    } else if (std.mem.startsWith(u8, parsed.path, "/")) {
        try out.appendSlice(allocator, parsed.path);
    } else {
        // scp paths are relative to the login home; git spells that /~/ in ssh:// URLs.
        try out.print(allocator, "/~/{s}", .{parsed.path});
    }
    return out.toOwnedSlice(allocator);
}

/// libgit2 exposes no agent socket setting, so IdentityAgent is applied by pointing
/// SSH_AUTH_SOCK at it for the duration of the operation. `IdentityAgent none`
/// clears the variable so the agent candidate fails over to key files.
pub const AgentOverride = struct {
    allocator: std.mem.Allocator,
    previous: ?[:0]u8 = null,
    active: bool = false,

    pub fn apply(allocator: std.mem.Allocator, config: ssh_config.HostConfig) !AgentOverride {
        var override = AgentOverride{ .allocator = allocator };
        if (config.identity_agent == null and !config.agent_disabled) return override;
        if (libc.getenv(AGENT_VARIABLE)) |current| override.previous = try allocator.dupeZ(u8, std.mem.span(current));
        errdefer if (override.previous) |value| allocator.free(value);
        if (config.identity_agent) |socket| {
            const value = try allocator.dupeZ(u8, socket);
            defer allocator.free(value);
            if (libc.setenv(AGENT_VARIABLE, value, 1) != 0) return error.EnvironmentUpdateFailed;
        } else {
            _ = libc.unsetenv(AGENT_VARIABLE);
        }
        override.active = true;
        return override;
    }

    pub fn restore(self: *AgentOverride) void {
        if (self.active) {
            if (self.previous) |value| {
                _ = libc.setenv(AGENT_VARIABLE, value, 1);
            } else {
                _ = libc.unsetenv(AGENT_VARIABLE);
            }
        }
        if (self.previous) |value| self.allocator.free(value);
        self.* = .{ .allocator = self.allocator };
    }
};

const testing = std.testing;

fn expectParsed(url: []const u8, user: ?[]const u8, host: []const u8, port: ?u16, path: []const u8, scp_form: bool) !void {
    const parsed = parseUrl(url) orelse return error.TestUnexpectedResult;
    if (user) |name| try testing.expectEqualStrings(name, parsed.user.?) else try testing.expect(parsed.user == null);
    try testing.expectEqualStrings(host, parsed.host);
    try testing.expectEqual(port, parsed.port);
    try testing.expectEqualStrings(path, parsed.path);
    try testing.expectEqual(scp_form, parsed.scp_form);
}

test "parseUrl recognises the SSH forms git accepts" {
    try expectParsed("ssh://git@github.com/org/repo.git", "git", "github.com", null, "/org/repo.git", false);
    try expectParsed("ssh://deploy@[::1]:2222/srv/repo", "deploy", "::1", 2222, "/srv/repo", false);
    try expectParsed("git+ssh://host:22/x", null, "host", 22, "/x", false);
    try expectParsed("SSH://host", null, "host", null, "", false);
    try expectParsed("git@github.com:org/repo.git", "git", "github.com", null, "org/repo.git", true);
    try expectParsed("alias:/abs/path.git", null, "alias", null, "/abs/path.git", true);
    try expectParsed("[::1]:repo", null, "::1", null, "repo", true);
    try expectParsed("git@[::1]:repo", "git", "::1", null, "repo", true);
}

test "parseUrl rejects everything that is not an SSH remote" {
    try testing.expect(parseUrl("https://github.com/org/repo.git") == null);
    try testing.expect(parseUrl("file:///tmp/repo") == null);
    try testing.expect(parseUrl("/tmp/repo") == null);
    try testing.expect(parseUrl("./dir:with-colon") == null);
    try testing.expect(parseUrl("host:") == null);
    try testing.expect(parseUrl("@host:path") == null);
    try testing.expect(parseUrl("ssh://host:notaport/x") == null);
    try testing.expect(parseUrl("ssh://host:0/x") == null);
    try testing.expect(parseUrl("ssh://[::1/x") == null);
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    home: [:0]const u8,
    config_path: []const u8,

    fn init(config: []const u8) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const home = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        errdefer testing.allocator.free(home);
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "config", .data = config });
        const config_path = try std.fs.path.join(testing.allocator, &.{ home, "config" });
        return .{ .tmp = tmp, .home = home, .config_path = config_path };
    }

    fn deinit(self: *Fixture) void {
        testing.allocator.free(self.config_path);
        testing.allocator.free(self.home);
        self.tmp.cleanup();
    }

    fn resolve(self: *Fixture, url: []const u8) !?Remote {
        return resolveWith(testing.allocator, testing.io, url, self.config_path, .{ .home = self.home, .local_user = "me" });
    }
};

test "resolve rewrites aliases and carries the config's keys" {
    var fixture = try Fixture.init(
        \\Host work
        \\    HostName git.internal
        \\    User deploy
        \\    IdentityFile ~/work.pem
        \\Host ported
        \\    HostName git.internal
        \\    Port 2222
        \\Host six
        \\    HostName ::1
        \\    Port 2222
        \\Host agentless
        \\    IdentityAgent none
    );
    defer fixture.deinit();

    var scp = (try fixture.resolve("work:org/repo.git")).?;
    defer scp.deinit(testing.allocator);
    try testing.expectEqualStrings("deploy@git.internal:org/repo.git", scp.url);
    const key = try std.fs.path.join(testing.allocator, &.{ fixture.home, "work.pem" });
    defer testing.allocator.free(key);
    try testing.expectEqual(@as(usize, 1), scp.config.identity_files.len);
    try testing.expectEqualStrings(key, scp.config.identity_files[0]);

    var url_user = (try fixture.resolve("ssh://admin@work/srv/repo")).?;
    defer url_user.deinit(testing.allocator);
    try testing.expectEqualStrings("ssh://admin@git.internal/srv/repo", url_user.url);

    var relative = (try fixture.resolve("ported:org/repo.git")).?;
    defer relative.deinit(testing.allocator);
    try testing.expectEqualStrings("ssh://git.internal:2222/~/org/repo.git", relative.url);

    var absolute = (try fixture.resolve("git@ported:/srv/repo.git")).?;
    defer absolute.deinit(testing.allocator);
    try testing.expectEqualStrings("ssh://git@git.internal:2222/srv/repo.git", absolute.url);

    var url_port = (try fixture.resolve("ssh://ported:2200/srv/repo")).?;
    defer url_port.deinit(testing.allocator);
    try testing.expectEqualStrings("ssh://git.internal:2200/srv/repo", url_port.url);

    var six = (try fixture.resolve("six:repo")).?;
    defer six.deinit(testing.allocator);
    try testing.expectEqualStrings("ssh://[::1]:2222/~/repo", six.url);

    var agentless = (try fixture.resolve("git@agentless:repo")).?;
    defer agentless.deinit(testing.allocator);
    try testing.expectEqualStrings("git@agentless:repo", agentless.url);
    try testing.expect(agentless.config.agent_disabled);

    var untouched = (try fixture.resolve("git@github.com:org/repo.git")).?;
    defer untouched.deinit(testing.allocator);
    try testing.expectEqualStrings("git@github.com:org/repo.git", untouched.url);
    try testing.expect(try fixture.resolve("https://github.com/org/repo.git") == null);
}

test "credentialsFromConfig maps IdentityAgent none and IdentityFile onto the candidates" {
    const config = ssh_config.HostConfig{ .agent_disabled = true, .identity_files = &.{"/configured.pem"} };
    const credentials = credentialsFromConfig(config, null);
    try testing.expect(!credentials.agent_allowed);
    try testing.expectEqual(@as(usize, 1), credentials.identity_files.len);
    try testing.expectEqualStrings("/explicit.pem", credentialsFromConfig(.{}, "/explicit.pem").explicit_key.?);
    try testing.expect(credentialsFromConfig(.{}, null).agent_allowed);
}

test "AgentOverride points SSH_AUTH_SOCK at the configured agent and restores it" {
    const original: ?[:0]u8 = if (libc.getenv(AGENT_VARIABLE)) |value| try testing.allocator.dupeZ(u8, std.mem.span(value)) else null;
    defer if (original) |value| testing.allocator.free(value);
    defer if (original) |value| {
        _ = libc.setenv(AGENT_VARIABLE, value, 1);
    } else {
        _ = libc.unsetenv(AGENT_VARIABLE);
    };

    _ = libc.setenv(AGENT_VARIABLE, "/before.sock", 1);
    var untouched = try AgentOverride.apply(testing.allocator, .{});
    try testing.expectEqualStrings("/before.sock", std.mem.span(libc.getenv(AGENT_VARIABLE).?));
    untouched.restore();

    var pointed = try AgentOverride.apply(testing.allocator, .{ .identity_agent = "/per-host.sock" });
    try testing.expectEqualStrings("/per-host.sock", std.mem.span(libc.getenv(AGENT_VARIABLE).?));
    pointed.restore();
    try testing.expectEqualStrings("/before.sock", std.mem.span(libc.getenv(AGENT_VARIABLE).?));

    var disabled = try AgentOverride.apply(testing.allocator, .{ .agent_disabled = true });
    try testing.expect(libc.getenv(AGENT_VARIABLE) == null);
    disabled.restore();
    try testing.expectEqualStrings("/before.sock", std.mem.span(libc.getenv(AGENT_VARIABLE).?));

    _ = libc.unsetenv(AGENT_VARIABLE);
    var from_unset = try AgentOverride.apply(testing.allocator, .{ .identity_agent = "/per-host.sock" });
    from_unset.restore();
    try testing.expect(libc.getenv(AGENT_VARIABLE) == null);
}
