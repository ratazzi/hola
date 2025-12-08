const std = @import("std");
const mruby = @import("mruby.zig");
const builtin = @import("builtin");

// Platform-specific C imports
const c = if (builtin.os.tag == .macos) @cImport({
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
    @cInclude("net/if.h");
    @cInclude("ifaddrs.h");
    @cInclude("net/route.h");
    @cInclude("sys/sysctl.h");
}) else @cImport({
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
    @cInclude("net/if.h");
    @cInclude("ifaddrs.h");
});

/// Root Node structure matching Chef Ohai JSON
pub const Node = struct {
    hostname: []const u8,
    fqdn: []const u8,
    platform: []const u8,
    platform_family: []const u8,
    platform_version: ?[]const u8,
    os: []const u8,
    machine: []const u8,
    kernel: Kernel,
    cpu: CPU,
    memory: Memory,
    network: Network,
    lsb: ?LsbInfo = null,
    platform_checks: PlatformChecks,

    /// Free all allocated memory in this Node
    pub fn deinit(self: Node, allocator: std.mem.Allocator) void {
        allocator.free(self.hostname);
        allocator.free(self.fqdn);
        allocator.free(self.platform);
        allocator.free(self.platform_family);
        if (self.platform_version) |v| allocator.free(v);
        allocator.free(self.machine);
        allocator.free(self.kernel.release);
        if (self.cpu.model_name.len > 0) allocator.free(self.cpu.model_name);
        if (self.memory.total.len > 0) allocator.free(self.memory.total);
        if (self.memory.free.len > 0) allocator.free(self.memory.free);
        if (self.memory.available) |v| allocator.free(v);
        if (self.memory.active) |v| allocator.free(v);
        if (self.memory.inactive) |v| allocator.free(v);
        if (self.memory.wired) |v| allocator.free(v);
        if (self.memory.compressed) |v| allocator.free(v);
        if (self.memory.buffers) |v| allocator.free(v);
        if (self.memory.cached) |v| allocator.free(v);
        if (self.memory.swap_total) |v| allocator.free(v);
        if (self.memory.swap_free) |v| allocator.free(v);
        if (self.network.default_gateway) |v| allocator.free(v);
        if (self.network.default_interface) |v| allocator.free(v);
        for (self.network.interfaces) |iface| {
            allocator.free(iface.name);
            allocator.free(iface.ip_address);
        }
        allocator.free(self.network.interfaces);
        if (self.lsb) |lsb| {
            allocator.free(lsb.id);
            allocator.free(lsb.description);
            allocator.free(lsb.release);
            allocator.free(lsb.codename);
        }
    }
};

pub const Kernel = struct {
    name: []const u8,
    release: []const u8,
    machine: []const u8,
};

pub const CPU = struct {
    architecture: []const u8,
    cores: u32 = 0,
    total: u32 = 0,
    real: u32 = 0,
    model_name: []const u8 = "",
};

pub const Memory = struct {
    total: []const u8 = "",
    free: []const u8 = "",
    available: ?[]const u8 = null,
    active: ?[]const u8 = null,
    inactive: ?[]const u8 = null,
    wired: ?[]const u8 = null,
    compressed: ?[]const u8 = null,
    buffers: ?[]const u8 = null,
    cached: ?[]const u8 = null,
    swap_total: ?[]const u8 = null,
    swap_free: ?[]const u8 = null,
};

pub const PlatformChecks = struct {
    mac_os_x: bool,
    linux: bool,
};

pub const Network = struct {
    default_gateway: ?[]const u8 = null,
    default_interface: ?[]const u8 = null,
    interfaces: []Interface,
};

pub const Interface = struct {
    name: []const u8,
    ip_address: []const u8,
    up: bool,
    loopback: bool,
    running: bool,
    multicast: bool,
};

/// Network interface information (internal use)
const NetworkInterface = struct {
    name: []const u8,
    ip_address: []const u8,
    is_up: bool,
    is_loopback: bool,
    is_running: bool,
    is_multicast: bool,
};

/// Get complete node information
pub fn getNodeInfo(allocator: std.mem.Allocator) !Node {
    const hostname = try getHostname(allocator);
    const fqdn = try getFqdn(allocator);
    const platform = try getPlatform(allocator);
    const platform_family = try getPlatformFamily(allocator);
    const platform_version = try getPlatformVersion(allocator);
    const machine = try getMachine(allocator);
    const kernel_release = try getKernelRelease(allocator);

    // Network info
    var default_gateway: ?[]const u8 = null;
    var default_interface: ?[]const u8 = null;
    if (try getDefaultGateway(allocator)) |gw| {
        default_gateway = gw.ip;
        default_interface = gw.interface;
    }

    const raw_interfaces = try getNetworkInterfaces(allocator);
    var interfaces = try allocator.alloc(Interface, raw_interfaces.len);
    for (raw_interfaces, 0..) |raw, i| {
        interfaces[i] = Interface{
            .name = raw.name,
            .ip_address = raw.ip_address,
            .up = raw.is_up,
            .loopback = raw.is_loopback,
            .running = raw.is_running,
            .multicast = raw.is_multicast,
        };
    }
    // Note: raw_interfaces slice itself needs freeing, but contents are moved to Node
    allocator.free(raw_interfaces);

    // Get CPU and memory information
    const cpu = try getCpuInfo(allocator);
    const memory = try getMemoryInfo(allocator);

    return Node{
        .hostname = hostname,
        .fqdn = fqdn,
        .platform = platform,
        .platform_family = platform_family,
        .platform_version = platform_version,
        .os = getOs(),
        .machine = machine,
        .kernel = Kernel{
            .name = getKernelName(),
            .release = kernel_release,
            .machine = getCpuArch(),
        },
        .cpu = cpu,
        .memory = memory,
        .network = Network{
            .default_gateway = default_gateway,
            .default_interface = default_interface,
            .interfaces = interfaces,
        },
        .lsb = try getLsbInfo(allocator),
        .platform_checks = PlatformChecks{
            .mac_os_x = builtin.os.tag == .macos,
            .linux = builtin.os.tag == .linux,
        },
    };
}

/// Get hostname (short hostname, without domain)
pub fn getHostname(allocator: std.mem.Allocator) ![]const u8 {
    // Try to get hostname from uname
    const uname_buf = std.posix.uname();
    const nodename = std.mem.sliceTo(&uname_buf.nodename, 0);

    // Extract just the hostname part before the first dot
    if (std.mem.indexOf(u8, nodename, ".")) |dot_pos| {
        return try allocator.dupe(u8, nodename[0..dot_pos]);
    } else {
        return try allocator.dupe(u8, nodename);
    }
}

/// Get FQDN (fully qualified domain name)
pub fn getFqdn(allocator: std.mem.Allocator) ![]const u8 {
    // Get the original nodename from uname for FQDN
    const uname_buf = std.posix.uname();
    const nodename = std.mem.sliceTo(&uname_buf.nodename, 0);
    return try allocator.dupe(u8, nodename);
}

/// Get platform (specific distro on Linux, os name otherwise)
pub fn getPlatform(allocator: std.mem.Allocator) ![]const u8 {
    return switch (builtin.os.tag) {
        .macos => try allocator.dupe(u8, "mac_os_x"),
        .linux => blk: {
            // Try to get distro from /etc/os-release
            const lsb_opt = getLsbInfo(allocator) catch null;
            if (lsb_opt) |lsb| {
                // We don't free lsb contents here because getLsbInfo returns allocated strings
                // that we might want to reuse or free later.
                // BUT here we are just using it to determine platform string.
                // So we should free the LsbInfo parts we don't use.
                defer {
                    allocator.free(lsb.id);
                    allocator.free(lsb.description);
                    allocator.free(lsb.release);
                    allocator.free(lsb.codename);
                }
                break :blk try allocator.dupe(u8, lsb.id);
            } else {
                break :blk try allocator.dupe(u8, "linux");
            }
        },
        .freebsd => try allocator.dupe(u8, "freebsd"),
        .openbsd => try allocator.dupe(u8, "openbsd"),
        .netbsd => try allocator.dupe(u8, "netbsd"),
        else => try allocator.dupe(u8, "unknown"),
    };
}

/// Get platform family (debian, rhel, arch, etc.)
pub fn getPlatformFamily(allocator: std.mem.Allocator) ![]const u8 {
    return switch (builtin.os.tag) {
        .macos => try allocator.dupe(u8, "mac_os_x"),
        .linux => blk: {
            // Try to detect from /etc/os-release
            const lsb_opt = getLsbInfo(allocator) catch null;
            if (lsb_opt) |lsb| {
                defer {
                    allocator.free(lsb.id);
                    allocator.free(lsb.description);
                    allocator.free(lsb.release);
                    allocator.free(lsb.codename);
                }
                // Map distros to families
                if (std.mem.eql(u8, lsb.id, "debian") or std.mem.eql(u8, lsb.id, "ubuntu")) {
                    break :blk try allocator.dupe(u8, "debian");
                } else if (std.mem.eql(u8, lsb.id, "fedora") or std.mem.eql(u8, lsb.id, "rhel") or std.mem.eql(u8, lsb.id, "centos")) {
                    break :blk try allocator.dupe(u8, "rhel");
                } else if (std.mem.eql(u8, lsb.id, "arch")) {
                    break :blk try allocator.dupe(u8, "arch");
                } else {
                    break :blk try allocator.dupe(u8, lsb.id);
                }
            } else {
                break :blk try allocator.dupe(u8, "linux");
            }
        },
        .freebsd, .openbsd, .netbsd => try allocator.dupe(u8, "bsd"),
        else => try allocator.dupe(u8, "unknown"),
    };
}

/// Get platform version (from LSB on Linux)
pub fn getPlatformVersion(allocator: std.mem.Allocator) !?[]const u8 {
    return switch (builtin.os.tag) {
        .linux => blk: {
            const lsb_opt = getLsbInfo(allocator) catch null;
            if (lsb_opt) |lsb| {
                // Copy the release version before freeing
                const version = try allocator.dupe(u8, lsb.release);
                // Now free all LSB fields
                allocator.free(lsb.id);
                allocator.free(lsb.description);
                allocator.free(lsb.release);
                allocator.free(lsb.codename);
                break :blk version;
            } else {
                break :blk null;
            }
        },
        else => null,
    };
}

/// Get OS name
pub fn getOs() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "darwin",
        .linux => "linux",
        .freebsd => "freebsd",
        .openbsd => "openbsd",
        .netbsd => "netbsd",
        .windows => "windows",
        else => "unknown",
    };
}

/// Get kernel name
pub fn getKernelName() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "Darwin",
        .linux => "Linux",
        .freebsd => "FreeBSD",
        else => "Unknown",
    };
}

/// Get kernel release (version string)
pub fn getKernelRelease(allocator: std.mem.Allocator) ![]const u8 {
    const uname_buf = std.posix.uname();
    const release = std.mem.sliceTo(&uname_buf.release, 0);
    return try allocator.dupe(u8, release);
}

/// Get machine architecture
pub fn getMachine(allocator: std.mem.Allocator) ![]const u8 {
    const uname_buf = std.posix.uname();
    const machine = std.mem.sliceTo(&uname_buf.machine, 0);
    return try allocator.dupe(u8, machine);
}

/// Get CPU architecture in Chef format
pub fn getCpuArch() []const u8 {
    return switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .arm => "arm",
        .x86 => "i686",
        else => "unknown",
    };
}

/// Get network interfaces using std.posix.ifaddrs (real API approach)
pub fn getNetworkInterfaces(allocator: std.mem.Allocator) ![]NetworkInterface {
    var interfaces = std.ArrayList(NetworkInterface).initCapacity(allocator, 0) catch return error.OutOfMemory;
    defer interfaces.deinit(allocator); // We return owned slice, so this only frees the list structure if we fail

    var ifaddrs_ptr: ?*c.ifaddrs = null;
    defer if (ifaddrs_ptr) |ptr| c.freeifaddrs(ptr);

    if (c.getifaddrs(&ifaddrs_ptr) != 0) return error.SystemCallFailed;

    var current = ifaddrs_ptr;
    while (current) |ifaddr| {
        const interface_name = std.mem.sliceTo(ifaddr.ifa_name, 0);

        // Only process IPv4 interfaces with valid addresses
        if (ifaddr.ifa_addr != null) {
            // Get the address family (sa_family is the first field of sockaddr)
            const sockaddr = @as(*c.struct_sockaddr, @ptrCast(@alignCast(ifaddr.ifa_addr.?)));

            if (sockaddr.sa_family == c.AF_INET) {
                const sockaddr_in = @as(*c.struct_sockaddr_in, @ptrCast(@alignCast(ifaddr.ifa_addr.?)));
                var addr: [4]u8 = undefined;
                std.mem.writeInt(u32, &addr, @byteSwap(sockaddr_in.sin_addr.s_addr), .big);

                const ip_str = try std.fmt.allocPrint(allocator, "{}.{}.{}.{}", .{ addr[0], addr[1], addr[2], addr[3] });

                const flags = ifaddr.ifa_flags;
                const is_up = (flags & c.IFF_UP) != 0;
                const is_loopback = (flags & c.IFF_LOOPBACK) != 0;
                const is_running = (flags & c.IFF_RUNNING) != 0;
                const is_multicast = (flags & c.IFF_MULTICAST) != 0;

                try interfaces.append(allocator, NetworkInterface{
                    .name = try allocator.dupe(u8, interface_name),
                    .ip_address = ip_str,
                    .is_up = is_up,
                    .is_loopback = is_loopback,
                    .is_running = is_running,
                    .is_multicast = is_multicast,
                });
            }
        }

        current = ifaddr.ifa_next;
    }

    return interfaces.toOwnedSlice(allocator);
}

/// Default gateway information
const DefaultGateway = struct {
    ip: []const u8,
    interface: []const u8,
};

/// LSB (Linux Standard Base) information
pub const LsbInfo = struct {
    id: []const u8,
    description: []const u8,
    release: []const u8,
    codename: []const u8,
};

/// Get default gateway IP address and interface
pub fn getDefaultGateway(allocator: std.mem.Allocator) !?DefaultGateway {
    if (builtin.os.tag == .macos) {
        return getDefaultGatewayMacOS(allocator);
    } else if (builtin.os.tag == .linux) {
        return getDefaultGatewayLinux(allocator);
    }
    return null;
}

/// Get LSB information by reading /etc/os-release (Linux only)
pub fn getLsbInfo(allocator: std.mem.Allocator) !?LsbInfo {
    if (builtin.os.tag != .linux) return null;

    const file = std.fs.cwd().openFile("/etc/os-release", .{}) catch return null;
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 8192);
    defer allocator.free(content);

    var id: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    var release: ?[]const u8 = null;
    var codename: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;

        if (std.mem.indexOf(u8, line, "=")) |eq_pos| {
            const key = line[0..eq_pos];
            var value = line[eq_pos + 1 ..];

            // Remove quotes if present
            if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
                value = value[1 .. value.len - 1];
            }

            if (std.mem.eql(u8, key, "ID")) {
                id = try allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "PRETTY_NAME")) {
                description = try allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "VERSION_ID")) {
                release = try allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "VERSION_CODENAME")) {
                codename = try allocator.dupe(u8, value);
            }
        }
    }

    if (id != null and description != null and release != null and codename != null) {
        return LsbInfo{
            .id = id.?,
            .description = description.?,
            .release = release.?,
            .codename = codename.?,
        };
    }

    // Clean up if incomplete
    if (id) |v| allocator.free(v);
    if (description) |v| allocator.free(v);
    if (release) |v| allocator.free(v);
    if (codename) |v| allocator.free(v);

    return null;
}

/// Get default gateway on macOS using sysctl
fn getDefaultGatewayMacOS(allocator: std.mem.Allocator) !?DefaultGateway {
    // Use sysctl to get routing table
    var mib = [_]c_int{ c.CTL_NET, c.PF_ROUTE, 0, c.AF_INET, c.NET_RT_FLAGS, c.RTF_GATEWAY };
    var buf_size: usize = 0;

    // Get required buffer size
    if (c.sysctl(&mib, 6, null, &buf_size, null, 0) != 0) {
        return null;
    }

    // Allocate buffer
    const buf = try allocator.alloc(u8, buf_size);
    defer allocator.free(buf);

    // Get routing table
    if (c.sysctl(&mib, 6, buf.ptr, &buf_size, null, 0) != 0) {
        return null;
    }

    // Parse routing messages to find default gateway
    var offset: usize = 0;
    while (offset < buf_size) {
        const rt_msghdr = @as(*c.struct_rt_msghdr, @ptrCast(@alignCast(buf.ptr + offset)));

        // Check if this is a default route (destination 0.0.0.0)
        if ((rt_msghdr.rtm_flags & c.RTF_GATEWAY) != 0) {
            // Skip to sockaddr section
            const sa_offset = offset + @sizeOf(c.struct_rt_msghdr);

            // The gateway address is in the sockaddrs following rt_msghdr
            // We need to parse through the sockaddrs based on rtm_addrs bitmask
            var current_offset = sa_offset;
            const mask = rt_msghdr.rtm_addrs;

            // Skip destination address (RTA_DST = 0x1)
            if ((mask & c.RTA_DST) != 0) {
                const sa = @as(*c.struct_sockaddr, @ptrCast(@alignCast(buf.ptr + current_offset)));
                current_offset += @max(@as(usize, @intCast(sa.sa_len)), @sizeOf(c.struct_sockaddr));
            }

            // Get gateway address (RTA_GATEWAY = 0x2)
            if ((mask & c.RTA_GATEWAY) != 0) {
                const sa = @as(*c.struct_sockaddr, @ptrCast(@alignCast(buf.ptr + current_offset)));
                if (sa.sa_family == c.AF_INET) {
                    const sin = @as(*c.struct_sockaddr_in, @ptrCast(@alignCast(buf.ptr + current_offset)));
                    var addr: [4]u8 = undefined;
                    std.mem.writeInt(u32, &addr, @byteSwap(sin.sin_addr.s_addr), .big);

                    const ip = try std.fmt.allocPrint(allocator, "{}.{}.{}.{}", .{ addr[0], addr[1], addr[2], addr[3] });

                    // Get interface name using if_indextoname
                    const if_index = rt_msghdr.rtm_index;
                    var if_name_buf: [c.IF_NAMESIZE]u8 = undefined;
                    const if_name_ptr = c.if_indextoname(@intCast(if_index), &if_name_buf);

                    if (if_name_ptr != null) {
                        const if_name = std.mem.sliceTo(&if_name_buf, 0);
                        const interface = try allocator.dupe(u8, if_name);
                        return DefaultGateway{
                            .ip = ip,
                            .interface = interface,
                        };
                    } else {
                        return DefaultGateway{
                            .ip = ip,
                            .interface = try allocator.dupe(u8, "unknown"),
                        };
                    }
                }
            }
        }

        offset += @as(usize, @intCast(rt_msghdr.rtm_msglen));
    }

    return null;
}

/// Get default gateway on Linux by reading /proc/net/route
fn getDefaultGatewayLinux(allocator: std.mem.Allocator) !?DefaultGateway {
    const file = std.fs.cwd().openFile("/proc/net/route", .{}) catch return null;
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 8192);
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    _ = lines.next(); // Skip header

    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        const iface_name = fields.next() orelse continue;
        const dest = fields.next() orelse continue;
        const gateway = fields.next() orelse continue;

        // Check for default route (destination 00000000)
        if (std.mem.eql(u8, dest, "00000000")) {
            // Parse gateway hex string (little-endian)
            const gateway_int = try std.fmt.parseInt(u32, gateway, 16);
            const a = @as(u8, @truncate(gateway_int & 0xFF));
            const b = @as(u8, @truncate((gateway_int >> 8) & 0xFF));
            const c_val = @as(u8, @truncate((gateway_int >> 16) & 0xFF));
            const d = @as(u8, @truncate((gateway_int >> 24) & 0xFF));

            const ip = try std.fmt.allocPrint(allocator, "{}.{}.{}.{}", .{ a, b, c_val, d });
            const interface = try allocator.dupe(u8, iface_name);

            return DefaultGateway{
                .ip = ip,
                .interface = interface,
            };
        }
    }

    return null;
}

/// Global allocator for node info
var global_allocator: ?std.mem.Allocator = null;

pub fn setAllocator(allocator: std.mem.Allocator) void {
    global_allocator = allocator;
}

/// mruby binding: get_node_hostname()
pub fn zig_get_node_hostname(mrb: *mruby.mrb_state, _: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    const allocator = global_allocator orelse return mruby.mrb_nil_value();
    const hostname = getHostname(allocator) catch return mruby.mrb_nil_value();
    defer allocator.free(hostname);
    return mruby.mrb_str_new(mrb, hostname.ptr, @intCast(hostname.len));
}

/// mruby binding: get_node_fqdn()
pub fn zig_get_node_fqdn(mrb: *mruby.mrb_state, _: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    const allocator = global_allocator orelse return mruby.mrb_nil_value();
    const fqdn = getFqdn(allocator) catch return mruby.mrb_nil_value();
    defer allocator.free(fqdn);
    return mruby.mrb_str_new(mrb, fqdn.ptr, @intCast(fqdn.len));
}

/// mruby binding: get_node_platform()
pub fn zig_get_node_platform(mrb: *mruby.mrb_state, _: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    const allocator = global_allocator orelse return mruby.mrb_nil_value();
    const platform = getPlatform(allocator) catch return mruby.mrb_nil_value();
    defer allocator.free(platform);
    return mruby.mrb_str_new(mrb, platform.ptr, @intCast(platform.len));
}

/// mruby binding: get_node_platform_family()
pub fn zig_get_node_platform_family(mrb: *mruby.mrb_state, _: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    const allocator = global_allocator orelse return mruby.mrb_nil_value();
    const family = getPlatformFamily(allocator) catch return mruby.mrb_nil_value();
    defer allocator.free(family);
    return mruby.mrb_str_new(mrb, family.ptr, @intCast(family.len));
}

/// mruby binding: get_node_platform_version()
pub fn zig_get_node_platform_version(mrb: *mruby.mrb_state, _: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    const allocator = global_allocator orelse return mruby.mrb_nil_value();
    const version = getPlatformVersion(allocator) catch return mruby.mrb_nil_value();
    if (version) |v| {
        defer allocator.free(v);
        return mruby.mrb_str_new(mrb, v.ptr, @intCast(v.len));
    }
    return mruby.mrb_nil_value();
}

/// mruby binding: get_node_os()
pub fn zig_get_node_os(mrb: *mruby.mrb_state, _: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    const os = getOs();
    return mruby.mrb_str_new(mrb, os.ptr, @intCast(os.len));
}

/// mruby binding: get_node_kernel_name()
pub fn zig_get_node_kernel_name(mrb: *mruby.mrb_state, _: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    const name = getKernelName();
    return mruby.mrb_str_new(mrb, name.ptr, @intCast(name.len));
}

/// mruby binding: get_node_kernel_release()
pub fn zig_get_node_kernel_release(mrb: *mruby.mrb_state, _: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    const allocator = global_allocator orelse return mruby.mrb_nil_value();
    const release = getKernelRelease(allocator) catch return mruby.mrb_nil_value();
    defer allocator.free(release);
    return mruby.mrb_str_new(mrb, release.ptr, @intCast(release.len));
}

/// mruby binding: get_node_machine()
pub fn zig_get_node_machine(mrb: *mruby.mrb_state, _: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    const allocator = global_allocator orelse return mruby.mrb_nil_value();
    const machine = getMachine(allocator) catch return mruby.mrb_nil_value();
    defer allocator.free(machine);
    return mruby.mrb_str_new(mrb, machine.ptr, @intCast(machine.len));
}

/// mruby binding: get_node_cpu_arch()
pub fn zig_get_node_cpu_arch(mrb: *mruby.mrb_state, _: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    const arch = getCpuArch();
    return mruby.mrb_str_new(mrb, arch.ptr, @intCast(arch.len));
}

/// mruby binding: get_node_network_interfaces()
pub fn zig_get_node_network_interfaces(mrb: *mruby.mrb_state, _: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    const allocator = global_allocator orelse return mruby.mrb_nil_value();
    const interfaces = getNetworkInterfaces(allocator) catch return mruby.mrb_nil_value();
    defer {
        for (interfaces) |iface| {
            allocator.free(iface.name);
            allocator.free(iface.ip_address);
        }
        allocator.free(interfaces);
    }

    const interfaces_array = mruby.mrb_ary_new_capa(mrb, @intCast(interfaces.len));

    for (interfaces) |iface| {
        const iface_hash = mruby.mrb_hash_new(mrb);

        // Add interface name
        const name_key = mruby.mrb_str_new(mrb, "name", 4);
        const name_val = mruby.mrb_str_new(mrb, iface.name.ptr, @intCast(iface.name.len));
        mruby.mrb_hash_set(mrb, iface_hash, name_key, name_val);

        // Add IP address
        const ip_key = mruby.mrb_str_new(mrb, "ip_address", 10);
        const ip_val = mruby.mrb_str_new(mrb, iface.ip_address.ptr, @intCast(iface.ip_address.len));
        mruby.mrb_hash_set(mrb, iface_hash, ip_key, ip_val);

        // Add status flags
        addBoolToHash(mrb, iface_hash, "up", iface.is_up);
        addBoolToHash(mrb, iface_hash, "loopback", iface.is_loopback);
        addBoolToHash(mrb, iface_hash, "running", iface.is_running);
        addBoolToHash(mrb, iface_hash, "multicast", iface.is_multicast);

        mruby.mrb_ary_push(mrb, interfaces_array, iface_hash);
    }

    return interfaces_array;
}

/// mruby binding: get_node_default_gateway_ip()
pub fn zig_get_node_default_gateway_ip(mrb: *mruby.mrb_state, _: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    const allocator = global_allocator orelse return mruby.mrb_nil_value();
    const gateway = getDefaultGateway(allocator) catch return mruby.mrb_nil_value();
    if (gateway) |gw| {
        defer {
            allocator.free(gw.ip);
            allocator.free(gw.interface);
        }
        return mruby.mrb_str_new(mrb, gw.ip.ptr, @intCast(gw.ip.len));
    }
    return mruby.mrb_nil_value();
}

/// mruby binding: get_node_default_interface()
pub fn zig_get_node_default_interface(mrb: *mruby.mrb_state, _: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    const allocator = global_allocator orelse return mruby.mrb_nil_value();
    const gateway = getDefaultGateway(allocator) catch return mruby.mrb_nil_value();
    if (gateway) |gw| {
        defer {
            allocator.free(gw.ip);
            allocator.free(gw.interface);
        }
        return mruby.mrb_str_new(mrb, gw.interface.ptr, @intCast(gw.interface.len));
    }
    return mruby.mrb_nil_value();
}

/// mruby binding: get_node_lsb_info()
pub fn zig_get_node_lsb_info(mrb: *mruby.mrb_state, _: mruby.mrb_value) callconv(.c) mruby.mrb_value {
    const allocator = global_allocator orelse return mruby.mrb_nil_value();
    const lsb = getLsbInfo(allocator) catch return mruby.mrb_nil_value();
    if (lsb) |info| {
        defer {
            allocator.free(info.id);
            allocator.free(info.description);
            allocator.free(info.release);
            allocator.free(info.codename);
        }

        // Return a hash with LSB information
        const hash = mruby.mrb_hash_new(mrb);

        const id_key = mruby.mrb_str_new(mrb, "id", 2);
        const id_val = mruby.mrb_str_new(mrb, info.id.ptr, @intCast(info.id.len));
        mruby.mrb_hash_set(mrb, hash, id_key, id_val);

        const desc_key = mruby.mrb_str_new(mrb, "description", 11);
        const desc_val = mruby.mrb_str_new(mrb, info.description.ptr, @intCast(info.description.len));
        mruby.mrb_hash_set(mrb, hash, desc_key, desc_val);

        const release_key = mruby.mrb_str_new(mrb, "release", 7);
        const release_val = mruby.mrb_str_new(mrb, info.release.ptr, @intCast(info.release.len));
        mruby.mrb_hash_set(mrb, hash, release_key, release_val);

        const codename_key = mruby.mrb_str_new(mrb, "codename", 8);
        const codename_val = mruby.mrb_str_new(mrb, info.codename.ptr, @intCast(info.codename.len));
        mruby.mrb_hash_set(mrb, hash, codename_key, codename_val);

        return hash;
    }
    return mruby.mrb_nil_value();
}

// External helper functions from mruby_helpers.c
extern fn zig_mrb_true_value() mruby.mrb_value;
extern fn zig_mrb_false_value() mruby.mrb_value;

/// Helper function to add boolean values to mruby hash
fn addBoolToHash(mrb: *mruby.mrb_state, hash: mruby.mrb_value, key: []const u8, value: bool) void {
    const key_val = mruby.mrb_str_new(mrb, key.ptr, @intCast(key.len));
    const bool_val = if (value) zig_mrb_true_value() else zig_mrb_false_value();
    mruby.mrb_hash_set(mrb, hash, key_val, bool_val);
}

/// Get CPU information
pub fn getCpuInfo(allocator: std.mem.Allocator) !CPU {
    if (builtin.os.tag == .macos) {
        return getCpuInfoMacOS(allocator);
    } else if (builtin.os.tag == .linux) {
        return getCpuInfoLinux(allocator);
    }
    return CPU{ .architecture = getCpuArch() };
}

/// Get CPU information on macOS using sysctl
fn getCpuInfoMacOS(allocator: std.mem.Allocator) !CPU {
    var cpu = CPU{ .architecture = getCpuArch() };

    // Get CPU core count
    var core_count: c_int = 0;
    var core_count_size: usize = @sizeOf(c_int);
    var mib_cores = [_]c_int{ c.CTL_HW, c.HW_NCPU };
    if (c.sysctl(&mib_cores, 2, &core_count, &core_count_size, null, 0) == 0) {
        cpu.cores = @intCast(core_count);
        cpu.total = @intCast(core_count);
    }

    // Get physical CPU package count (number of physical CPUs/sockets)
    var package_count: c_int = 0;
    var package_count_size: usize = @sizeOf(c_int);
    const packages_name = "hw.packages";
    if (c.sysctlbyname(packages_name.ptr, &package_count, &package_count_size, null, 0) == 0) {
        cpu.real = @intCast(package_count);
    } else {
        cpu.real = 1; // Fallback to 1 physical CPU
    }

    // Get CPU model name
    var brand_buf: [256]u8 = undefined;
    var brand_size: usize = brand_buf.len;
    const brand_name = "machdep.cpu.brand_string";
    if (c.sysctlbyname(brand_name.ptr, &brand_buf, &brand_size, null, 0) == 0) {
        const brand_str = std.mem.sliceTo(&brand_buf, 0);
        cpu.model_name = try allocator.dupe(u8, brand_str);
    }

    return cpu;
}

/// Get CPU information on Linux by reading /proc/cpuinfo
fn getCpuInfoLinux(allocator: std.mem.Allocator) !CPU {
    var cpu = CPU{ .architecture = getCpuArch() };

    const file = std.fs.cwd().openFile("/proc/cpuinfo", .{}) catch return cpu;
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 65536);
    defer allocator.free(content);

    var processor_count: u32 = 0;
    var physical_ids = std.AutoHashMap(u32, void).init(allocator);
    defer physical_ids.deinit();
    var core_ids = std.AutoHashMap(u32, void).init(allocator);
    defer core_ids.deinit();
    var model_name: ?[]const u8 = null;
    var current_physical_id: ?u32 = null;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        if (std.mem.indexOf(u8, line, ":")) |colon_pos| {
            const key = std.mem.trim(u8, line[0..colon_pos], " \t");
            const value = std.mem.trim(u8, line[colon_pos + 1 ..], " \t");

            if (std.mem.eql(u8, key, "processor")) {
                processor_count += 1;
            } else if (std.mem.eql(u8, key, "physical id")) {
                const phys_id = std.fmt.parseInt(u32, value, 10) catch continue;
                current_physical_id = phys_id;
                try physical_ids.put(phys_id, {});
            } else if (std.mem.eql(u8, key, "core id")) {
                const core_id = std.fmt.parseInt(u32, value, 10) catch continue;
                try core_ids.put(core_id, {});
            } else if (std.mem.eql(u8, key, "model name") and model_name == null) {
                model_name = value;
            }
        }
    }

    cpu.total = processor_count;
    const physical_count = physical_ids.count();
    cpu.real = if (physical_count > 0) @intCast(physical_count) else 1;

    // Core count is cores per socket
    const cores_per_socket = core_ids.count();
    cpu.cores = if (cores_per_socket > 0) @intCast(cores_per_socket * cpu.real) else processor_count;

    if (model_name) |name| {
        cpu.model_name = try allocator.dupe(u8, name);
    }

    return cpu;
}

/// Get memory information
pub fn getMemoryInfo(allocator: std.mem.Allocator) !Memory {
    if (builtin.os.tag == .macos) {
        return getMemoryInfoMacOS(allocator);
    } else if (builtin.os.tag == .linux) {
        return getMemoryInfoLinux(allocator);
    }
    return Memory{};
}

/// Get memory information on macOS using sysctl and vm_stat
fn getMemoryInfoMacOS(allocator: std.mem.Allocator) !Memory {
    var memory = Memory{};

    // Get total memory
    var total_mem: u64 = 0;
    var total_mem_size: usize = @sizeOf(u64);
    var mib_mem = [_]c_int{ c.CTL_HW, c.HW_MEMSIZE };
    if (c.sysctl(&mib_mem, 2, &total_mem, &total_mem_size, null, 0) == 0) {
        const total_mb = total_mem / (1024 * 1024);
        memory.total = try std.fmt.allocPrint(allocator, "{d}MB", .{total_mb});
    }

    // Use vm_stat command to get memory statistics
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{"vm_stat"},
    }) catch return memory;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    var page_size: u64 = 4096; // Default page size
    var free_pages: u64 = 0;
    var active_pages: u64 = 0;
    var inactive_pages: u64 = 0;
    var wired_pages: u64 = 0;
    var compressed_pages: u64 = 0;

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "page size of ")) |start_pos| {
            const after_prefix = start_pos + "page size of ".len;
            if (std.mem.indexOf(u8, line[after_prefix..], " bytes")) |end_offset| {
                const end_pos = after_prefix + end_offset;
                const page_str = line[after_prefix..end_pos];
                page_size = std.fmt.parseInt(u64, page_str, 10) catch 4096;
            }
        } else if (std.mem.indexOf(u8, line, "Pages free:")) |_| {
            if (std.mem.indexOf(u8, line, ":")) |colon_pos| {
                const value_str = std.mem.trim(u8, line[colon_pos + 1 ..], " \t.");
                free_pages = std.fmt.parseInt(u64, value_str, 10) catch 0;
            }
        } else if (std.mem.indexOf(u8, line, "Pages active:")) |_| {
            if (std.mem.indexOf(u8, line, ":")) |colon_pos| {
                const value_str = std.mem.trim(u8, line[colon_pos + 1 ..], " \t.");
                active_pages = std.fmt.parseInt(u64, value_str, 10) catch 0;
            }
        } else if (std.mem.indexOf(u8, line, "Pages inactive:")) |_| {
            if (std.mem.indexOf(u8, line, ":")) |colon_pos| {
                const value_str = std.mem.trim(u8, line[colon_pos + 1 ..], " \t.");
                inactive_pages = std.fmt.parseInt(u64, value_str, 10) catch 0;
            }
        } else if (std.mem.indexOf(u8, line, "Pages wired down:")) |_| {
            if (std.mem.indexOf(u8, line, ":")) |colon_pos| {
                const value_str = std.mem.trim(u8, line[colon_pos + 1 ..], " \t.");
                wired_pages = std.fmt.parseInt(u64, value_str, 10) catch 0;
            }
        } else if (std.mem.indexOf(u8, line, "Pages occupied by compressor:")) |_| {
            if (std.mem.indexOf(u8, line, ":")) |colon_pos| {
                const value_str = std.mem.trim(u8, line[colon_pos + 1 ..], " \t.");
                compressed_pages = std.fmt.parseInt(u64, value_str, 10) catch 0;
            }
        }
    }

    const active_mb = (active_pages * page_size) / (1024 * 1024);
    memory.active = try std.fmt.allocPrint(allocator, "{d}MB", .{active_mb});

    const inactive_mb = (inactive_pages * page_size) / (1024 * 1024);
    memory.inactive = try std.fmt.allocPrint(allocator, "{d}MB", .{inactive_mb});

    const wired_mb = (wired_pages * page_size) / (1024 * 1024);
    memory.wired = try std.fmt.allocPrint(allocator, "{d}MB", .{wired_mb});

    const compressed_mb = (compressed_pages * page_size) / (1024 * 1024);
    memory.compressed = try std.fmt.allocPrint(allocator, "{d}MB", .{compressed_mb});

    // Parse total memory to calculate free like Chef Ohai does
    // Free = Total - Active - Inactive
    const total_str = memory.total;
    if (std.mem.indexOf(u8, total_str, "MB")) |mb_pos| {
        const total_mb = std.fmt.parseInt(u64, total_str[0..mb_pos], 10) catch 0;
        const calculated_free = total_mb - active_mb - inactive_mb;
        memory.free = try std.fmt.allocPrint(allocator, "{d}MB", .{calculated_free});
    } else {
        // Fallback to actual free pages if total parsing fails
        const free_mb = (free_pages * page_size) / (1024 * 1024);
        memory.free = try std.fmt.allocPrint(allocator, "{d}MB", .{free_mb});
    }

    return memory;
}

/// Helper function to convert kB to MB string
fn convertKBtoMB(allocator: std.mem.Allocator, value_str: []const u8) ![]const u8 {
    // Parse the number from "12345 kB" format
    var parts = std.mem.splitScalar(u8, value_str, ' ');
    const kb_str = parts.next() orelse return allocator.dupe(u8, "0MB");
    const kb_value = std.fmt.parseInt(u64, kb_str, 10) catch return allocator.dupe(u8, "0MB");
    const mb_value = kb_value / 1024;
    return std.fmt.allocPrint(allocator, "{d}MB", .{mb_value});
}

/// Get memory information on Linux by reading /proc/meminfo
fn getMemoryInfoLinux(allocator: std.mem.Allocator) !Memory {
    var memory = Memory{};

    const file = std.fs.cwd().openFile("/proc/meminfo", .{}) catch return memory;
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 8192);
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        if (std.mem.indexOf(u8, line, ":")) |colon_pos| {
            const key = std.mem.trim(u8, line[0..colon_pos], " \t");
            const value_part = std.mem.trim(u8, line[colon_pos + 1 ..], " \t");

            if (std.mem.eql(u8, key, "MemTotal")) {
                memory.total = try convertKBtoMB(allocator, value_part);
            } else if (std.mem.eql(u8, key, "MemFree")) {
                memory.free = try convertKBtoMB(allocator, value_part);
            } else if (std.mem.eql(u8, key, "MemAvailable")) {
                memory.available = try convertKBtoMB(allocator, value_part);
            } else if (std.mem.eql(u8, key, "Active")) {
                memory.active = try convertKBtoMB(allocator, value_part);
            } else if (std.mem.eql(u8, key, "Inactive")) {
                memory.inactive = try convertKBtoMB(allocator, value_part);
            } else if (std.mem.eql(u8, key, "Buffers")) {
                memory.buffers = try convertKBtoMB(allocator, value_part);
            } else if (std.mem.eql(u8, key, "Cached")) {
                memory.cached = try convertKBtoMB(allocator, value_part);
            } else if (std.mem.eql(u8, key, "SwapTotal")) {
                memory.swap_total = try convertKBtoMB(allocator, value_part);
            } else if (std.mem.eql(u8, key, "SwapFree")) {
                memory.swap_free = try convertKBtoMB(allocator, value_part);
            }
        }
    }

    return memory;
}

/// Ruby prelude for node object
pub const ruby_prelude = @embedFile("ruby_prelude/node_info.rb");

// MRuby module registration interface
const mruby_module = @import("mruby_module.zig");

const node_info_functions = [_]mruby_module.ModuleFunction{
    .{ .name = "get_node_hostname", .func = zig_get_node_hostname, .args = mruby.MRB_ARGS_NONE() },
    .{ .name = "get_node_fqdn", .func = zig_get_node_fqdn, .args = mruby.MRB_ARGS_NONE() },
    .{ .name = "get_node_platform", .func = zig_get_node_platform, .args = mruby.MRB_ARGS_NONE() },
    .{ .name = "get_node_platform_family", .func = zig_get_node_platform_family, .args = mruby.MRB_ARGS_NONE() },
    .{ .name = "get_node_platform_version", .func = zig_get_node_platform_version, .args = mruby.MRB_ARGS_NONE() },
    .{ .name = "get_node_os", .func = zig_get_node_os, .args = mruby.MRB_ARGS_NONE() },
    .{ .name = "get_node_kernel_name", .func = zig_get_node_kernel_name, .args = mruby.MRB_ARGS_NONE() },
    .{ .name = "get_node_kernel_release", .func = zig_get_node_kernel_release, .args = mruby.MRB_ARGS_NONE() },
    .{ .name = "get_node_machine", .func = zig_get_node_machine, .args = mruby.MRB_ARGS_NONE() },
    .{ .name = "get_node_cpu_arch", .func = zig_get_node_cpu_arch, .args = mruby.MRB_ARGS_NONE() },
    .{ .name = "get_node_network_interfaces", .func = zig_get_node_network_interfaces, .args = mruby.MRB_ARGS_NONE() },
    .{ .name = "get_node_default_gateway_ip", .func = zig_get_node_default_gateway_ip, .args = mruby.MRB_ARGS_NONE() },
    .{ .name = "get_node_default_interface", .func = zig_get_node_default_interface, .args = mruby.MRB_ARGS_NONE() },
    .{ .name = "get_node_lsb_info", .func = zig_get_node_lsb_info, .args = mruby.MRB_ARGS_NONE() },
};

fn getFunctions() []const mruby_module.ModuleFunction {
    return &node_info_functions;
}

fn getPrelude() []const u8 {
    return ruby_prelude;
}

pub const mruby_module_def = mruby_module.MRubyModule{
    .name = "Node",
    .initFn = setAllocator,
    .getFunctions = getFunctions,
    .getPrelude = getPrelude,
};
