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
const node_info = @import("node_info.zig");
const build_options = @import("build_options");

const is_macos = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;

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
    \\-h, --help                 Show help for link
    \\--dotfiles <dotfiles_dir>  Dotfiles repository location (default ~/.dotfiles)
    \\--home <home_dir>          Home directory to link into (default $HOME)
    \\--dry-run                  Preview changes without creating links
    \\
);
const link_parsers = .{
    .dotfiles_dir = clap.parsers.string,
    .home_dir = clap.parsers.string,
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
    \\-h, --help                 Show help for apply
    \\--dotfiles <dotfiles_dir>  Dotfiles repository location (default ~/.dotfiles)
    \\--github <repo>            Clone from GitHub via SSH (format: username/repo)
    \\--repo <url>               Clone from full repository URL (any protocol)
    \\--branch <name>            Git branch to checkout (default: repository's default branch)
    \\--dry-run                  Show what would be done without actually doing it
    \\
);
const apply_parsers = .{
    .dotfiles_dir = clap.parsers.string,
    .repo = clap.parsers.string,
    .url = clap.parsers.string,
    .name = clap.parsers.string,
};

const provision_params = clap.parseParamsComptime(
    \\-h, --help            Show help for provision
    \\-o, --output <MODE>   Output mode: pretty (default) or plain
    \\<path>                Path to provision file (.rb)
    \\
);
const provision_parsers = .{
    .path = clap.parsers.string,
    .MODE = clap.parsers.string,
};

const node_info_params = clap.parseParamsComptime(
    \\-h, --help            Show help for node-info
    \\
);
const node_info_parsers = .{};

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
    if (std.mem.eql(u8, command, "dock")) {
        if (is_macos) {
            try runDockCommand(allocator, iter);
        } else {
            std.debug.print("Error: dock command is only available on macOS\n", .{});
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
    if (std.mem.eql(u8, command, "node-info")) {
        try runNodeInfoCommand(allocator, iter);
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

    // Get actual $HOME for path resolution
    const actual_home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(actual_home);

    // Resolve dotfiles path (could be relative or contain ~)
    if (res.args.dotfiles) |dotfiles_path| {
        options.root_override = try resolvePathForLink(allocator, dotfiles_path, actual_home);
    }

    // Resolve home path (could be relative or contain ~)
    if (res.args.home) |home_path| {
        options.home_override = try resolvePathForLink(allocator, home_path, actual_home);
    }

    // Default behavior: apply changes (dry_run = false)
    // Only set dry_run = true if --dry-run flag is specified
    const dry_run_flag = @field(res.args, "dry-run");
    if (dry_run_flag != 0) {
        options.dry_run = true;
    }

    // Load TOML configuration
    const base_root = options.root_override orelse "~/.dotfiles";
    const resolved_root = try resolvePathForLink(allocator, base_root, actual_home);
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

fn getDefaultDotfilesPath(allocator: std.mem.Allocator, home: []const u8) ![]const u8 {
    // Check if saved preference exists at ~/.local/state/hola/dotfiles
    const state_link = try std.fs.path.join(allocator, &.{ home, ".local/state/hola/dotfiles" });
    defer allocator.free(state_link);

    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.fs.readLinkAbsolute(state_link, &link_buf)) |target| {
        // Saved preference exists, use it
        return allocator.dupe(u8, target);
    } else |_| {
        // No saved preference, use default ~/.dotfiles
        return std.fs.path.join(allocator, &.{ home, ".dotfiles" });
    }
}

fn saveDotfilesPreference(allocator: std.mem.Allocator, dotfiles_path: []const u8, home: []const u8) !void {
    const state_dir = try std.fs.path.join(allocator, &.{ home, ".local/state/hola" });
    defer allocator.free(state_dir);

    const state_link = try std.fs.path.join(allocator, &.{ state_dir, "dotfiles" });
    defer allocator.free(state_link);

    // Create ~/.local/state/hola directory if it doesn't exist
    std.fs.makeDirAbsolute(state_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Remove existing symlink if present
    std.fs.deleteFileAbsolute(state_link) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    // Create new symlink pointing to dotfiles_path
    try std.fs.symLinkAbsolute(dotfiles_path, state_link, .{});
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
        logger.warn("Failed to parse {s}: {s}, using defaults", .{ config_path, @errorName(err) });
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

fn runDockCommand(allocator: std.mem.Allocator, iter: *std.process.ArgIterator) !void {
    _ = iter;

    // Helper function to read Dock preferences using CFPreferences API
    const readDockPref = struct {
        fn call(alloc: std.mem.Allocator, key: []const u8) !?plist.Value {
            const c = @cImport({
                @cInclude("CoreFoundation/CoreFoundation.h");
            });

            // Convert key to CFString
            const key_cf = c.CFStringCreateWithCString(null, key.ptr, c.kCFStringEncodingUTF8);
            if (key_cf == null) return error.OutOfMemory;
            defer c.CFRelease(key_cf);

            // Read preference using CFPreferences
            const domain = c.CFStringCreateWithCString(null, "com.apple.dock", c.kCFStringEncodingUTF8);
            if (domain == null) return error.OutOfMemory;
            defer c.CFRelease(domain);

            const value_cf = c.CFPreferencesCopyValue(key_cf, domain, c.kCFPreferencesCurrentUser, c.kCFPreferencesCurrentHost);
            if (value_cf == null) {
                return null;
            }
            defer c.CFRelease(value_cf);

            // Convert CFTypeRef to plist.Value
            const type_id = c.CFGetTypeID(value_cf);

            if (type_id == c.CFNumberGetTypeID()) {
                const num = @as(c.CFNumberRef, @ptrCast(value_cf));
                var int_val: c_longlong = undefined;
                if (c.CFNumberGetValue(num, c.kCFNumberLongLongType, &int_val) != 0) {
                    return plist.Value{ .integer = @as(i64, @intCast(int_val)) };
                }
                return null;
            } else if (type_id == c.CFBooleanGetTypeID()) {
                const bool_val = c.CFBooleanGetValue(@as(c.CFBooleanRef, @ptrCast(value_cf)));
                return plist.Value{ .boolean = bool_val != 0 };
            } else if (type_id == c.CFStringGetTypeID()) {
                const str = @as(c.CFStringRef, @ptrCast(value_cf));
                const max_len = c.CFStringGetMaximumSizeForEncoding(c.CFStringGetLength(str), c.kCFStringEncodingUTF8);
                var buf = try alloc.alloc(u8, @as(usize, @intCast(max_len)) + 1);
                if (c.CFStringGetCString(str, buf.ptr, @as(c_long, @intCast(buf.len)), c.kCFStringEncodingUTF8) == 0) {
                    alloc.free(buf);
                    return null;
                }
                // Trim to actual length (null-terminated)
                const len = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
                const str_slice = try alloc.dupe(u8, buf[0..len]);
                alloc.free(buf);
                return plist.Value{ .string = str_slice };
            } else if (type_id == c.CFArrayGetTypeID()) {
                // Return the array as-is for persistent-apps
                return plist.Value{ .array = undefined }; // We'll handle this specially
            }

            return null;
        }
    }.call;

    const home_dir = std.process.getEnvVarOwned(allocator, "HOME") catch {
        std.debug.print("Error: HOME environment variable not set\n", .{});
        return;
    };
    defer allocator.free(home_dir);

    const dock_plist_path = try std.fmt.allocPrint(allocator, "{s}/Library/Preferences/com.apple.dock.plist", .{home_dir});
    defer allocator.free(dock_plist_path);

    var dict = plist.Dictionary.loadFromFile(allocator, dock_plist_path) catch |err| {
        std.debug.print("Error loading Dock plist: {}\n", .{err});
        return;
    };
    defer dict.deinit();

    // Collect app paths (still from plist since persistent-apps is complex)
    var app_paths = std.ArrayList([]const u8).empty;
    defer {
        for (app_paths.items) |path| {
            allocator.free(path);
        }
        app_paths.deinit(allocator);
    }

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

    // Extract app paths
    for (apps_array) |app_item| {
        const app_dict = switch (app_item) {
            .dictionary => |d| d,
            else => continue,
        };

        var tile_data_value = app_dict.get("tile-data") orelse continue;
        defer tile_data_value.deinit(allocator);

        const tile_data = switch (tile_data_value) {
            .dictionary => |d| d,
            else => continue,
        };

        const file_data_value = tile_data.get("file-data") orelse continue;
        const file_data_dict = switch (file_data_value) {
            .dictionary => |d| d,
            else => continue,
        };
        defer file_data_value.deinit(allocator);

        const url_string_value = file_data_dict.get("_CFURLString") orelse continue;
        defer url_string_value.deinit(allocator);

        const app_path = switch (url_string_value) {
            .string => |s| s,
            else => continue,
        };

        try app_paths.append(allocator, try allocator.dupe(u8, app_path));
    }

    // Read Dock configuration settings using CFPreferences API
    var orientation_owned: ?[]u8 = null;
    defer if (orientation_owned) |s| allocator.free(s);

    const orientation = blk: {
        if (try readDockPref(allocator, "orientation")) |val| {
            defer val.deinit(allocator);
            break :blk switch (val) {
                .string => |s| blk2: {
                    orientation_owned = try allocator.dupe(u8, s);
                    break :blk2 orientation_owned.?;
                },
                else => "bottom",
            };
        }
        break :blk "bottom";
    };

    const autohide = blk: {
        if (try readDockPref(allocator, "autohide")) |val| {
            defer val.deinit(allocator);
            break :blk switch (val) {
                .boolean => |b| b,
                .integer => |i| i != 0,
                else => false,
            };
        }
        break :blk false;
    };

    const magnification = blk: {
        if (try readDockPref(allocator, "magnification")) |val| {
            defer val.deinit(allocator);
            break :blk switch (val) {
                .boolean => |b| b,
                .integer => |i| i != 0,
                else => false,
            };
        }
        break :blk false;
    };

    const tilesize = blk: {
        if (try readDockPref(allocator, "tilesize")) |val| {
            defer val.deinit(allocator);
            break :blk switch (val) {
                .integer => |i| i,
                .float => |f| @as(i64, @intFromFloat(f)),
                else => 50,
            };
        }
        break :blk 50;
    };

    const largesize = blk: {
        if (try readDockPref(allocator, "largesize")) |val| {
            defer val.deinit(allocator);
            break :blk switch (val) {
                .integer => |i| i,
                .float => |f| @as(i64, @intFromFloat(f)),
                else => 64,
            };
        }
        break :blk 64;
    };

    // Build output string atomically
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    try output.appendSlice(allocator, "macos_dock do\n");
    try output.appendSlice(allocator, "  apps [\n");

    for (app_paths.items) |path| {
        // Remove file:// prefix and decode URL
        const clean_path = if (std.mem.startsWith(u8, path, "file://"))
            path[7..]
        else
            path;

        // URL decode - allocate buffer and decode
        const decoded_buf = try allocator.alloc(u8, clean_path.len);
        defer allocator.free(decoded_buf);
        const decoded = std.Uri.percentDecodeBackwards(decoded_buf, clean_path);

        try output.appendSlice(allocator, "    '");
        try output.appendSlice(allocator, decoded);
        try output.appendSlice(allocator, "',\n");
    }

    try output.appendSlice(allocator, "  ]\n");
    try std.fmt.format(output.writer(allocator), "  orientation :{s}\n", .{orientation});
    try std.fmt.format(output.writer(allocator), "  autohide {s}\n", .{if (autohide) "true" else "false"});
    try std.fmt.format(output.writer(allocator), "  magnification {s}\n", .{if (magnification) "true" else "false"});
    try std.fmt.format(output.writer(allocator), "  tilesize {d}\n", .{tilesize});
    try std.fmt.format(output.writer(allocator), "  largesize {d}\n", .{largesize});
    try output.appendSlice(allocator, "end\n");

    // Print atomically
    std.debug.print("{s}", .{output.items});
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

    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);

    const dry_run = @field(res.args, "dry-run") != 0;

    // Check if both --github and --repo are specified
    if (res.args.github != null and res.args.repo != null) {
        std.debug.print("Error: Cannot specify both --github and --repo\n", .{});
        std.debug.print("Use --github for GitHub repos (username/repo format)\n", .{});
        std.debug.print("Use --repo for full URLs (any git URL)\n", .{});
        return error.ConflictingOptions;
    }

    // Handle --github flag: clone from GitHub via SSH
    if (res.args.github) |github_repo| {
        // Validate format (should be username/repo)
        if (std.mem.indexOfScalar(u8, github_repo, '/') == null) {
            std.debug.print("Error: --github must be in format 'username/repo'\n", .{});
            std.debug.print("Example: --github user/dotfiles\n", .{});
            return error.InvalidGithubFormat;
        }

        // Determine clone destination: use --dotfiles if specified, otherwise ~/.dotfiles
        const clone_dest = if (res.args.dotfiles) |dotfiles_path|
            try resolvePathForLink(allocator, dotfiles_path, home)
        else
            try std.fs.path.join(allocator, &.{ home, ".dotfiles" });
        defer allocator.free(clone_dest);

        // Check if destination already exists and is not empty
        if (std.fs.openDirAbsolute(clone_dest, .{ .iterate = true })) |dir_handle| {
            var dir = dir_handle;
            defer dir.close();

            var iter_dir = dir.iterate();
            if (try iter_dir.next()) |_| {
                // Directory exists and has contents
                std.debug.print("Warning: {s} already exists and is not empty\n", .{clone_dest});
                std.debug.print("Please remove it first or use --dotfiles to specify a different location\n", .{});
                return error.DotfilesAlreadyExists;
            }
        } else |_| {
            // Directory doesn't exist, we'll clone
        }

        if (!dry_run) {
            // Build GitHub URL (using SSH format: git@github.com:user/repo.git)
            const github_url = try std.fmt.allocPrint(allocator, "git@github.com:{s}.git", .{github_repo});
            defer allocator.free(github_url);

            std.debug.print("[clone] {s} -> {s}\n", .{ github_url, clone_dest });

            // Clone using our git client
            var client = try git.Client.init();
            defer client.deinit();

            var clone_options: git.CloneOptions = .{};
            if (res.args.branch) |branch_name| {
                clone_options.branch = branch_name;
            }

            client.clone(allocator, github_url, clone_dest, clone_options) catch |err| {
                std.debug.print("\n\x1b[31mError: Failed to clone repository\x1b[0m\n", .{});
                std.debug.print("Repository: {s}\n", .{github_url});
                std.debug.print("Destination: {s}\n", .{clone_dest});
                std.debug.print("\nPossible reasons:\n", .{});
                std.debug.print("  • Repository does not exist or is private\n", .{});
                std.debug.print("  • SSH key not set up or not added to ssh-agent\n", .{});
                std.debug.print("  • SSH key not added to GitHub account\n", .{});
                std.debug.print("  • Network connectivity issues\n", .{});
                if (res.args.branch) |branch| {
                    std.debug.print("  • Branch '{s}' does not exist\n", .{branch});
                }
                std.debug.print("\nTo set up SSH authentication:\n", .{});
                std.debug.print("  1. Generate SSH key: ssh-keygen -t ed25519 -C \"your@email.com\"\n", .{});
                std.debug.print("  2. Add to ssh-agent: ssh-add ~/.ssh/id_ed25519\n", .{});
                std.debug.print("  3. Add public key to GitHub: https://github.com/settings/keys\n", .{});
                std.debug.print("  4. Test connection: ssh -T git@github.com\n", .{});
                std.debug.print("\nCheck the log file for detailed error information.\n", .{});
                if (logger.getLogPath()) |log_path| {
                    std.debug.print("Log file: {s}\n", .{log_path});
                }
                return err;
            };
            std.debug.print("[done] Cloned {s}\n\n", .{github_repo});
        } else {
            // Build GitHub URL for dry-run display
            const github_url = try std.fmt.allocPrint(allocator, "git@github.com:{s}.git", .{github_repo});
            defer allocator.free(github_url);
            std.debug.print("[dry-run] Would clone {s} to {s}\n", .{ github_url, clone_dest });
        }
    }

    // Handle --repo flag: clone from full repository URL
    if (res.args.repo) |repo_url| {
        // Determine clone destination: use --dotfiles if specified, otherwise ~/.dotfiles
        const clone_dest = if (res.args.dotfiles) |dotfiles_path|
            try resolvePathForLink(allocator, dotfiles_path, home)
        else
            try std.fs.path.join(allocator, &.{ home, ".dotfiles" });
        defer allocator.free(clone_dest);

        // Check if destination already exists and is not empty
        if (std.fs.openDirAbsolute(clone_dest, .{ .iterate = true })) |dir_handle| {
            var dir = dir_handle;
            defer dir.close();

            var iter_dir = dir.iterate();
            if (try iter_dir.next()) |_| {
                // Directory exists and has contents
                std.debug.print("Warning: {s} already exists and is not empty\n", .{clone_dest});
                std.debug.print("Please remove it first or use --dotfiles to specify a different location\n", .{});
                return error.DotfilesAlreadyExists;
            }
        } else |_| {
            // Directory doesn't exist, we'll clone
        }

        if (!dry_run) {
            std.debug.print("[clone] {s} -> {s}\n", .{ repo_url, clone_dest });

            // Clone using our git client
            var client = try git.Client.init();
            defer client.deinit();

            var clone_options: git.CloneOptions = .{};
            if (res.args.branch) |branch_name| {
                clone_options.branch = branch_name;
            }

            client.clone(allocator, repo_url, clone_dest, clone_options) catch |err| {
                std.debug.print("\n\x1b[31mError: Failed to clone repository\x1b[0m\n", .{});
                std.debug.print("Repository: {s}\n", .{repo_url});
                std.debug.print("Destination: {s}\n", .{clone_dest});
                std.debug.print("\nPossible reasons:\n", .{});
                std.debug.print("  • Repository does not exist or is private\n", .{});
                std.debug.print("  • Invalid repository URL\n", .{});
                std.debug.print("  • Authentication required (check credentials)\n", .{});
                std.debug.print("  • Network connectivity issues\n", .{});
                if (res.args.branch) |branch| {
                    std.debug.print("  • Branch '{s}' does not exist\n", .{branch});
                }
                std.debug.print("\nFor SSH URLs (git@host:path), make sure:\n", .{});
                std.debug.print("  • SSH key is set up and added to ssh-agent\n", .{});
                std.debug.print("  • Public key is added to the Git hosting service\n", .{});
                std.debug.print("\nFor HTTPS URLs, you may need to configure credentials.\n", .{});
                std.debug.print("\nCheck the log file for detailed error information.\n", .{});
                if (logger.getLogPath()) |log_path| {
                    std.debug.print("Log file: {s}\n", .{log_path});
                }
                return err;
            };
            std.debug.print("[done] Cloned repository\n\n", .{});
        } else {
            std.debug.print("[dry-run] Would clone {s} to {s}\n", .{ repo_url, clone_dest });
        }
    }

    // Determine dotfiles root
    const config_root = if (res.args.dotfiles) |dotfiles_path| blk: {
        // User specified a dotfiles path, resolve it
        const resolved = try resolvePathForLink(allocator, dotfiles_path, home);
        // Save this preference for future use (unless dry-run)
        if (!dry_run) {
            try saveDotfilesPreference(allocator, resolved, home);
        }
        break :blk resolved;
    } else blk: {
        // Use saved preference or default
        break :blk try getDefaultDotfilesPath(allocator, home);
    };
    defer allocator.free(config_root);

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
        \\  hola apply [OPTIONS]
        \\
        \\Execute the full bootstrap sequence:
        \\  1. Clone dotfiles (if --github or --repo specified)
        \\  2. Link dotfiles
        \\  3. Install Homebrew (if needed)
        \\  4. Install Homebrew packages and casks (parallel)
        \\  5. Install mise (if needed)
        \\  6. Install mise tools (parallel)
        \\  7. Run provision script (provision.rb)
        \\
        \\Flags
        \\  --github <repo>    Clone from GitHub via SSH (format: username/dotfiles)
        \\                     Shorthand for git@github.com:username/dotfiles.git
        \\  --repo <url>       Clone from full repository URL (any protocol)
        \\                     Supports SSH, HTTPS, and other Git protocols
        \\  --branch <name>    Git branch to checkout
        \\                     If not specified, uses repository's default branch
        \\  --dotfiles <path>  Dotfiles repository location (default ~/.dotfiles)
        \\  --dry-run          Show what would be done without actually doing it
        \\
        \\Examples
        \\  # GitHub via SSH (recommended)
        \\  hola apply --github username/dotfiles
        \\  hola apply --github username/dotfiles --branch develop
        \\
        \\  # Full URLs (any Git hosting)
        \\  hola apply --repo git@github.com:username/dotfiles.git
        \\  hola apply --repo https://github.com/username/dotfiles.git
        \\
        \\  # Use local directory
        \\  hola apply --dotfiles ~/Dropbox/dotfiles
        \\
        \\  # Preview changes
        \\  hola apply --github username/dotfiles --dry-run
        \\
        \\Note: SSH URLs require SSH key authentication:
        \\  • Generate key: ssh-keygen -t ed25519 -C "your@email.com"
        \\  • Add to agent: ssh-add ~/.ssh/id_ed25519
        \\  • Add to GitHub/GitLab: Settings > SSH keys
        \\  • Test: ssh -T git@github.com
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

    const script_path_or_url = res.positionals[0] orelse return printProvisionHelp("Missing provision file path or URL.");

    // Determine output mode
    var use_pretty_output = true; // Default to pretty
    if (res.args.output) |output_mode| {
        if (std.mem.eql(u8, output_mode, "plain")) {
            use_pretty_output = false;
        } else if (std.mem.eql(u8, output_mode, "pretty")) {
            use_pretty_output = true;
        } else {
            std.debug.print("Invalid output mode: {s}\n", .{output_mode});
            std.debug.print("Valid modes: pretty, plain\n", .{});
            return error.InvalidOutputMode;
        }
    }

    // Check if input is a URL
    const is_url = std.mem.startsWith(u8, script_path_or_url, "http://") or
        std.mem.startsWith(u8, script_path_or_url, "https://");

    var temp_file_path: ?[]const u8 = null;
    defer if (temp_file_path) |path| {
        std.fs.deleteFileAbsolute(path) catch {};
        allocator.free(path);
    };

    const script_path = if (is_url) blk: {
        // Parse URL to check for Basic Auth
        const uri = std.Uri.parse(script_path_or_url) catch |err| {
            std.debug.print("Error: Invalid URL: {}\n", .{err});
            return error.InvalidUrl;
        };

        // Build display URL (mask password if present)
        const display_url = if (uri.password != null) display_blk: {
            const user_part = if (uri.user) |u| u.percent_encoded else "";
            const host_part = if (uri.host) |h| h.percent_encoded else "";
            break :display_blk try std.fmt.allocPrint(allocator, "{s}://{s}:***@{s}{s}", .{
                uri.scheme,
                user_part,
                host_part,
                uri.path.percent_encoded,
            });
        } else script_path_or_url;
        defer if (uri.password != null) allocator.free(display_url);

        std.debug.print("[fetch] Downloading provision script from {s}\n", .{display_url});

        // Get system temporary directory ($TMPDIR or fallback to /tmp)
        const temp_dir = std.process.getEnvVarOwned(allocator, "TMPDIR") catch
            try allocator.dupe(u8, "/tmp");
        defer allocator.free(temp_dir);

        // Create temporary file with unique name
        const temp_file = try std.fmt.allocPrint(allocator, "{s}/provision-{d}.rb", .{ temp_dir, std.time.timestamp() });
        temp_file_path = temp_file;

        // Use http_utils to download
        const http_utils = @import("http_utils.zig");
        const result = http_utils.downloadFile(allocator, script_path_or_url, temp_file, .{}) catch |err| {
            std.debug.print("\nError: Failed to download provision script: {}\n", .{err});
            std.debug.print("URL: {s}\n", .{display_url});
            std.debug.print("\nPossible reasons:\n", .{});
            std.debug.print("  • URL is not accessible\n", .{});
            std.debug.print("  • Network connectivity issues\n", .{});
            std.debug.print("  • Invalid credentials (if using Basic Auth)\n", .{});
            std.debug.print("  • Server returned an error\n", .{});
            return error.DownloadFailed;
        };

        // Clean up result
        if (result.etag) |etag| allocator.free(etag);
        if (result.last_modified) |lm| allocator.free(lm);

        std.debug.print("[fetch] Downloaded to {s}\n", .{temp_file});
        break :blk temp_file;
    } else script_path_or_url;

    provision.run(allocator, .{
        .script_path = script_path,
        .use_pretty_output = use_pretty_output,
    }) catch |err| {
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
        \\  hola provision [OPTIONS] <file-or-url>
        \\
        \\Run a provisioning script that defines infrastructure resources.
        \\Supports both local files and remote URLs.
        \\
        \\Options:
        \\  -o, --output MODE    Output mode: pretty (default) or plain
        \\
        \\Examples
        \\  # Local file
        \\  hola provision provision.rb
        \\  hola provision ~/.config/hola/provision.rb
        \\
        \\  # Remote URL
        \\  hola provision https://example.com/provision.rb
        \\  hola provision https://username:password@example.com/provision.rb
        \\  hola provision https://raw.githubusercontent.com/user/dotfiles/master/.config/hola/provision.rb
        \\
        \\  # With output mode
        \\  hola provision --output plain provision.rb
        \\
        \\Ruby DSL:
        \\  file "/tmp/config" do
        \\    content "hello\n"
        \\    mode "0644"
        \\    notifies :run, "execute[reload]", :delayed
        \\  end
        \\
        \\  execute "deploy" do
        \\    command "bash deploy.sh"
        \\    cwd "/opt/app"
        \\    only_if { File.exist?("/opt/app") }
        \\  end
        \\
        \\  # Subscribes (alternative to notifies)
        \\  execute "restart" do
        \\    command "systemctl restart app"
        \\    action :nothing
        \\    subscribes :run, "file[/etc/app/config]", :delayed
        \\  end
        \\
    );
}

fn runNodeInfoCommand(allocator: std.mem.Allocator, iter: *std.process.ArgIterator) !void {
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &node_info_params, node_info_parsers, iter, .{
        .allocator = allocator,
        .diagnostic = &diag,
    }) catch |err| {
        try diag.reportToFile(std.fs.File.stderr(), err);
        return;
    };
    defer res.deinit();

    if (res.args.help != 0) return printNodeInfoHelp(null);

    try printNodeInfo(allocator);
}

fn printNodeInfo(allocator: std.mem.Allocator) !void {
    const node = try node_info.getNodeInfo(allocator);
    defer node.deinit(allocator);

    // Use std.json.fmt for proper JSON serialization
    const json_str = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(node, .{ .whitespace = .indent_2 })});
    defer allocator.free(json_str);

    const stdout = std.fs.File.stdout();
    try stdout.writeAll(json_str);
    try stdout.writeAll("\n");
}

fn printNodeInfoHelp(reason: ?[]const u8) !void {
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
    const commands = [_]help_formatter.HelpFormatter.CommandItem{
        .{ .command = "git-clone", .description = "Clone repositories with embedded libgit2 client" },
        .{ .command = "link", .description = "Create symlinks from dotfiles to home directory" },
        .{ .command = "dock", .description = "Show current macOS Dock configuration" },
        .{ .command = "applescript", .description = "Execute AppleScript via macOS system API" },
        .{ .command = "provision", .description = "Run infrastructure-as-code scripts" },
        .{ .command = "node-info", .description = "Display complete node information (like Chef Ohai)" },
        .{ .command = "apply", .description = "Execute full bootstrap sequence" },
        .{ .command = "help", .description = "Show this help menu" },
    };
    help_formatter.HelpFormatter.printCommandTable(&commands);
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
