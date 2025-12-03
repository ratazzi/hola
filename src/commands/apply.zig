const std = @import("std");
const clap = @import("clap");
const git = @import("../git.zig");
const apply_module = @import("../apply.zig");
const logger = @import("../logger.zig");
const dotfiles_paths = @import("../dotfiles_paths.zig");

/// Check if clone destination exists and is non-empty
fn checkCloneDestination(dest: []const u8) !void {
    if (std.fs.openDirAbsolute(dest, .{ .iterate = true })) |dir_handle| {
        var dir = dir_handle;
        defer dir.close();

        var iter_dir = dir.iterate();
        if (try iter_dir.next()) |_| {
            std.debug.print("Warning: {s} already exists and is not empty\n", .{dest});
            std.debug.print("Please remove it first or use --dotfiles to specify a different location\n", .{});
            return error.DotfilesAlreadyExists;
        }
    } else |_| {}
}

/// Clone a repository with detailed error reporting
fn cloneRepository(
    allocator: std.mem.Allocator,
    url: []const u8,
    dest: []const u8,
    branch: ?[]const u8,
    is_github: bool,
    display_name: []const u8,
) !void {
    std.debug.print("[clone] {s} -> {s}\n", .{ url, dest });

    var client = try git.Client.init();
    defer client.deinit();

    var clone_options: git.CloneOptions = .{};
    if (branch) |branch_name| {
        clone_options.branch = branch_name;
    }

    client.clone(allocator, url, dest, clone_options) catch |err| {
        std.debug.print("\n\x1b[31mError: Failed to clone repository\x1b[0m\n", .{});
        std.debug.print("Repository: {s}\n", .{url});
        std.debug.print("Destination: {s}\n", .{dest});
        std.debug.print("\nPossible reasons:\n", .{});
        std.debug.print("  • Repository does not exist or is private\n", .{});

        if (is_github) {
            std.debug.print("  • SSH key not set up or not added to ssh-agent\n", .{});
            std.debug.print("  • SSH key not added to GitHub account\n", .{});
        } else {
            std.debug.print("  • Invalid repository URL\n", .{});
            std.debug.print("  • Authentication required (check credentials)\n", .{});
        }

        std.debug.print("  • Network connectivity issues\n", .{});
        if (branch) |b| {
            std.debug.print("  • Branch '{s}' does not exist\n", .{b});
        }

        if (is_github) {
            std.debug.print("\nTo set up SSH authentication:\n", .{});
            std.debug.print("  1. Generate SSH key: ssh-keygen -t ed25519 -C \"your@email.com\"\n", .{});
            std.debug.print("  2. Add to ssh-agent: ssh-add ~/.ssh/id_ed25519\n", .{});
            std.debug.print("  3. Add public key to GitHub: https://github.com/settings/keys\n", .{});
            std.debug.print("  4. Test connection: ssh -T git@github.com\n", .{});
        } else {
            std.debug.print("\nFor SSH URLs (git@host:path), make sure:\n", .{});
            std.debug.print("  • SSH key is set up and added to ssh-agent\n", .{});
            std.debug.print("  • Public key is added to the Git hosting service\n", .{});
            std.debug.print("\nFor HTTPS URLs, you may need to configure credentials.\n", .{});
        }

        std.debug.print("\nCheck the log file for detailed error information.\n", .{});
        if (logger.getLogPath()) |log_path| {
            std.debug.print("Log file: {s}\n", .{log_path});
        }
        return err;
    };

    std.debug.print("[done] Cloned {s}\n\n", .{display_name});
}

/// Resolve clone destination path from args
fn resolveCloneDestination(allocator: std.mem.Allocator, dotfiles_arg: ?[]const u8, home: []const u8) ![]const u8 {
    return if (dotfiles_arg) |dotfiles_path|
        try dotfiles_paths.resolvePathForLink(allocator, dotfiles_path, home)
    else
        try std.fs.path.join(allocator, &.{ home, ".dotfiles" });
}

const params = clap.parseParamsComptime(
    \\-h, --help                 Show help for apply
    \\--dotfiles <dotfiles_dir>  Dotfiles repository location (default ~/.dotfiles)
    \\--github <repo>            Clone from GitHub via SSH (format: username/repo)
    \\--repo <url>               Clone from full repository URL (any protocol)
    \\--branch <name>            Git branch to checkout (default: repository's default branch)
    \\--dry-run                  Show what would be done without actually doing it
    \\
);

const parsers = .{
    .dotfiles_dir = clap.parsers.string,
    .repo = clap.parsers.string,
    .url = clap.parsers.string,
    .name = clap.parsers.string,
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

    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);

    const dry_run = @field(res.args, "dry-run") != 0;

    if (res.args.github != null and res.args.repo != null) {
        std.debug.print("Error: Cannot specify both --github and --repo\n", .{});
        std.debug.print("Use --github for GitHub repos (username/repo format)\n", .{});
        std.debug.print("Use --repo for full URLs (any git URL)\n", .{});
        return error.ConflictingOptions;
    }

    if (res.args.github) |github_repo| {
        if (std.mem.indexOfScalar(u8, github_repo, '/') == null) {
            std.debug.print("Error: --github must be in format 'username/repo'\n", .{});
            std.debug.print("Example: --github user/dotfiles\n", .{});
            return error.InvalidGithubFormat;
        }

        const clone_dest = try resolveCloneDestination(allocator, res.args.dotfiles, home);
        defer allocator.free(clone_dest);

        try checkCloneDestination(clone_dest);

        const github_url = try std.fmt.allocPrint(allocator, "git@github.com:{s}.git", .{github_repo});
        defer allocator.free(github_url);

        if (!dry_run) {
            try cloneRepository(allocator, github_url, clone_dest, res.args.branch, true, github_repo);
        } else {
            std.debug.print("[dry-run] Would clone {s} to {s}\n", .{ github_url, clone_dest });
        }
    }

    if (res.args.repo) |repo_url| {
        const clone_dest = try resolveCloneDestination(allocator, res.args.dotfiles, home);
        defer allocator.free(clone_dest);

        try checkCloneDestination(clone_dest);

        if (!dry_run) {
            try cloneRepository(allocator, repo_url, clone_dest, res.args.branch, false, "repository");
        } else {
            std.debug.print("[dry-run] Would clone {s} to {s}\n", .{ repo_url, clone_dest });
        }
    }

    const config_root = if (res.args.dotfiles) |dotfiles_path| blk: {
        const resolved = try dotfiles_paths.resolvePathForLink(allocator, dotfiles_path, home);
        if (!dry_run) {
            try dotfiles_paths.saveDotfilesPreference(allocator, resolved, home);
        }
        break :blk resolved;
    } else blk: {
        break :blk try dotfiles_paths.getDefaultDotfilesPath(allocator, home);
    };
    defer allocator.free(config_root);

    try apply_module.run(allocator, .{
        .config_root = config_root,
        .dry_run = dry_run,
    });
}

fn printHelp(reason: ?[]const u8) !void {
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
        \\  • Generate key: ssh-keygen -t ed25519 -C \"your@email.com\"
        \\  • Add to agent: ssh-add ~/.ssh/id_ed25519
        \\  • Add to GitHub/GitLab: Settings > SSH keys
        \\  • Test: ssh -T git@github.com
        \\
    );
}
