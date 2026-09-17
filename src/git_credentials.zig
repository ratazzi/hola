//! SSH credential candidates for libgit2 connections, shared by hola git-clone
//! and the git resource. libgit2 calls its credentials callback again after
//! every credential the server rejects, with no limit of its own, so a callback
//! must hand out the next candidate on every call and stop once they run out.
const std = @import("std");
const global_io = @import("global_io.zig");

/// Key files tried after the agent, in OpenSSH's default order.
pub const DEFAULT_KEY_NAMES = [_][]const u8{ "id_ed25519", "id_rsa", "id_ecdsa", "id_dsa" };

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
            std.Io.Dir.cwd().access(global_io.io(), path, .{}) catch continue;
            return .{ .key = path };
        }
    }
};

const testing = std.testing;

test "Credentials hands out each candidate once, skipping missing key files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(home);
    try tmp.dir.createDirPath(testing.io, ".ssh");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".ssh/id_rsa", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "present.pem", .data = "" });
    const present = try std.fs.path.join(testing.allocator, &.{ home, "present.pem" });
    defer testing.allocator.free(present);
    const id_rsa = try std.fs.path.join(testing.allocator, &.{ home, ".ssh", "id_rsa" });
    defer testing.allocator.free(id_rsa);
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;

    var defaults = Credentials{ .home = home };
    try testing.expectEqual(Candidate.agent, defaults.next(&buf).?);
    try testing.expectEqualStrings(id_rsa, defaults.next(&buf).?.key);
    try testing.expect(defaults.next(&buf) == null);
    try testing.expect(defaults.next(&buf) == null);

    var configured = Credentials{ .home = home, .identity_files = &.{ "/missing.pem", present }, .agent_allowed = false };
    try testing.expectEqualStrings(present, configured.next(&buf).?.key);
    try testing.expect(configured.next(&buf) == null);

    var explicit = Credentials{ .home = home, .explicit_key = "/explicit.pem", .identity_files = &.{present} };
    try testing.expectEqualStrings("/explicit.pem", explicit.next(&buf).?.key);
    try testing.expect(explicit.next(&buf) == null);

    var homeless = Credentials{};
    try testing.expectEqual(Candidate.agent, homeless.next(&buf).?);
    try testing.expect(homeless.next(&buf) == null);
}
