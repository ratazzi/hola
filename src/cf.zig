// Global CoreFoundation bindings
// Import this instead of doing @cImport in each file to ensure constants have consistent addresses

pub const c = @cImport({
    @cInclude("CoreFoundation/CoreFoundation.h");
});
