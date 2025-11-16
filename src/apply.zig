const std = @import("std");
const builtin = @import("builtin");
const dotfiles = @import("dotfiles.zig");
const brew = @import("brew.zig");
const apt_bootstrap = if (builtin.os.tag == .linux) @import("apt_bootstrap.zig") else struct {};
const provision = @import("provision.zig");
const modern_display = @import("modern_provision_display.zig");
const logger = @import("logger.zig");
const notifications = @import("notifications.zig");
const help_formatter = @import("help_formatter.zig");
const command_runner = @import("command_runner.zig");

const is_macos = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;

/// Helper: find an executable by searching PATH, returning its absolute path if found.
fn findExecutableInPath(allocator: std.mem.Allocator, names: []const []const u8) !?[]const u8 {
    const path_env = std.process.getEnvVarOwned(allocator, "PATH") catch return null;
    defer allocator.free(path_env);

    var it = std.mem.splitScalar(u8, path_env, std.fs.path.delimiter);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        for (names) |name| {
            const full_path = try std.fs.path.join(allocator, &.{ dir, name });
            defer allocator.free(full_path);

            if (std.fs.accessAbsolute(full_path, .{})) |_| {
                return try allocator.dupe(u8, full_path);
            } else |_| {}
        }
    }

    return null;
}

/// Helper: prefer apt-get, then apt, for Debian-like systems.
fn findAptExecutable(allocator: std.mem.Allocator) !?[]const u8 {
    const candidates = [_][]const u8{ "apt-get", "apt" };
    return try findExecutableInPath(allocator, &candidates);
}

/// Helper: given a list of root directories and a leaf name (e.g. "provision.rb"),
/// return the first existing absolute path, or null if none exist.
fn findFirstExistingJoinedPath(
    allocator: std.mem.Allocator,
    roots: []const []const u8,
    leaf: []const u8,
) !?[]const u8 {
    for (roots) |root| {
        const path = try std.fs.path.join(allocator, &.{ root, leaf });
        defer allocator.free(path);

        std.fs.accessAbsolute(path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };

        // Found the first match; return an owned copy of the path.
        return try allocator.dupe(u8, path);
    }

    return null;
}

/// Apply command - executes the full bootstrap sequence
pub const ApplyOptions = struct {
    config_root: []const u8, // Root directory containing config files
    dry_run: bool = false,
};

/// Platform-specific bootstrap implementations.
///
/// Currently:
/// - macOS: Homebrew + mise
/// - Linux (Debian/Ubuntu-style): apt + mise
/// Other platforms fall back to macOS implementation for now.
const MacosBootstrap = struct {
    pub fn installFoundation(allocator: std.mem.Allocator, display: *modern_display.ModernProvisionDisplay) !void {
        try installHomebrew(allocator, display);
    }

    pub fn installPackagesParallel(allocator: std.mem.Allocator, config_root: []const u8) !void {
        try installPackagesParallelImpl(allocator, config_root);
    }
};

const AptBootstrap = if (is_linux) struct {
    pub fn installFoundation(allocator: std.mem.Allocator, display: *modern_display.ModernProvisionDisplay) !void {
        _ = allocator;
        try display.showInfo("Using apt for package management (no separate foundation step)");
    }

    pub fn installPackagesParallel(allocator: std.mem.Allocator, config_root: []const u8) !void {
        // For apt we run installs sequentially: apt first, then mise.
        var apt_display = try modern_display.ModernProvisionDisplay.init(allocator, false);
        defer apt_display.deinit();

        var mise_display = try modern_display.ModernProvisionDisplay.init(allocator, false);
        defer mise_display.deinit();

        // Detect apt (apt-get preferred) at the platform layer so we can extend
        // this later for yum/dnf/pacman, etc.
        const apt_path_opt = try findAptExecutable(allocator);
        const apt_path = apt_path_opt orelse {
            try apt_display.showInfo("apt / apt-get not found in PATH, skipping apt install");
            return;
        };
        defer allocator.free(apt_path);

        try apt_bootstrap.installPackages(allocator, config_root, &apt_display, apt_path);
        try installMiseTools(allocator, config_root, &mise_display);
    }
} else struct {};

/// The concrete platform implementation selected for this build.
const PlatformBootstrapImpl = if (is_macos)
    MacosBootstrap
else if (is_linux)
    AptBootstrap
else
    MacosBootstrap;

/// Trait-style runner: any Impl that provides installFoundation / installPackagesParallel
/// can be used here (MacosBootstrap, AptBootstrap, or a test stub).
fn runWithBootstrap(comptime Impl: type, allocator: std.mem.Allocator, opts: ApplyOptions) !void {
    // Compile-time "trait" check: Impl must expose the expected functions.
    comptime {
        _ = Impl.installFoundation;
        _ = Impl.installPackagesParallel;
    }

    // Use simple output for apply command (no spinner)
    // provision command will use its own spinner display
    var display = try modern_display.ModernProvisionDisplay.init(allocator, false);
    defer display.deinit();

    // Print banner using help formatter
    help_formatter.HelpFormatter.printHeader("Hola", "Brewfile + mise + dotfiles = your dev environment");

    // Phase 1: Link dotfiles
    try linkDotfiles(allocator, opts.config_root, opts.dry_run, &display);

    // Phase 2: Platform foundation (macOS: Homebrew, Linux: apt)
    try Impl.installFoundation(allocator, &display);

    // Phase 3: Platform packages (macOS: brew bundle + mise, Linux: apt + mise)
    try Impl.installPackagesParallel(allocator, opts.config_root);

    // Phase 4: Provision
    // Search for provision.rb in multiple locations (first match wins):
    // 1. config_root/.config/hola/provision.rb
    // 2. ~/.dotfiles/.config/hola/provision.rb
    // 3. $HOME/.config/hola/provision.rb
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    const dotfiles_root = try std.fs.path.join(allocator, &.{ home, ".dotfiles" });
    defer allocator.free(dotfiles_root);

    const resources_roots = [_][]const u8{ opts.config_root, dotfiles_root, home };
    const resources_path = try findFirstExistingJoinedPath(allocator, &resources_roots, ".config/hola/provision.rb");

    // Check if provision.rb exists
    const script_path = resources_path orelse {
        const msg = try std.fmt.allocPrint(
            allocator,
            "No provision.rb found (searched in {s}/.config/hola, ~/.dotfiles/.config/hola, $HOME/.config/hola), skipping provision",
            .{opts.config_root},
        );
        defer allocator.free(msg);
        try display.showInfo(msg);
        return;
    };
    defer allocator.free(script_path);

    // Skip provision in dry-run mode
    if (opts.dry_run) {
        const msg = try std.fmt.allocPrint(allocator, "Skipping provision (dry-run mode)", .{});
        defer allocator.free(msg);
        try display.showInfo(msg);
        return;
    }

    std.debug.print("\n", .{});
    // provision.run() will use its own ModernProvisionDisplay with spinner and will show section
    try provision.run(allocator, .{ .script_path = script_path });

    // Show log file location
    if (logger.getLogPath()) |log_file| {
        std.debug.print("\n\x1b[90mLog file: {s}\x1b[0m\n", .{log_file});
    }

    // Show celebration message
    std.debug.print("\n\x1b[1m\x1b[32m🎉 All done! You're ready to code.\x1b[0m\n\n", .{});

    // Send completion notification
    notifications.notifySimple(allocator, "Hola Apply Complete", "🎉 All done! You're ready to code.") catch |err| {
        std.debug.print("Warning: Failed to send notification: {}\n", .{err});
    };
}

/// Execute the full bootstrap sequence for the current platform.
pub fn run(allocator: std.mem.Allocator, opts: ApplyOptions) !void {
    return runWithBootstrap(PlatformBootstrapImpl, allocator, opts);
}

/// Step 1: Link dotfiles
fn linkDotfiles(allocator: std.mem.Allocator, config_root: []const u8, dry_run: bool, display: *modern_display.ModernProvisionDisplay) !void {
    try display.showSection("Linking Dotfiles");

    // Try multiple possible dotfiles root locations:
    // 1. config_root/home (for structured config layout)
    // 2. ~/.dotfiles (default dotfiles location, same as link command)
    // 3. config_root itself (if config_root is already a dotfiles root)
    var dotfiles_root: ?[]const u8 = null;

    // Try config_root/home first
    const config_home = try std.fs.path.join(allocator, &.{ config_root, "home" });
    defer allocator.free(config_home);

    std.fs.accessAbsolute(config_home, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            // Try ~/.dotfiles as fallback
            const home = try std.process.getEnvVarOwned(allocator, "HOME");
            defer allocator.free(home);
            const default_dotfiles = try std.fs.path.join(allocator, &.{ home, ".dotfiles" });
            defer allocator.free(default_dotfiles);

            std.fs.accessAbsolute(default_dotfiles, .{}) catch |err2| switch (err2) {
                error.FileNotFound => {
                    // Try config_root itself as last resort
                    std.fs.accessAbsolute(config_root, .{}) catch |err3| switch (err3) {
                        error.FileNotFound => {
                            const msg = try std.fmt.allocPrint(allocator, "No dotfiles directory found (tried {s}/home, ~/.dotfiles, {s}), skipping dotfiles linking", .{ config_root, config_root });
                            defer allocator.free(msg);
                            try display.showInfo(msg);
                            return;
                        },
                        else => return err3,
                    };
                    dotfiles_root = try allocator.dupe(u8, config_root);
                },
                else => return err2,
            };
            if (dotfiles_root == null) {
                dotfiles_root = try allocator.dupe(u8, default_dotfiles);
            }
        },
        else => return err,
    };

    if (dotfiles_root == null) {
        dotfiles_root = try allocator.dupe(u8, config_home);
    }
    defer allocator.free(dotfiles_root.?);

    var options: dotfiles.Options = .{
        .root_override = dotfiles_root.?,
        .dry_run = dry_run,
    };
    defer {
        if (options.ignore_patterns) |patterns| {
            for (patterns) |pattern| {
                allocator.free(pattern);
            }
            allocator.free(patterns);
        }
    }

    // Load TOML configuration for ignore patterns
    // Try config_root first, then dotfiles_root
    var ignore_patterns = try loadLinkConfig(allocator, config_root);
    if (ignore_patterns == null) {
        ignore_patterns = try loadLinkConfig(allocator, dotfiles_root.?);
    }
    if (ignore_patterns) |patterns| {
        options.ignore_patterns = patterns;
    }

    // Call dotfiles.run() - it will output directly to stdout
    // Since show_progress is false, output will be clean text
    try dotfiles.run(allocator, options);
}

/// Step 2: Install homebrew (if not installed)
fn installHomebrew(allocator: std.mem.Allocator, display: *modern_display.ModernProvisionDisplay) !void {
    try display.showSection("Installing Foundation");

    // Check if brew is already installed
    const brew_path = brew.findBrew(allocator) catch |err| switch (err) {
        brew.Error.BrewNotFound => {
            // Need to install homebrew
            try display.showInfo("Installing Homebrew...");

            // Run homebrew install script
            const install_script = "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"";
            var proc = std.process.Child.init(&[_][]const u8{ "/bin/bash", "-c", install_script }, allocator);
            proc.stdout_behavior = .Inherit;
            proc.stderr_behavior = .Inherit;

            const term = try proc.spawnAndWait();
            switch (term) {
                .Exited => |code| {
                    if (code != 0) {
                        return error.HomebrewInstallFailed;
                    }
                },
                else => return error.HomebrewInstallFailed,
            }

            // Verify installation
            const brew_path = try findBrewAfterInstall(allocator);
            defer allocator.free(brew_path);

            try display.showInfo("Homebrew installed successfully\n");
            return;
        },
        else => return err,
    };
    defer allocator.free(brew_path);

    // Brew is already installed
    try display.showInfo("Homebrew already installed");
}

/// Find brew after installation (check both common locations)
fn findBrewAfterInstall(allocator: std.mem.Allocator) ![]const u8 {
    return brew.findBrew(allocator);
}
//// Step 3: Install packages in parallel (brew bundle + mise) on macOS
fn installPackagesParallelImpl(allocator: std.mem.Allocator, config_root: []const u8) !void {
    // Note: Section display is handled in child functions to avoid thread safety issues

    // Create separate display instances for each thread to avoid thread safety issues
    var brew_display = try modern_display.ModernProvisionDisplay.init(allocator, false);
    defer brew_display.deinit();

    var mise_display = try modern_display.ModernProvisionDisplay.init(allocator, false);
    defer mise_display.deinit();

    // Spawn threads for parallel execution
    var brew_thread = try std.Thread.spawn(.{}, installBrewPackages, .{ allocator, config_root, &brew_display });
    var mise_thread = try std.Thread.spawn(.{}, installMiseTools, .{ allocator, config_root, &mise_display });

    // Wait for both threads to complete
    brew_thread.join();
    mise_thread.join();

    // Check for errors (they are logged in the functions, but we can't propagate them from threads)
    // The functions catch errors and log them, so we just wait for completion
}

/// Install Homebrew packages from Brewfile using brew bundle --global
fn installBrewPackages(allocator: std.mem.Allocator, _: []const u8, display: *modern_display.ModernProvisionDisplay) !void {
    try display.showSection("Installing Packages (Parallel)");

    const brew_path = try brew.findBrew(allocator);
    defer allocator.free(brew_path);

    // Use brew bundle --global to let Homebrew handle the search order:
    // 1. $HOMEBREW_BUNDLE_FILE_GLOBAL (if set)
    // 2. $XDG_CONFIG_HOME/homebrew/Brewfile (if $XDG_CONFIG_HOME is set)
    // 3. ~/.config/homebrew/Brewfile (XDG default)
    // 4. ~/.homebrew/Brewfile
    // 5. ~/.Brewfile
    try display.showInfo("Installing Homebrew packages...");

    // Check if user wants to skip upgrades (default: yes, skip upgrades)
    // Only upgrade if HOMEBREW_BUNDLE_NO_UPGRADE is explicitly set to "0"
    const should_upgrade = blk: {
        const env_val = std.process.getEnvVarOwned(allocator, "HOMEBREW_BUNDLE_NO_UPGRADE") catch break :blk false;
        defer allocator.free(env_val);
        break :blk std.mem.eql(u8, env_val, "0");
    };

    // Build args array with --global flag
    var args_list = std.ArrayList([]const u8).initCapacity(allocator, 5) catch std.ArrayList([]const u8).empty;
    defer args_list.deinit(allocator);

    try args_list.append(allocator, brew_path);
    try args_list.append(allocator, "bundle");
    try args_list.append(allocator, "--global");

    if (!should_upgrade) {
        try args_list.append(allocator, "--no-upgrade");
    }

    // Add --force to handle conflicting versions
    try args_list.append(allocator, "--force");

    command_runner.executeCommandWithLogging(allocator, args_list.items, null) catch |err| {
        const warning_msg = try std.fmt.allocPrint(
            allocator,
            "Warning: Some Homebrew packages failed to install (error: {}). Continuing...",
            .{err},
        );
        defer allocator.free(warning_msg);
        try display.showInfo(warning_msg);
        logger.warn("brew bundle --global failed: {}\n", .{err});
    };
}

/// Install mise and mise tools
fn installMiseTools(allocator: std.mem.Allocator, config_root: []const u8, display: *modern_display.ModernProvisionDisplay) !void {
    // Step 1: Install mise if not installed
    const mise_path = findMise(allocator) catch |err| switch (err) {
        error.MiseNotFound => blk: {
            try display.showInfo("Installing mise...");
            try installMise(allocator);
            // Verify installation - if it fails, return error
            break :blk findMise(allocator) catch return error.MiseInstallFailed;
        },
        else => return err,
    };
    defer allocator.free(mise_path);

    // Mise is already installed
    try display.showInfo("mise already installed\n");

    // Step 2: Find mise.toml or .mise.toml in config_root, dotfiles root, or $HOME
    // Try multiple locations:
    // 1. config_root/.mise.toml
    // 2. config_root/mise.toml
    // 3. ~/.dotfiles/.mise.toml
    // 4. ~/.dotfiles/mise.toml
    // 5. $HOME/.mise.toml (after linking)
    // 6. $HOME/mise.toml (after linking)
    var mise_toml_path: ?[]const u8 = null;
    var mise_toml_dir: ?[]const u8 = null;

    const config_paths = [_][]const u8{ ".mise.toml", "mise.toml" };

    // Try config_root first
    for (config_paths) |config_name| {
        const path = try std.fs.path.join(allocator, &.{ config_root, config_name });
        defer allocator.free(path);

        std.fs.accessAbsolute(path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };

        mise_toml_path = try allocator.dupe(u8, path);
        mise_toml_dir = try allocator.dupe(u8, config_root);
        break;
    }

    // If not found in config_root, try ~/.dotfiles
    if (mise_toml_path == null) {
        const home = try std.process.getEnvVarOwned(allocator, "HOME");
        defer allocator.free(home);
        const dotfiles_root = try std.fs.path.join(allocator, &.{ home, ".dotfiles" });
        defer allocator.free(dotfiles_root);

        for (config_paths) |config_name| {
            const path = try std.fs.path.join(allocator, &.{ dotfiles_root, config_name });
            defer allocator.free(path);

            std.fs.accessAbsolute(path, .{}) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };

            mise_toml_path = try allocator.dupe(u8, path);
            mise_toml_dir = try allocator.dupe(u8, dotfiles_root);
            break;
        }

        // If still not found, try $HOME directly (after linking)
        if (mise_toml_path == null) {
            for (config_paths) |config_name| {
                const path = try std.fs.path.join(allocator, &.{ home, config_name });
                defer allocator.free(path);

                std.fs.accessAbsolute(path, .{}) catch |err| switch (err) {
                    error.FileNotFound => continue,
                    else => return err,
                };

                mise_toml_path = try allocator.dupe(u8, path);
                mise_toml_dir = try allocator.dupe(u8, home);
                break;
            }
        }
    }

    // No mise.toml found, skip
    const toml_path = mise_toml_path orelse return;
    defer allocator.free(toml_path);
    const toml_dir = mise_toml_dir orelse return;
    defer allocator.free(toml_dir);

    try display.showInfo("Installing mise tools...");

    // Step 1: Trust the mise.toml file first
    var trust_args = [_][]const u8{ mise_path, "trust", "--quiet" };
    try command_runner.executeCommandWithLogging(allocator, &trust_args, toml_dir);

    // Step 2: Run mise install (in the directory containing mise.toml)
    var install_args = [_][]const u8{ mise_path, "install" };
    try command_runner.executeCommandWithLogging(allocator, &install_args, toml_dir);
}

/// Find mise executable
fn findMise(allocator: std.mem.Allocator) ![]const u8 {
    // Check common locations
    const locations = [_][]const u8{
        "/usr/local/bin/mise",
        "/opt/homebrew/bin/mise",
        "~/.local/bin/mise",
    };

    for (locations) |path| {
        const expanded = if (path[0] == '~') blk: {
            const home = std.process.getEnvVarOwned(allocator, "HOME") catch continue;
            defer allocator.free(home);
            break :blk try std.fmt.allocPrint(allocator, "{s}{s}", .{ home, path[1..] });
        } else try allocator.dupe(u8, path);
        defer allocator.free(expanded);

        std.fs.accessAbsolute(expanded, .{}) catch continue;
        return try allocator.dupe(u8, expanded);
    }

    // Search PATH environment variable
    const path_env = std.process.getEnvVarOwned(allocator, "PATH") catch return error.MiseNotFound;
    defer allocator.free(path_env);

    var it = std.mem.splitScalar(u8, path_env, std.fs.path.delimiter);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full_path = std.fs.path.join(allocator, &.{ dir, "mise" }) catch continue;
        defer allocator.free(full_path);

        if (std.fs.accessAbsolute(full_path, .{})) |_| {
            return allocator.dupe(u8, full_path) catch return error.MiseNotFound;
        } else |_| {}
    }

    return error.MiseNotFound;
}

/// Install mise using official installer
fn installMise(allocator: std.mem.Allocator) !void {
    // Use official mise installer
    const install_script = "curl https://mise.run | sh";
    var proc = std.process.Child.init(&[_][]const u8{ "/bin/bash", "-c", install_script }, allocator);
    proc.stdout_behavior = .Inherit;
    proc.stderr_behavior = .Inherit;

    const term = try proc.spawnAndWait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                return error.MiseInstallFailed;
            }
        },
        else => return error.MiseInstallFailed,
    }
}

/// Load link config (same as in main.zig)
fn loadLinkConfig(allocator: std.mem.Allocator, root: []const u8) !?[]const []const u8 {
    const toml = @import("toml");

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

const Error = error{
    HomebrewInstallFailed,
    MiseNotFound,
    MiseInstallFailed,
};
