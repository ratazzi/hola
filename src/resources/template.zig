const std = @import("std");
const mruby = @import("../mruby.zig");
const base = @import("../base_resource.zig");
const logger = @import("../logger.zig");
const global_io = @import("../global_io.zig");

/// Template resource data structure
pub const Resource = struct {
    // Resource-specific properties
    path: []const u8,
    source: []const u8, // Template file path
    attrs: base.FileAttributes,
    variables: std.ArrayList(Variable), // Template variables
    action: Action,

    // Common properties (guards, notifications, etc.)
    common: base.CommonProps,

    pub const Variable = struct {
        name: []const u8,
        value: []const u8, // Value as string
        var_type: []const u8, // Type: 'string', 'integer', 'float', 'boolean', 'nil'

        pub fn deinit(self: Variable, allocator: std.mem.Allocator) void {
            allocator.free(self.name);
            allocator.free(self.value);
            allocator.free(self.var_type);
        }
    };

    pub const Action = enum {
        create,
        delete,
    };

    pub fn deinit(self: Resource, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.source);
        self.attrs.deinit(allocator);
        var variables = self.variables;
        for (variables.items) |var_| {
            var_.deinit(allocator);
        }
        variables.deinit(allocator);

        // Deinit common props
        var common = self.common;
        common.deinit(allocator);
    }

    pub fn apply(self: Resource) !base.ApplyResult {
        const skip_reason = try self.common.shouldRun(self.attrs.owner, self.attrs.group);
        if (skip_reason) |reason| {
            const action_name = switch (self.action) {
                .create => "create",
                .delete => "delete",
            };
            return base.ApplyResult{
                .was_updated = false,
                .action = action_name,
                .skip_reason = reason,
            };
        }

        const action_name = switch (self.action) {
            .create => "create",
            .delete => "delete",
        };

        switch (self.action) {
            .create => {
                const was_created = try applyCreate(self);
                return base.ApplyResult{
                    .was_updated = was_created,
                    .action = action_name,
                    .skip_reason = if (was_created) null else "up to date",
                };
            },
            .delete => {
                const was_deleted = try applyDelete(self);
                return base.ApplyResult{
                    .was_updated = was_deleted,
                    .action = action_name,
                    .skip_reason = if (was_deleted) null else "up to date",
                };
            },
        }
    }

    fn applyCreate(self: Resource) !bool {
        // Read template file
        const template_content = readTemplateFile(self.source) catch |err| {
            base.recordProvisionErrorDetail("template source templates/{s}: {s}", .{ self.source, base.userFacingError(err) });
            return err;
        };
        defer std.heap.c_allocator.free(template_content);

        // Render template using mruby
        const rendered_content = try renderTemplate(self, template_content, self.variables.items);
        defer std.heap.c_allocator.free(rendered_content);

        // Check if file exists and content matches
        const io = global_io.io();
        const is_abs = std.fs.path.isAbsolute(self.path);
        const file_exists = blk: {
            if (is_abs) {
                std.Io.Dir.accessAbsolute(io, self.path, .{}) catch |err| switch (err) {
                    error.FileNotFound => break :blk false,
                    else => return err,
                };
            } else {
                std.Io.Dir.cwd().access(io, self.path, .{}) catch |err| switch (err) {
                    error.FileNotFound => break :blk false,
                    else => return err,
                };
            }
            break :blk true;
        };

        if (file_exists) {
            // Read existing file and compare content
            const existing_file = if (is_abs)
                try std.Io.Dir.openFileAbsolute(io, self.path, .{})
            else
                try std.Io.Dir.cwd().openFile(io, self.path, .{});
            defer existing_file.close(io);

            var existing_reader = existing_file.reader(io, &.{});
            const existing_content = try existing_reader.interface.allocRemaining(std.heap.c_allocator, .unlimited);
            defer std.heap.c_allocator.free(existing_content);

            if (std.mem.eql(u8, existing_content, rendered_content)) {
                // Content matches, check attributes if specified
                if (self.attrs.mode) |m| {
                    const stat = try existing_file.stat(io);
                    const current_mode = stat.permissions.toMode() & 0o777;
                    if (current_mode == m) {
                        return false; // File exists with same content and mode
                    }
                } else {
                    return false; // File exists with same content
                }
            }
        }

        // Write rendered content to target file
        try base.ensureParentDir(self.path);
        var file = if (is_abs)
            try std.Io.Dir.createFileAbsolute(io, self.path, .{ .truncate = true })
        else
            try std.Io.Dir.cwd().createFile(io, self.path, .{ .truncate = true });

        var file_writer = file.writer(io, &.{});
        try file_writer.interface.writeAll(rendered_content);
        try file_writer.interface.flush();

        // Apply file mode if specified
        if (self.attrs.mode) |m| {
            file.setPermissions(io, .fromMode(@as(std.posix.mode_t, @intCast(m)))) catch {};
        }

        // Close file before changing ownership
        file.close(io);

        // Apply owner/group after file is closed
        if (self.attrs.owner != null or self.attrs.group != null) {
            base.applyFileAttributes(self.path, self.attrs) catch |err| {
                logger.warn("Failed to set owner/group for {s}: {}", .{ self.path, err });
            };
        }

        return true; // File was created or updated
    }

    fn applyDelete(self: Resource) !bool {
        const io = global_io.io();
        const is_abs = std.fs.path.isAbsolute(self.path);
        if (is_abs) {
            std.Io.Dir.deleteFileAbsolute(io, self.path) catch |err| switch (err) {
                error.FileNotFound => return false,
                else => return err,
            };
        } else {
            std.Io.Dir.cwd().deleteFile(io, self.path) catch |err| switch (err) {
                error.FileNotFound => return false,
                else => return err,
            };
        }
        return true;
    }

    fn readTemplateFile(source: []const u8) ![]u8 {
        const io = global_io.io();
        // Try to find template file in templates/ directory
        const templates_dir = "templates";
        const template_path = try std.fmt.allocPrint(std.heap.c_allocator, "{s}/{s}", .{ templates_dir, source });
        defer std.heap.c_allocator.free(template_path);

        // Try to read from templates directory first
        const content = std.Io.Dir.cwd().readFileAlloc(io, template_path, std.heap.c_allocator, .unlimited) catch {
            // If not found, try absolute path or current directory
            if (std.fs.path.isAbsolute(source)) {
                var file = try std.Io.Dir.openFileAbsolute(io, source, .{});
                defer file.close(io);
                var file_reader = file.reader(io, &.{});
                return try file_reader.interface.allocRemaining(std.heap.c_allocator, .unlimited);
            } else {
                return try std.Io.Dir.cwd().readFileAlloc(io, source, std.heap.c_allocator, .unlimited);
            }
        };

        return content;
    }

    fn renderTemplate(self: Resource, template_content: []const u8, variables: []const Variable) ![]u8 {
        // Use mruby to render ERB template
        // Convert ERB template to Ruby code and execute it

        const mrb = self.common.mrb_state orelse {
            // Fallback to simple substitution if no mrb_state
            return renderTemplateSimple(template_content, variables);
        };

        // Build Ruby code from ERB template
        var ruby_code = std.ArrayList(u8).initCapacity(std.heap.c_allocator, template_content.len * 2) catch std.ArrayList(u8).empty;
        defer ruby_code.deinit(std.heap.c_allocator);

        // Set up variables in Ruby as local variables
        try ruby_code.appendSlice(std.heap.c_allocator, "_erb_result = ''\n");
        for (variables) |var_| {
            // Convert variable name to valid Ruby identifier
            const safe_name = try sanitizeRubyIdentifier(var_.name);
            defer std.heap.c_allocator.free(safe_name);

            // Generate Ruby code based on type
            if (std.mem.eql(u8, var_.var_type, "integer")) {
                // Integer: convert string to integer
                try ruby_code.print(std.heap.c_allocator, "{s} = {s}.to_i\n", .{ safe_name, var_.value });
            } else if (std.mem.eql(u8, var_.var_type, "float")) {
                // Float: convert string to float
                try ruby_code.print(std.heap.c_allocator, "{s} = {s}.to_f\n", .{ safe_name, var_.value });
            } else if (std.mem.eql(u8, var_.var_type, "boolean")) {
                // Boolean: convert string to boolean
                if (std.mem.eql(u8, var_.value, "true")) {
                    try ruby_code.print(std.heap.c_allocator, "{s} = true\n", .{safe_name});
                } else {
                    try ruby_code.print(std.heap.c_allocator, "{s} = false\n", .{safe_name});
                }
            } else if (std.mem.eql(u8, var_.var_type, "nil")) {
                // Nil
                try ruby_code.print(std.heap.c_allocator, "{s} = nil\n", .{safe_name});
            } else if (std.mem.eql(u8, var_.var_type, "array")) {
                // Array: value is already a Ruby array literal string, just assign it
                try ruby_code.print(std.heap.c_allocator, "{s} = {s}\n", .{ safe_name, var_.value });
            } else {
                // String: escape properly
                const escaped_value = try escapeRubyString(var_.value);
                defer std.heap.c_allocator.free(escaped_value);
                try ruby_code.print(std.heap.c_allocator, "{s} = {s}\n", .{ safe_name, escaped_value });
            }
        }

        // Convert ERB to Ruby code
        var i: usize = 0;
        while (i < template_content.len) {
            // Look for <%= expression %> pattern
            if (i + 2 < template_content.len and
                template_content[i] == '<' and
                template_content[i + 1] == '%' and
                template_content[i + 2] == '=')
            {
                // Find closing %>
                var j = i + 3;
                var found = false;
                while (j + 1 < template_content.len) {
                    if (template_content[j] == '%' and template_content[j + 1] == '>') {
                        found = true;
                        break;
                    }
                    j += 1;
                }

                if (found) {
                    // Extract expression
                    const expr = std.mem.trim(u8, template_content[i + 3 .. j], " \t\n\r");
                    // Convert to Ruby: _erb_result << (expression).to_s
                    try ruby_code.print(std.heap.c_allocator, "_erb_result << ({s}).to_s\n", .{expr});
                    i = j + 2;
                    continue;
                }
            }

            // Look for <% code %> pattern (execute but don't output)
            if (i + 1 < template_content.len and
                template_content[i] == '<' and
                template_content[i + 1] == '%')
            {
                // Find closing %>
                var j = i + 2;
                var found = false;
                while (j + 1 < template_content.len) {
                    if (template_content[j] == '%' and template_content[j + 1] == '>') {
                        found = true;
                        break;
                    }
                    j += 1;
                }

                if (found) {
                    // Extract code
                    const code = std.mem.trim(u8, template_content[i + 2 .. j], " \t\n\r");
                    // Execute code directly
                    try ruby_code.print(std.heap.c_allocator, "{s}\n", .{code});
                    i = j + 2;
                    continue;
                }
            }

            // Regular text - find next ERB tag or end
            const text_start = i;
            var text_end = i;
            while (text_end < template_content.len) {
                // Check if we hit an ERB tag
                if (text_end + 1 < template_content.len and
                    template_content[text_end] == '<' and
                    template_content[text_end + 1] == '%')
                {
                    break;
                }
                text_end += 1;
            }

            // Escape and append text block
            if (text_end > text_start) {
                const text_block = template_content[text_start..text_end];
                const escaped_text = try escapeRubyString(text_block);
                defer std.heap.c_allocator.free(escaped_text);
                try ruby_code.print(std.heap.c_allocator, "_erb_result << {s}\n", .{escaped_text});
                i = text_end;
            } else {
                i += 1;
            }
        }

        // Get result: _erb_result
        try ruby_code.appendSlice(std.heap.c_allocator, "_erb_result");

        // Execute Ruby code
        const code_str = try ruby_code.toOwnedSlice(std.heap.c_allocator);
        defer std.heap.c_allocator.free(code_str);

        // Create null-terminated string for mruby
        const code_with_null = try std.heap.c_allocator.alloc(u8, code_str.len + 1);
        defer std.heap.c_allocator.free(code_with_null);
        @memcpy(code_with_null[0..code_str.len], code_str);
        code_with_null[code_str.len] = 0;

        const result_val = mruby.mrb_load_string(mrb, code_with_null.ptr);

        // Check for an exception directly instead of relying on a string-match
        // heuristic over the result. When the ERB code raised, also capture a
        // friendly "template raised: ClassName: message" summary into the
        // shared provision error-detail buffer so the top-level apply loop /
        // agent callback can surface it instead of the raw "TemplateRenderFailed".
        const exc = mruby.mrb_get_exception(mrb);
        if (mruby.mrb_test(exc)) {
            base.recordProvisionException(mrb, exc, "template raised");
            mruby.mrb_print_error(mrb);
            return error.TemplateRenderFailed;
        }

        // Convert result to string
        const result_cstr = mruby.mrb_str_to_cstr(mrb, result_val);
        const result_str = std.mem.span(result_cstr);

        return try std.heap.c_allocator.dupe(u8, result_str);
    }

    fn renderTemplateSimple(template_content: []const u8, variables: []const Variable) ![]u8 {
        // Fallback simple substitution (original implementation)
        var result = std.ArrayList(u8).initCapacity(std.heap.c_allocator, template_content.len) catch std.ArrayList(u8).empty;
        defer result.deinit(std.heap.c_allocator);

        var i: usize = 0;
        while (i < template_content.len) {
            if (i + 2 < template_content.len and
                template_content[i] == '<' and
                template_content[i + 1] == '%' and
                template_content[i + 2] == '=')
            {
                var j = i + 3;
                var found = false;
                while (j + 1 < template_content.len) {
                    if (template_content[j] == '%' and template_content[j + 1] == '>') {
                        found = true;
                        break;
                    }
                    j += 1;
                }

                if (found) {
                    const var_name = std.mem.trim(u8, template_content[i + 3 .. j], " \t\n\r");
                    var var_found = false;
                    for (variables) |var_| {
                        if (std.mem.eql(u8, var_.name, var_name)) {
                            try result.appendSlice(std.heap.c_allocator, var_.value);
                            var_found = true;
                            break;
                        }
                    }
                    if (!var_found) {
                        try result.appendSlice(std.heap.c_allocator, template_content[i .. j + 2]);
                    }
                    i = j + 2;
                    continue;
                }
            }

            if (i + 1 < template_content.len and
                template_content[i] == '<' and
                template_content[i + 1] == '%')
            {
                var j = i + 2;
                var found = false;
                while (j + 1 < template_content.len) {
                    if (template_content[j] == '%' and template_content[j + 1] == '>') {
                        found = true;
                        break;
                    }
                    j += 1;
                }
                if (found) {
                    i = j + 2;
                    continue;
                }
            }

            try result.append(std.heap.c_allocator, template_content[i]);
            i += 1;
        }

        return try result.toOwnedSlice(std.heap.c_allocator);
    }

    fn escapeRubyString(str: []const u8) ![]u8 {
        var result = std.ArrayList(u8).initCapacity(std.heap.c_allocator, str.len * 2) catch std.ArrayList(u8).empty;
        defer result.deinit(std.heap.c_allocator);

        try result.append(std.heap.c_allocator, '"');
        for (str) |ch| {
            switch (ch) {
                '\n' => try result.appendSlice(std.heap.c_allocator, "\\n"),
                '\r' => try result.appendSlice(std.heap.c_allocator, "\\r"),
                '\t' => try result.appendSlice(std.heap.c_allocator, "\\t"),
                '"' => try result.appendSlice(std.heap.c_allocator, "\\\""),
                '\\' => try result.appendSlice(std.heap.c_allocator, "\\\\"),
                '$' => try result.appendSlice(std.heap.c_allocator, "\\$"),
                else => {
                    if (ch >= 32 and ch <= 126) {
                        try result.append(std.heap.c_allocator, ch);
                    } else {
                        try result.print(std.heap.c_allocator, "\\x{x:0>2}", .{ch});
                    }
                },
            }
        }
        try result.append(std.heap.c_allocator, '"');

        return try result.toOwnedSlice(std.heap.c_allocator);
    }

    fn sanitizeRubyIdentifier(name: []const u8) ![]u8 {
        // Convert variable name to valid Ruby identifier
        // Replace invalid characters with underscore
        var result = std.ArrayList(u8).initCapacity(std.heap.c_allocator, name.len) catch std.ArrayList(u8).empty;
        defer result.deinit(std.heap.c_allocator);

        var first = true;
        for (name) |ch| {
            if (first) {
                // First char must be letter or underscore
                if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or ch == '_') {
                    try result.append(std.heap.c_allocator, ch);
                    first = false;
                } else {
                    try result.append(std.heap.c_allocator, '_');
                    first = false;
                }
            } else {
                // Subsequent chars can be letter, digit, or underscore
                if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_') {
                    try result.append(std.heap.c_allocator, ch);
                } else {
                    try result.append(std.heap.c_allocator, '_');
                }
            }
        }

        // Ensure non-empty
        if (result.items.len == 0) {
            try result.appendSlice(std.heap.c_allocator, "var");
        }

        return try result.toOwnedSlice(std.heap.c_allocator);
    }
};

/// Ruby prelude for template resource
pub const ruby_prelude = @embedFile("template_resource.rb");

/// Zig callback: called from Ruby to add a template resource
/// Format: add_template(path, source, mode, owner, group, variables_array, action, only_if_block, not_if_block, ignore_failure, notifications_array)
pub fn zigAddResource(
    mrb: *mruby.mrb_state,
    self: mruby.mrb_value,
    resources: *std.ArrayList(Resource),
    allocator: std.mem.Allocator,
) mruby.mrb_value {
    _ = self;

    var path_val: mruby.mrb_value = undefined;
    var source_val: mruby.mrb_value = undefined;
    var mode_val: mruby.mrb_value = undefined;
    var owner_val: mruby.mrb_value = undefined;
    var group_val: mruby.mrb_value = undefined;
    var variables_val: mruby.mrb_value = undefined;
    var action_val: mruby.mrb_value = undefined;
    var only_if_val: mruby.mrb_value = undefined;
    var not_if_val: mruby.mrb_value = undefined;
    var ignore_failure_val: mruby.mrb_value = undefined;
    var notifications_val: mruby.mrb_value = undefined;
    var subscriptions_val: mruby.mrb_value = undefined;

    // Get 5 strings + 1 array (variables) + 1 string (action) + 2 optional blocks + 1 optional boolean + 2 optional arrays
    _ = mruby.mrb_get_args(mrb, "SSSSSAS|oooAA", &path_val, &source_val, &mode_val, &owner_val, &group_val, &variables_val, &action_val, &only_if_val, &not_if_val, &ignore_failure_val, &notifications_val, &subscriptions_val);

    const path_cstr = mruby.mrb_str_to_cstr(mrb, path_val);
    const source_cstr = mruby.mrb_str_to_cstr(mrb, source_val);
    const mode_cstr = mruby.mrb_str_to_cstr(mrb, mode_val);
    const owner_cstr = mruby.mrb_str_to_cstr(mrb, owner_val);
    const group_cstr = mruby.mrb_str_to_cstr(mrb, group_val);
    const action_cstr = mruby.mrb_str_to_cstr(mrb, action_val);

    const path = allocator.dupe(u8, std.mem.span(path_cstr)) catch return mruby.mrb_nil_value();
    const source = allocator.dupe(u8, std.mem.span(source_cstr)) catch return mruby.mrb_nil_value();

    const action_str = std.mem.span(action_cstr);
    const action: Resource.Action = if (std.mem.eql(u8, action_str, "delete"))
        .delete
    else
        .create;

    const mode_str = std.mem.span(mode_cstr);
    const mode: ?u32 = if (mode_str.len > 0)
        std.fmt.parseInt(u32, mode_str, 8) catch null
    else
        null;

    const owner_str = std.mem.span(owner_cstr);
    const owner: ?[]const u8 = if (owner_str.len > 0)
        allocator.dupe(u8, owner_str) catch return mruby.mrb_nil_value()
    else
        null;

    const group_str = std.mem.span(group_cstr);
    const group: ?[]const u8 = if (group_str.len > 0)
        allocator.dupe(u8, group_str) catch return mruby.mrb_nil_value()
    else
        null;

    // Parse variables array: [[name, value, type], ...]
    var variables = std.ArrayList(Resource.Variable).initCapacity(allocator, 0) catch std.ArrayList(Resource.Variable).empty;
    if (mruby.mrb_test(variables_val)) {
        const arr_len = mruby.mrb_ary_len(mrb, variables_val);
        var i: mruby.mrb_int = 0;
        while (i < arr_len) : (i += 1) {
            const var_arr = mruby.mrb_ary_ref(mrb, variables_val, i);

            // Each variable is [name, value, type]
            const name_val = mruby.mrb_ary_ref(mrb, var_arr, 0);
            const value_val = mruby.mrb_ary_ref(mrb, var_arr, 1);
            const type_val = mruby.mrb_ary_ref(mrb, var_arr, 2);

            const name_cstr = mruby.mrb_str_to_cstr(mrb, name_val);
            const value_cstr = mruby.mrb_str_to_cstr(mrb, value_val);
            const type_cstr = mruby.mrb_str_to_cstr(mrb, type_val);

            const name = allocator.dupe(u8, std.mem.span(name_cstr)) catch continue;
            const value = allocator.dupe(u8, std.mem.span(value_cstr)) catch {
                allocator.free(name);
                continue;
            };
            const var_type = allocator.dupe(u8, std.mem.span(type_cstr)) catch {
                allocator.free(name);
                allocator.free(value);
                continue;
            };

            variables.append(allocator, Resource.Variable{
                .name = name,
                .value = value,
                .var_type = var_type,
            }) catch {
                allocator.free(name);
                allocator.free(value);
                allocator.free(var_type);
                continue;
            };
        }
    }

    // Build common properties (guards + notifications)
    var common = base.CommonProps.init(allocator);
    base.fillCommonFromRuby(&common, mrb, only_if_val, not_if_val, ignore_failure_val, notifications_val, subscriptions_val, allocator);

    resources.append(allocator, .{
        .path = path,
        .source = source,
        .attrs = .{
            .mode = mode,
            .owner = owner,
            .group = group,
        },
        .variables = variables,
        .action = action,
        .common = common,
    }) catch return mruby.mrb_nil_value();

    return mruby.mrb_nil_value();
}
