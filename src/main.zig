const std = @import("std");
const builtin = @import("builtin");
const mruby = @import("mruby.zig");
const git = @import("git.zig");
const dotfiles = @import("dotfiles.zig");
const plist = if (builtin.os.tag == .macos) @import("plist.zig") else struct {};
const applescript = if (builtin.os.tag == .macos) @import("applescript.zig") else struct {};
const provision = @import("provision.zig");
const apply_module = @import("apply.zig");
const clap = @import("clap");
const toml = @import("toml");
const logger = @import("logger.zig");
const help_formatter = @import("help_formatter.zig");

const is_macos = builtin.os.tag == .macos;

const main_params = clap.parseParamsComptime(
    \\-h, --help   Print this help and exit
    \\<command>
    \\
);
const main_parsers = .{
    .command = clap.parsers.string,
};

const git_clone_params = clap.parseParamsComptime(
    \\-h, --help            Show help for git-clone
    \\--branch <str>        Checkout the given branch
    \\--bare                Clone without working tree
    \\--no-checkout         Alias for --bare
    \\--quiet               Suppress progress output
    \\<url>
    \\<dest>
    \\
);
const git_clone_parsers = .{
    .str = clap.parsers.string,
    .url = clap.parsers.string,
    .dest = clap.parsers.string,
};

const link_params = clap.parseParamsComptime(
    \\-h, --help             Show help for link
    \\--root <root_path>     Override dotfiles root (defaults to ~/.dotfiles)
    \\--target <target_dir>  Override link destination (defaults to $HOME)
    \\--apply                Actually create links (dry-run only right now)
    \\
);
const link_parsers = .{
    .root_path = clap.parsers.string,
    .target_dir = clap.parsers.string,
};

const applescript_params = clap.parseParamsComptime(
    \\-h, --help            Show help for applescript
    \\--file <file_path>    Read script from file instead of command line
    \\<script>
    \\
);
const applescript_parsers = .{
    .file_path = clap.parsers.string,
    .script = clap.parsers.string,
};

const apply_params = clap.parseParamsComptime(
    \\-h, --help            Show help for apply
    \\--root <root_path>    Override config root (defaults to ~/.local/share/hola/config)
    \\--dry-run             Show what would be done without actually doing it
    \\
);
const apply_parsers = .{
    .root_path = clap.parsers.string,
};

const provision_params = clap.parseParamsComptime(
    \\-h, --help            Show help for provision
    \\<path>                Path to provision file (.rb)
    \\
);
const provision_parsers = .{
    .path = clap.parsers.string,
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
    if (std.mem.eql(u8, command, "git-clone")) {
        try runGitCloneCommand(allocator, iter);
        return;
    }
    if (std.mem.eql(u8, command, "link")) {
        try runLinkCommand(allocator, iter);
        return;
    }
    if (std.mem.eql(u8, command, "dock-apps")) {
        if (is_macos) {
            try runDockAppsCommand(allocator, iter);
        } else {
            std.debug.print("Error: dock-apps command is only available on macOS\n", .{});
        }
        return;
    }
    if (std.mem.eql(u8, command, "applescript")) {
        if (is_macos) {
            try runApplescriptCommand(allocator, iter);
        } else {
            std.debug.print("Error: applescript command is only available on macOS\n", .{});
        }
        return;
    }
    if (std.mem.eql(u8, command, "provision")) {
        try runProvisionCommand(allocator, iter);
        return;
    }
    if (std.mem.eql(u8, command, "apply")) {
        try runApplyCommand(allocator, iter);
        return;
    }

    try printMainHelp(command);
}

fn runGitCloneCommand(allocator: std.mem.Allocator, iter: *std.process.ArgIterator) !void {
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &git_clone_params, git_clone_parsers, iter, .{
        .allocator = allocator,
        .diagnostic = &diag,
    }) catch |err| {
        try diag.reportToFile(std.fs.File.stderr(), err);
        return;
    };
    defer res.deinit();

    if (res.args.help != 0) return printGitCloneHelp(null);

    const url = res.positionals[0] orelse return printGitCloneHelp("Missing repository URL.");
    const destination = res.positionals[1] orelse return printGitCloneHelp("Missing destination path.");

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

fn printGitCloneHelp(reason: ?[]const u8) !void {
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

fn runLinkCommand(allocator: std.mem.Allocator, iter: *std.process.ArgIterator) !void {
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &link_params, link_parsers, iter, .{
        .allocator = allocator,
        .diagnostic = &diag,
    }) catch |err| {
        try diag.reportToFile(std.fs.File.stderr(), err);
        return;
    };
    defer res.deinit();

    if (res.args.help != 0) return printLinkHelp(null);

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

    if (res.args.root) |root_path| {
        options.root_override = try allocator.dupe(u8, root_path);
    }
    if (res.args.target) |target_path| {
        options.home_override = try allocator.dupe(u8, target_path);
    }

    if (res.args.apply != 0) {
        options.dry_run = false;
    }

    // Load TOML configuration
    const base_root = options.root_override orelse "~/.dotfiles";
    const home_dir = try resolveHomeForLink(allocator, options.home_override);
    defer allocator.free(home_dir);
    const resolved_root = try resolvePathForLink(allocator, base_root, home_dir);
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

fn resolveHomeForLink(allocator: std.mem.Allocator, override: ?[]const u8) ![]const u8 {
    if (override) |value| return allocator.dupe(u8, value);
    return std.process.getEnvVarOwned(allocator, "HOME");
}

fn resolvePathForLink(allocator: std.mem.Allocator, path: []const u8, home: []const u8) ![]const u8 {
    if (path.len == 0) return error.InvalidPath;
    if (path[0] == '~') {
        if (path.len == 1) return allocator.dupe(u8, home);
        if (path[1] != '/')
            return error.UnsupportedTildeUser;
        return std.fs.path.join(allocator, &.{ home, path[2..] });
    }
    if (std.fs.path.isAbsolute(path)) {
        return allocator.dupe(u8, path);
    }
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, path });
}

fn loadLinkConfig(allocator: std.mem.Allocator, root: []const u8) !?[]const []const u8 {
    // Search order:
    // 1. Project directory: .hola.toml, hola.toml
    // 2. XDG config directory: ~/.config/hola/hola.toml
    const project_config_paths = [_][]const u8{ ".hola.toml", "hola.toml" };
    var config_file: ?std.fs.File = null;
    var config_path: []const u8 = undefined;

    // Try project directory first
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

    // If not found in project directory, try XDG config directory
    if (config_file == null) {
        const xdg = @import("xdg.zig").XDG.init(allocator);
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

    // No config file found, use defaults
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
        std.log.warn("Failed to parse {s}: {s}, using defaults", .{ config_path, @errorName(err) });
        return null;
    };
    defer parsed.deinit();

    if (parsed.value.dotfiles) |dotfiles_config| {
        if (dotfiles_config.ignore) |patterns| {
            // Copy patterns to owned memory
            var owned_patterns = try allocator.alloc([]const u8, patterns.len);
            for (patterns, 0..) |pattern, i| {
                owned_patterns[i] = try allocator.dupe(u8, pattern);
            }
            return owned_patterns;
        }
    }

    return null;
}

fn printLinkHelp(reason: ?[]const u8) !void {
    const out = std.fs.File.stdout();
    if (reason) |msg| {
        try out.writeAll(msg);
        try out.writeAll("\n\n");
    }
    try out.writeAll(
        \\link
        \\  hola link [--root <path>] [--target <path>] [--apply]
        \\
        \\Flags
        \\  --root <path>     Override the dotfiles root (default ~/.dotfiles)
        \\  --target <path>   Override the link destination (default $HOME)
        \\  --apply           Actually create links (dry-run only right now)
        \\
        \\Example
        \\  hola link --root ~/workspace/dotfiles --target /tmp/link-playground
        \\
    );
}

fn runDockAppsCommand(allocator: std.mem.Allocator, iter: *std.process.ArgIterator) !void {
    _ = iter;

    const home_dir = std.process.getEnvVarOwned(allocator, "HOME") catch {
        std.debug.print("Error: HOME environment variable not set\n", .{});
        return;
    };
    defer allocator.free(home_dir);

    const dock_plist_path = try std.fmt.allocPrint(allocator, "{s}/Library/Preferences/com.apple.dock.plist", .{home_dir});
    defer allocator.free(dock_plist_path);

    std.debug.print("Reading Dock plist: {s}\n\n", .{dock_plist_path});

    var dict = plist.Dictionary.loadFromFile(allocator, dock_plist_path) catch |err| {
        std.debug.print("Error loading Dock plist: {}\n", .{err});
        return;
    };
    defer dict.deinit();

    // Get persistent-apps array
    var persistent_apps_value = dict.get("persistent-apps") orelse {
        std.debug.print("No 'persistent-apps' key found in Dock plist\n", .{});
        return;
    };
    defer persistent_apps_value.deinit(allocator);

    const apps_array = switch (persistent_apps_value) {
        .array => |arr| arr,
        else => {
            std.debug.print("Error: 'persistent-apps' is not an array\n", .{});
            return;
        },
    };

    std.debug.print("Found {d} applications in Dock:\n\n", .{apps_array.len});

    for (apps_array, 0..) |app_item, i| {
        const app_dict = switch (app_item) {
            .dictionary => |d| d,
            else => {
                std.debug.print("  [{d}] (invalid format)\n", .{i + 1});
                continue;
            },
        };

        // Get tile-data
        var tile_data_value = app_dict.get("tile-data") orelse {
            std.debug.print("  [{d}] (no tile-data)\n", .{i + 1});
            continue;
        };
        defer tile_data_value.deinit(allocator);

        const tile_data = switch (tile_data_value) {
            .dictionary => |d| d,
            else => {
                std.debug.print("  [{d}] (tile-data is not a dict)\n", .{i + 1});
                continue;
            },
        };

        // Get file-label (app name)
        const file_label_value = tile_data.get("file-label");
        var app_name: []const u8 = "(no name)";
        var app_name_owned: ?plist.Value = null;
        if (file_label_value) |label| {
            app_name_owned = label;
            switch (label) {
                .string => |s| {
                    app_name = s;
                },
                else => {},
            }
        }

        // Get file-data -> _CFURLString (app path)
        const file_data_value = tile_data.get("file-data");
        var app_path: []const u8 = "(no path)";
        var app_path_owned: ?plist.Value = null;
        if (file_data_value) |data| {
            app_path_owned = data;
            const file_data_dict = switch (data) {
                .dictionary => |d| d,
                else => {
                    continue;
                },
            };

            const url_string_value = file_data_dict.get("_CFURLString");
            if (url_string_value) |url_str| {
                app_path_owned = url_str;
                switch (url_str) {
                    .string => |s| {
                        app_path = s;
                    },
                    else => {},
                }
            }
        }

        std.debug.print("  [{d}] {s}\n", .{ i + 1, app_name });
        if (!std.mem.eql(u8, app_path, "(no path)")) {
            std.debug.print("      Path: {s}\n", .{app_path});
        }

        // Clean up after printing
        if (app_path_owned) |path_val| {
            path_val.deinit(allocator);
        }
        if (app_name_owned) |name_val| {
            name_val.deinit(allocator);
        }
    }
}

fn runApplescriptCommand(allocator: std.mem.Allocator, iter: *std.process.ArgIterator) !void {
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &applescript_params, applescript_parsers, iter, .{
        .allocator = allocator,
        .diagnostic = &diag,
    }) catch |err| {
        try diag.reportToFile(std.fs.File.stderr(), err);
        return;
    };
    defer res.deinit();

    if (res.args.help != 0) return printApplescriptHelp(null);

    var script_source: []const u8 = undefined;
    var script_owned: ?[]u8 = null;
    defer if (script_owned) |s| allocator.free(s);

    if (res.args.file) |file_path| {
        // Read script from file
        const file = std.fs.openFileAbsolute(file_path, .{}) catch |err| {
            std.debug.print("Error opening file '{s}': {}\n", .{ file_path, err });
            return;
        };
        defer file.close();

        script_owned = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
        script_source = script_owned.?;
    } else {
        // Get script from command line argument
        script_source = res.positionals[0] orelse return printApplescriptHelp("Missing script argument.");
    }

    // Execute AppleScript
    const result = applescript.execute(allocator, script_source) catch |err| {
        std.debug.print("Error executing AppleScript: {}\n", .{err});
        return;
    };
    defer allocator.free(result);

    // Print result (empty string means script executed but returned nothing)
    if (result.len > 0) {
        std.debug.print("{s}\n", .{result});
    } else {
        std.debug.print("(script executed successfully, no return value)\n", .{});
    }
}

fn printApplescriptHelp(reason: ?[]const u8) !void {
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
        \\  hola applescript "1 + 1"
        \\  hola applescript "tell application \"Finder\" to display dialog \"Hello\""
        \\  hola applescript --file script.applescript
        \\
        \\Note: This command is only available on macOS.
        \\
    );
}

fn runApplyCommand(allocator: std.mem.Allocator, iter: *std.process.ArgIterator) !void {
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &apply_params, apply_parsers, iter, .{
        .allocator = allocator,
        .diagnostic = &diag,
    }) catch |err| {
        try diag.reportToFile(std.fs.File.stderr(), err);
        return;
    };
    defer res.deinit();

    if (res.args.help != 0) return printApplyHelp(null);

    // Determine config root
    const config_root = if (res.args.root) |root|
        try allocator.dupe(u8, root)
    else
        try getDefaultConfigRoot(allocator);
    defer allocator.free(config_root);

    const dry_run = @field(res.args, "dry-run") != 0;

    try apply_module.run(allocator, .{
        .config_root = config_root,
        .dry_run = dry_run,
    });
}

fn getDefaultConfigRoot(allocator: std.mem.Allocator) ![]const u8 {
    const xdg = @import("xdg.zig").XDG.init(allocator);
    return try xdg.getDefaultConfigRoot();
}

fn printApplyHelp(reason: ?[]const u8) !void {
    const out = std.fs.File.stdout();
    if (reason) |msg| {
        try out.writeAll(msg);
        try out.writeAll("\n\n");
    }
    try out.writeAll(
        \\apply
        \\  hola apply [--root <path>] [--dry-run]
        \\
        \\Execute the full bootstrap sequence:
        \\  1. Link dotfiles
        \\  2. Install Homebrew (if needed)
        \\  3. Install Homebrew packages and casks (parallel)
        \\  4. Install mise (if needed)
        \\  5. Install mise tools (parallel)
        \\  6. Run provision script (provision.rb)
        \\
        \\Flags
        \\  --root <path>    Override config root (default: ~/.local/share/hola/config)
        \\  --dry-run        Show what would be done without actually doing it
        \\
        \\Example
        \\  hola apply
        \\  hola apply --root ~/workspace/my-config
        \\  hola apply --dry-run
        \\
    );
}

fn runProvisionCommand(allocator: std.mem.Allocator, iter: *std.process.ArgIterator) !void {
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &provision_params, provision_parsers, iter, .{
        .allocator = allocator,
        .diagnostic = &diag,
    }) catch |err| {
        try diag.reportToFile(std.fs.File.stderr(), err);
        return;
    };
    defer res.deinit();

    if (res.args.help != 0) return printProvisionHelp(null);

    const script_path = res.positionals[0] orelse return printProvisionHelp("Missing provision file path.");

    provision.run(allocator, .{ .script_path = script_path }) catch |err| {
        std.debug.print("Provision failed: {}\n", .{err});
    };
}

fn printProvisionHelp(reason: ?[]const u8) !void {
    const out = std.fs.File.stdout();
    if (reason) |msg| {
        try out.writeAll(msg);
        try out.writeAll("\n\n");
    }
    try out.writeAll(
        \\provision
        \\  hola provision <file>
        \\
        \\Run a provisioning script that defines infrastructure resources.
        \\
        \\Example
        \\  hola provision provision.rb
        \\
        \\Ruby DSL:
        \\  file "/tmp/config" do
        \\    content "hello\\n"
        \\    mode "0644"
        \\    notifies "execute[reload]", timing: :delayed
        \\  end
        \\
        \\  execute "deploy" do
        \\    command "bash deploy.sh"
        \\    cwd "/opt/app"
        \\    only_if { File.exist?("/opt/app") }
        \\  end
        \\
    );
}

fn printMainHelp(unknown: ?[]const u8) !void {
    const gpa = std.heap.page_allocator;

    if (unknown) |cmd| {
        const error_msg = try std.fmt.allocPrint(gpa, "Unknown command \"{s}\"", .{cmd});
        defer gpa.free(error_msg);
        help_formatter.HelpFormatter.printError(error_msg);
        help_formatter.HelpFormatter.newline();
    }

    // Header with branding (Bun style)
    help_formatter.HelpFormatter.printHeader("Hola", "Brewfile + mise + dotfiles = your dev environment\n");

    // Usage section (Bun style with colon on same line)
    help_formatter.HelpFormatter.usageHeader();
    help_formatter.HelpFormatter.printUsage("hola", "<command> [...flags>");
    help_formatter.HelpFormatter.newline();

    // Commands section with table alignment
    help_formatter.HelpFormatter.sectionHeader("Commands");
    const commands = [_]help_formatter.HelpFormatter.CommandItem{
        .{ .command = "git-clone", .description = "Clone repositories with embedded libgit2 client" },
        .{ .command = "link", .description = "Scan ~/.dotfiles and show link plan (dry-run mode)" },
        .{ .command = "dock-apps", .description = "List applications in macOS Dock" },
        .{ .command = "applescript", .description = "Execute AppleScript via macOS system API" },
        .{ .command = "provision", .description = "Run infrastructure-as-code scripts" },
        .{ .command = "apply", .description = "Execute full bootstrap sequence" },
        .{ .command = "help", .description = "Show this help menu" },
    };
    help_formatter.HelpFormatter.printCommandTable(&commands);
    help_formatter.HelpFormatter.newline();

    // Examples section with table alignment
    help_formatter.HelpFormatter.sectionHeader("Examples");
    const examples = [_]help_formatter.HelpFormatter.ExampleItem{
        .{ .prefix = "Clone config:", .command = "git-clone https://github.com/user/hola ~/.local/share/hola/config --branch main" },
        .{ .prefix = "Link dotfiles:", .command = "link --root ~/.dotfiles" },
        .{ .prefix = "Dock utilities:", .command = "dock-apps" },
        .{ .prefix = "AppleScript:", .command = "applescript \"1 + 1\"" },
        .{ .prefix = "AppleScript file:", .command = "applescript --file script.applescript" },
        .{ .prefix = "Infrastructure:", .command = "provision provision.rb" },
        .{ .prefix = "Full bootstrap:", .command = "apply" },
        .{ .prefix = "Dry run:", .command = "apply --dry-run" },
    };
    help_formatter.HelpFormatter.printExamples(&examples);
    help_formatter.HelpFormatter.newline();

    // Footer
    help_formatter.HelpFormatter.printNote("Use 'hola <command> --help' for detailed command information");
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
