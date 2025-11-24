const std = @import("std");
const mruby = @import("mruby.zig");
const simple_dns = @import("simple_dns.zig");

/// Global allocator for mruby callbacks
var global_allocator: ?std.mem.Allocator = null;

pub fn setAllocator(allocator: std.mem.Allocator) void {
    global_allocator = allocator;
}

/// Resolv.getaddress(name) - Get first IPv4 address for hostname
/// Returns: String (IP address)
pub fn zig_resolv_getaddress(mrb: *mruby.mrb_state, _: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    const allocator = global_allocator orelse return mruby.mrb_nil_value();

    var name_ptr: [*c]const u8 = null;
    var name_len: mruby.mrb_int = 0;

    _ = mruby.mrb_get_args(mrb, "s", &name_ptr, &name_len);

    if (name_ptr == null or name_len <= 0) {
        return mruby.mrb_nil_value();
    }

    const hostname = name_ptr[0..@intCast(name_len)];

    // Resolve DNS
    const address_list = std.net.getAddressList(allocator, hostname, 0) catch {
        return mruby.mrb_nil_value();
    };
    defer address_list.deinit();

    // Find first IPv4 address
    for (address_list.addrs) |addr| {
        if (addr.any.family == std.posix.AF.INET) {
            // Format IPv4 address
            const addr_bytes = @as(*const [4]u8, @ptrCast(&addr.in.sa.addr));
            var ip_buf: [16]u8 = undefined;
            const ip_str = std.fmt.bufPrint(&ip_buf, "{d}.{d}.{d}.{d}", .{
                addr_bytes[0],
                addr_bytes[1],
                addr_bytes[2],
                addr_bytes[3],
            }) catch {
                return mruby.mrb_nil_value();
            };

            return mruby.mrb_str_new(mrb, ip_str.ptr, @intCast(ip_str.len));
        }
    }

    return mruby.mrb_nil_value();
}

/// Resolv.getaddresses(name, nameserver=nil) - Get all addresses (IPv4 and IPv6) for hostname
/// Returns: Array of Strings (IP addresses)
/// nameserver: optional DNS server address (can be domain name or IP)
pub fn zig_resolv_getaddresses(mrb: *mruby.mrb_state, _: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    const allocator = global_allocator orelse return mruby.mrb_nil_value();

    var name_ptr: [*c]const u8 = null;
    var name_len: mruby.mrb_int = 0;
    var nameserver_ptr: [*c]const u8 = null;
    var nameserver_len: mruby.mrb_int = 0;

    _ = mruby.mrb_get_args(mrb, "s|s", &name_ptr, &name_len, &nameserver_ptr, &nameserver_len);

    if (name_ptr == null or name_len <= 0) {
        return mruby.mrb_nil_value();
    }

    const hostname = name_ptr[0..@intCast(name_len)];

    // Check if custom nameserver is provided
    const nameserver: ?[]const u8 = if (nameserver_ptr != null and nameserver_len > 0)
        nameserver_ptr[0..@intCast(nameserver_len)]
    else
        null;

    // Use custom DNS or system resolver
    if (nameserver) |ns| {
        // Query both A and AAAA records
        var all_addresses = std.ArrayList([]const u8).empty;
        defer {
            for (all_addresses.items) |addr| {
                allocator.free(addr);
            }
            all_addresses.deinit(allocator);
        }

        // Query A records (IPv4)
        if (simple_dns.query(allocator, ns, hostname, .A)) |result| {
            defer {
                var res = result;
                res.deinit();
            }
            for (result.addresses) |addr| {
                const addr_copy = allocator.dupe(u8, addr) catch continue;
                all_addresses.append(allocator, addr_copy) catch {
                    allocator.free(addr_copy);
                };
            }
        } else |_| {}

        // Query AAAA records (IPv6)
        if (simple_dns.query(allocator, ns, hostname, .AAAA)) |result| {
            defer {
                var res = result;
                res.deinit();
            }
            for (result.addresses) |addr| {
                const addr_copy = allocator.dupe(u8, addr) catch continue;
                all_addresses.append(allocator, addr_copy) catch {
                    allocator.free(addr_copy);
                };
            }
        } else |_| {}

        // Create result array
        const result = mruby.mrb_ary_new_capa(mrb, @intCast(all_addresses.items.len));
        for (all_addresses.items) |addr| {
            const ip_mrb = mruby.mrb_str_new(mrb, addr.ptr, @intCast(addr.len));
            mruby.mrb_ary_push(mrb, result, ip_mrb);
        }
        return result;
    }

    // Use system resolver
    const address_list = std.net.getAddressList(allocator, hostname, 0) catch {
        return mruby.mrb_nil_value();
    };
    defer address_list.deinit();

    // Create result array
    const result = mruby.mrb_ary_new_capa(mrb, 8);

    var ip_buf: [46]u8 = undefined;

    for (address_list.addrs) |addr| {
        const ip_str = if (addr.any.family == std.posix.AF.INET) blk: {
            // IPv4
            const addr_bytes = @as(*const [4]u8, @ptrCast(&addr.in.sa.addr));
            break :blk std.fmt.bufPrint(&ip_buf, "{d}.{d}.{d}.{d}", .{
                addr_bytes[0],
                addr_bytes[1],
                addr_bytes[2],
                addr_bytes[3],
            }) catch continue;
        } else if (addr.any.family == std.posix.AF.INET6) blk: {
            // IPv6
            const addr_bytes = &addr.in6.sa.addr;
            var parts: [8]u16 = undefined;
            for (0..8) |i| {
                parts[i] = (@as(u16, addr_bytes[i * 2]) << 8) | addr_bytes[i * 2 + 1];
            }
            break :blk std.fmt.bufPrint(&ip_buf, "{x}:{x}:{x}:{x}:{x}:{x}:{x}:{x}", .{
                parts[0], parts[1], parts[2], parts[3],
                parts[4], parts[5], parts[6], parts[7],
            }) catch continue;
        } else continue;

        const ip_mrb = mruby.mrb_str_new(mrb, ip_str.ptr, @intCast(ip_str.len));
        mruby.mrb_ary_push(mrb, result, ip_mrb);
    }

    return result;
}

/// Resolv.getname(address) - Reverse DNS lookup
/// Returns: String (hostname)
/// Note: Currently returns the IP address itself as reverse DNS is not implemented
pub fn zig_resolv_getname(mrb: *mruby.mrb_state, _: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    _ = global_allocator;

    var addr_ptr: [*c]const u8 = null;
    var addr_len: mruby.mrb_int = 0;

    _ = mruby.mrb_get_args(mrb, "s", &addr_ptr, &addr_len);

    if (addr_ptr == null or addr_len <= 0) {
        return mruby.mrb_nil_value();
    }

    const addr_str = addr_ptr[0..@intCast(addr_len)];

    // For now, just return the address itself
    // TODO: Implement proper reverse DNS lookup when Zig std lib supports it
    return mruby.mrb_str_new(mrb, addr_str.ptr, @intCast(addr_str.len));
}

pub const ruby_prelude = @embedFile("ruby_prelude/resolv.rb");

// MRuby module registration interface
const mruby_module = @import("mruby_module.zig");

const resolv_functions = [_]mruby_module.ModuleFunction{
    .{ .name = "resolv_getaddress", .func = zig_resolv_getaddress, .args = mruby.MRB_ARGS_REQ(1) },
    .{ .name = "resolv_getaddresses", .func = zig_resolv_getaddresses, .args = mruby.MRB_ARGS_REQ(1) | mruby.MRB_ARGS_OPT(1) },
    .{ .name = "resolv_getname", .func = zig_resolv_getname, .args = mruby.MRB_ARGS_REQ(1) },
};

fn getFunctions() []const mruby_module.ModuleFunction {
    return &resolv_functions;
}

fn getPrelude() []const u8 {
    return ruby_prelude;
}

pub const mruby_module_def = mruby_module.MRubyModule{
    .name = "Resolv",
    .initFn = setAllocator,
    .getFunctions = getFunctions,
    .getPrelude = getPrelude,
};
