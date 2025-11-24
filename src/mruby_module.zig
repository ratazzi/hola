const std = @import("std");
const mruby = @import("mruby.zig");
const logger = @import("logger.zig");

/// Module function definition
pub const ModuleFunction = struct {
    name: []const u8,
    func: mruby.mrb_func_t,
    args: c_uint,
};

/// MRuby module interface
pub const MRubyModule = struct {
    /// Module name for logging
    name: []const u8,

    /// Initialize module with allocator (optional)
    initFn: ?*const fn (std.mem.Allocator) void = null,

    /// Get list of functions to register
    getFunctions: *const fn () []const ModuleFunction,

    /// Get Ruby prelude code
    getPrelude: *const fn () []const u8,

    /// Optional platform check (returns true if module should be loaded)
    platformCheck: ?*const fn () bool = null,
};

/// Register a module with mruby
pub fn registerModule(
    mrb: *mruby.mrb_state,
    zig_module: *mruby.RClass,
    allocator: std.mem.Allocator,
    module: MRubyModule,
    mrb_state: *mruby.State,
) !void {
    // Check platform compatibility
    if (module.platformCheck) |check| {
        if (!check()) {
            logger.warn("Module '{s}' skipped: platform check failed", .{module.name});
            return;
        }
    }

    logger.debug("Registering module: {s}", .{module.name});

    // Initialize module if needed
    if (module.initFn) |init| {
        init(allocator);
    }

    // Register all functions
    for (module.getFunctions()) |func| {
        mruby.mrb_define_module_function(
            mrb,
            zig_module,
            func.name.ptr,
            func.func,
            func.args,
        );
    }

    // Load Ruby prelude - if this fails, propagate the error with context
    mrb_state.evalString(module.getPrelude()) catch |err| {
        logger.err("Failed to load Ruby prelude for module '{s}': {}", .{ module.name, err });
        return err;
    };

    logger.debug("Module '{s}' registered successfully", .{module.name});
}
