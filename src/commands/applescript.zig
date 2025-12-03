const std = @import("std");
const clap = @import("clap");
const applescript = @import("../applescript.zig");

const params = clap.parseParamsComptime(
    \\-h, --help            Show help for applescript
    \\--file <file_path>    Read script from file instead of command line
    \\<script>
    \\
);

const parsers = .{
    .file_path = clap.parsers.string,
    .script = clap.parsers.string,
};

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

    var script_source: []const u8 = undefined;
    var script_owned: ?[]u8 = null;
    defer if (script_owned) |s| allocator.free(s);

    if (res.args.file) |file_path| {
        const file = std.fs.openFileAbsolute(file_path, .{}) catch |err| {
            std.debug.print("Error opening file '{s}': {}\n", .{ file_path, err });
            return;
        };
        defer file.close();

        script_owned = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
        script_source = script_owned.?;
    } else {
        script_source = res.positionals[0] orelse return printHelp("Missing script argument.");
    }

    const result = applescript.execute(allocator, script_source) catch |err| {
        std.debug.print("Error executing AppleScript: {}\n", .{err});
        return;
    };
    defer allocator.free(result);

    if (result.len > 0) {
        std.debug.print("{s}\n", .{result});
    } else {
        std.debug.print("(script executed successfully, no return value)\n", .{});
    }
}

fn printHelp(reason: ?[]const u8) !void {
    const out = std.fs.File.stdout();
    if (reason) |msg| {
        try out.writeAll(msg);
        try out.writeAll("\n\n");
    }
    try out.writeAll(
        \\applescript
        \\  hola applescript <script> [--file <path>]
        \\
        \\Execute AppleScript using macOS system API (not command line osascript).
        \\
        \\Flags
        \\  --file <path>    Read script from file instead of command line argument
        \\
        \\Examples
        \\  hola applescript \"1 + 1\"
        \\  hola applescript \"tell application \\\"Finder\\\" to display dialog \\\"Hello\\\"\"
        \\  hola applescript --file script.applescript
        \\
        \\Note: This command is only available on macOS.
        \\
    );
}
