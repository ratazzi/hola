const std = @import("std");
const clap = @import("clap");
const git = @import("../git.zig");

const params = clap.parseParamsComptime(
    \\-h, --help            Show help for git-clone
    \\--branch <str>        Checkout the given branch
    \\--bare                Clone without working tree
    \\--no-checkout         Alias for --bare
    \\--quiet               Suppress progress output
    \\<url>
    \\<dest>
    \\
);

const parsers = .{
    .str = clap.parsers.string,
    .url = clap.parsers.string,
    .dest = clap.parsers.string,
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

    const url = res.positionals[0] orelse return printHelp("Missing repository URL.");
    const destination = res.positionals[1] orelse return printHelp("Missing destination path.");

    var options: git.CloneOptions = .{};
    if (res.args.branch) |branch_name| options.branch = branch_name;
    const no_checkout = @field(res.args, "no-checkout");
    if (res.args.bare != 0 or no_checkout != 0) options.checkout_workdir = false;
    if (res.args.quiet != 0) options.show_progress = false;

    var client = try git.Client.init();
    defer client.deinit();

    std.debug.print("[clone] -> {s}\n", .{destination});
    try client.clone(allocator, url, destination, options);
    if (options.show_progress) std.debug.print("\n", .{});
    std.debug.print("[done] {s} -> {s}\n", .{ url, destination });
}

fn printHelp(reason: ?[]const u8) !void {
    const out = std.fs.File.stdout();
    if (reason) |msg| {
        try out.writeAll(msg);
        try out.writeAll("\n\n");
    }
    try out.writeAll(
        \\git-clone
        \\  hola git-clone <repo> <dest> [--branch <name>] [--bare] [--quiet]
        \\
        \\Flags
        \\  --branch <name>     Checkout the given branch after cloning
        \\  --bare              Clone without a working tree (alias: --no-checkout)
        \\  --quiet             Suppress libgit2 progress output
        \\
        \\Example
        \\  hola git-clone https://github.com/ratazzi/hola ~/.local/share/hola/config --branch main
        \\
    );
}
