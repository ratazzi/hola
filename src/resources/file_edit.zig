/// file_edit resource - Edit files using regex patterns
/// Inspired by Chef::Util::FileEdit
const std = @import("std");
const mruby = @import("../mruby.zig");
const base = @import("../base_resource.zig");
const regex = @import("../regex.zig");
const logger = @import("../logger.zig");

pub const Resource = struct {
    name: []const u8,
    path: []const u8,
    operations: []Operation,
    backup: bool,
    mode: ?u32,
    owner: ?[]const u8,
    group: ?[]const u8,
    common: base.CommonProps,
    allocator: std.mem.Allocator,

    pub const Operation = struct {
        op_type: OpType,
        pattern: []const u8,
        replacement: []const u8,
    };

    pub const OpType = enum {
        search_file_replace,
        search_file_replace_line,
        search_file_delete,
        search_file_delete_line,
        insert_line_after_match,
        insert_line_if_no_match,
    };

    pub fn deinit(self: Resource, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.allocator.free(self.name);
        self.allocator.free(self.path);
        for (self.operations) |op| {
            self.allocator.free(op.pattern);
            self.allocator.free(op.replacement);
        }
        self.allocator.free(self.operations);
        if (self.owner) |o| self.allocator.free(o);
        if (self.group) |g| self.allocator.free(g);
        var common = self.common;
        common.deinit(self.allocator);
    }

    pub fn apply(self: Resource) !base.ApplyResult {
        const skip_reason = try self.common.shouldRun(self.owner, self.group);
        if (skip_reason) |reason| {
            return base.ApplyResult{
                .was_updated = false,
                .action = "edit",
                .skip_reason = reason,
            };
        }

        const was_updated = try applyEdit(self);

        return base.ApplyResult{
            .was_updated = was_updated,
            .action = "edit",
            .skip_reason = if (was_updated) null else "up to date",
        };
    }
};

fn applyEdit(res: Resource) !bool {
    const file = std.fs.openFileAbsolute(res.path, .{}) catch |err| {
        logger.err("Failed to open file {s}: {}", .{ res.path, err });
        return err;
    };
    defer file.close();

    const content = file.readToEndAlloc(res.allocator, std.math.maxInt(usize)) catch |err| {
        logger.err("Failed to read file {s}: {}", .{ res.path, err });
        return err;
    };
    defer res.allocator.free(content);

    var modified_content = try res.allocator.dupe(u8, content);
    var file_edited = false;

    for (res.operations) |op| {
        const result = try applyOperation(res.allocator, modified_content, op);
        if (!std.mem.eql(u8, result, modified_content)) {
            file_edited = true;
            res.allocator.free(modified_content);
            modified_content = result;
        } else {
            res.allocator.free(result);
        }
    }
    defer res.allocator.free(modified_content);

    if (!file_edited) {
        return false;
    }

    if (res.backup) {
        const backup_path = try std.fmt.allocPrint(res.allocator, "{s}.bak", .{res.path});
        defer res.allocator.free(backup_path);
        std.fs.copyFileAbsolute(res.path, backup_path, .{}) catch |err| {
            logger.warn("Failed to create backup {s}: {}", .{ backup_path, err });
        };
    }

    try writeFile(res, modified_content);
    return true;
}

fn applyOperation(allocator: std.mem.Allocator, content: []const u8, op: Resource.Operation) ![]u8 {
    return switch (op.op_type) {
        .search_file_replace => try doSearchFileReplace(allocator, content, op.pattern, op.replacement),
        .search_file_replace_line => try doSearchFileReplaceLine(allocator, content, op.pattern, op.replacement),
        .search_file_delete => try doSearchFileReplace(allocator, content, op.pattern, ""),
        .search_file_delete_line => try doSearchFileDeleteLine(allocator, content, op.pattern),
        .insert_line_after_match => try doInsertLineAfterMatch(allocator, content, op.pattern, op.replacement),
        .insert_line_if_no_match => try doInsertLineIfNoMatch(allocator, content, op.pattern, op.replacement),
    };
}

fn doSearchFileReplace(allocator: std.mem.Allocator, content: []const u8, pattern: []const u8, replacement: []const u8) ![]u8 {
    var re = regex.Regex.compile(allocator, pattern, .{}) catch {
        logger.err("Invalid regex pattern: {s}", .{pattern});
        return try allocator.dupe(u8, content);
    };
    defer re.deinit();

    var result = std.ArrayList(u8).initCapacity(allocator, content.len) catch std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try result.append(allocator, '\n');
        first = false;

        const modified = try re.replaceAll(allocator, line, replacement);
        defer allocator.free(modified);
        try result.appendSlice(allocator, modified);
    }

    return result.toOwnedSlice(allocator);
}

fn doSearchFileReplaceLine(allocator: std.mem.Allocator, content: []const u8, pattern: []const u8, replacement: []const u8) ![]u8 {
    var re = regex.Regex.compile(allocator, pattern, .{}) catch {
        logger.err("Invalid regex pattern: {s}", .{pattern});
        return try allocator.dupe(u8, content);
    };
    defer re.deinit();

    var result = std.ArrayList(u8).initCapacity(allocator, content.len) catch std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try result.append(allocator, '\n');
        first = false;

        if (re.isMatch(line)) {
            try result.appendSlice(allocator, replacement);
        } else {
            try result.appendSlice(allocator, line);
        }
    }

    return result.toOwnedSlice(allocator);
}

fn doSearchFileDeleteLine(allocator: std.mem.Allocator, content: []const u8, pattern: []const u8) ![]u8 {
    var re = regex.Regex.compile(allocator, pattern, .{}) catch {
        logger.err("Invalid regex pattern: {s}", .{pattern});
        return try allocator.dupe(u8, content);
    };
    defer re.deinit();

    var result = std.ArrayList(u8).initCapacity(allocator, content.len) catch std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!re.isMatch(line)) {
            if (!first) try result.append(allocator, '\n');
            first = false;
            try result.appendSlice(allocator, line);
        }
    }

    return result.toOwnedSlice(allocator);
}

fn doInsertLineAfterMatch(allocator: std.mem.Allocator, content: []const u8, pattern: []const u8, newline: []const u8) ![]u8 {
    var re = regex.Regex.compile(allocator, pattern, .{}) catch {
        logger.err("Invalid regex pattern: {s}", .{pattern});
        return try allocator.dupe(u8, content);
    };
    defer re.deinit();

    var result = std.ArrayList(u8).initCapacity(allocator, content.len + newline.len + 1) catch std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try result.append(allocator, '\n');
        first = false;

        try result.appendSlice(allocator, line);
        if (re.isMatch(line)) {
            try result.append(allocator, '\n');
            try result.appendSlice(allocator, newline);
        }
    }

    return result.toOwnedSlice(allocator);
}

fn doInsertLineIfNoMatch(allocator: std.mem.Allocator, content: []const u8, pattern: []const u8, newline: []const u8) ![]u8 {
    var re = regex.Regex.compile(allocator, pattern, .{}) catch {
        logger.err("Invalid regex pattern: {s}", .{pattern});
        return try allocator.dupe(u8, content);
    };
    defer re.deinit();

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (re.isMatch(line)) {
            return try allocator.dupe(u8, content);
        }
    }

    var result = std.ArrayList(u8).initCapacity(allocator, content.len + newline.len + 2) catch std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator, content);
    if (content.len > 0 and content[content.len - 1] != '\n') {
        try result.append(allocator, '\n');
    }
    try result.appendSlice(allocator, newline);
    try result.append(allocator, '\n');

    return result.toOwnedSlice(allocator);
}

fn writeFile(res: Resource, content: []const u8) !void {
    try base.ensureParentDir(res.path);

    const dir_path = std.fs.path.dirname(res.path);
    const timestamp = std.time.nanoTimestamp();
    const pid = std.c.getpid();

    const temp_name = try std.fmt.allocPrint(res.allocator, ".hola-file-edit-{d}-{d}", .{ timestamp, pid });
    defer res.allocator.free(temp_name);

    const temp_path = if (dir_path) |d|
        try std.fs.path.join(res.allocator, &.{ d, temp_name })
    else
        try res.allocator.dupe(u8, temp_name);
    defer res.allocator.free(temp_path);

    var temp_file = try std.fs.createFileAbsolute(temp_path, .{ .truncate = true, .exclusive = true });
    errdefer std.fs.deleteFileAbsolute(temp_path) catch {};

    try temp_file.writeAll(content);
    try temp_file.sync();
    temp_file.close();

    try std.fs.renameAbsolute(temp_path, res.path);

    base.applyFileAttributes(res.path, .{
        .mode = res.mode,
        .owner = res.owner,
        .group = res.group,
    }) catch |err| {
        logger.warn("Failed to apply file attributes for {s}: {}", .{ res.path, err });
    };
}

pub const ruby_prelude = @embedFile("file_edit_resource.rb");

pub fn zigAddResource(
    mrb: *mruby.mrb_state,
    self_val: mruby.mrb_value,
    resources: *std.ArrayList(Resource),
    allocator: std.mem.Allocator,
) mruby.mrb_value {
    _ = self_val;

    var path_val: mruby.mrb_value = undefined;
    var operations_val: mruby.mrb_value = undefined;
    var backup_val: mruby.mrb_value = undefined;
    var mode_val: mruby.mrb_value = undefined;
    var owner_val: mruby.mrb_value = undefined;
    var group_val: mruby.mrb_value = undefined;
    var only_if_val: mruby.mrb_value = undefined;
    var not_if_val: mruby.mrb_value = undefined;
    var ignore_failure_val: mruby.mrb_value = undefined;
    var notifications_val: mruby.mrb_value = undefined;
    var subscriptions_val: mruby.mrb_value = undefined;

    _ = mruby.mrb_get_args(mrb, "SAoSSS|oooAA", &path_val, &operations_val, &backup_val, &mode_val, &owner_val, &group_val, &only_if_val, &not_if_val, &ignore_failure_val, &notifications_val, &subscriptions_val);

    const path = allocator.dupe(u8, std.mem.span(mruby.mrb_str_to_cstr(mrb, path_val))) catch return mruby.mrb_nil_value();

    // Parse operations array: [[op_type, pattern, replacement], ...]
    var ops_list = std.ArrayList(Resource.Operation).initCapacity(allocator, 4) catch std.ArrayList(Resource.Operation).empty;

    const ops_len = mruby.mrb_ary_len(mrb, operations_val);
    for (0..@intCast(ops_len)) |i| {
        const op_arr = mruby.mrb_ary_ref(mrb, operations_val, @intCast(i));
        const arr_len = mruby.mrb_ary_len(mrb, op_arr);
        if (arr_len >= 3) {
            const op_type_val = mruby.mrb_ary_ref(mrb, op_arr, 0);
            const pattern_val = mruby.mrb_ary_ref(mrb, op_arr, 1);
            const replacement_val = mruby.mrb_ary_ref(mrb, op_arr, 2);

            const op_type_str = std.mem.span(mruby.mrb_str_to_cstr(mrb, op_type_val));
            const op_type: Resource.OpType = if (std.mem.eql(u8, op_type_str, "search_file_replace"))
                .search_file_replace
            else if (std.mem.eql(u8, op_type_str, "search_file_replace_line"))
                .search_file_replace_line
            else if (std.mem.eql(u8, op_type_str, "search_file_delete"))
                .search_file_delete
            else if (std.mem.eql(u8, op_type_str, "search_file_delete_line"))
                .search_file_delete_line
            else if (std.mem.eql(u8, op_type_str, "insert_line_after_match"))
                .insert_line_after_match
            else if (std.mem.eql(u8, op_type_str, "insert_line_if_no_match"))
                .insert_line_if_no_match
            else
                continue;

            const pattern = allocator.dupe(u8, std.mem.span(mruby.mrb_str_to_cstr(mrb, pattern_val))) catch continue;
            const replacement = allocator.dupe(u8, std.mem.span(mruby.mrb_str_to_cstr(mrb, replacement_val))) catch {
                allocator.free(pattern);
                continue;
            };

            ops_list.append(allocator, .{
                .op_type = op_type,
                .pattern = pattern,
                .replacement = replacement,
            }) catch continue;
        }
    }

    const operations = ops_list.toOwnedSlice(allocator) catch return mruby.mrb_nil_value();

    const backup = mruby.mrb_test(backup_val);

    const mode_str = std.mem.span(mruby.mrb_str_to_cstr(mrb, mode_val));
    const mode: ?u32 = if (mode_str.len > 0)
        std.fmt.parseInt(u32, mode_str, 8) catch null
    else
        null;

    const owner_str = std.mem.span(mruby.mrb_str_to_cstr(mrb, owner_val));
    const owner: ?[]const u8 = if (owner_str.len > 0)
        allocator.dupe(u8, owner_str) catch null
    else
        null;

    const group_str = std.mem.span(mruby.mrb_str_to_cstr(mrb, group_val));
    const group: ?[]const u8 = if (group_str.len > 0)
        allocator.dupe(u8, group_str) catch null
    else
        null;

    var common = base.CommonProps.init(allocator);
    base.fillCommonFromRuby(&common, mrb, only_if_val, not_if_val, ignore_failure_val, notifications_val, subscriptions_val, allocator);

    resources.append(allocator, .{
        .name = path,
        .path = allocator.dupe(u8, path) catch return mruby.mrb_nil_value(),
        .operations = operations,
        .backup = backup,
        .mode = mode,
        .owner = owner,
        .group = group,
        .common = common,
        .allocator = allocator,
    }) catch return mruby.mrb_nil_value();

    return mruby.mrb_nil_value();
}
