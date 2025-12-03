const std = @import("std");
const clap = @import("clap");
const dotfiles = @import("../dotfiles.zig");
const toml = @import("toml");
const logger = @import("../logger.zig");
const dotfiles_paths = @import("../dotfiles_paths.zig");

const params = clap.parseParamsComptime(
    \\-h, --help                 Show help for link
    \\--dotfiles <dotfiles_dir>  Dotfiles repository location (default ~/.dotfiles)
    \\--home <home_dir>          Home directory to link into (default $HOME)
    \\--dry-run                  Preview changes without creating links
    \\
);

const parsers = .{
    .dotfiles_dir = clap.parsers.string,
    .home_dir = clap.parsers.string,
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

    var options: dotfiles.Options = .{};
    defer {
        if (options.root_override) |root| allocator.free(root);
        if (options.home_override) |home| allocator.free(home);
        if (options.ignore_patterns) |patterns| {
            for (patterns) |pattern| {
                allocator.free(pattern);
            }
            allocator.free(patterns);
        }
    }

    const actual_home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(actual_home);

    if (res.args.dotfiles) |dotfiles_path| {
        options.root_override = try dotfiles_paths.resolvePathForLink(allocator, dotfiles_path, actual_home);
    }

    if (res.args.home) |home_path| {
        options.home_override = try dotfiles_paths.resolvePathForLink(allocator, home_path, actual_home);
    }

    const dry_run_flag = @field(res.args, "dry-run");
    if (dry_run_flag != 0) {
        options.dry_run = true;
    }

    const base_root = options.root_override orelse "~/.dotfiles";
    const resolved_root = try dotfiles_paths.resolvePathForLink(allocator, base_root, actual_home);
    defer allocator.free(resolved_root);

    const ignore_patterns = try loadLinkConfig(allocator, resolved_root);
    if (ignore_patterns) |patterns| {
        options.ignore_patterns = patterns;
    }

    if (!options.dry_run) {
        const target_display = options.home_override orelse "$HOME";
        std.debug.print("[link] applying into {s}\n", .{target_display});
    }

    try dotfiles.run(allocator, options);
}

fn loadLinkConfig(allocator: std.mem.Allocator, root: []const u8) !?[]const []const u8 {
    const project_config_paths = [_][]const u8{ ".hola.toml", "hola.toml" };
    var config_file: ?std.fs.File = null;
    var config_path: []const u8 = undefined;

    for (project_config_paths) |config_name| {
        const path = try std.fs.path.join(allocator, &.{ root, config_name });
        defer allocator.free(path);

        const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };

        config_file = file;
        config_path = try allocator.dupe(u8, path);
        break;
    }

    if (config_file == null) {
        const xdg = @import("../xdg.zig").XDG.init(allocator);
        const xdg_config_path = try xdg.getConfigFile();
        defer allocator.free(xdg_config_path);

        if (std.fs.openFileAbsolute(xdg_config_path, .{})) |f| {
            config_file = f;
            config_path = try allocator.dupe(u8, xdg_config_path);
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
    }

    const file = config_file orelse return null;
    defer file.close();
    defer allocator.free(config_path);

    const content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(content);

    const Config = struct {
        dotfiles: ?struct {
            ignore: ?[]const []const u8 = null,
        } = null,
    };

    var parser = toml.Parser(Config).init(allocator);
    defer parser.deinit();

    const parsed = parser.parseString(content) catch |err| {
        logger.warn("Failed to parse {s}: {s}, using defaults", .{ config_path, @errorName(err) });
        return null;
    };
    defer parsed.deinit();

    if (parsed.value.dotfiles) |dotfiles_config| {
        if (dotfiles_config.ignore) |patterns| {
            var owned_patterns = try allocator.alloc([]const u8, patterns.len);
            for (patterns, 0..) |pattern, i| {
                owned_patterns[i] = try allocator.dupe(u8, pattern);
            }
            return owned_patterns;
        }
    }

    return null;
}

fn printHelp(reason: ?[]const u8) !void {
    const out = std.fs.File.stdout();
    if (reason) |msg| {
        try out.writeAll(msg);
        try out.writeAll("\n\n");
    }
    try out.writeAll(
        \\link
        \\  hola link [--dotfiles <path>] [--home <path>] [--dry-run]
        \\
        \\Flags
        \\  --dotfiles <path>  Dotfiles repository location (default ~/.dotfiles)
        \\  --home <path>      Home directory to link into (default $HOME)
        \\  --dry-run          Preview changes without creating links
        \\
        \\Example
        \\  hola link --dotfiles ~/workspace/dotfiles --home /tmp/test-home
        \\  hola link --dry-run  # Preview changes only
        \\
    );
}
