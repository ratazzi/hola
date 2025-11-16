const std = @import("std");

// Ruby C API bindings
pub const c = @cImport({
    @cInclude("ruby.h");
});

pub fn evalString(code: []const u8) void {
    // Copy code and ensure null-termination with a sentinel slot
    var buf: [4096:0]u8 = undefined;
    if (code.len >= buf.len) return;

    @memcpy(buf[0..code.len], code);
    buf[code.len] = 0;

    _ = c.rb_eval_string(&buf);
}
