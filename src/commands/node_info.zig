const std = @import("std");
const clap = @import("clap");
const node_info = @import("../node_info.zig");

const params = clap.parseParamsComptime(
    \\-h, --help            Show help for node-info
    \\
);

const parsers = .{};

pub fn run(allocator: std.mem.Allocator, iter: *std.process.ArgIterator) !void {
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, parsers, iter, .{
        .allocator = allocator,
        .diagnostic = &diag,
    }) catch |err| {
        try diag.reportToFile(std.fs.File.stderr(), err);
        return;
    };
    defer res.deinit();

    if (res.args.help != 0) return printHelp(null);

    try printNodeInfo(allocator);
}

fn printNodeInfo(allocator: std.mem.Allocator) !void {
    const node = try node_info.getNodeInfo(allocator);
    defer node.deinit(allocator);

    const json_str = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(node, .{ .whitespace = .indent_2 })});
    defer allocator.free(json_str);

    const stdout = std.fs.File.stdout();
    try stdout.writeAll(json_str);
    try stdout.writeAll("\n");
}

fn printHelp(reason: ?[]const u8) !void {
    const out = std.fs.File.stdout();
    if (reason) |msg| {
        try out.writeAll(msg);
        try out.writeAll("\n\n");
    }
    try out.writeAll(
        \\node-info
        \\  hola node-info
        \\
        \\Display complete node information in JSON format (like Chef Ohai).
        \\
        \\Example
        \\  hola node-info
        \\
        \\
    );
}
