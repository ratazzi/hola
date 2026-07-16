const std = @import("std");
const clap = @import("clap");
const node_info = @import("../node_info.zig");
const global_io = @import("../global_io.zig");

const params = clap.parseParamsComptime(
    \\-h, --help            Show help for node-info
    \\
);

const parsers = .{};

pub fn run(allocator: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, parsers, iter, .{
        .allocator = allocator,
        .diagnostic = &diag,
    }) catch |err| {
        try diag.reportToFile(global_io.io(), std.Io.File.stderr(), err);
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

    const io = global_io.io();
    const stdout = std.Io.File.stdout();
    try stdout.writeStreamingAll(io, json_str);
    try stdout.writeStreamingAll(io, "\n");
}

fn printHelp(reason: ?[]const u8) !void {
    const io = global_io.io();
    const out = std.Io.File.stdout();
    if (reason) |msg| {
        try out.writeStreamingAll(io, msg);
        try out.writeStreamingAll(io, "\n\n");
    }
    try out.writeStreamingAll(io,
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
