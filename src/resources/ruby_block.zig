const std = @import("std");
const mruby = @import("../mruby.zig");
const base = @import("../base_resource.zig");

// External helper for checking nil values and exceptions
extern fn zig_mrb_nil_p(val: mruby.mrb_value) c_int;
extern fn zig_mrb_has_exception(mrb: *mruby.mrb_state) c_int;

/// Ruby block resource data structure
pub const Resource = struct {
    // Resource-specific properties
    name: []const u8,
    block_proc: ?mruby.mrb_value, // Ruby Proc to execute
    action: Action,

    // Common properties (guards, notifications, etc.)
    common: base.CommonProps,

    pub const Action = enum {
        run, // Execute the block
        nothing, // Do nothing
    };

    pub fn deinit(self: Resource, allocator: std.mem.Allocator) void {
        allocator.free(self.name);

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
        const skip_reason = try self.common.shouldRun();
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
                std.log.err("Ruby block execution failed: {s}", .{err_msg});

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
    var action_val: mruby.mrb_value = undefined;
    var only_if_val: mruby.mrb_value = undefined;
    var not_if_val: mruby.mrb_value = undefined;
    var notifications_val: mruby.mrb_value = undefined;

    // Get name (string), block (proc), action (string), and 3 optional (blocks + array)
    _ = mruby.mrb_get_args(mrb, "SoS|ooA", &name_val, &block_val, &action_val, &only_if_val, &not_if_val, &notifications_val);

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

    // Build common properties (guards + notifications)
    var common = base.CommonProps.init(allocator);
    base.fillCommonFromRuby(&common, mrb, only_if_val, not_if_val, notifications_val, allocator);

    // Register block with GC to prevent collection
    if (block_proc) |proc| {
        mruby.mrb_gc_register(mrb, proc);
    }

    resources.append(allocator, .{
        .name = name,
        .block_proc = block_proc,
        .action = action,
        .common = common,
    }) catch return mruby.mrb_nil_value();

    return mruby.mrb_nil_value();
}
