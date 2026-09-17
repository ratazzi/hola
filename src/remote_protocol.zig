//! Versioned request carried on SSH stdin; completion is separate from user output.
const std = @import("std");
const provision = @import("provision.zig");
const display = @import("modern_provision_display.zig");

pub const VERSION = 1;
pub const MAX_REQUEST_BYTES = 8 * 1024 * 1024;

pub const Request = struct {
    version: u32 = VERSION,
    script_path: []const u8,
    result_path: []const u8,
    phase: ?[]const u8 = null,
    output_mode: display.OutputMode = .normal,
    params_json: ?[]const u8 = null,
    secrets_json: ?[]const u8 = null,
};

pub const Completion = struct {
    version: u32 = VERSION,
    success: bool,
    error_name: ?[]const u8 = null,
    executed_count: usize = 0,
    updated_count: usize = 0,
    skipped_count: usize = 0,
    failed_count: usize = 0,
    duration_ms: i64 = 0,
    resource_results: []const provision.ResourceResult = &.{},
};

test "remote request round trips secrets without shell interpretation" {
    const allocator = std.testing.allocator;
    const request = Request{ .script_path = "recipe.rb", .result_path = "../result.json", .secrets_json = "{\"key\":\"'$(secret)\\n\"}" };
    const encoded = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(request, .{})});
    defer allocator.free(encoded);
    const parsed = try std.json.parseFromSlice(Request, allocator, encoded, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(request.secrets_json.?, parsed.value.secrets_json.?);
    try std.testing.expectEqual(VERSION, parsed.value.version);
}
