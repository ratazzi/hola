//! Reader for the client side of ssh_config(5), modelled on Net::SSH::Config and
//! OpenSSH readconf.c: the first obtained value wins, IdentityFile accumulates and
//! Include is expanded in place. Only directives Hola can honour are kept.
const std = @import("std");
const glob = @import("glob.zig");

pub const MAX_INCLUDE_DEPTH = 16;
const DEFAULT_PORT = 22;

/// Values normally taken from the process environment, injectable for tests.
pub const Environment = struct {
    home: []const u8,
    local_user: []const u8,
};

pub const HostConfig = struct {
    host_name: ?[]const u8 = null,
    user: ?[]const u8 = null,
    port: ?u16 = null,
    /// Expanded paths in file order; entries equal to `none` are dropped.
    identity_files: []const []const u8 = &.{},
    /// Expanded agent socket path; null means the default agent.
    identity_agent: ?[]const u8 = null,
    /// `IdentityAgent none`.
    agent_disabled: bool = false,
    identities_only: bool = false,
    user_known_hosts_file: ?[]const u8 = null,
    /// Recorded so callers can refuse it clearly; Hola does not implement jumps.
    proxy_jump: ?[]const u8 = null,

    pub fn deinit(self: *HostConfig, allocator: std.mem.Allocator) void {
        inline for (.{ "host_name", "user", "identity_agent", "user_known_hosts_file", "proxy_jump" }) |name| {
            if (@field(self, name)) |value| allocator.free(value);
        }
        for (self.identity_files) |file| allocator.free(file);
        allocator.free(self.identity_files);
        self.* = .{};
    }
};

/// Resolve `alias` (the host as typed) against the config at `path`.
/// A missing file yields the empty config; other read or syntax errors are returned.
pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8, alias: []const u8, env: Environment) !HostConfig {
    var parser = Parser{ .allocator = allocator, .io = io, .env = env, .alias = alias };
    defer parser.deinit();
    var active = true;
    parser.parseFile(path, &active, 0) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    return parser.finish();
}

const Parser = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    env: Environment,
    alias: []const u8,
    host_name: ?[]const u8 = null,
    user: ?[]const u8 = null,
    port: ?u16 = null,
    identity_files: std.ArrayList([]const u8) = .empty,
    identity_agent: ?[]const u8 = null,
    seen_identity_agent: bool = false,
    agent_disabled: bool = false,
    identities_only: ?bool = null,
    user_known_hosts_file: ?[]const u8 = null,
    proxy_jump: ?[]const u8 = null,

    fn deinit(self: *Parser) void {
        inline for (.{ "host_name", "user", "identity_agent", "user_known_hosts_file", "proxy_jump" }) |name| {
            if (@field(self, name)) |value| self.allocator.free(value);
        }
        for (self.identity_files.items) |file| self.allocator.free(file);
        self.identity_files.deinit(self.allocator);
    }

    // Recursive through include(), so the error set cannot be inferred.
    fn parseFile(self: *Parser, path: []const u8, active: *bool, depth: usize) anyerror!void {
        if (depth > MAX_INCLUDE_DEPTH) return error.SshConfigIncludeTooDeep;
        const source = try std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .unlimited);
        defer self.allocator.free(source);
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const split = splitKeyword(line);
            var keyword_buf: [32]u8 = undefined;
            if (split.keyword.len > keyword_buf.len) continue;
            const keyword = std.ascii.lowerString(&keyword_buf, split.keyword);
            var args = try tokenize(self.allocator, split.rest);
            defer freeTokens(self.allocator, &args);
            if (std.mem.eql(u8, keyword, "host")) {
                active.* = matchPatternList(args.items, self.alias);
            } else if (std.mem.eql(u8, keyword, "match")) {
                active.* = self.evalMatch(args.items);
            } else if (std.mem.eql(u8, keyword, "include")) {
                for (args.items) |pattern| try self.include(pattern, active, depth);
            } else if (active.*) {
                try self.apply(keyword, args.items);
            }
        }
    }

    fn include(self: *Parser, pattern: []const u8, active: *bool, depth: usize) !void {
        const expanded = try self.expandPath(pattern, true);
        defer self.allocator.free(expanded);
        var matches = try glob.expand(self.allocator, self.io, expanded);
        defer glob.freeMatches(self.allocator, &matches);
        for (matches.items) |file| {
            const stat = std.Io.Dir.cwd().statFile(self.io, file, .{}) catch continue;
            if (stat.kind != .file) continue;
            try self.parseFile(file, active, depth + 1);
        }
    }

    fn evalMatch(self: *Parser, args: []const []const u8) bool {
        if (args.len == 1 and std.ascii.eqlIgnoreCase(args[0], "all")) return true;
        var index: usize = 0;
        while (index < args.len) : (index += 2) {
            var criterion = args[index];
            const negate = criterion.len > 0 and criterion[0] == '!';
            if (negate) criterion = criterion[1..];
            if (index + 1 >= args.len) return false;
            const patterns = args[index + 1];
            const matched = if (std.ascii.eqlIgnoreCase(criterion, "host"))
                matchPattern(patterns, self.host_name orelse self.alias)
            else if (std.ascii.eqlIgnoreCase(criterion, "originalhost"))
                matchPattern(patterns, self.alias)
            else if (std.ascii.eqlIgnoreCase(criterion, "user"))
                matchPattern(patterns, self.user orelse self.env.local_user)
            else if (std.ascii.eqlIgnoreCase(criterion, "localuser"))
                matchPattern(patterns, self.env.local_user)
            else
                return false; // exec, canonical, final and friends cannot be evaluated here.
            if (matched == negate) return false;
        }
        return true;
    }

    fn apply(self: *Parser, keyword: []const u8, args: []const []const u8) !void {
        if (args.len == 0) return error.SshConfigMissingArgument;
        const value = args[0];
        if (std.mem.eql(u8, keyword, "hostname")) {
            if (self.host_name == null) self.host_name = try self.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, keyword, "user")) {
            if (self.user == null) self.user = try self.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, keyword, "port")) {
            const port = std.fmt.parseInt(u16, value, 10) catch return error.SshConfigInvalidPort;
            if (port == 0) return error.SshConfigInvalidPort;
            if (self.port == null) self.port = port;
        } else if (std.mem.eql(u8, keyword, "identityfile")) {
            for (args) |file| {
                if (std.ascii.eqlIgnoreCase(file, "none")) continue;
                try self.identity_files.append(self.allocator, try self.allocator.dupe(u8, file));
            }
        } else if (std.mem.eql(u8, keyword, "identityagent")) {
            if (self.seen_identity_agent) return;
            self.seen_identity_agent = true;
            if (std.ascii.eqlIgnoreCase(value, "none")) {
                self.agent_disabled = true;
            } else if (!std.mem.eql(u8, value, "SSH_AUTH_SOCK")) {
                self.identity_agent = try self.allocator.dupe(u8, value);
            }
        } else if (std.mem.eql(u8, keyword, "identitiesonly")) {
            if (self.identities_only == null) self.identities_only = try parseYesNo(value);
        } else if (std.mem.eql(u8, keyword, "userknownhostsfile")) {
            if (self.user_known_hosts_file == null) self.user_known_hosts_file = try self.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, keyword, "proxyjump")) {
            if (self.proxy_jump == null and !std.ascii.eqlIgnoreCase(value, "none"))
                self.proxy_jump = try self.allocator.dupe(u8, value);
        }
    }

    /// Move the collected values out, expanding tokens now that the final host and user are known.
    fn finish(self: *Parser) !HostConfig {
        var result = HostConfig{ .agent_disabled = self.agent_disabled, .identities_only = self.identities_only orelse false, .port = self.port };
        errdefer result.deinit(self.allocator);
        if (self.identity_agent) |raw| result.identity_agent = try self.expandTokens(raw);
        if (self.user_known_hosts_file) |raw| result.user_known_hosts_file = try self.expandTokens(raw);
        const files = try self.allocator.alloc([]const u8, self.identity_files.items.len);
        var count: usize = 0;
        errdefer {
            for (files[0..count]) |file| self.allocator.free(file);
            self.allocator.free(files);
        }
        for (self.identity_files.items) |raw| {
            files[count] = try self.expandTokens(raw);
            count += 1;
        }
        result.identity_files = files;
        // Expansion above needed the final host and user; hand them over only now.
        result.host_name = self.host_name;
        self.host_name = null;
        result.user = self.user;
        self.user = null;
        result.proxy_jump = self.proxy_jump;
        self.proxy_jump = null;
        return result;
    }

    /// Expand a leading `~` and the percent tokens ssh_config(5) allows in paths.
    fn expandTokens(self: *Parser, raw: []const u8) ![]const u8 {
        const tilde_free = try self.expandPath(raw, false);
        defer self.allocator.free(tilde_free);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);
        var index: usize = 0;
        while (index < tilde_free.len) : (index += 1) {
            const byte = tilde_free[index];
            if (byte != '%' or index + 1 >= tilde_free.len) {
                try out.append(self.allocator, byte);
                continue;
            }
            index += 1;
            switch (tilde_free[index]) {
                '%' => try out.append(self.allocator, '%'),
                'd' => try out.appendSlice(self.allocator, self.env.home),
                'h' => try out.appendSlice(self.allocator, self.host_name orelse self.alias),
                'n' => try out.appendSlice(self.allocator, self.alias),
                'r' => try out.appendSlice(self.allocator, self.user orelse self.env.local_user),
                'u' => try out.appendSlice(self.allocator, self.env.local_user),
                'p' => try out.print(self.allocator, "{d}", .{self.port orelse DEFAULT_PORT}),
                else => |other| try out.appendSlice(self.allocator, &.{ '%', other }),
            }
        }
        return out.toOwnedSlice(self.allocator);
    }

    /// `~` refers to the home directory; relative Include paths live under ~/.ssh.
    fn expandPath(self: *Parser, raw: []const u8, relative_to_ssh_dir: bool) ![]const u8 {
        if (std.mem.eql(u8, raw, "~")) return self.allocator.dupe(u8, self.env.home);
        if (std.mem.startsWith(u8, raw, "~/")) return std.fs.path.join(self.allocator, &.{ self.env.home, raw[2..] });
        if (relative_to_ssh_dir and !std.fs.path.isAbsolute(raw)) return std.fs.path.join(self.allocator, &.{ self.env.home, ".ssh", raw });
        return self.allocator.dupe(u8, raw);
    }
};

const KeywordSplit = struct { keyword: []const u8, rest: []const u8 };

/// Split `Keyword args`, `Keyword=args` or `Keyword = args` into its two halves.
fn splitKeyword(line: []const u8) KeywordSplit {
    const end = std.mem.indexOfAny(u8, line, " \t=") orelse line.len;
    var rest = std.mem.trimStart(u8, line[end..], " \t");
    if (rest.len > 0 and rest[0] == '=') rest = std.mem.trimStart(u8, rest[1..], " \t");
    return .{ .keyword = line[0..end], .rest = rest };
}

/// Split arguments like OpenSSH's argv_split: whitespace separated, double quotes group,
/// backslash escapes the next character and `#` starts a comment outside quotes.
fn tokenize(allocator: std.mem.Allocator, text: []const u8) !std.ArrayList([]const u8) {
    var tokens: std.ArrayList([]const u8) = .empty;
    errdefer freeTokens(allocator, &tokens);
    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(allocator);
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        const byte = text[index];
        if (byte == ' ' or byte == '\t') continue;
        if (byte == '#') break;
        var quoted = false;
        while (index < text.len) : (index += 1) {
            const inner = text[index];
            if (inner == '"') {
                quoted = !quoted;
            } else if (inner == '\\' and index + 1 < text.len) {
                index += 1;
                try current.append(allocator, text[index]);
            } else if (!quoted and (inner == ' ' or inner == '\t')) {
                break;
            } else {
                try current.append(allocator, inner);
            }
        }
        if (quoted) return error.SshConfigUnterminatedQuote;
        try tokens.append(allocator, try current.toOwnedSlice(allocator));
    }
    return tokens;
}

fn freeTokens(allocator: std.mem.Allocator, tokens: *std.ArrayList([]const u8)) void {
    for (tokens.items) |token| allocator.free(token);
    tokens.deinit(allocator);
}

fn parseYesNo(value: []const u8) !bool {
    if (std.ascii.eqlIgnoreCase(value, "yes") or std.ascii.eqlIgnoreCase(value, "true")) return true;
    if (std.ascii.eqlIgnoreCase(value, "no") or std.ascii.eqlIgnoreCase(value, "false")) return false;
    return error.SshConfigInvalidBoolean;
}

/// `Host` arguments: any negated pattern that matches excludes the block,
/// otherwise any positive match includes it.
fn matchPatternList(patterns: []const []const u8, text: []const u8) bool {
    var matched = false;
    for (patterns) |pattern| {
        if (pattern.len > 0 and pattern[0] == '!') {
            if (matchPattern(pattern[1..], text)) return false;
        } else if (matchPattern(pattern, text)) matched = true;
    }
    return matched;
}

/// A comma-separated pattern list with the same negation rule as `Host`.
fn matchPattern(list: []const u8, text: []const u8) bool {
    var matched = false;
    var patterns = std.mem.splitScalar(u8, list, ',');
    while (patterns.next()) |pattern| {
        if (pattern.len > 0 and pattern[0] == '!') {
            if (matchOne(pattern[1..], text)) return false;
        } else if (matchOne(pattern, text)) matched = true;
    }
    return matched;
}

/// OpenSSH match_pattern: `*` matches any run, `?` one character, case-insensitively.
fn matchOne(pattern: []const u8, text: []const u8) bool {
    if (pattern.len == 0) return text.len == 0;
    switch (pattern[0]) {
        '*' => {
            var skip: usize = 0;
            while (skip <= text.len) : (skip += 1) {
                if (matchOne(pattern[1..], text[skip..])) return true;
            }
            return false;
        },
        '?' => return text.len > 0 and matchOne(pattern[1..], text[1..]),
        else => return text.len > 0 and std.ascii.toLower(pattern[0]) == std.ascii.toLower(text[0]) and matchOne(pattern[1..], text[1..]),
    }
}

const testing = std.testing;
const test_env = Environment{ .home = "/home/me", .local_user = "me" };

const TestFixture = struct {
    tmp: std.testing.TmpDir,
    home: [:0]const u8,

    fn init() !TestFixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const home = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        return .{ .tmp = tmp, .home = home };
    }

    fn deinit(self: *TestFixture) void {
        testing.allocator.free(self.home);
        self.tmp.cleanup();
    }

    fn write(self: *TestFixture, sub_path: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(sub_path)) |dir| try self.tmp.dir.createDirPath(testing.io, dir);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = sub_path, .data = data });
    }

    fn env(self: TestFixture) Environment {
        return .{ .home = self.home, .local_user = "me" };
    }

    fn load(self: *TestFixture, sub_path: []const u8, alias: []const u8) !HostConfig {
        const path = try std.fs.path.join(testing.allocator, &.{ self.home, sub_path });
        defer testing.allocator.free(path);
        return ssh_config_load(testing.allocator, testing.io, path, alias, self.env());
    }
};

const ssh_config_load = load;

fn expectFiles(expected: []const []const u8, actual: []const []const u8) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| try testing.expectEqualStrings(want, got);
}

test "tokenize handles quotes, escapes, equals and comments" {
    var tokens = try tokenize(testing.allocator, "\"/Users/me/Library/Application Support/x\" plain a\\ b # trailing comment");
    defer freeTokens(testing.allocator, &tokens);
    try expectFiles(&.{ "/Users/me/Library/Application Support/x", "plain", "a b" }, tokens.items);

    var mixed = try tokenize(testing.allocator, "pre\"fix ed\"post \"\\\"quoted\\\"\"");
    defer freeTokens(testing.allocator, &mixed);
    try expectFiles(&.{ "prefix edpost", "\"quoted\"" }, mixed.items);

    try testing.expectError(error.SshConfigUnterminatedQuote, tokenize(testing.allocator, "\"open"));

    const split = splitKeyword("User = admin");
    try testing.expectEqualStrings("User", split.keyword);
    try testing.expectEqualStrings("admin", split.rest);
    const tight = splitKeyword("Port=2222");
    try testing.expectEqualStrings("Port", tight.keyword);
    try testing.expectEqualStrings("2222", tight.rest);
    const bare = splitKeyword("Host");
    try testing.expectEqualStrings("Host", bare.keyword);
    try testing.expectEqualStrings("", bare.rest);
}

test "patterns support wildcards, negation, lists and case folding" {
    try testing.expect(matchOne("ec2*.eu-central-1.compute.amazonaws.com", "ec2-63-180-85-82.eu-central-1.compute.amazonaws.com"));
    try testing.expect(matchOne("*", ""));
    try testing.expect(matchOne("web?", "web1"));
    try testing.expect(!matchOne("web?", "web10"));
    try testing.expect(matchOne("Example.COM", "example.com"));
    try testing.expect(!matchOne("example.com", "example.comm"));
    try testing.expect(matchPattern("a.example,b.example", "b.example"));
    try testing.expect(!matchPattern("*.example,!b.example", "b.example"));
    try testing.expect(matchPatternList(&.{ "*.example", "!b.*" }, "a.example"));
    try testing.expect(!matchPatternList(&.{ "*.example", "!b.*" }, "b.example"));
    try testing.expect(!matchPatternList(&.{"!b.*"}, "a.example"));
}

test "first obtained value wins and global settings apply to every host" {
    var fixture = try TestFixture.init();
    defer fixture.deinit();
    try fixture.write("config",
        \\User global-user
        \\
        \\Host prod
        \\    HostName prod.internal
        \\    User prod-user
        \\    Port 2201
        \\Host prod
        \\    Port 9999
        \\Host *
        \\    Port 2222
        \\    HostName never.used
        \\    IdentitiesOnly yes
    );
    var prod = try fixture.load("config", "prod");
    defer prod.deinit(testing.allocator);
    try testing.expectEqualStrings("prod.internal", prod.host_name.?);
    try testing.expectEqualStrings("global-user", prod.user.?);
    try testing.expectEqual(@as(?u16, 2201), prod.port);
    try testing.expect(prod.identities_only);

    var other = try fixture.load("config", "other");
    defer other.deinit(testing.allocator);
    try testing.expectEqualStrings("never.used", other.host_name.?);
    try testing.expectEqual(@as(?u16, 2222), other.port);
}

test "IdentityFile accumulates in order, drops none and expands tokens" {
    var fixture = try TestFixture.init();
    defer fixture.deinit();
    try fixture.write("config",
        \\Host box
        \\    IdentityFile none
        \\    IdentityFile ~/.ssh/%r@%h:%p
        \\    HostName box.internal
        \\    User deploy
        \\    Port 2200
        \\Host *
        \\    IdentityFile %d/.ssh/%n-%u-%%
        \\    IdentityFile "/keys/with space" /keys/second
        \\    UserKnownHostsFile ~/known/%h
    );
    var config = try fixture.load("config", "box");
    defer config.deinit(testing.allocator);
    const first = try std.fmt.allocPrint(testing.allocator, "{s}/.ssh/deploy@box.internal:2200", .{fixture.home});
    defer testing.allocator.free(first);
    const second = try std.fmt.allocPrint(testing.allocator, "{s}/.ssh/box-me-%", .{fixture.home});
    defer testing.allocator.free(second);
    try expectFiles(&.{ first, second, "/keys/with space", "/keys/second" }, config.identity_files);
    const known = try std.fmt.allocPrint(testing.allocator, "{s}/known/box.internal", .{fixture.home});
    defer testing.allocator.free(known);
    try testing.expectEqualStrings(known, config.user_known_hosts_file.?);
}

test "IdentityAgent keeps the first value and understands none and SSH_AUTH_SOCK" {
    var fixture = try TestFixture.init();
    defer fixture.deinit();
    try fixture.write("config",
        \\Host agent-path
        \\    IdentityAgent "~/Library/Application Support/agent.sock"
        \\    IdentityAgent /ignored/second
        \\Host agent-none
        \\    IdentityAgent none
        \\Host agent-default
        \\    IdentityAgent SSH_AUTH_SOCK
        \\Host *
        \\    IdentityAgent /global/agent.sock
    );
    var with_path = try fixture.load("config", "agent-path");
    defer with_path.deinit(testing.allocator);
    const expected = try std.fs.path.join(testing.allocator, &.{ fixture.home, "Library/Application Support/agent.sock" });
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, with_path.identity_agent.?);
    try testing.expect(!with_path.agent_disabled);

    var none = try fixture.load("config", "agent-none");
    defer none.deinit(testing.allocator);
    try testing.expect(none.agent_disabled);
    try testing.expect(none.identity_agent == null);

    var default = try fixture.load("config", "agent-default");
    defer default.deinit(testing.allocator);
    try testing.expect(default.identity_agent == null);
    try testing.expect(!default.agent_disabled);

    var global = try fixture.load("config", "elsewhere");
    defer global.deinit(testing.allocator);
    try testing.expectEqualStrings("/global/agent.sock", global.identity_agent.?);
}

test "Include resolves relative to ~/.ssh, expands ~ and globs, and honours the enclosing block" {
    var fixture = try TestFixture.init();
    defer fixture.deinit();
    try fixture.write(".ssh/config",
        \\Include "sub dir/first.conf"
        \\Include ~/.ssh/conf.d/*.conf missing-file.conf
        \\Host scoped
        \\    Include scoped.conf
        \\Host *
        \\    Port 3333
    );
    try fixture.write(".ssh/sub dir/first.conf", "Host first\n    User first-user\n");
    try fixture.write(".ssh/conf.d/a.conf", "Host globbed\n    HostName a.internal\n");
    try fixture.write(".ssh/conf.d/b.conf", "Host globbed\n    HostName b.internal\n    User b-user\n");
    try fixture.write(".ssh/conf.d/ignored.txt", "Host globbed\n    Port 1\n");
    try fixture.write(".ssh/scoped.conf", "User scoped-user\nPort 4444\n");

    var first = try fixture.load(".ssh/config", "first");
    defer first.deinit(testing.allocator);
    try testing.expectEqualStrings("first-user", first.user.?);
    try testing.expectEqual(@as(?u16, 3333), first.port);

    var globbed = try fixture.load(".ssh/config", "globbed");
    defer globbed.deinit(testing.allocator);
    try testing.expectEqualStrings("a.internal", globbed.host_name.?);
    try testing.expectEqualStrings("b-user", globbed.user.?);
    try testing.expectEqual(@as(?u16, 3333), globbed.port);

    var scoped = try fixture.load(".ssh/config", "scoped");
    defer scoped.deinit(testing.allocator);
    try testing.expectEqualStrings("scoped-user", scoped.user.?);
    try testing.expectEqual(@as(?u16, 4444), scoped.port);

    var unscoped = try fixture.load(".ssh/config", "unscoped");
    defer unscoped.deinit(testing.allocator);
    try testing.expect(unscoped.user == null);
    try testing.expectEqual(@as(?u16, 3333), unscoped.port);
}

test "Host blocks inside an included file keep applying after the Include" {
    var fixture = try TestFixture.init();
    defer fixture.deinit();
    try fixture.write("config",
        \\Include included.conf
        \\Port 5555
    );
    try fixture.write(".ssh/included.conf", "Host only-this\n    User inner\n");
    var matching = try fixture.load("config", "only-this");
    defer matching.deinit(testing.allocator);
    try testing.expectEqualStrings("inner", matching.user.?);
    try testing.expectEqual(@as(?u16, 5555), matching.port);

    var other = try fixture.load("config", "other");
    defer other.deinit(testing.allocator);
    try testing.expect(other.user == null);
    try testing.expect(other.port == null);
}

test "Include recursion is bounded" {
    var fixture = try TestFixture.init();
    defer fixture.deinit();
    try fixture.write(".ssh/config", "Include config\n");
    try testing.expectError(error.SshConfigIncludeTooDeep, fixture.load(".ssh/config", "any"));
}

test "Match supports all, host, originalhost, user, localuser and negation" {
    var fixture = try TestFixture.init();
    defer fixture.deinit();
    try fixture.write("config",
        \\Host alias
        \\    HostName real.internal
        \\Match host real.internal
        \\    User by-host
        \\Match originalhost alias
        \\    Port 1001
        \\Match user by-host
        \\    IdentityFile /by-user
        \\Match localuser me !user by-host
        \\    IdentityFile /never
        \\Match exec "true"
        \\    IdentityFile /cannot-evaluate
        \\Match all
        \\    IdentitiesOnly yes
        \\Match host
        \\    IdentityFile /malformed
    );
    var config = try fixture.load("config", "alias");
    defer config.deinit(testing.allocator);
    try testing.expectEqualStrings("by-host", config.user.?);
    try testing.expectEqual(@as(?u16, 1001), config.port);
    try expectFiles(&.{"/by-user"}, config.identity_files);
    try testing.expect(config.identities_only);
}

test "invalid values are reported and unknown directives are ignored" {
    var fixture = try TestFixture.init();
    defer fixture.deinit();
    try fixture.write("bad-port", "Port 70000\n");
    try testing.expectError(error.SshConfigInvalidPort, fixture.load("bad-port", "x"));
    try fixture.write("zero-port", "Port 0\n");
    try testing.expectError(error.SshConfigInvalidPort, fixture.load("zero-port", "x"));
    try fixture.write("bad-bool", "IdentitiesOnly maybe\n");
    try testing.expectError(error.SshConfigInvalidBoolean, fixture.load("bad-bool", "x"));
    try fixture.write("missing-arg", "User\n");
    try testing.expectError(error.SshConfigMissingArgument, fixture.load("missing-arg", "x"));
    try fixture.write("unknown", "ServerAliveInterval 30\nProxyJump none\nProxyCommand nc %h %p\nUser fine\n");
    var config = try fixture.load("unknown", "x");
    defer config.deinit(testing.allocator);
    try testing.expectEqualStrings("fine", config.user.?);
    try testing.expect(config.proxy_jump == null);
}

test "ProxyJump is surfaced for the caller to refuse" {
    var fixture = try TestFixture.init();
    defer fixture.deinit();
    try fixture.write("config", "Host inner\n    ProxyJump bastion.example\n");
    var config = try fixture.load("config", "inner");
    defer config.deinit(testing.allocator);
    try testing.expectEqualStrings("bastion.example", config.proxy_jump.?);
}

test "a missing config file yields the empty config" {
    var config = try load(testing.allocator, testing.io, "/nonexistent/ssh_config", "host", test_env);
    defer config.deinit(testing.allocator);
    try testing.expect(config.host_name == null);
    try testing.expect(config.user == null);
    try testing.expectEqual(@as(usize, 0), config.identity_files.len);
}

test "a generated per-host agent config resolves like OpenSSH does" {
    var fixture = try TestFixture.init();
    defer fixture.deinit();
    try fixture.write(".ssh/config",
        \\Include ~/.orbstack/ssh/config
        \\Include "~/Library/Application Support/floria/ssh/config"
        \\Host *
        \\    IdentityFile ~/.ssh/default.pem
    );
    try fixture.write("Library/Application Support/floria/ssh/config",
        \\# Generated by Floria. Do not edit.
        \\# Include this file near the top of ~/.ssh/config.
        \\
        \\# Gutline
        \\Host ec2-63-180-85-82.eu-central-1.compute.amazonaws.com
        \\    IdentityAgent "/tmp/floria-ssh-agent-501/qZmwUFs823XonzVm.sock"
        \\    IdentityFile none
        \\    User "admin"
        \\
        \\# agent.sock
        \\Host ec2*.eu-central-1.compute.amazonaws.com
        \\    IdentityAgent "/tmp/floria-ssh-agent-501/3YUjhPR-lx4my6EW.sock"
        \\    IdentityFile none
        \\    User "admin"
    );
    var config = try fixture.load(".ssh/config", "ec2-63-180-85-82.eu-central-1.compute.amazonaws.com");
    defer config.deinit(testing.allocator);
    try testing.expectEqualStrings("admin", config.user.?);
    try testing.expectEqualStrings("/tmp/floria-ssh-agent-501/qZmwUFs823XonzVm.sock", config.identity_agent.?);
    try testing.expect(config.host_name == null);
    const default_key = try std.fs.path.join(testing.allocator, &.{ fixture.home, ".ssh/default.pem" });
    defer testing.allocator.free(default_key);
    try expectFiles(&.{default_key}, config.identity_files);

    var wildcard = try fixture.load(".ssh/config", "ec2-1-2-3-4.eu-central-1.compute.amazonaws.com");
    defer wildcard.deinit(testing.allocator);
    try testing.expectEqualStrings("/tmp/floria-ssh-agent-501/3YUjhPR-lx4my6EW.sock", wildcard.identity_agent.?);
}
