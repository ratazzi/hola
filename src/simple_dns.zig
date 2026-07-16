const std = @import("std");
const logger = @import("logger.zig");
const global_io = @import("global_io.zig");

/// Simple DNS query implementation for A and AAAA records
/// This is a minimal implementation to support custom DNS servers
pub const QueryType = enum(u16) {
    A = 1, // IPv4 address
    AAAA = 28, // IPv6 address
};

/// DNS query result
pub const DNSResult = struct {
    addresses: [][]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *DNSResult) void {
        for (self.addresses) |addr| {
            self.allocator.free(addr);
        }
        self.allocator.free(self.addresses);
    }
};

/// Perform DNS query to a specific nameserver
pub fn query(
    allocator: std.mem.Allocator,
    nameserver: []const u8,
    hostname: []const u8,
    qtype: QueryType,
) !DNSResult {
    // First, resolve the nameserver address if it's a hostname
    const ns_addr = resolveNameserver(allocator, nameserver) catch |err| {
        logger.warn("Failed to resolve nameserver {s}: {}", .{ nameserver, err });
        return err;
    };
    defer allocator.free(ns_addr);

    // Create UDP socket (raw libc; zig 0.16 removed std.posix socket wrappers)
    const sock = std.c.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP);
    if (sock < 0) return error.SocketFailed;
    defer _ = std.c.close(sock);

    // Parse nameserver address
    const ns_ip = std.Io.net.IpAddress.parseIp4(ns_addr, 53) catch {
        return error.InvalidNameserver;
    };

    // Build DNS query packet
    var query_buf: [512]u8 = undefined;
    const query_len = try buildDNSQuery(&query_buf, hostname, qtype);

    // Send query
    var sa_storage: std.Io.Threaded.PosixAddress = undefined;
    const sa_len = std.Io.Threaded.addressToPosix(&ns_ip, &sa_storage);
    const sent = std.c.sendto(sock, &query_buf, query_len, 0, &sa_storage.any, sa_len);
    if (sent < 0 or @as(usize, @intCast(sent)) != query_len) {
        return error.SendFailed;
    }

    // Receive response with timeout
    var response_buf: [512]u8 = undefined;

    // Set receive timeout
    const timeout = std.posix.timeval{
        .sec = 5,
        .usec = 0,
    };
    try std.posix.setsockopt(
        sock,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        &std.mem.toBytes(timeout),
    );

    const recv_result = std.c.recv(sock, &response_buf, response_buf.len, 0);
    if (recv_result < 0) return error.RecvFailed;
    const recv_len: usize = @intCast(recv_result);

    // Parse DNS response
    return try parseDNSResponse(allocator, response_buf[0..recv_len], qtype);
}

/// Resolve nameserver hostname to IP address
fn resolveNameserver(allocator: std.mem.Allocator, nameserver: []const u8) ![]const u8 {
    // Check if it's already an IP address
    if (std.Io.net.IpAddress.parseIp4(nameserver, 0)) |_| {
        return try allocator.dupe(u8, nameserver);
    } else |_| {}

    // It's a hostname, resolve it using system resolver
    var addrs: [max_lookup_results]std.Io.net.IpAddress = undefined;
    const count = lookupHost(nameserver, &addrs) catch return error.NoIPv4Address;

    for (addrs[0..count]) |addr| {
        if (addr == .ip4) {
            const b = addr.ip4.bytes;
            return try std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{ b[0], b[1], b[2], b[3] });
        }
    }

    return error.NoIPv4Address;
}

pub const max_lookup_results = 16;

/// Resolve a hostname with the system resolver, writing up to `out.len`
/// addresses. Returns the number of addresses written. Replaces the removed
/// `std.net.getAddressList`.
pub fn lookupHost(hostname: []const u8, out: []std.Io.net.IpAddress) !usize {
    const io = global_io.io();
    const host = std.Io.net.HostName.init(hostname) catch return error.UnknownHostName;
    var queue_buf: [16]std.Io.net.HostName.LookupResult = undefined;
    var queue: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&queue_buf);
    try host.lookup(io, &queue, .{ .port = 0 });
    var n: usize = 0;
    while (n < out.len) {
        const res = queue.getOne(io) catch break;
        switch (res) {
            .address => |a| {
                out[n] = a;
                n += 1;
            },
            .canonical_name => {},
        }
    }
    return n;
}

/// Build DNS query packet
fn buildDNSQuery(buf: []u8, hostname: []const u8, qtype: QueryType) !usize {
    var pos: usize = 0;

    // DNS Header (12 bytes)
    // Transaction ID
    buf[pos] = 0x12;
    buf[pos + 1] = 0x34;
    pos += 2;

    // Flags: Standard query with recursion desired
    buf[pos] = 0x01;
    buf[pos + 1] = 0x00;
    pos += 2;

    // Question count: 1
    buf[pos] = 0x00;
    buf[pos + 1] = 0x01;
    pos += 2;

    // Answer, Authority, Additional: 0
    for (0..6) |_| {
        buf[pos] = 0x00;
        pos += 1;
    }

    // Question section
    // Encode domain name
    var it = std.mem.splitScalar(u8, hostname, '.');
    while (it.next()) |label| {
        if (label.len > 63) return error.LabelTooLong;
        buf[pos] = @intCast(label.len);
        pos += 1;
        @memcpy(buf[pos .. pos + label.len], label);
        pos += label.len;
    }
    buf[pos] = 0; // End of domain name
    pos += 1;

    // Query type
    const qtype_val: u16 = @intFromEnum(qtype);
    buf[pos] = @intCast(qtype_val >> 8);
    buf[pos + 1] = @intCast(qtype_val & 0xFF);
    pos += 2;

    // Query class: IN (Internet)
    buf[pos] = 0x00;
    buf[pos + 1] = 0x01;
    pos += 2;

    return pos;
}

/// Parse DNS response
fn parseDNSResponse(allocator: std.mem.Allocator, response: []const u8, qtype: QueryType) !DNSResult {
    if (response.len < 12) return error.InvalidResponse;

    // Check response code
    const flags = (@as(u16, response[2]) << 8) | response[3];
    const rcode = flags & 0x0F;
    if (rcode != 0) return error.DNSError;

    // Get answer count
    const answer_count = (@as(u16, response[6]) << 8) | response[7];
    if (answer_count == 0) return DNSResult{
        .addresses = &.{},
        .allocator = allocator,
    };

    var addresses = std.ArrayList([]const u8).empty;
    errdefer {
        for (addresses.items) |addr| {
            allocator.free(addr);
        }
        addresses.deinit(allocator);
    }

    // Skip question section
    var pos: usize = 12;
    while (pos < response.len and response[pos] != 0) {
        const len = response[pos];
        if (len > 63) {
            // Compression pointer
            pos += 2;
            break;
        }
        pos += 1 + len;
    }
    if (pos < response.len and response[pos] == 0) pos += 1;
    pos += 4; // Skip qtype and qclass

    // Parse answers
    var i: usize = 0;
    while (i < answer_count and pos + 12 <= response.len) : (i += 1) {
        // Skip name (usually compressed)
        if (response[pos] >= 0xC0) {
            pos += 2;
        } else {
            while (pos < response.len and response[pos] != 0) {
                pos += 1 + response[pos];
            }
            pos += 1;
        }

        if (pos + 10 > response.len) break;

        const rtype = (@as(u16, response[pos]) << 8) | response[pos + 1];
        pos += 8; // Skip type, class, TTL

        const rdlen = (@as(u16, response[pos]) << 8) | response[pos + 1];
        pos += 2;

        if (pos + rdlen > response.len) break;

        // Extract address based on type
        if (rtype == @intFromEnum(QueryType.A) and qtype == .A) {
            // IPv4 address
            if (rdlen == 4) {
                const addr = try std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{
                    response[pos],
                    response[pos + 1],
                    response[pos + 2],
                    response[pos + 3],
                });
                try addresses.append(allocator, addr);
            }
        } else if (rtype == @intFromEnum(QueryType.AAAA) and qtype == .AAAA) {
            // IPv6 address
            if (rdlen == 16) {
                var parts: [8]u16 = undefined;
                for (0..8) |j| {
                    parts[j] = (@as(u16, response[pos + j * 2]) << 8) | response[pos + j * 2 + 1];
                }
                const addr = try std.fmt.allocPrint(allocator, "{x}:{x}:{x}:{x}:{x}:{x}:{x}:{x}", .{
                    parts[0], parts[1], parts[2], parts[3],
                    parts[4], parts[5], parts[6], parts[7],
                });
                try addresses.append(allocator, addr);
            }
        }

        pos += rdlen;
    }

    return DNSResult{
        .addresses = try addresses.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}
