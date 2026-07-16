// Global CoreFoundation bindings
// Import this instead of doing @cImport in each file to ensure constants have consistent addresses

// Note: zig 0.16's translate-c cannot handle the mach_msg descriptor types
// pulled in by the CoreFoundation.h umbrella header (via CFRunLoop/CFMachPort),
// so include only the specific headers this codebase uses.
pub const c = @cImport({
    // Skip mach/message.h: its descriptor types are untranslatable and its
    // eager _Static_asserts fail under translate-c. Nothing here needs
    // mach messaging (pulled in only via CFPropertyList -> CFStream -> CFRunLoop).
    @cDefine("_MACH_MESSAGE_H_", "1");
    @cInclude("CoreFoundation/CFBase.h");
    @cInclude("CoreFoundation/CFString.h");
    @cInclude("CoreFoundation/CFArray.h");
    @cInclude("CoreFoundation/CFDictionary.h");
    @cInclude("CoreFoundation/CFData.h");
    @cInclude("CoreFoundation/CFDate.h");
    @cInclude("CoreFoundation/CFNumber.h");
    @cInclude("CoreFoundation/CFPreferences.h");
    @cInclude("CoreFoundation/CFPropertyList.h");
    @cInclude("CoreFoundation/CFURL.h");
    @cInclude("CoreFoundation/CFURLAccess.h");
    @cInclude("CoreFoundation/CFError.h");
});
