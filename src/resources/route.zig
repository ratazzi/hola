const std = @import("std");
const mruby = @import("../mruby.zig");
const base = @import("../base_resource.zig");
const logger = @import("../logger.zig");
const builtin = @import("builtin");

pub const Resource = struct {
    target: []const u8,
    gateway: ?[]const u8,
    netmask: ?[]const u8,
    device: ?[]const u8,
    action: Action,
    common: base.CommonProps,

    pub const Action = enum {
        add,
        delete,
    };

    pub fn deinit(self: Resource, allocator: std.mem.Allocator) void {
        allocator.free(self.target);
        if (self.gateway) |g| allocator.free(g);
        if (self.netmask) |n| allocator.free(n);
        if (self.device) |d| allocator.free(d);

        var common = self.common;
        common.deinit(allocator);
    }

    pub fn apply(self: Resource) !base.ApplyResult {
        const skip_reason = try self.common.shouldRun();
        if (skip_reason) |reason| {
            return base.ApplyResult{
                .was_updated = false,
                .action = @tagName(self.action),
                .skip_reason = reason,
            };
        }

        if (builtin.os.tag == .macos) {
            return macos_impl.apply(self);
        } else if (builtin.os.tag == .linux) {
            return linux_impl.apply(self);
        } else {
            return base.ApplyResult{
                .was_updated = false,
                .action = @tagName(self.action),
                .skip_reason = "unsupported platform",
            };
        }
    }
};

// Helper to parse IPv4 string to u32 (host byte order)
// Automatically strips CIDR suffix if present
fn parseIp(ip: []const u8) !u32 {
    const clean_ip = if (std.mem.indexOf(u8, ip, "/")) |idx| ip[0..idx] else ip;
    const parsed = try std.net.Address.parseIp4(clean_ip, 0);
    return parsed.in.sa.addr; // This is network byte order
}

// Helper to parse CIDR or Netmask
fn parseNetmask(cidr_or_mask: []const u8) !u32 {
    if (std.mem.indexOf(u8, cidr_or_mask, ".") != null) {
        return parseIp(cidr_or_mask);
    } else {
        const prefix = try std.fmt.parseInt(u8, cidr_or_mask, 10);
        if (prefix == 0) return 0;
        if (prefix > 32) return error.InvalidPrefix;
        const shift = 32 - prefix;
        const host_mask = ~(@as(u32, 0)) << @as(u5, @intCast(shift));
        return std.mem.nativeToBig(u32, host_mask);
    }
}

const macos_impl = if (builtin.os.tag == .macos) struct {
    const c = @cImport({
        @cInclude("sys/socket.h");
        @cInclude("netinet/in.h");
        @cInclude("net/if.h");
        @cInclude("net/route.h");
        @cInclude("sys/sysctl.h");
        @cInclude("arpa/inet.h");
        @cInclude("unistd.h");
        @cInclude("sys/errno.h");
    });

    // Helper to align up to next 4-byte boundary
    fn alignUp(val: usize) usize {
        return (val + 3) & ~@as(usize, 3);
    }

    fn writeSockaddrIn(buf: []u8, offset: usize, addr: u32) usize {
        const sa_len = @sizeOf(c.struct_sockaddr_in);
        if (offset + sa_len > buf.len) return 0;

        var sa = @as(*c.struct_sockaddr_in, @ptrCast(@alignCast(&buf[offset])));
        // Reset memory
        @memset(buf[offset .. offset + sa_len], 0);

        sa.sin_len = @intCast(sa_len);
        sa.sin_family = c.AF_INET;
        sa.sin_addr.s_addr = addr;

        return alignUp(sa_len);
    }

    pub fn apply(self: Resource) !base.ApplyResult {
        const action_name = @tagName(self.action);
        switch (self.action) {
            .add => {
                const updated = try applyAdd(self);
                return base.ApplyResult{
                    .was_updated = updated,
                    .action = action_name,
                    .skip_reason = if (!updated) "up to date" else null,
                };
            },
            .delete => {
                const updated = try applyDelete(self);
                return base.ApplyResult{
                    .was_updated = updated,
                    .action = action_name,
                    .skip_reason = if (!updated) "up to date" else null,
                };
            },
        }
    }

    fn applyAdd(self: Resource) !bool {
        const sockfd = c.socket(c.PF_ROUTE, c.SOCK_RAW, 0);
        if (sockfd < 0) return error.SocketFailed;
        defer _ = c.close(sockfd);

        var buf: [1024]u8 = undefined;
        @memset(&buf, 0);

        var rtm = @as(*c.struct_rt_msghdr, @ptrCast(@alignCast(&buf[0])));
        var ptr: usize = @sizeOf(c.struct_rt_msghdr); // No alignment needed for header usually

        rtm.rtm_version = c.RTM_VERSION;
        rtm.rtm_type = c.RTM_ADD;
        rtm.rtm_flags = c.RTF_UP | c.RTF_STATIC;
        rtm.rtm_seq = 1;
        rtm.rtm_pid = std.c.getpid();
        rtm.rtm_addrs = c.RTA_DST;

        // Parse target IP
        const dst_ip = try parseIp(self.target);
        ptr += writeSockaddrIn(&buf, ptr, dst_ip);

        // Add Gateway if present
        if (self.gateway) |gw| {
            const gw_ip = try parseIp(gw);
            rtm.rtm_flags |= c.RTF_GATEWAY;
            rtm.rtm_addrs |= c.RTA_GATEWAY;
            ptr += writeSockaddrIn(&buf, ptr, gw_ip);
        }

        // Determine Netmask
        var mask_val: u32 = 0xFFFFFFFF; // Default to /32
        var has_mask = false;

        if (self.netmask) |nm| {
            mask_val = try parseNetmask(nm);
            has_mask = true;
        } else if (std.mem.indexOf(u8, self.target, "/")) |idx| {
            const cidr = self.target[idx + 1 ..];
            mask_val = try parseNetmask(cidr);
            has_mask = true;
        }

        // If mask is host mask (all ones), we can use RTF_HOST and skip RTA_NETMASK
        // But if explicit mask is provided (even /32), passing it explicitly is safer for specificity.
        // However, traditionally RTF_HOST implies /32.
        // Let's use RTA_NETMASK if it's NOT /32.

        if (mask_val == 0xFFFFFFFF) {
            rtm.rtm_flags |= c.RTF_HOST;
            // Don't add netmask sockaddr for host route on macOS usually
        } else {
            rtm.rtm_addrs |= c.RTA_NETMASK;
            ptr += writeSockaddrIn(&buf, ptr, mask_val);
        }

        rtm.rtm_msglen = @intCast(ptr);

        const written = c.write(sockfd, &buf, ptr);
        if (written < 0) {
            // On macOS, we need to check the global errno.
            // std.c._errno() returns a pointer to the thread-local errno.
            const err_val = std.c._errno().*;

            if (err_val == c.EEXIST) {
                return false; // Already exists
            }

            // Log detailed error information
            logger.err("Route add failed for {s}: errno={d}", .{ self.target, err_val });

            if (err_val == c.EACCES or err_val == c.EPERM) {
                logger.err("Permission denied. Root/sudo access required to modify routing table.", .{});
            } else if (err_val == c.EINVAL) {
                logger.err("Invalid argument. Check target={s}, gateway={s}, netmask={s}", .{
                    self.target,
                    self.gateway orelse "none",
                    self.netmask orelse "none",
                });
            }

            return error.RouteAddFailed;
        }

        return true;
    }

    fn applyDelete(self: Resource) !bool {
        const sockfd = c.socket(c.PF_ROUTE, c.SOCK_RAW, 0);
        if (sockfd < 0) return error.SocketFailed;
        defer _ = c.close(sockfd);

        var buf: [1024]u8 = undefined;
        @memset(&buf, 0);

        var rtm = @as(*c.struct_rt_msghdr, @ptrCast(@alignCast(&buf[0])));
        var ptr: usize = @sizeOf(c.struct_rt_msghdr);

        rtm.rtm_version = c.RTM_VERSION;
        rtm.rtm_type = c.RTM_DELETE;
        rtm.rtm_seq = 1;
        rtm.rtm_pid = std.c.getpid();
        rtm.rtm_addrs = c.RTA_DST;

        const dst_ip = try parseIp(self.target);
        ptr += writeSockaddrIn(&buf, ptr, dst_ip);

        // For delete, we might need gateway to match exactly if multiple routes exist?
        // Usually just DST + MASK is enough to delete.

        if (self.gateway) |gw| {
            // If user specifies gateway, they probably want to delete THAT route
            const gw_ip = try parseIp(gw);
            rtm.rtm_addrs |= c.RTA_GATEWAY;
            ptr += writeSockaddrIn(&buf, ptr, gw_ip);
        }

        var mask_val: u32 = 0xFFFFFFFF;
        if (self.netmask) |nm| {
            mask_val = try parseNetmask(nm);
        } else if (std.mem.indexOf(u8, self.target, "/")) |idx| {
            const cidr = self.target[idx + 1 ..];
            mask_val = try parseNetmask(cidr);
        }

        if (mask_val == 0xFFFFFFFF) {
            // Host route delete
            // Don't set RTA_NETMASK
        } else {
            rtm.rtm_addrs |= c.RTA_NETMASK;
            ptr += writeSockaddrIn(&buf, ptr, mask_val);
        }

        rtm.rtm_msglen = @intCast(ptr);

        const written = c.write(sockfd, &buf, ptr);
        if (written < 0) {
            const err = std.posix.errno(0);
            if (err == .SRCH) {
                return false; // Not found
            }

            // Log detailed error information
            logger.err("Route delete failed for {s}: errno={d} ({s})", .{
                self.target,
                @intFromEnum(err),
                @tagName(err),
            });

            if (err == .ACCES or err == .PERM) {
                logger.err("Permission denied. Root/sudo access required to modify routing table.", .{});
            } else if (err == .INVAL) {
                logger.err("Invalid argument. Check target={s}, gateway={s}, netmask={s}", .{
                    self.target,
                    self.gateway orelse "none",
                    self.netmask orelse "none",
                });
            }

            return error.RouteDeleteFailed;
        }

        return true;
    }
} else struct {
    pub fn apply(_: Resource) !base.ApplyResult {
        unreachable;
    }
};

const linux_impl = if (builtin.os.tag == .linux) struct {
    const c = @cImport({
        @cInclude("sys/socket.h");
        @cInclude("netinet/in.h");
        @cInclude("net/if.h");
        @cInclude("net/route.h");
        @cInclude("sys/ioctl.h");
        @cInclude("arpa/inet.h");
        @cInclude("unistd.h");
    });

    pub fn apply(self: Resource) !base.ApplyResult {
        const action_name = @tagName(self.action);
        switch (self.action) {
            .add => {
                const updated = try applyAdd(self);
                return base.ApplyResult{
                    .was_updated = updated,
                    .action = action_name,
                    .skip_reason = if (!updated) "up to date" else null,
                };
            },
            .delete => {
                const updated = try applyDelete(self);
                return base.ApplyResult{
                    .was_updated = updated,
                    .action = action_name,
                    .skip_reason = if (!updated) "up to date" else null,
                };
            },
        }
    }

    fn applyAdd(self: Resource) !bool {
        const sockfd = c.socket(c.AF_INET, c.SOCK_DGRAM, 0);
        if (sockfd < 0) return error.SocketFailed;
        defer _ = c.close(sockfd);

        var rt: c.struct_rtentry = undefined;
        @memset(@as([*]u8, @ptrCast(&rt))[0..@sizeOf(c.struct_rtentry)], 0);

        var dst_sin = @as(*c.struct_sockaddr_in, @ptrCast(&rt.rt_dst));
        dst_sin.sin_family = c.AF_INET;
        dst_sin.sin_addr.s_addr = try parseIp(self.target);

        if (self.gateway) |gw| {
            var gw_sin = @as(*c.struct_sockaddr_in, @ptrCast(&rt.rt_gateway));
            gw_sin.sin_family = c.AF_INET;
            gw_sin.sin_addr.s_addr = try parseIp(gw);
            rt.rt_flags |= c.RTF_GATEWAY;
        }

        if (self.netmask) |nm| {
            var mask_sin = @as(*c.struct_sockaddr_in, @ptrCast(&rt.rt_genmask));
            mask_sin.sin_family = c.AF_INET;
            mask_sin.sin_addr.s_addr = try parseNetmask(nm);
        } else if (std.mem.indexOf(u8, self.target, "/")) |idx| {
            const cidr = self.target[idx + 1 ..];
            var mask_sin = @as(*c.struct_sockaddr_in, @ptrCast(&rt.rt_genmask));
            mask_sin.sin_family = c.AF_INET;
            mask_sin.sin_addr.s_addr = try parseNetmask(cidr);
        } else {
            var mask_sin = @as(*c.struct_sockaddr_in, @ptrCast(&rt.rt_genmask));
            mask_sin.sin_family = c.AF_INET;
            mask_sin.sin_addr.s_addr = 0xFFFFFFFF;
        }

        rt.rt_flags |= c.RTF_UP;

        if (c.ioctl(sockfd, c.SIOCADDRT, &rt) < 0) {
            const err = std.posix.errno(-1);
            if (err == .EXIST) {
                return false; // Route already exists
            }

            // Log detailed error information
            logger.err("Route add failed for {s}: errno={d} ({s})", .{
                self.target,
                @intFromEnum(err),
                @tagName(err),
            });

            if (err == .ACCES or err == .PERM) {
                logger.err("Permission denied. Root/sudo access required to modify routing table.", .{});
            } else if (err == .INVAL) {
                logger.err("Invalid argument. Check target={s}, gateway={s}, netmask={s}, device={s}", .{
                    self.target,
                    self.gateway orelse "none",
                    self.netmask orelse "none",
                    self.device orelse "none",
                });
            } else if (err == .NETUNREACH) {
                logger.err("Network is unreachable. Gateway or device may be invalid.", .{});
            }

            return error.RouteAddFailed;
        }

        return true;
    }

    fn applyDelete(self: Resource) !bool {
        const sockfd = c.socket(c.AF_INET, c.SOCK_DGRAM, 0);
        if (sockfd < 0) return error.SocketFailed;
        defer _ = c.close(sockfd);

        var rt: c.struct_rtentry = undefined;
        @memset(@as([*]u8, @ptrCast(&rt))[0..@sizeOf(c.struct_rtentry)], 0);

        var dst_sin = @as(*c.struct_sockaddr_in, @ptrCast(&rt.rt_dst));
        dst_sin.sin_family = c.AF_INET;
        dst_sin.sin_addr.s_addr = try parseIp(self.target);

        // Need correct netmask to match for delete
        if (self.netmask) |nm| {
            var mask_sin = @as(*c.struct_sockaddr_in, @ptrCast(&rt.rt_genmask));
            mask_sin.sin_family = c.AF_INET;
            mask_sin.sin_addr.s_addr = try parseNetmask(nm);
        } else if (std.mem.indexOf(u8, self.target, "/")) |idx| {
            const cidr = self.target[idx + 1 ..];
            var mask_sin = @as(*c.struct_sockaddr_in, @ptrCast(&rt.rt_genmask));
            mask_sin.sin_family = c.AF_INET;
            mask_sin.sin_addr.s_addr = try parseNetmask(cidr);
        } else {
            var mask_sin = @as(*c.struct_sockaddr_in, @ptrCast(&rt.rt_genmask));
            mask_sin.sin_family = c.AF_INET;
            mask_sin.sin_addr.s_addr = 0xFFFFFFFF;
        }

        if (c.ioctl(sockfd, c.SIOCDELRT, &rt) < 0) {
            const err = std.posix.errno(-1);
            if (err == .SRCH) {
                return false; // Route not found
            }

            // Log detailed error information
            logger.err("Route delete failed for {s}: errno={d} ({s})", .{
                self.target,
                @intFromEnum(err),
                @tagName(err),
            });

            if (err == .ACCES or err == .PERM) {
                logger.err("Permission denied. Root/sudo access required to modify routing table.", .{});
            } else if (err == .INVAL) {
                logger.err("Invalid argument. Check target={s}, netmask={s}", .{
                    self.target,
                    self.netmask orelse "none",
                });
            }

            return error.RouteDeleteFailed;
        }

        return true;
    }
} else struct {
    pub fn apply(_: Resource) !base.ApplyResult {
        unreachable;
    }
};

/// Ruby prelude
pub const ruby_prelude = @embedFile("route_resource.rb");

/// Zig callback
pub fn zigAddResource(
    mrb: *mruby.mrb_state,
    _: mruby.mrb_value,
    resources: *std.ArrayList(Resource),
    allocator: std.mem.Allocator,
) mruby.mrb_value {
    var target_val: mruby.mrb_value = undefined;
    var gateway_val: mruby.mrb_value = undefined;
    var netmask_val: mruby.mrb_value = undefined;
    var device_val: mruby.mrb_value = undefined;
    var action_val: mruby.mrb_value = undefined;
    var only_if_val: mruby.mrb_value = undefined;
    var not_if_val: mruby.mrb_value = undefined;
    var ignore_failure_val: mruby.mrb_value = undefined;
    var notifications_val: mruby.mrb_value = undefined;
    var subscriptions_val: mruby.mrb_value = undefined;

    // add_route(target, gateway, netmask, device, action, only_if, not_if, ignore_failure, notifications, subscriptions)
    _ = mruby.mrb_get_args(mrb, "SSSSS|oooAA", &target_val, &gateway_val, &netmask_val, &device_val, &action_val, &only_if_val, &not_if_val, &ignore_failure_val, &notifications_val, &subscriptions_val);

    const target_cstr = mruby.mrb_str_to_cstr(mrb, target_val);
    const target = allocator.dupe(u8, std.mem.span(target_cstr)) catch return mruby.mrb_nil_value();

    const gateway_cstr = mruby.mrb_str_to_cstr(mrb, gateway_val);
    const gateway_str = std.mem.span(gateway_cstr);
    const gateway: ?[]const u8 = if (gateway_str.len > 0) allocator.dupe(u8, gateway_str) catch return mruby.mrb_nil_value() else null;

    const netmask_cstr = mruby.mrb_str_to_cstr(mrb, netmask_val);
    const netmask_str = std.mem.span(netmask_cstr);
    const netmask: ?[]const u8 = if (netmask_str.len > 0) allocator.dupe(u8, netmask_str) catch return mruby.mrb_nil_value() else null;

    const device_cstr = mruby.mrb_str_to_cstr(mrb, device_val);
    const device_str = std.mem.span(device_cstr);
    const device: ?[]const u8 = if (device_str.len > 0) allocator.dupe(u8, device_str) catch return mruby.mrb_nil_value() else null;

    const action_cstr = mruby.mrb_str_to_cstr(mrb, action_val);
    const action_str = std.mem.span(action_cstr);
    const action: Resource.Action = if (std.mem.eql(u8, action_str, "delete")) .delete else .add;

    var common = base.CommonProps.init(allocator);
    base.fillCommonFromRuby(&common, mrb, only_if_val, not_if_val, ignore_failure_val, notifications_val, subscriptions_val, allocator);

    resources.append(allocator, .{
        .target = target,
        .gateway = gateway,
        .netmask = netmask,
        .device = device,
        .action = action,
        .common = common,
    }) catch return mruby.mrb_nil_value();

    return mruby.mrb_nil_value();
}
