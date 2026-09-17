//! SSH credential candidates for libgit2 connections, shared by hola git-clone
//! and the git resource. libgit2 calls its credentials callback again after
//! every credential the server rejects, with no limit of its own, so a callback
//! must hand out the next candidate on every call and stop once they run out.
const std = @import("std");
const global_io = @import("global_io.zig");

/// Key files tried after the agent, in OpenSSH's default order.
pub const DEFAULT_KEY_NAMES = [_][]const u8{ "id_ed25519", "id_rsa", "id_ecdsa", "id_dsa" };
const MAX_KEY_BYTES = 64 * 1024;
const OPENSSH_HEADER = "-----BEGIN OPENSSH PRIVATE KEY-----";
const OPENSSH_MAGIC = "openssh-key-v1\x00";

pub const Candidate = union(enum) { agent, key: [:0]const u8 };

pub const Credentials = struct {
    /// An explicit key (the git resource's ssh_key) is used alone.
    explicit_key: ?[:0]const u8 = null,
    agent_allowed: bool = true,
    /// Configured key files; when non-empty these replace the default names, as in OpenSSH.
    identity_files: []const []const u8 = &.{},
    /// Directory holding `.ssh/` for the default key names.
    home: ?[]const u8 = null,
    attempt: usize = 0,

    /// The next credential to offer, or null when none remain. `buf` backs a returned key path.
    /// Key files libssh2 could not load are skipped here: libgit2 turns a load failure
    /// into a hard error instead of GIT_EAUTH, which would end the attempts early.
    pub fn next(self: *Credentials, buf: *[std.fs.max_path_bytes:0]u8) ?Candidate {
        while (true) {
            const index = self.attempt;
            self.attempt += 1;
            if (self.explicit_key) |key| return if (index == 0) .{ .key = key } else null;
            if (index == 0) {
                if (self.agent_allowed) return .agent;
                continue;
            }
            const file_index = index - 1;
            const path = if (self.identity_files.len > 0) blk: {
                if (file_index >= self.identity_files.len) return null;
                break :blk std.fmt.bufPrintZ(buf, "{s}", .{self.identity_files[file_index]}) catch continue;
            } else blk: {
                if (file_index >= DEFAULT_KEY_NAMES.len) return null;
                const home = self.home orelse return null;
                break :blk std.fmt.bufPrintZ(buf, "{s}/.ssh/{s}", .{ home, DEFAULT_KEY_NAMES[file_index] }) catch continue;
            };
            if (keyLoadable(global_io.io(), path)) return .{ .key = path };
        }
    }
};

/// Whether libssh2 can load `path` without a passphrase: the file exists and is an
/// unencrypted private key. Encrypted keys belong in the agent, which is tried first.
pub fn keyLoadable(io: std.Io, path: []const u8) bool {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    defer file.close(io);
    var buffer: [MAX_KEY_BYTES]u8 = undefined;
    const length = file.readStreaming(io, &.{&buffer}) catch return false;
    return keyTextLoadable(buffer[0..length]);
}

fn keyTextLoadable(text: []const u8) bool {
    // PEM "Proc-Type: 4,ENCRYPTED" and PKCS#8 "BEGIN ENCRYPTED PRIVATE KEY".
    if (std.mem.indexOf(u8, text, "ENCRYPTED") != null) return false;
    if (std.mem.indexOf(u8, text, OPENSSH_HEADER)) |start| return opensshKeyUnencrypted(text[start + OPENSSH_HEADER.len ..]);
    return std.mem.indexOf(u8, text, "PRIVATE KEY-----") != null;
}

/// The OpenSSH format starts with a magic string followed by the cipher name; "none" means unencrypted.
fn opensshKeyUnencrypted(body: []const u8) bool {
    var compact: [MAX_KEY_BYTES]u8 = undefined;
    var count: usize = 0;
    for (body) |byte| {
        if (byte == '-') break;
        if (std.ascii.isWhitespace(byte)) continue;
        if (count == compact.len) return false;
        compact[count] = byte;
        count += 1;
    }
    var decoded: [MAX_KEY_BYTES]u8 = undefined;
    const size = std.base64.standard.Decoder.calcSizeForSlice(compact[0..count]) catch return false;
    if (size > decoded.len) return false;
    std.base64.standard.Decoder.decode(decoded[0..size], compact[0..count]) catch return false;
    const bytes = decoded[0..size];
    if (!std.mem.startsWith(u8, bytes, OPENSSH_MAGIC)) return false;
    const cipher_start = OPENSSH_MAGIC.len + 4;
    if (bytes.len < cipher_start) return false;
    const cipher_len = std.mem.readInt(u32, bytes[OPENSSH_MAGIC.len..][0..4], .big);
    if (bytes.len < cipher_start + cipher_len) return false;
    return std.mem.eql(u8, bytes[cipher_start..][0..cipher_len], "none");
}

const testing = std.testing;

/// Build the head of an OpenSSH-format key with the given cipher, wrapped like ssh-keygen output.
fn opensshKeyText(allocator: std.mem.Allocator, cipher: []const u8) ![]const u8 {
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(allocator);
    try raw.appendSlice(allocator, OPENSSH_MAGIC);
    try raw.append(allocator, 0);
    try raw.append(allocator, 0);
    try raw.append(allocator, 0);
    try raw.append(allocator, @intCast(cipher.len));
    try raw.appendSlice(allocator, cipher);
    try raw.appendSlice(allocator, "\x00\x00\x00\x06bcrypt");
    const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(raw.items.len));
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, raw.items);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    try text.appendSlice(allocator, OPENSSH_HEADER ++ "\n");
    var offset: usize = 0;
    while (offset < encoded.len) : (offset += 70) {
        try text.appendSlice(allocator, encoded[offset..@min(offset + 70, encoded.len)]);
        try text.append(allocator, '\n');
    }
    try text.appendSlice(allocator, "-----END OPENSSH PRIVATE KEY-----\n");
    return text.toOwnedSlice(allocator);
}

test "keyTextLoadable accepts unencrypted keys and rejects encrypted or unrecognised files" {
    const plain = try opensshKeyText(testing.allocator, "none");
    defer testing.allocator.free(plain);
    try testing.expect(keyTextLoadable(plain));

    const encrypted = try opensshKeyText(testing.allocator, "aes256-ctr");
    defer testing.allocator.free(encrypted);
    try testing.expect(!keyTextLoadable(encrypted));

    try testing.expect(keyTextLoadable("-----BEGIN RSA PRIVATE KEY-----\nMIIE...\n-----END RSA PRIVATE KEY-----\n"));
    try testing.expect(!keyTextLoadable("-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\nDEK-Info: AES-128-CBC,00\n"));
    try testing.expect(!keyTextLoadable("-----BEGIN ENCRYPTED PRIVATE KEY-----\nMIIF...\n"));
    try testing.expect(keyTextLoadable("-----BEGIN PRIVATE KEY-----\nMIIE...\n-----END PRIVATE KEY-----\n"));
    try testing.expect(!keyTextLoadable("ssh-ed25519 AAAA public-key-only"));
    try testing.expect(!keyTextLoadable(""));
    try testing.expect(!keyTextLoadable(OPENSSH_HEADER ++ "\nnot base64!\n-----END OPENSSH PRIVATE KEY-----\n"));
    try testing.expect(!keyTextLoadable(OPENSSH_HEADER ++ "\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n"));
}

test "Credentials hands out each candidate once, skipping missing and unloadable keys" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(home);
    const plain = try opensshKeyText(testing.allocator, "none");
    defer testing.allocator.free(plain);
    const encrypted = try opensshKeyText(testing.allocator, "aes256-ctr");
    defer testing.allocator.free(encrypted);
    try tmp.dir.createDirPath(testing.io, ".ssh");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".ssh/id_ed25519", .data = encrypted });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".ssh/id_rsa", .data = plain });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".ssh/id_ecdsa", .data = "garbage" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "present.pem", .data = plain });
    const present = try std.fs.path.join(testing.allocator, &.{ home, "present.pem" });
    defer testing.allocator.free(present);
    const id_rsa = try std.fs.path.join(testing.allocator, &.{ home, ".ssh", "id_rsa" });
    defer testing.allocator.free(id_rsa);
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;

    // The encrypted id_ed25519 and the garbage id_ecdsa are skipped; id_dsa is missing.
    var defaults = Credentials{ .home = home };
    try testing.expectEqual(Candidate.agent, defaults.next(&buf).?);
    try testing.expectEqualStrings(id_rsa, defaults.next(&buf).?.key);
    try testing.expect(defaults.next(&buf) == null);
    try testing.expect(defaults.next(&buf) == null);

    var configured = Credentials{ .home = home, .identity_files = &.{ "/missing.pem", present }, .agent_allowed = false };
    try testing.expectEqualStrings(present, configured.next(&buf).?.key);
    try testing.expect(configured.next(&buf) == null);

    // An explicit key is offered as given, even if it could not be loaded, so the failure is visible.
    var explicit = Credentials{ .home = home, .explicit_key = "/explicit.pem", .identity_files = &.{present} };
    try testing.expectEqualStrings("/explicit.pem", explicit.next(&buf).?.key);
    try testing.expect(explicit.next(&buf) == null);

    var homeless = Credentials{};
    try testing.expectEqual(Candidate.agent, homeless.next(&buf).?);
    try testing.expect(homeless.next(&buf) == null);
}
