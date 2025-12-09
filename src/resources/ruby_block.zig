const std = @import("std");
const mruby = @import("../mruby.zig");
const base = @import("../base_resource.zig");
const logger = @import("../logger.zig");

// External helper for checking nil values and exceptions
extern fn zig_mrb_nil_p(val: mruby.mrb_value) c_int;
extern fn zig_mrb_has_exception(mrb: *mruby.mrb_state) c_int;

/// Ruby block resource data structure
pub const Resource = struct {
    // Resource-specific properties
    name: []const u8,
    block_proc: ?mruby.mrb_value, // Ruby Proc to execute
    environment: ?[]const u8, // Environment variables (KEY=VALUE\0KEY2=VALUE2\0)
    action: Action,

    // Common properties (guards, notifications, etc.)
    common: base.CommonProps,

    pub const Action = enum {
        run, // Execute the block
        nothing, // Do nothing
    };

    pub fn deinit(self: Resource, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.environment) |env| allocator.free(env);

        // Unregister block from GC
        if (self.common.mrb_state) |mrb| {
            if (self.block_proc) |block| {
                mruby.mrb_gc_unregister(mrb, block);
            }
        }

        // Deinit common props
        var common = self.common;
        common.deinit(allocator);
    }

    pub fn apply(self: Resource) !base.ApplyResult {
        const skip_reason = try self.common.shouldRun(null, null);
        if (skip_reason) |reason| {
            const action_name = switch (self.action) {
                .run => "run",
                .nothing => "nothing",
            };
            return base.ApplyResult{
                .was_updated = false,
                .action = action_name,
                .skip_reason = reason,
            };
        }

        const action_name = switch (self.action) {
            .run => "run",
            .nothing => "nothing",
        };

        switch (self.action) {
            .run => {
                const was_executed = try applyRun(self);
                return base.ApplyResult{
                    .was_updated = was_executed,
                    .action = action_name,
                    .skip_reason = if (was_executed) null else "skipped",
                };
            },
            .nothing => {
                return base.ApplyResult{
                    .was_updated = false,
                    .action = action_name,
                    .skip_reason = "nothing",
                };
            },
        }
    }

    fn applyRun(self: Resource) !bool {
        if (self.block_proc) |proc| {
            // Get mruby state from common props
            const mrb = self.common.mrb_state orelse return error.NoMrubyState;

            // Set environment variables if specified
            const c = @cImport({
                @cInclude("stdlib.h");
            });

            const EnvEntry = struct { key: []const u8, value: ?[]const u8 };
            var saved_env = std.ArrayList(EnvEntry).empty;
            defer {
                // Restore original environment and free allocated memory
                for (saved_env.items) |item| {
                    const key_z = std.heap.page_allocator.dupeZ(u8, item.key) catch continue;
                    defer std.heap.page_allocator.free(key_z);

                    if (item.value) |val| {
                        const val_z = std.heap.page_allocator.dupeZ(u8, val) catch continue;
                        defer std.heap.page_allocator.free(val_z);
                        _ = c.setenv(key_z.ptr, val_z.ptr, 1);

                        // Free the saved value
                        std.heap.page_allocator.free(val);
                    } else {
                        _ = c.unsetenv(key_z.ptr);
                    }

                    // Free the saved key
                    std.heap.page_allocator.free(item.key);
                }
                saved_env.deinit(std.heap.page_allocator);
            }

            if (self.environment) |env_str| {
                // Parse environment string "KEY=VALUE\0KEY2=VALUE2\0"
                var pos: usize = 0;
                while (pos < env_str.len) {
                    const start = pos;
                    while (pos < env_str.len and env_str[pos] != 0) : (pos += 1) {}

                    const pair = env_str[start..pos];
                    if (pair.len > 0) {
                        if (std.mem.indexOfScalar(u8, pair, '=')) |eq_pos| {
                            const key = pair[0..eq_pos];
                            const value = pair[eq_pos + 1 ..];

                            // Save current value
                            const key_z = std.heap.page_allocator.dupeZ(u8, key) catch continue;
                            defer std.heap.page_allocator.free(key_z);

                            const old_value_ptr = c.getenv(key_z.ptr);
                            const old_value = if (old_value_ptr != null) std.mem.span(old_value_ptr) else null;

                            // Save current value - handle allocation failures properly
                            const key_copy = std.heap.page_allocator.dupe(u8, key) catch continue;
                            errdefer std.heap.page_allocator.free(key_copy);

                            const old_value_copy = if (old_value) |v|
                                std.heap.page_allocator.dupe(u8, v) catch {
                                    // If value copy fails, free key_copy and skip this entry
                                    std.heap.page_allocator.free(key_copy);
                                    continue;
                                }
                            else
                                null;
                            errdefer if (old_value_copy) |ov| std.heap.page_allocator.free(ov);

                            // Append to saved_env - if this fails, errdefer will clean up
                            saved_env.append(std.heap.page_allocator, .{ .key = key_copy, .value = old_value_copy }) catch {
                                std.heap.page_allocator.free(key_copy);
                                if (old_value_copy) |ov| std.heap.page_allocator.free(ov);
                                continue;
                            };

                            // Set new value
                            const val_z = std.heap.page_allocator.dupeZ(u8, value) catch continue;
                            defer std.heap.page_allocator.free(val_z);
                            _ = c.setenv(key_z.ptr, val_z.ptr, 1);
                        }
                    }

                    pos += 1; // Skip null terminator
                }
            }

            // Call the Ruby proc using mrb_funcall
            // Proc.call() in Ruby translates to funcall with "call" method
            const call_sym = mruby.mrb_intern_cstr(mrb, "call");
            const result = mruby.mrb_funcall_argv(mrb, proc, call_sym, 0, null);

            // Check if an exception occurred
            if (zig_mrb_has_exception(mrb) != 0) {
                // Get exception object and convert to string
                const exc = mruby.mrb_get_exception(mrb);
                const exc_str = mruby.mrb_inspect(mrb, exc);
                const err_msg_cstr = mruby.mrb_str_to_cstr(mrb, exc_str);
                const err_msg = std.mem.span(err_msg_cstr);

                // Log the error message
                logger.err("Ruby block execution failed: {s}", .{err_msg});

                // Also print to stderr for consistency
                mruby.mrb_print_error(mrb);
                return error.RubyBlockFailed;
            }

            _ = result;
            return true; // Block was executed
        }
        return false; // No block to execute
    }
};

/// Ruby prelude for ruby_block resource
pub const ruby_prelude = @embedFile("ruby_block_resource.rb");

/// Zig callback: called from Ruby to add a ruby_block resource
pub fn zigAddResource(
    mrb: *mruby.mrb_state,
    self: mruby.mrb_value,
    resources: *std.ArrayList(Resource),
    allocator: std.mem.Allocator,
) mruby.mrb_value {
    _ = self;

    var name_val: mruby.mrb_value = undefined;
    var block_val: mruby.mrb_value = undefined;
    var environment_val: mruby.mrb_value = undefined;
    var action_val: mruby.mrb_value = undefined;
    var only_if_val: mruby.mrb_value = undefined;
    var not_if_val: mruby.mrb_value = undefined;
    var ignore_failure_val: mruby.mrb_value = undefined;
    var notifications_val: mruby.mrb_value = undefined;
    var subscriptions_val: mruby.mrb_value = undefined;

    // Get name (string), block (proc), environment (array), action (string), and 4 optional (blocks + arrays)
    _ = mruby.mrb_get_args(mrb, "SoAS|oooAA", &name_val, &block_val, &environment_val, &action_val, &only_if_val, &not_if_val, &ignore_failure_val, &notifications_val, &subscriptions_val);

    const name_cstr = mruby.mrb_str_to_cstr(mrb, name_val);
    const action_cstr = mruby.mrb_str_to_cstr(mrb, action_val);

    const name = allocator.dupe(u8, std.mem.span(name_cstr)) catch return mruby.mrb_nil_value();

    const action_str = std.mem.span(action_cstr);
    const action: Resource.Action = if (std.mem.eql(u8, action_str, "nothing"))
        .nothing
    else
        .run;

    // Store the block proc (if it's a proc)
    const block_proc: ?mruby.mrb_value = if (zig_mrb_nil_p(block_val) == 0) block_val else null;

    // Parse environment array [[key, value], ...]
    var environment: ?[]const u8 = null;
    const env_len = mruby.mrb_ary_len(mrb, environment_val);
    if (env_len > 0) {
        // Build environment string in format "KEY=VALUE\0KEY2=VALUE2\0"
        var env_list = std.ArrayList(u8).initCapacity(allocator, @intCast(env_len * 32)) catch std.ArrayList(u8).empty;
        defer env_list.deinit(allocator);

        var i: mruby.mrb_int = 0;
        while (i < env_len) : (i += 1) {
            const pair = mruby.mrb_ary_ref(mrb, environment_val, i);
            if (mruby.mrb_ary_len(mrb, pair) != 2) continue;

            const key_val = mruby.mrb_ary_ref(mrb, pair, 0);
            const val_val = mruby.mrb_ary_ref(mrb, pair, 1);

            const key_cstr = mruby.mrb_str_to_cstr(mrb, key_val);
            const val_cstr = mruby.mrb_str_to_cstr(mrb, val_val);

            const key_str = std.mem.span(key_cstr);
            const val_str = std.mem.span(val_cstr);

            // Append "KEY=VALUE\0"
            env_list.appendSlice(allocator, key_str) catch return mruby.mrb_nil_value();
            env_list.append(allocator, '=') catch return mruby.mrb_nil_value();
            env_list.appendSlice(allocator, val_str) catch return mruby.mrb_nil_value();
            env_list.append(allocator, 0) catch return mruby.mrb_nil_value();
        }

        if (env_list.items.len > 0) {
            environment = allocator.dupe(u8, env_list.items) catch return mruby.mrb_nil_value();
        }
    }

    // Build common properties (guards + notifications)
    var common = base.CommonProps.init(allocator);
    base.fillCommonFromRuby(&common, mrb, only_if_val, not_if_val, ignore_failure_val, notifications_val, subscriptions_val, allocator);

    // Register block with GC to prevent collection
    if (block_proc) |proc| {
        mruby.mrb_gc_register(mrb, proc);
    }

    resources.append(allocator, .{
        .name = name,
        .block_proc = block_proc,
        .environment = environment,
        .action = action,
        .common = common,
    }) catch return mruby.mrb_nil_value();

    return mruby.mrb_nil_value();
}
