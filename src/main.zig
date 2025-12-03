const std = @import("std");
const builtin = @import("builtin");
const clap = @import("clap");
const logger = @import("logger.zig");
const help_formatter = @import("help_formatter.zig");
const build_options = @import("build_options");
const commands = @import("commands.zig");

const is_macos = builtin.os.tag == .macos;

const main_params = clap.parseParamsComptime(
    \\-h, --help       Print this help and exit
    \\-v, --version    Show version information
    \\<command>
    \\
);
const main_parsers = .{
    .command = clap.parsers.string,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize logger (non-critical, continue if it fails)
    logger.initGlobal(allocator, null) catch {};
    defer logger.deinitGlobal();

    var iter = try std.process.ArgIterator.initWithAllocator(allocator);
    defer iter.deinit();
    _ = iter.next(); // skip exe name

    var diag = clap.Diagnostic{};
    var parsed = clap.parseEx(clap.Help, &main_params, main_parsers, &iter, .{
        .allocator = allocator,
        .diagnostic = &diag,
        .terminating_positional = 0,
    }) catch |err| {
        try diag.reportToFile(std.fs.File.stderr(), err);
        return;
    };
    defer parsed.deinit();

    if (parsed.args.help != 0) {
        try printMainHelp(null);
        return;
    }

    if (parsed.args.version != 0) {
        try printVersion(allocator);
        return;
    }

    if (parsed.positionals[0]) |command| {
        return dispatchCommand(command, allocator, &iter);
    }

    // No command provided, show help
    try printMainHelp(null);
}

fn dispatchCommand(command: []const u8, allocator: std.mem.Allocator, iter: *std.process.ArgIterator) !void {
    if (std.mem.eql(u8, command, "help")) {
        try printMainHelp(null);
        return;
    }
    if (std.mem.eql(u8, command, "version")) {
        try printVersion(allocator);
        return;
    }
    if (std.mem.eql(u8, command, "git-clone")) {
        try commands.git_clone.run(allocator, iter);
        return;
    }
    if (std.mem.eql(u8, command, "link")) {
        try commands.link.run(allocator, iter);
        return;
    }
    if (std.mem.eql(u8, command, "dock")) {
        if (is_macos) {
            try commands.dock.run(allocator, iter);
        } else {
            std.debug.print("Error: dock command is only available on macOS\n", .{});
        }
        return;
    }
    if (std.mem.eql(u8, command, "applescript")) {
        if (is_macos) {
            try commands.applescript.run(allocator, iter);
        } else {
            std.debug.print("Error: applescript command is only available on macOS\n", .{});
        }
        return;
    }
    if (std.mem.eql(u8, command, "provision")) {
        try commands.provision.run(allocator, iter);
        return;
    }
    if (std.mem.eql(u8, command, "apply")) {
        try commands.apply.run(allocator, iter);
        return;
    }
    if (std.mem.eql(u8, command, "node-info")) {
        try commands.node_info.run(allocator, iter);
        return;
    }

    try printMainHelp(command);
}

fn printMainHelp(unknown: ?[]const u8) !void {
    const gpa = std.heap.page_allocator;

    if (unknown) |cmd| {
        const error_msg = try std.fmt.allocPrint(gpa, "Unknown command \"{s}\"", .{cmd});
        defer gpa.free(error_msg);
        help_formatter.HelpFormatter.printError(error_msg);
        help_formatter.HelpFormatter.newline();
    }

    // Header with branding and version info (Bun style)
    const ansi_constants = @import("ansi_constants.zig");
    const version_info = std.fmt.allocPrint(
        gpa,
        "Brewfile + mise.toml + dotfiles = your dev environment {s}({s}+{s}){s}",
        .{ ansi_constants.ANSI.DIM, build_options.version, build_options.git_commit, ansi_constants.ANSI.RESET },
    ) catch "Brewfile + mise.toml + dotfiles = your dev environment";
    defer if (!std.mem.eql(u8, version_info, "Brewfile + mise.toml + dotfiles = your dev environment")) gpa.free(version_info);

    help_formatter.HelpFormatter.printHeader("Hola", version_info);
    help_formatter.HelpFormatter.newline();

    // Usage section (Bun style with colon on same line)
    help_formatter.HelpFormatter.usageHeader();
    help_formatter.HelpFormatter.printUsage("hola", "<command> [...flags]");
    help_formatter.HelpFormatter.newline();

    // Commands section with table alignment
    help_formatter.HelpFormatter.sectionHeader("Commands");
    const command_items = [_]help_formatter.HelpFormatter.CommandItem{
        .{ .command = "git-clone", .description = "Clone repositories with embedded libgit2 client" },
        .{ .command = "link", .description = "Create symlinks from dotfiles to home directory" },
        .{ .command = "dock", .description = "Show current macOS Dock configuration" },
        .{ .command = "applescript", .description = "Execute AppleScript via macOS system API" },
        .{ .command = "provision", .description = "Run infrastructure-as-code scripts" },
        .{ .command = "node-info", .description = "Display complete node information (like Chef Ohai)" },
        .{ .command = "apply", .description = "Execute full bootstrap sequence" },
        .{ .command = "help", .description = "Show this help menu" },
    };
    help_formatter.HelpFormatter.printCommandTable(&command_items);
    help_formatter.HelpFormatter.newline();

    // Examples section with table alignment
    help_formatter.HelpFormatter.sectionHeader("Examples");
    const examples = [_]help_formatter.HelpFormatter.ExampleItem{
        .{ .prefix = "Clone config:", .command = "git-clone https://github.com/user/hola ~/.local/share/hola/config --branch main" },
        .{ .prefix = "Link dotfiles:", .command = "link --dotfiles ~/.dotfiles" },
        .{ .prefix = "Dock utilities:", .command = "dock" },
        .{ .prefix = "AppleScript:", .command = "applescript \"1 + 1\"" },
        .{ .prefix = "AppleScript file:", .command = "applescript --file script.applescript" },
        .{ .prefix = "Infrastructure:", .command = "provision provision.rb" },
        .{ .prefix = "Node information:", .command = "node-info" },
        .{ .prefix = "Full bootstrap:", .command = "apply --github user/dotfiles" },
        .{ .prefix = "Dry run:", .command = "apply --dry-run" },
    };
    help_formatter.HelpFormatter.printExamples(&examples);
    help_formatter.HelpFormatter.newline();

    // Footer
    help_formatter.HelpFormatter.printNote("Use 'hola <command> --help' for detailed command information");
}

fn printVersion(allocator: std.mem.Allocator) !void {
    _ = allocator;
    const curl = @import("curl.zig");

    // Get curl version info
    const curl_info = curl.getVersionInfo();
    const curl_ver = curl.parseVersion(curl_info.version_num);

    std.debug.print(
        \\Hola version {s}
        \\
        \\Built with:
        \\
    , .{build_options.version});

    // Core libraries
    std.debug.print("  • Zig {s} (https://ziglang.org)\n", .{builtin.zig_version_string});
    std.debug.print("  • libcurl {d}.{d}.{d} (https://curl.se)\n", .{ curl_ver.major, curl_ver.minor, curl_ver.patch });

    if (curl_info.ssl_version) |ssl| {
        std.debug.print("  • {s} (https://www.openssl.org)\n", .{std.mem.span(ssl)});
    }

    if (curl_info.libz_version) |libz| {
        std.debug.print("  • zlib {s} (https://zlib.net)\n", .{std.mem.span(libz)});
    }

    // Additional compression libraries
    std.debug.print("  • brotli (https://github.com/google/brotli)\n", .{});
    std.debug.print("  • zstd (https://facebook.github.io/zstd)\n", .{});

    // Git and SSH
    std.debug.print("  • libgit2 (https://libgit2.org)\n", .{});
    std.debug.print("  • libssh2 (https://www.libssh2.org)\n", .{});

    // HTTP protocols
    std.debug.print("  • nghttp2 - HTTP/2 (https://nghttp2.org)\n", .{});
    std.debug.print("  • nghttp3 - HTTP/3 (https://nghttp2.org/nghttp3)\n", .{});

    // Ruby
    std.debug.print("  • mruby (https://mruby.org)\n", .{});

    // Infrastructure as Code & Package managers
    std.debug.print("\nInspired by and works with:\n", .{});
    std.debug.print("  • Chef Infra (https://www.chef.io)\n", .{});
    std.debug.print("  • Homebrew (https://brew.sh)\n", .{});
    std.debug.print("  • mise (https://mise.jdx.dev)\n", .{});

    std.debug.print(
        \\
        \\Special thanks to all the amazing open source projects that make Hola possible!
        \\
        \\For more information: https://github.com/ratazzi/hola
        \\
    , .{});
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    const Context = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}
