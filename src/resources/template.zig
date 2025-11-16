const std = @import("std");
const mruby = @import("../mruby.zig");
const base = @import("../base_resource.zig");

/// Template resource data structure
pub const Resource = struct {
    // Resource-specific properties
    path: []const u8,
    source: []const u8, // Template file path
    mode: ?u32,
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
        const skip_reason = try self.common.shouldRun();
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
                try applyDelete(self);
                return base.ApplyResult{
                    .was_updated = false,
                    .action = action_name,
                    .skip_reason = "up to date",
                };
            },
        }
    }

    fn applyCreate(self: Resource) !bool {
        // Read template file
        const template_content = try readTemplateFile(self.source);
        defer std.heap.c_allocator.free(template_content);

        // Render template using mruby
        const rendered_content = try renderTemplate(self, template_content, self.variables.items);
        defer std.heap.c_allocator.free(rendered_content);

        // Check if file exists and content matches
        const is_abs = std.fs.path.isAbsolute(self.path);
        const file_exists = blk: {
            if (is_abs) {
                std.fs.accessAbsolute(self.path, .{}) catch |err| switch (err) {
                    error.FileNotFound => break :blk false,
                    else => return err,
                };
            } else {
                std.fs.cwd().access(self.path, .{}) catch |err| switch (err) {
                    error.FileNotFound => break :blk false,
                    else => return err,
                };
            }
            break :blk true;
        };

        if (file_exists) {
            // Read existing file and compare content
            const existing_file = if (is_abs)
                try std.fs.openFileAbsolute(self.path, .{})
            else
                try std.fs.cwd().openFile(self.path, .{});
            defer existing_file.close();

            const existing_content = try existing_file.readToEndAlloc(std.heap.c_allocator, std.math.maxInt(usize));
            defer std.heap.c_allocator.free(existing_content);

            if (std.mem.eql(u8, existing_content, rendered_content)) {
                // Content matches, check mode if specified
                if (self.mode) |m| {
                    const stat = try existing_file.stat();
                    const current_mode = stat.mode & 0o777;
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
            try std.fs.createFileAbsolute(self.path, .{ .truncate = true })
        else
            try std.fs.cwd().createFile(self.path, .{ .truncate = true });
        defer file.close();

        try file.writeAll(rendered_content);

        if (self.mode) |m| {
            std.posix.fchmod(file.handle, @as(std.posix.mode_t, @intCast(m))) catch {};
        }

        return true; // File was created or updated
    }

    fn applyDelete(self: Resource) !void {
        const is_abs = std.fs.path.isAbsolute(self.path);
        if (is_abs) {
            std.fs.deleteFileAbsolute(self.path) catch |err| switch (err) {
                error.FileNotFound => return,
                else => return err,
            };
        } else {
            std.fs.cwd().deleteFile(self.path) catch |err| switch (err) {
                error.FileNotFound => return,
                else => return err,
            };
        }
    }

    fn readTemplateFile(source: []const u8) ![]u8 {
        // Try to find template file in templates/ directory
        const templates_dir = "templates";
        const template_path = try std.fmt.allocPrint(std.heap.c_allocator, "{s}/{s}", .{ templates_dir, source });
        defer std.heap.c_allocator.free(template_path);

        // Try to read from templates directory first
        const content = std.fs.cwd().readFileAlloc(std.heap.c_allocator, template_path, std.math.maxInt(usize)) catch {
            // If not found, try absolute path or current directory
            if (std.fs.path.isAbsolute(source)) {
                var file = try std.fs.openFileAbsolute(source, .{});
                defer file.close();
                return try file.readToEndAlloc(std.heap.c_allocator, std.math.maxInt(usize));
            } else {
                return try std.fs.cwd().readFileAlloc(std.heap.c_allocator, source, std.math.maxInt(usize));
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
        try ruby_code.writer(std.heap.c_allocator).writeAll("_erb_result = ''\n");
        for (variables) |var_| {
            // Convert variable name to valid Ruby identifier
            const safe_name = try sanitizeRubyIdentifier(var_.name);
            defer std.heap.c_allocator.free(safe_name);

            // Generate Ruby code based on type
            if (std.mem.eql(u8, var_.var_type, "integer")) {
                // Integer: convert string to integer
                try ruby_code.writer(std.heap.c_allocator).print("{s} = {s}.to_i\n", .{ safe_name, var_.value });
            } else if (std.mem.eql(u8, var_.var_type, "float")) {
                // Float: convert string to float
                try ruby_code.writer(std.heap.c_allocator).print("{s} = {s}.to_f\n", .{ safe_name, var_.value });
            } else if (std.mem.eql(u8, var_.var_type, "boolean")) {
                // Boolean: convert string to boolean
                if (std.mem.eql(u8, var_.value, "true")) {
                    try ruby_code.writer(std.heap.c_allocator).print("{s} = true\n", .{safe_name});
                } else {
                    try ruby_code.writer(std.heap.c_allocator).print("{s} = false\n", .{safe_name});
                }
            } else if (std.mem.eql(u8, var_.var_type, "nil")) {
                // Nil
                try ruby_code.writer(std.heap.c_allocator).print("{s} = nil\n", .{safe_name});
            } else if (std.mem.eql(u8, var_.var_type, "array")) {
                // Array: value is already a Ruby array literal string, just assign it
                try ruby_code.writer(std.heap.c_allocator).print("{s} = {s}\n", .{ safe_name, var_.value });
            } else {
                // String: escape properly
                const escaped_value = try escapeRubyString(var_.value);
                defer std.heap.c_allocator.free(escaped_value);
                try ruby_code.writer(std.heap.c_allocator).print("{s} = {s}\n", .{ safe_name, escaped_value });
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
                    try ruby_code.writer(std.heap.c_allocator).print("_erb_result << ({s}).to_s\n", .{expr});
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
                    try ruby_code.writer(std.heap.c_allocator).print("{s}\n", .{code});
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
                try ruby_code.writer(std.heap.c_allocator).print("_erb_result << {s}\n", .{escaped_text});
                i = text_end;
            } else {
                i += 1;
            }
        }

        // Get result: _erb_result
        try ruby_code.writer(std.heap.c_allocator).writeAll("_erb_result");

        // Execute Ruby code
        const code_str = try ruby_code.toOwnedSlice(std.heap.c_allocator);
        defer std.heap.c_allocator.free(code_str);

        // Debug: print generated Ruby code (for debugging)
        // std.debug.print("Generated Ruby code:\n{s}\n", .{code_str});

        // Create null-terminated string for mruby
        const code_with_null = try std.heap.c_allocator.alloc(u8, code_str.len + 1);
        defer std.heap.c_allocator.free(code_with_null);
        @memcpy(code_with_null[0..code_str.len], code_str);
        code_with_null[code_str.len] = 0;

        const result_val = mruby.mrb_load_string(mrb, code_with_null.ptr);

        // Print any errors first
        mruby.mrb_print_error(mrb);

        // Try to convert result to string
        // If it's an exception, mrb_str_to_cstr might fail or return error message
        const result_cstr = mruby.mrb_str_to_cstr(mrb, result_val);
        const result_str = std.mem.span(result_cstr);

        // Check if result looks like an error (starts with error indicators)
        // This is a heuristic - proper way would be to check mrb_type
        if (result_str.len > 0 and
            (std.mem.startsWith(u8, result_str, "SyntaxError") or
                std.mem.startsWith(u8, result_str, "NameError") or
                std.mem.startsWith(u8, result_str, "RuntimeError") or
                std.mem.startsWith(u8, result_str, "TypeError")))
        {
            return error.TemplateRenderFailed;
        }

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
                            try result.writer(std.heap.c_allocator).writeAll(var_.value);
                            var_found = true;
                            break;
                        }
                    }
                    if (!var_found) {
                        try result.writer(std.heap.c_allocator).writeAll(template_content[i .. j + 2]);
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

            try result.writer(std.heap.c_allocator).writeByte(template_content[i]);
            i += 1;
        }

        return try result.toOwnedSlice(std.heap.c_allocator);
    }

    fn escapeRubyString(str: []const u8) ![]u8 {
        var result = std.ArrayList(u8).initCapacity(std.heap.c_allocator, str.len * 2) catch std.ArrayList(u8).empty;
        defer result.deinit(std.heap.c_allocator);

        try result.writer(std.heap.c_allocator).writeByte('"');
        for (str) |ch| {
            switch (ch) {
                '\n' => try result.writer(std.heap.c_allocator).writeAll("\\n"),
                '\r' => try result.writer(std.heap.c_allocator).writeAll("\\r"),
                '\t' => try result.writer(std.heap.c_allocator).writeAll("\\t"),
                '"' => try result.writer(std.heap.c_allocator).writeAll("\\\""),
                '\\' => try result.writer(std.heap.c_allocator).writeAll("\\\\"),
                '$' => try result.writer(std.heap.c_allocator).writeAll("\\$"),
                else => {
                    if (ch >= 32 and ch <= 126) {
                        try result.writer(std.heap.c_allocator).writeByte(ch);
                    } else {
                        try result.writer(std.heap.c_allocator).print("\\x{x:0>2}", .{ch});
                    }
                },
            }
        }
        try result.writer(std.heap.c_allocator).writeByte('"');

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
                    try result.writer(std.heap.c_allocator).writeByte(ch);
                    first = false;
                } else {
                    try result.writer(std.heap.c_allocator).writeByte('_');
                    first = false;
                }
            } else {
                // Subsequent chars can be letter, digit, or underscore
                if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_') {
                    try result.writer(std.heap.c_allocator).writeByte(ch);
                } else {
                    try result.writer(std.heap.c_allocator).writeByte('_');
                }
            }
        }

        // Ensure non-empty
        if (result.items.len == 0) {
            try result.writer(std.heap.c_allocator).writeAll("var");
        }

        return try result.toOwnedSlice(std.heap.c_allocator);
    }
};

/// Ruby prelude for template resource
pub const ruby_prelude = @embedFile("template_resource.rb");

/// Zig callback: called from Ruby to add a template resource
/// Format: add_template(path, source, mode, variables_array, action, only_if_block, not_if_block, notifications_array)
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
    var variables_val: mruby.mrb_value = undefined;
    var action_val: mruby.mrb_value = undefined;
    var only_if_val: mruby.mrb_value = undefined;
    var not_if_val: mruby.mrb_value = undefined;
    var notifications_val: mruby.mrb_value = undefined;

    // Get 3 strings + 1 array (variables) + 1 string (action) + 2 optional blocks + 1 optional array
    _ = mruby.mrb_get_args(mrb, "SSSAS|ooA", &path_val, &source_val, &mode_val, &variables_val, &action_val, &only_if_val, &not_if_val, &notifications_val);

    const path_cstr = mruby.mrb_str_to_cstr(mrb, path_val);
    const source_cstr = mruby.mrb_str_to_cstr(mrb, source_val);
    const mode_cstr = mruby.mrb_str_to_cstr(mrb, mode_val);
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
    base.fillCommonFromRuby(&common, mrb, only_if_val, not_if_val, notifications_val, allocator);

    resources.append(allocator, .{
        .path = path,
        .source = source,
        .mode = mode,
        .variables = variables,
        .action = action,
        .common = common,
    }) catch return mruby.mrb_nil_value();

    return mruby.mrb_nil_value();
}
