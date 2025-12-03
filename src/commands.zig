const builtin = @import("builtin");

pub const git_clone = @import("commands/git_clone.zig");
pub const link = @import("commands/link.zig");
pub const apply = @import("commands/apply.zig");
pub const provision = @import("commands/provision.zig");
pub const node_info = @import("commands/node_info.zig");
pub const applescript = if (builtin.os.tag == .macos) @import("commands/applescript.zig") else struct {};
pub const dock = if (builtin.os.tag == .macos) @import("commands/dock.zig") else struct {};
