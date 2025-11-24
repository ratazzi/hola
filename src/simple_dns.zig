const std = @import("std");

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
        std.log.warn("Failed to resolve nameserver {s}: {}", .{ nameserver, err });
        return err;
    };
    defer allocator.free(ns_addr);

    // Create UDP socket
    const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP);
    defer std.posix.close(sock);

    // Parse nameserver address
    const ns_ip = std.net.Address.parseIp4(ns_addr, 53) catch {
        return error.InvalidNameserver;
    };

    // Build DNS query packet
    var query_buf: [512]u8 = undefined;
    const query_len = try buildDNSQuery(&query_buf, hostname, qtype);

    // Send query
    const sent = try std.posix.sendto(sock, query_buf[0..query_len], 0, &ns_ip.any, ns_ip.getOsSockLen());
    if (sent != query_len) {
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

    const recv_len = try std.posix.recv(sock, &response_buf, 0);

    // Parse DNS response
    return try parseDNSResponse(allocator, response_buf[0..recv_len], qtype);
}

/// Resolve nameserver hostname to IP address
fn resolveNameserver(allocator: std.mem.Allocator, nameserver: []const u8) ![]const u8 {
    // Check if it's already an IP address
    if (std.net.Address.parseIp4(nameserver, 0)) |_| {
        return try allocator.dupe(u8, nameserver);
    } else |_| {}

    // It's a hostname, resolve it using system resolver
    const addr_list = try std.net.getAddressList(allocator, nameserver, 0);
    defer addr_list.deinit();

    for (addr_list.addrs) |addr| {
        if (addr.any.family == std.posix.AF.INET) {
            // Format IPv4 address
            const addr_bytes = @as(*const [4]u8, @ptrCast(&addr.in.sa.addr));
            return try std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{
                addr_bytes[0],
                addr_bytes[1],
                addr_bytes[2],
                addr_bytes[3],
            });
        }
    }

    return error.NoIPv4Address;
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
