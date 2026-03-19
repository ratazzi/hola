const std = @import("std");
const mruby = @import("../mruby.zig");
const base = @import("../base_resource.zig");
const builtin = @import("builtin");
const logger = @import("../logger.zig");

pub const Resource = struct {
    mount_point: []const u8,
    device: []const u8,
    device_type: DeviceType,
    fstype: []const u8,
    options: []const u8,
    dump: u8,
    pass: u8,
    supports_remount: bool,
    action: Action,
    common: base.CommonProps,

    pub const DeviceType = enum { device, label, uuid };

    pub const Action = enum {
        mount_action,
        umount,
        remount,
        enable,
        disable,
        nothing,
    };

    pub fn deinit(self: Resource, allocator: std.mem.Allocator) void {
        allocator.free(self.mount_point);
        allocator.free(self.device);
        allocator.free(self.fstype);
        allocator.free(self.options);
        var common = self.common;
        common.deinit(allocator);
    }

    pub fn apply(self: Resource) !base.ApplyResult {
        if (builtin.os.tag != .linux) {
            return base.ApplyResult{
                .was_updated = false,
                .action = "skipped",
                .skip_reason = "mount only available on Linux",
            };
        }

        const skip_reason = try self.common.shouldRun(null, null);
        if (skip_reason) |reason| {
            return base.ApplyResult{
                .was_updated = false,
                .action = self.actionName(),
                .skip_reason = reason,
            };
        }

        const was_updated = switch (self.action) {
            .mount_action => try self.applyMount(),
            .umount => try self.applyUmount(),
            .remount => try self.applyRemount(),
            .enable => try self.applyEnable(),
            .disable => try self.applyDisable(),
            .nothing => false,
        };

        return base.ApplyResult{
            .was_updated = was_updated,
            .action = self.actionName(),
            .skip_reason = if (was_updated) null else "up to date",
        };
    }

    fn actionName(self: Resource) []const u8 {
        return switch (self.action) {
            .mount_action => "mount",
            .umount => "umount",
            .remount => "remount",
            .enable => "enable",
            .disable => "disable",
            .nothing => "nothing",
        };
    }

    fn applyMount(self: Resource) !bool {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        if (try isMounted(allocator, self.mount_point)) {
            return false;
        }

        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(allocator);

        try argv.append(allocator, "/bin/mount");
        try argv.append(allocator, "-t");
        try argv.append(allocator, self.fstype);
        try argv.append(allocator, "-o");
        try argv.append(allocator, self.options);

        switch (self.device_type) {
            .uuid => {
                try argv.append(allocator, "-U");
                try argv.append(allocator, self.device);
            },
            .label => {
                try argv.append(allocator, "-L");
                try argv.append(allocator, self.device);
            },
            .device => {
                try argv.append(allocator, self.device);
            },
        }
        try argv.append(allocator, self.mount_point);

        _ = try runCommand(allocator, argv.items);
        return true;
    }

    fn applyUmount(self: Resource) !bool {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        if (!try isMounted(allocator, self.mount_point)) {
            return false;
        }

        _ = try runCommand(allocator, &[_][]const u8{ "/bin/umount", self.mount_point });
        return true;
    }

    fn applyRemount(self: Resource) !bool {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        if (!try isMounted(allocator, self.mount_point)) {
            return false;
        }

        if (self.supports_remount) {
            const remount_opts = try std.fmt.allocPrint(allocator, "remount,{s}", .{self.options});
            _ = try runCommand(allocator, &[_][]const u8{ "/bin/mount", "-o", remount_opts, self.mount_point });
        } else {
            _ = try runCommand(allocator, &[_][]const u8{ "/bin/umount", self.mount_point });

            var argv = std.ArrayList([]const u8).empty;
            defer argv.deinit(allocator);
            try argv.append(allocator, "/bin/mount");
            try argv.append(allocator, "-t");
            try argv.append(allocator, self.fstype);
            try argv.append(allocator, "-o");
            try argv.append(allocator, self.options);

            switch (self.device_type) {
                .uuid => {
                    try argv.append(allocator, "-U");
                    try argv.append(allocator, self.device);
                },
                .label => {
                    try argv.append(allocator, "-L");
                    try argv.append(allocator, self.device);
                },
                .device => {
                    try argv.append(allocator, self.device);
                },
            }
            try argv.append(allocator, self.mount_point);
            _ = try runCommand(allocator, argv.items);
        }
        return true;
    }

    fn applyEnable(self: Resource) !bool {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const device_str = try self.fstabDeviceString(allocator);
        const new_line = try std.fmt.allocPrint(
            allocator,
            "{s}\t{s}\t{s}\t{s}\t{d}\t{d}",
            .{ device_str, self.mount_point, self.fstype, self.options, self.dump, self.pass },
        );

        const existing = parseFstab(allocator, self.mount_point) catch null;
        if (existing) |entry| {
            if (std.mem.eql(u8, entry.line, new_line)) {
                return false;
            }
        }

        // Read fstab, replace or append
        const fstab_content = std.fs.cwd().readFileAlloc(allocator, "/etc/fstab", 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => "",
            else => return err,
        };
        var output = std.ArrayList(u8).empty;
        defer output.deinit(allocator);

        var replaced = false;
        var last_match_line: ?usize = null;

        // Find last matching line index
        var line_idx: usize = 0;
        var lines_iter = std.mem.splitScalar(u8, fstab_content, '\n');
        while (lines_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t");
            if (trimmed.len > 0 and trimmed[0] != '#') {
                if (parseFstabFields(trimmed)) |fields| {
                    if (std.mem.eql(u8, fields.mount_point, self.mount_point)) {
                        last_match_line = line_idx;
                    }
                }
            }
            line_idx += 1;
        }

        // Rebuild fstab
        var line_idx2: usize = 0;
        var lines_iter2 = std.mem.splitScalar(u8, fstab_content, '\n');
        while (lines_iter2.next()) |line| {
            if (last_match_line != null and line_idx2 == last_match_line.?) {
                try output.appendSlice(allocator, new_line);
                replaced = true;
            } else {
                try output.appendSlice(allocator, line);
            }
            if (lines_iter2.peek() != null) {
                try output.append(allocator, '\n');
            }
            line_idx2 += 1;
        }

        if (!replaced) {
            // Append new entry
            if (output.items.len > 0 and output.items[output.items.len - 1] != '\n') {
                try output.append(allocator, '\n');
            }
            try output.appendSlice(allocator, new_line);
            try output.append(allocator, '\n');
        }

        try atomicWriteFstab(output.items);
        return true;
    }

    fn applyDisable(self: Resource) !bool {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const existing = parseFstab(allocator, self.mount_point) catch null;
        if (existing == null) {
            return false;
        }

        const fstab_content = std.fs.cwd().readFileAlloc(allocator, "/etc/fstab", 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        var output = std.ArrayList(u8).empty;
        defer output.deinit(allocator);

        // Find last matching line index
        var last_match_line: ?usize = null;
        var line_idx: usize = 0;
        var lines_iter = std.mem.splitScalar(u8, fstab_content, '\n');
        while (lines_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t");
            if (trimmed.len > 0 and trimmed[0] != '#') {
                if (parseFstabFields(trimmed)) |fields| {
                    if (std.mem.eql(u8, fields.mount_point, self.mount_point)) {
                        last_match_line = line_idx;
                    }
                }
            }
            line_idx += 1;
        }

        // Rebuild without the matched line
        var line_idx2: usize = 0;
        var lines_iter2 = std.mem.splitScalar(u8, fstab_content, '\n');
        while (lines_iter2.next()) |line| {
            if (last_match_line != null and line_idx2 == last_match_line.?) {
                line_idx2 += 1;
                continue;
            }
            if (output.items.len > 0) {
                try output.append(allocator, '\n');
            }
            try output.appendSlice(allocator, line);
            line_idx2 += 1;
        }

        if (output.items.len > 0 and output.items[output.items.len - 1] != '\n') {
            try output.append(allocator, '\n');
        }

        try atomicWriteFstab(output.items);
        return true;
    }

    pub fn fstabDeviceString(self: Resource, allocator: std.mem.Allocator) ![]const u8 {
        return switch (self.device_type) {
            .uuid => try std.fmt.allocPrint(allocator, "UUID={s}", .{self.device}),
            .label => try std.fmt.allocPrint(allocator, "LABEL={s}", .{self.device}),
            .device => try allocator.dupe(u8, self.device),
        };
    }

    fn atomicWriteFstab(content: []const u8) !void {
        const tmp_path = "/etc/fstab.hola.tmp";
        const file = try std.fs.createFileAbsolute(tmp_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(content);

        try std.fs.renameAbsolute(tmp_path, "/etc/fstab");
    }

    pub fn actionFromString(action_str: []const u8) Action {
        if (std.mem.eql(u8, action_str, "mount")) return .mount_action;
        if (std.mem.eql(u8, action_str, "umount")) return .umount;
        if (std.mem.eql(u8, action_str, "remount")) return .remount;
        if (std.mem.eql(u8, action_str, "enable")) return .enable;
        if (std.mem.eql(u8, action_str, "disable")) return .disable;
        return .nothing;
    }

    fn deviceTypeFromString(dt_str: []const u8) DeviceType {
        if (std.mem.eql(u8, dt_str, "uuid")) return .uuid;
        if (std.mem.eql(u8, dt_str, "label")) return .label;
        return .device;
    }
};

pub const FstabFields = struct {
    device: []const u8,
    mount_point: []const u8,
    fstype: []const u8,
    options: []const u8,
    dump: []const u8,
    pass: []const u8,
    line: []const u8,
};

pub fn parseFstabFields(line: []const u8) ?FstabFields {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0 or trimmed[0] == '#') return null;

    var fields: [6][]const u8 = undefined;
    var count: usize = 0;
    var iter = std.mem.tokenizeAny(u8, trimmed, " \t");
    while (iter.next()) |field| {
        if (count >= 6) break;
        fields[count] = field;
        count += 1;
    }
    if (count < 4) return null;

    return FstabFields{
        .device = fields[0],
        .mount_point = fields[1],
        .fstype = fields[2],
        .options = fields[3],
        .dump = if (count > 4) fields[4] else "0",
        .pass = if (count > 5) fields[5] else "0",
        .line = trimmed,
    };
}

fn parseFstab(allocator: std.mem.Allocator, mount_point: []const u8) !?FstabFields {
    const content = try std.fs.cwd().readFileAlloc(allocator, "/etc/fstab", 1024 * 1024);

    var result: ?FstabFields = null;
    var lines_iter = std.mem.splitScalar(u8, content, '\n');
    while (lines_iter.next()) |line| {
        if (parseFstabFields(line)) |fields| {
            if (std.mem.eql(u8, fields.mount_point, mount_point)) {
                result = fields;
            }
        }
    }
    return result;
}

fn isMounted(allocator: std.mem.Allocator, mount_point: []const u8) !bool {
    const output = try runCommand(allocator, &[_][]const u8{"/bin/mount"});

    var lines_iter = std.mem.splitScalar(u8, output, '\n');
    while (lines_iter.next()) |line| {
        if (parseMountOutputLine(line, mount_point)) return true;
    }
    return false;
}

pub fn parseMountOutputLine(line: []const u8, mount_point: []const u8) bool {
    // Format: "device on mount_point type fstype (options)"
    const needle = " on ";
    const on_idx = std.mem.indexOf(u8, line, needle) orelse return false;
    const after_on = line[on_idx + needle.len ..];
    const type_idx = std.mem.indexOf(u8, after_on, " type ") orelse return false;
    const mp = after_on[0..type_idx];
    return std.mem.eql(u8, mp, mount_point);
}

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    const stdout = try child.stdout.?.readToEndAlloc(allocator, std.math.maxInt(usize));
    const stderr = try child.stderr.?.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(stderr);

    const term = try child.wait();

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                logger.debug("[mount] command failed with code {d}\n", .{code});
                if (stderr.len > 0) {
                    logger.err("  stderr: {s}\n", .{stderr});
                }
                return error.CommandFailed;
            }
        },
        else => return error.CommandFailed,
    }

    return stdout;
}

pub const ruby_prelude = @embedFile("mount_resource.rb");

pub fn zigAddResource(
    mrb: *mruby.mrb_state,
    _: mruby.mrb_value,
    mount_resources: *std.ArrayList(Resource),
    allocator: std.mem.Allocator,
) mruby.mrb_value {
    var mount_point_val: mruby.mrb_value = undefined;
    var device_val: mruby.mrb_value = undefined;
    var device_type_val: mruby.mrb_value = undefined;
    var fstype_val: mruby.mrb_value = undefined;
    var options_val: mruby.mrb_value = undefined;
    var dump_val: mruby.mrb_value = undefined;
    var pass_val: mruby.mrb_value = undefined;
    var supports_remount_val: mruby.mrb_value = undefined;
    var actions_val: mruby.mrb_value = undefined;
    var only_if_val: mruby.mrb_value = undefined;
    var not_if_val: mruby.mrb_value = undefined;
    var ignore_failure_val: mruby.mrb_value = undefined;
    var notifications_val: mruby.mrb_value = undefined;
    var subscriptions_val: mruby.mrb_value = undefined;

    // Format: SSSSSSSoA|oooAA (7 strings + 1 object + 1 array | optionals)
    _ = mruby.mrb_get_args(
        mrb,
        "SSSSSSSoA|oooAA",
        &mount_point_val,
        &device_val,
        &device_type_val,
        &fstype_val,
        &options_val,
        &dump_val,
        &pass_val,
        &supports_remount_val,
        &actions_val,
        &only_if_val,
        &not_if_val,
        &ignore_failure_val,
        &notifications_val,
        &subscriptions_val,
    );

    const mount_point_cstr = mruby.mrb_str_to_cstr(mrb, mount_point_val);
    const mount_point_span = std.mem.span(mount_point_cstr);

    const device_cstr = mruby.mrb_str_to_cstr(mrb, device_val);
    const device_span = std.mem.span(device_cstr);

    const device_type_cstr = mruby.mrb_str_to_cstr(mrb, device_type_val);
    const device_type = Resource.deviceTypeFromString(std.mem.span(device_type_cstr));

    const fstype_cstr = mruby.mrb_str_to_cstr(mrb, fstype_val);
    const fstype_span = std.mem.span(fstype_cstr);

    const options_cstr = mruby.mrb_str_to_cstr(mrb, options_val);
    const options_span = std.mem.span(options_cstr);

    const dump_cstr = mruby.mrb_str_to_cstr(mrb, dump_val);
    const dump = std.fmt.parseInt(u8, std.mem.span(dump_cstr), 10) catch 0;

    const pass_cstr = mruby.mrb_str_to_cstr(mrb, pass_val);
    const pass_num = std.fmt.parseInt(u8, std.mem.span(pass_cstr), 10) catch 0;

    const supports_remount = mruby.mrb_test(supports_remount_val);

    const actions_len = mruby.mrb_ary_len(mrb, actions_val);

    logger.debug("[mount] actions_len = {d}", .{actions_len});

    var i: mruby.mrb_int = 0;
    while (i < actions_len) : (i += 1) {
        const action_val = mruby.mrb_ary_ref(mrb, actions_val, @intCast(i));
        const action_cstr = mruby.mrb_str_to_cstr(mrb, action_val);
        const action = Resource.actionFromString(std.mem.span(action_cstr));

        const mount_point = allocator.dupe(u8, mount_point_span) catch return mruby.mrb_nil_value();
        const device = allocator.dupe(u8, device_span) catch return mruby.mrb_nil_value();
        const fstype = allocator.dupe(u8, fstype_span) catch return mruby.mrb_nil_value();
        const options = allocator.dupe(u8, options_span) catch return mruby.mrb_nil_value();

        var common = base.CommonProps.init(allocator);
        base.fillCommonFromRuby(&common, mrb, only_if_val, not_if_val, ignore_failure_val, notifications_val, subscriptions_val, allocator);

        mount_resources.append(allocator, .{
            .mount_point = mount_point,
            .device = device,
            .device_type = device_type,
            .fstype = fstype,
            .options = options,
            .dump = dump,
            .pass = pass_num,
            .supports_remount = supports_remount,
            .action = action,
            .common = common,
        }) catch return mruby.mrb_nil_value();
    }

    return mruby.mrb_nil_value();
}

// Tests
test "parseFstabFields parses standard fstab line" {
    const line = "/dev/sda1\t/\text4\tdefaults\t0\t1";
    const fields = parseFstabFields(line).?;
    try std.testing.expectEqualStrings("/dev/sda1", fields.device);
    try std.testing.expectEqualStrings("/", fields.mount_point);
    try std.testing.expectEqualStrings("ext4", fields.fstype);
    try std.testing.expectEqualStrings("defaults", fields.options);
    try std.testing.expectEqualStrings("0", fields.dump);
    try std.testing.expectEqualStrings("1", fields.pass);
}

test "parseFstabFields skips comments" {
    const line = "# /dev/sda1 / ext4 defaults 0 1";
    try std.testing.expect(parseFstabFields(line) == null);
}

test "parseFstabFields skips empty lines" {
    try std.testing.expect(parseFstabFields("") == null);
    try std.testing.expect(parseFstabFields("   ") == null);
}

test "parseFstabFields parses line with spaces" {
    const line = "UUID=abc-123   /mnt/data   ext4   defaults,noatime   0   2";
    const fields = parseFstabFields(line).?;
    try std.testing.expectEqualStrings("UUID=abc-123", fields.device);
    try std.testing.expectEqualStrings("/mnt/data", fields.mount_point);
    try std.testing.expectEqualStrings("ext4", fields.fstype);
    try std.testing.expectEqualStrings("defaults,noatime", fields.options);
    try std.testing.expectEqualStrings("0", fields.dump);
    try std.testing.expectEqualStrings("2", fields.pass);
}

test "parseFstabFields handles minimal fields" {
    const line = "/dev/sdb1 /mnt/backup xfs rw";
    const fields = parseFstabFields(line).?;
    try std.testing.expectEqualStrings("/dev/sdb1", fields.device);
    try std.testing.expectEqualStrings("/mnt/backup", fields.mount_point);
    try std.testing.expectEqualStrings("xfs", fields.fstype);
    try std.testing.expectEqualStrings("rw", fields.options);
    try std.testing.expectEqualStrings("0", fields.dump);
    try std.testing.expectEqualStrings("0", fields.pass);
}

test "actionFromString converts correctly" {
    try std.testing.expect(Resource.actionFromString("mount") == .mount_action);
    try std.testing.expect(Resource.actionFromString("umount") == .umount);
    try std.testing.expect(Resource.actionFromString("remount") == .remount);
    try std.testing.expect(Resource.actionFromString("enable") == .enable);
    try std.testing.expect(Resource.actionFromString("disable") == .disable);
    try std.testing.expect(Resource.actionFromString("unknown") == .nothing);
}

test "parseMountOutputLine matches mount point" {
    const line = "/dev/sda1 on / type ext4 (rw,relatime)";
    try std.testing.expect(parseMountOutputLine(line, "/"));
    try std.testing.expect(!parseMountOutputLine(line, "/mnt"));
}

test "parseMountOutputLine handles NFS" {
    const line = "server:/export on /mnt/nfs type nfs (rw,hard,intr)";
    try std.testing.expect(parseMountOutputLine(line, "/mnt/nfs"));
    try std.testing.expect(!parseMountOutputLine(line, "/mnt"));
}

test "parseMountOutputLine rejects invalid lines" {
    try std.testing.expect(!parseMountOutputLine("", "/mnt"));
    try std.testing.expect(!parseMountOutputLine("no on keyword here", "/mnt"));
}
