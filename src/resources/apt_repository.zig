const std = @import("std");
const mruby = @import("../mruby.zig");
const base = @import("../base_resource.zig");
const http = @import("../http.zig");
const logger = @import("../logger.zig");

/// APT repository resource data structure
/// Manages APT repositories on Debian/Ubuntu systems
pub const Resource = struct {
    name: []const u8, // Repository name (used for sources.list.d filename)
    uri: []const u8, // Repository URI (e.g., "https://..." or "ppa:user/repo")
    key_url: ?[]const u8 = null, // GPG key URL to download
    key_path: ?[]const u8 = null, // Path to save the GPG key
    distribution: ?[]const u8 = null, // Distribution codename (e.g., "jammy", "any-version")
    components: ?[]const u8 = null, // Components (e.g., "main contrib non-free")
    arch: ?[]const u8 = null, // Architecture (e.g., "amd64")
    options: ?[]const u8 = null, // Additional options (e.g., "signed-by=/path/to/key")
    repo_type: RepoType = .deb,
    action: Action,

    // Common properties (guards, notifications, etc.)
    common: base.CommonProps,

    pub const RepoType = enum {
        deb,
        deb_src,
        ppa, // Ubuntu PPA
    };

    pub const Action = enum {
        add, // Add repository
        remove, // Remove repository
    };

    pub fn deinit(self: Resource, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.uri);
        if (self.key_url) |key_url| allocator.free(key_url);
        if (self.key_path) |key_path| allocator.free(key_path);
        if (self.distribution) |dist| allocator.free(dist);
        if (self.components) |comp| allocator.free(comp);
        if (self.arch) |arch| allocator.free(arch);
        if (self.options) |opts| allocator.free(opts);

        var common = self.common;
        common.deinit(allocator);
    }

    pub fn apply(self: Resource) !base.ApplyResult {
        const skip_reason = try self.common.shouldRun(null, null);
        if (skip_reason) |reason| {
            const action_name = switch (self.action) {
                .add => "add",
                .remove => "remove",
            };
            return base.ApplyResult{
                .was_updated = false,
                .action = action_name,
                .skip_reason = reason,
            };
        }

        switch (self.action) {
            .add => {
                const was_updated = try applyAdd(self);
                return base.ApplyResult{
                    .was_updated = was_updated,
                    .action = "add",
                    .skip_reason = if (was_updated) null else "up to date",
                };
            },
            .remove => {
                const was_updated = try applyRemove(self);
                return base.ApplyResult{
                    .was_updated = was_updated,
                    .action = "remove",
                    .skip_reason = if (was_updated) null else "up to date",
                };
            },
        }
    }

    fn applyAdd(self: Resource) !bool {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        var updated = false;

        // Step 1: Download GPG key if specified
        if (self.key_url) |key_url| {
            const key_path = self.key_path orelse blk: {
                // Default key path: /etc/apt/keyrings/<name>.gpg
                break :blk try std.fmt.allocPrint(allocator, "/etc/apt/keyrings/{s}.gpg", .{self.name});
            };
            defer if (self.key_path == null) allocator.free(key_path);

            // Create keyrings directory if it doesn't exist
            std.fs.cwd().makePath("/etc/apt/keyrings") catch |err| {
                logger.warn("Failed to create /etc/apt/keyrings: {}", .{err});
            };

            // Check if key already exists
            const key_exists = blk: {
                std.fs.accessAbsolute(key_path, .{}) catch |err| switch (err) {
                    error.FileNotFound => break :blk false,
                    else => return err,
                };
                break :blk true;
            };

            if (!key_exists) {
                logger.info("Downloading GPG key from {s} to {s}", .{ key_url, key_path });
                const result = try http.downloadFile(allocator, key_url, key_path, .{});
                defer {
                    var mut_result = result;
                    mut_result.deinit(allocator);
                }
                updated = true;
            }
        }

        // Step 2: Generate sources.list entry
        const sources_list_path = try std.fmt.allocPrint(allocator, "/etc/apt/sources.list.d/{s}.list", .{self.name});
        defer allocator.free(sources_list_path);

        // Build the repository line
        var line_buf = std.ArrayList(u8).empty;
        defer line_buf.deinit(allocator);

        // Handle PPA specially
        if (self.repo_type == .ppa) {
            // PPA format: deb https://ppa.launchpadcontent.net/user/repo/ubuntu codename main
            // Extract user/repo from "ppa:user/repo"
            if (std.mem.startsWith(u8, self.uri, "ppa:")) {
                const ppa_spec = self.uri[4..];
                const dist = self.distribution orelse try getUbuntuCodename(allocator);
                defer if (self.distribution == null) allocator.free(dist);

                try line_buf.appendSlice(allocator, "deb https://ppa.launchpadcontent.net/");
                try line_buf.appendSlice(allocator, ppa_spec);
                try line_buf.appendSlice(allocator, "/ubuntu ");
                try line_buf.appendSlice(allocator, dist);
                try line_buf.appendSlice(allocator, " main\n");
            } else {
                return error.InvalidPPAFormat;
            }
        } else {
            // Standard deb/deb-src format
            const type_str = switch (self.repo_type) {
                .deb => "deb",
                .deb_src => "deb-src",
                .ppa => unreachable,
            };

            try line_buf.appendSlice(allocator, type_str);
            try line_buf.appendSlice(allocator, " ");

            // Add options if specified (e.g., [arch=amd64 signed-by=/path])
            // Auto-add signed-by if key_url is specified
            if (self.arch != null or self.options != null or self.key_url != null) {
                try line_buf.appendSlice(allocator, "[");
                var first = true;

                // Add arch if specified
                if (self.arch) |arch| {
                    try line_buf.appendSlice(allocator, "arch=");
                    try line_buf.appendSlice(allocator, arch);
                    first = false;
                }

                // Auto-add signed-by if key_url is specified
                if (self.key_url != null) {
                    if (!first) try line_buf.appendSlice(allocator, " ");
                    try line_buf.appendSlice(allocator, "signed-by=");
                    const key_path = self.key_path orelse blk: {
                        break :blk try std.fmt.allocPrint(allocator, "/etc/apt/keyrings/{s}.gpg", .{self.name});
                    };
                    defer if (self.key_path == null) allocator.free(key_path);
                    try line_buf.appendSlice(allocator, key_path);
                    first = false;
                }

                // Add other options if specified
                if (self.options) |opts| {
                    if (!first) try line_buf.appendSlice(allocator, " ");
                    try line_buf.appendSlice(allocator, opts);
                }

                try line_buf.appendSlice(allocator, "] ");
            }

            try line_buf.appendSlice(allocator, self.uri);
            try line_buf.appendSlice(allocator, " ");

            if (self.distribution) |dist| {
                try line_buf.appendSlice(allocator, dist);
            } else {
                // Default to system codename
                const dist = try getUbuntuCodename(allocator);
                defer allocator.free(dist);
                try line_buf.appendSlice(allocator, dist);
            }

            if (self.components) |comp| {
                try line_buf.appendSlice(allocator, " ");
                try line_buf.appendSlice(allocator, comp);
            }
            try line_buf.appendSlice(allocator, "\n");
        }

        // Check if sources.list.d file needs updating
        const new_content = line_buf.items;

        const needs_update = blk: {
            const file = std.fs.openFileAbsolute(sources_list_path, .{}) catch |err| switch (err) {
                error.FileNotFound => break :blk true,
                else => return err,
            };
            defer file.close();

            const existing_content = file.readToEndAlloc(allocator, std.math.maxInt(usize)) catch break :blk true;
            defer allocator.free(existing_content);

            break :blk !std.mem.eql(u8, existing_content, new_content);
        };

        if (needs_update) {
            logger.info("Writing repository configuration to {s}", .{sources_list_path});
            const file = try std.fs.createFileAbsolute(sources_list_path, .{});
            defer file.close();
            try file.writeAll(new_content);
            updated = true;
        }

        // Step 3: Run apt update if something changed
        if (updated) {
            logger.info("Running apt update", .{});
            try runAptUpdate(allocator);
        }

        return updated;
    }

    fn applyRemove(self: Resource) !bool {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        var updated = false;

        // Remove sources.list.d file
        const sources_list_path = try std.fmt.allocPrint(allocator, "/etc/apt/sources.list.d/{s}.list", .{self.name});
        defer allocator.free(sources_list_path);

        std.fs.deleteFileAbsolute(sources_list_path) catch |err| switch (err) {
            error.FileNotFound => {}, // Already removed
            else => return err,
        };
        updated = true;

        // Remove key if it was managed by us
        if (self.key_path) |key_path| {
            std.fs.deleteFileAbsolute(key_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        }

        // Run apt update
        if (updated) {
            logger.info("Running apt update after removing repository", .{});
            try runAptUpdate(allocator);
        }

        return updated;
    }

    fn getUbuntuCodename(allocator: std.mem.Allocator) ![]const u8 {
        // Try to get codename from /etc/os-release
        const file = std.fs.openFileAbsolute("/etc/os-release", .{}) catch {
            return try allocator.dupe(u8, "stable"); // Fallback for non-Debian systems
        };
        defer file.close();

        const content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
        defer allocator.free(content);

        // Parse VERSION_CODENAME=xxx
        var lines = std.mem.splitSequence(u8, content, "\n");
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "VERSION_CODENAME=")) {
                const codename = line["VERSION_CODENAME=".len..];
                return try allocator.dupe(u8, codename);
            }
        }

        return try allocator.dupe(u8, "stable");
    }

    fn runAptUpdate(allocator: std.mem.Allocator) !void {
        // Find apt-get or apt
        const apt_path = findAptExecutable(allocator) catch {
            logger.warn("apt/apt-get not found, skipping apt update", .{});
            return;
        };
        defer allocator.free(apt_path);

        var proc = std.process.Child.init(&[_][]const u8{ apt_path, "update" }, allocator);
        proc.stdout_behavior = .Pipe;
        proc.stderr_behavior = .Pipe;

        try proc.spawn();

        const stdout = try proc.stdout.?.readToEndAlloc(allocator, std.math.maxInt(usize));
        const stderr = try proc.stderr.?.readToEndAlloc(allocator, std.math.maxInt(usize));
        defer allocator.free(stdout);
        defer allocator.free(stderr);

        const term = try proc.wait();

        // Log output
        if (stdout.len > 0) {
            logger.debug("apt update stdout: {s}", .{stdout});
        }
        if (stderr.len > 0) {
            logger.warn("apt update stderr: {s}", .{stderr});
        }

        switch (term) {
            .Exited => |code| {
                if (code != 0) {
                    logger.err("apt update failed with exit code {d}", .{code});
                    return error.AptUpdateFailed;
                }
            },
            else => return error.AptUpdateFailed,
        }
    }

    fn findAptExecutable(allocator: std.mem.Allocator) ![]const u8 {
        const candidates = [_][]const u8{ "/usr/bin/apt-get", "/usr/bin/apt" };
        for (candidates) |path| {
            std.fs.accessAbsolute(path, .{}) catch continue;
            return try allocator.dupe(u8, path);
        }

        // Search PATH
        const path_env = std.process.getEnvVarOwned(allocator, "PATH") catch return error.AptNotFound;
        defer allocator.free(path_env);

        var it = std.mem.splitScalar(u8, path_env, std.fs.path.delimiter);
        while (it.next()) |dir| {
            if (dir.len == 0) continue;
            for ([_][]const u8{ "apt-get", "apt" }) |name| {
                const full_path = std.fs.path.join(allocator, &.{ dir, name }) catch continue;
                defer allocator.free(full_path);
                if (std.fs.accessAbsolute(full_path, .{})) |_| {
                    return allocator.dupe(u8, full_path) catch return error.AptNotFound;
                } else |_| {}
            }
        }

        return error.AptNotFound;
    }
};

/// Ruby prelude for apt_repository resource
pub const ruby_prelude = @embedFile("apt_repository_resource.rb");

/// Zig callback: called from Ruby to add an apt_repository resource
pub fn zigAddResource(
    mrb: *mruby.mrb_state,
    self: mruby.mrb_value,
    resources: *std.ArrayList(Resource),
    allocator: std.mem.Allocator,
) mruby.mrb_value {
    _ = self;

    var name_val: mruby.mrb_value = undefined;
    var uri_val: mruby.mrb_value = undefined;
    var key_url_val: mruby.mrb_value = undefined;
    var key_path_val: mruby.mrb_value = undefined;
    var distribution_val: mruby.mrb_value = undefined;
    var components_val: mruby.mrb_value = undefined;
    var arch_val: mruby.mrb_value = undefined;
    var options_val: mruby.mrb_value = undefined;
    var repo_type_val: mruby.mrb_value = undefined;
    var action_val: mruby.mrb_value = undefined;
    var only_if_val: mruby.mrb_value = undefined;
    var not_if_val: mruby.mrb_value = undefined;
    var ignore_failure_val: mruby.mrb_value = undefined;
    var notifications_val: mruby.mrb_value = undefined;
    var subscriptions_val: mruby.mrb_value = undefined;

    // Get 10 strings + 4 optional (blocks + arrays)
    _ = mruby.mrb_get_args(mrb, "SSSSSSSSSS|oooAA", &name_val, &uri_val, &key_url_val, &key_path_val, &distribution_val, &components_val, &arch_val, &options_val, &repo_type_val, &action_val, &only_if_val, &not_if_val, &ignore_failure_val, &notifications_val, &subscriptions_val);

    const name_cstr = mruby.mrb_str_to_cstr(mrb, name_val);
    const uri_cstr = mruby.mrb_str_to_cstr(mrb, uri_val);
    const key_url_cstr = mruby.mrb_str_to_cstr(mrb, key_url_val);
    const key_path_cstr = mruby.mrb_str_to_cstr(mrb, key_path_val);
    const distribution_cstr = mruby.mrb_str_to_cstr(mrb, distribution_val);
    const components_cstr = mruby.mrb_str_to_cstr(mrb, components_val);
    const arch_cstr = mruby.mrb_str_to_cstr(mrb, arch_val);
    const options_cstr = mruby.mrb_str_to_cstr(mrb, options_val);
    const repo_type_cstr = mruby.mrb_str_to_cstr(mrb, repo_type_val);
    const action_cstr = mruby.mrb_str_to_cstr(mrb, action_val);

    const name = allocator.dupe(u8, std.mem.span(name_cstr)) catch return mruby.mrb_nil_value();
    const uri = allocator.dupe(u8, std.mem.span(uri_cstr)) catch return mruby.mrb_nil_value();

    const key_url_str = std.mem.span(key_url_cstr);
    const key_url: ?[]const u8 = if (key_url_str.len > 0)
        allocator.dupe(u8, key_url_str) catch return mruby.mrb_nil_value()
    else
        null;

    const key_path_str = std.mem.span(key_path_cstr);
    const key_path: ?[]const u8 = if (key_path_str.len > 0)
        allocator.dupe(u8, key_path_str) catch return mruby.mrb_nil_value()
    else
        null;

    const distribution_str = std.mem.span(distribution_cstr);
    const distribution: ?[]const u8 = if (distribution_str.len > 0)
        allocator.dupe(u8, distribution_str) catch return mruby.mrb_nil_value()
    else
        null;

    const components_str = std.mem.span(components_cstr);
    const components: ?[]const u8 = if (components_str.len > 0)
        allocator.dupe(u8, components_str) catch return mruby.mrb_nil_value()
    else
        null;

    const arch_str = std.mem.span(arch_cstr);
    const arch: ?[]const u8 = if (arch_str.len > 0)
        allocator.dupe(u8, arch_str) catch return mruby.mrb_nil_value()
    else
        null;

    const options_str = std.mem.span(options_cstr);
    const options: ?[]const u8 = if (options_str.len > 0)
        allocator.dupe(u8, options_str) catch return mruby.mrb_nil_value()
    else
        null;

    const repo_type_str = std.mem.span(repo_type_cstr);
    const repo_type: Resource.RepoType = if (std.mem.eql(u8, repo_type_str, "deb-src"))
        .deb_src
    else if (std.mem.eql(u8, repo_type_str, "ppa"))
        .ppa
    else
        .deb;

    const action_str = std.mem.span(action_cstr);
    const action: Resource.Action = if (std.mem.eql(u8, action_str, "remove"))
        .remove
    else
        .add;

    // Build common properties (guards + notifications)
    var common = base.CommonProps.init(allocator);
    base.fillCommonFromRuby(&common, mrb, only_if_val, not_if_val, ignore_failure_val, notifications_val, subscriptions_val, allocator);

    resources.append(allocator, .{
        .name = name,
        .uri = uri,
        .key_url = key_url,
        .key_path = key_path,
        .distribution = distribution,
        .components = components,
        .arch = arch,
        .options = options,
        .repo_type = repo_type,
        .action = action,
        .common = common,
    }) catch return mruby.mrb_nil_value();

    return mruby.mrb_nil_value();
}
