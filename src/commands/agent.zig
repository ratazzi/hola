const std = @import("std");
const clap = @import("clap");
const http = @import("../http.zig");
const provision_cmd = @import("provision.zig");
const provision = @import("../provision.zig");
const node_info = @import("../node_info.zig");

const params = clap.parseParamsComptime(
    \\-h, --help                 Show help for agent
    \\-n, --node-name <NAME>     Node name (default: hostname)
    \\-m, --mode <MODE>          Mode: sse (default) or watch
    \\-i, --interval <SECONDS>   Watch polling interval in seconds (default: 10)
    \\-c, --callback <URL>       Default callback URL (overridden by event)
    \\<endpoint>                  Endpoint URL
    \\
);

const parsers = .{
    .endpoint = clap.parsers.string,
    .URL = clap.parsers.string,
    .NAME = clap.parsers.string,
    .MODE = clap.parsers.string,
    .SECONDS = clap.parsers.int(u32, 10),
};

/// Return a display-safe URL with password masked as "***".
/// If the URL has no password or parsing fails, returns the original string.
fn maskUrlPassword(allocator: std.mem.Allocator, url: []const u8) []const u8 {
    const uri = std.Uri.parse(url) catch return url;
    if (uri.password == null) return url;
    const user_part = if (uri.user) |u| u.percent_encoded else "";
    const host_part = if (uri.host) |h| h.percent_encoded else "";
    return std.fmt.allocPrint(allocator, "{s}://{s}:***@{s}{s}", .{
        uri.scheme,
        user_part,
        host_part,
        uri.path.percent_encoded,
    }) catch url;
}

const INITIAL_BACKOFF_MS: u64 = 1000;
const MAX_BACKOFF_MS: u64 = 30_000;
const DEFAULT_WATCH_INTERVAL: u32 = 10;

// -- Shared task handling --

/// Parse ISO 8601 UTC timestamp (e.g. "2026-03-11T12:00:00Z") to epoch seconds.
fn parseIso8601(s: []const u8) !i64 {
    if (s.len < 20) return error.InvalidFormat;
    if (s[4] != '-' or s[7] != '-' or (s[10] != 'T' and s[10] != 't') or s[13] != ':' or s[16] != ':')
        return error.InvalidFormat;

    const year = std.fmt.parseInt(i32, s[0..4], 10) catch return error.InvalidFormat;
    const month = std.fmt.parseInt(u8, s[5..7], 10) catch return error.InvalidFormat;
    const day = std.fmt.parseInt(u8, s[8..10], 10) catch return error.InvalidFormat;
    const hour = std.fmt.parseInt(u8, s[11..13], 10) catch return error.InvalidFormat;
    const min = std.fmt.parseInt(u8, s[14..16], 10) catch return error.InvalidFormat;
    const sec = std.fmt.parseInt(u8, s[17..19], 10) catch return error.InvalidFormat;

    if (month < 1 or month > 12 or day < 1 or day > 31) return error.InvalidFormat;
    if (hour > 23 or min > 59 or sec > 59) return error.InvalidFormat;

    // Days from year 1970 to start of given year
    var days: i64 = 0;
    var y: i32 = 1970;
    while (y < year) : (y += 1) {
        days += if (@mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0)) @as(i64, 366) else 365;
    }

    // Days from start of year to start of given month
    const month_days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const leap: bool = @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
    var m: u8 = 1;
    while (m < month) : (m += 1) {
        days += month_days[m - 1];
        if (m == 2 and leap) days += 1;
    }
    days += day - 1;

    return days * 86400 + @as(i64, hour) * 3600 + @as(i64, min) * 60 + sec;
}

fn handleTaskJson(allocator: std.mem.Allocator, data: []const u8, default_callback: ?[]const u8) void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch |err| {
        std.debug.print("[agent] failed to parse task: {}\n", .{err});
        return;
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        std.debug.print("[agent] task is not a JSON object\n", .{});
        return;
    }
    const obj = parsed.value.object;

    // Check expiration
    if (obj.get("expires_at")) |ea| {
        if (ea == .string) {
            const now = std.time.timestamp();
            const expires = parseIso8601(ea.string) catch |err| {
                std.debug.print("[agent] invalid expires_at: {s} ({})\n", .{ ea.string, err });
                return;
            };
            if (now > expires) {
                std.debug.print("[agent] task expired (expires_at={s}), skipping\n", .{ea.string});
                return;
            }
        }
    }

    const url_val = obj.get("url") orelse {
        std.debug.print("[agent] task missing 'url' field\n", .{});
        return;
    };
    if (url_val != .string) {
        std.debug.print("[agent] 'url' field is not a string\n", .{});
        return;
    }
    const url = url_val.string;

    const callback_url = blk: {
        if (obj.get("callback")) |v| {
            if (v == .string) break :blk @as(?[]const u8, v.string);
        }
        break :blk default_callback;
    };

    const task_id = blk: {
        if (obj.get("id")) |v| {
            if (v == .string) break :blk v.string;
        }
        break :blk "unknown";
    };
    const action_name = blk: {
        if (obj.get("action")) |v| {
            if (v == .string) break :blk v.string;
        }
        break :blk "unknown";
    };
    // Extract params field as JSON string for data_bag injection
    const params_json: ?[]const u8 = blk: {
        if (obj.get("params")) |v| {
            if (v == .object) {
                const json_str = std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(v, .{})}) catch break :blk null;
                break :blk json_str;
            }
        }
        break :blk null;
    };
    defer if (params_json) |p| allocator.free(p);

    const display_url = maskUrlPassword(allocator, url);
    defer if (display_url.ptr != url.ptr) allocator.free(display_url);
    std.debug.print("[agent] task={s} action={s} provisioning: {s}\n", .{ task_id, action_name, display_url });

    var prov_result = provision_cmd.runScript(allocator, url, false, params_json) catch |err| {
        std.debug.print("[agent] provision failed: {}\n", .{err});
        if (callback_url) |cb| {
            sendCallback(allocator, cb, data, "error", @errorName(err), null);
        }
        return;
    };
    defer prov_result.deinit(allocator);

    std.debug.print("[agent] provision complete\n", .{});
    if (callback_url) |cb| {
        sendCallback(allocator, cb, data, "ok", null, &prov_result);
    }
}

fn buildCallbackBody(allocator: std.mem.Allocator, event_data: []const u8, status: []const u8, err_msg: ?[]const u8, prov_result: ?*const provision.ProvisionResult) ![]const u8 {
    // Use arena for all intermediate JSON allocations; only the final string is duped to caller's allocator.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, aa, event_data, .{});

    var obj = parsed.value.object;

    _ = obj.fetchSwapRemove("url");
    _ = obj.fetchSwapRemove("callback");

    var result = std.json.ObjectMap.init(aa);
    try result.put("status", .{ .string = status });
    if (err_msg) |msg| {
        try result.put("error", .{ .string = msg });
    }

    if (prov_result) |pr| {
        try result.put("executed", .{ .integer = @intCast(pr.executed_count) });
        try result.put("updated", .{ .integer = @intCast(pr.updated_count) });
        try result.put("skipped", .{ .integer = @intCast(pr.skipped_count) });
        try result.put("failed", .{ .integer = @intCast(pr.failed_count) });
        try result.put("duration_ms", .{ .integer = pr.duration_ms });

        var resources_arr = std.json.Array.init(aa);
        for (pr.resource_results.items) |rr| {
            var res_obj = std.json.ObjectMap.init(aa);
            try res_obj.put("type", .{ .string = rr.type_name });
            try res_obj.put("name", .{ .string = rr.name });
            try res_obj.put("action", .{ .string = rr.action });
            try res_obj.put("updated", .{ .bool = rr.was_updated });
            if (rr.skipped) {
                try res_obj.put("skipped", .{ .bool = true });
            }
            if (rr.skip_reason) |sr| {
                try res_obj.put("skip_reason", .{ .string = sr });
            }
            if (rr.error_name) |en| {
                try res_obj.put("error", .{ .string = en });
            }
            if (rr.output) |o| {
                try res_obj.put("output", .{ .string = o });
            }
            try resources_arr.append(.{ .object = res_obj });
        }
        try result.put("resources", .{ .array = resources_arr });
    }

    try obj.put("result", .{ .object = result });

    const node = node_info.getNodeInfo(aa) catch null;
    if (node) |n| {
        const node_json = try std.fmt.allocPrint(aa, "{f}", .{std.json.fmt(n, .{})});
        const node_parsed = try std.json.parseFromSlice(std.json.Value, aa, node_json, .{});
        const node_clone = try cloneJsonValue(aa, node_parsed.value);
        try obj.put("node", node_clone);
    }

    const body = try std.fmt.allocPrint(aa, "{f}", .{std.json.fmt(std.json.Value{ .object = obj }, .{})});
    return try allocator.dupe(u8, body);
}

fn cloneJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    return switch (value) {
        .null => .null,
        .bool => |b| .{ .bool = b },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .number_string => |s| .{ .number_string = try allocator.dupe(u8, s) },
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .array => |arr| blk: {
            var new_arr = std.json.Array.init(allocator);
            try new_arr.ensureTotalCapacity(arr.items.len);
            for (arr.items) |item| {
                try new_arr.append(try cloneJsonValue(allocator, item));
            }
            break :blk .{ .array = new_arr };
        },
        .object => |obj| blk: {
            var new_obj = std.json.ObjectMap.init(allocator);
            var it = obj.iterator();
            while (it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                const val = try cloneJsonValue(allocator, entry.value_ptr.*);
                try new_obj.put(key, val);
            }
            break :blk .{ .object = new_obj };
        },
    };
}

fn sendCallback(allocator: std.mem.Allocator, callback_url: []const u8, event_data: []const u8, status: []const u8, err_msg: ?[]const u8, prov_result: ?*const provision.ProvisionResult) void {
    const body = buildCallbackBody(allocator, event_data, status, err_msg, prov_result) catch |err| {
        std.debug.print("[agent] failed to build callback body: {}\n", .{err});
        return;
    };
    defer allocator.free(body);

    std.debug.print("[agent] callback POST {s}\n", .{callback_url});

    var resp = http.post(allocator, callback_url, .{
        .body = body,
        .headers = .{ .@"Content-Type" = "application/json" },
    }) catch |err| {
        std.debug.print("[agent] callback POST failed: {}\n", .{err});
        return;
    };
    defer resp.deinit();

    std.debug.print("[agent] callback response: {d}\n", .{resp.status});
}

// -- WebSocket mode --

fn runSseMode(allocator: std.mem.Allocator, endpoint: []const u8, node_name: []const u8, default_callback: ?[]const u8) void {
    // Convert http(s) URL to ws(s) URL
    const ws_endpoint = blk: {
        if (std.mem.startsWith(u8, endpoint, "https://")) {
            break :blk std.fmt.allocPrint(allocator, "wss://{s}", .{endpoint["https://".len..]}) catch endpoint;
        } else if (std.mem.startsWith(u8, endpoint, "http://")) {
            break :blk std.fmt.allocPrint(allocator, "ws://{s}", .{endpoint["http://".len..]}) catch endpoint;
        }
        break :blk endpoint;
    };
    defer if (ws_endpoint.ptr != endpoint.ptr) allocator.free(ws_endpoint);

    const display_endpoint = maskUrlPassword(allocator, ws_endpoint);
    defer if (display_endpoint.ptr != ws_endpoint.ptr) allocator.free(display_endpoint);
    std.debug.print("[agent] node={s}, connecting to {s}\n", .{ node_name, display_endpoint });

    var backoff_ms: u64 = INITIAL_BACKOFF_MS;
    while (true) {
        wsConnect(allocator, ws_endpoint, node_name, default_callback) catch {
            std.debug.print("[agent] reconnecting in {d}ms...\n", .{backoff_ms});
            std.Thread.sleep(backoff_ms * std.time.ns_per_ms);
            backoff_ms = @min(backoff_ms * 2, MAX_BACKOFF_MS);
            continue;
        };

        backoff_ms = INITIAL_BACKOFF_MS;
        std.debug.print("[agent] connection closed, reconnecting...\n", .{});
    }
}

const WsContext = struct {
    allocator: std.mem.Allocator,
    default_callback: ?[]const u8,
};

fn wsWriteCallback(ptr: [*]const u8, size: usize, nmemb: usize, userdata: *anyopaque) callconv(.c) usize {
    const ctx: *WsContext = @ptrCast(@alignCast(userdata));
    const total = size * nmemb;
    if (total == 0) return 0;
    handleWsMessage(ctx.allocator, ptr[0..total], ctx.default_callback);
    return total;
}

fn wsConnect(allocator: std.mem.Allocator, endpoint: []const u8, node_name: []const u8, default_callback: ?[]const u8) !void {
    const curl = @import("../curl.zig");
    const handle = curl.curl_easy_init() orelse return error.ConnectionFailed;
    defer curl.curl_easy_cleanup(handle);

    const url_z = try allocator.dupeZ(u8, endpoint);
    defer allocator.free(url_z);
    _ = curl.curl_easy_setopt(handle, .CURLOPT_URL, url_z.ptr);

    // Custom headers
    var headers: ?*curl.curl_slist = null;
    const node_header = try std.fmt.allocPrint(allocator, "X-Hola-Node: {s}\x00", .{node_name});
    defer allocator.free(node_header);
    headers = curl.curl_slist_append(headers, @ptrCast(node_header.ptr));
    const platform_header = try std.fmt.allocPrint(allocator, "X-Hola-Platform: {s}\x00", .{node_info.getOs()});
    defer allocator.free(platform_header);
    headers = curl.curl_slist_append(headers, @ptrCast(platform_header.ptr));
    const arch_header = try std.fmt.allocPrint(allocator, "X-Hola-Arch: {s}\x00", .{node_info.getCpuArch()});
    defer allocator.free(arch_header);
    headers = curl.curl_slist_append(headers, @ptrCast(arch_header.ptr));
    if (headers) |h| {
        _ = curl.curl_easy_setopt(handle, .CURLOPT_HTTPHEADER, h);
    }
    defer if (headers) |h| curl.curl_slist_free_all(h);

    // Write callback receives WebSocket text frame payloads
    var ctx = WsContext{ .allocator = allocator, .default_callback = default_callback };
    _ = curl.curl_easy_setopt(handle, .CURLOPT_WRITEFUNCTION, @as(curl.WriteCallback, @ptrCast(&wsWriteCallback)));
    _ = curl.curl_easy_setopt(handle, .CURLOPT_WRITEDATA, @as(*anyopaque, @ptrCast(&ctx)));

    // Perform WebSocket connection (blocks until closed)
    const rc = curl.curl_easy_perform(handle);
    if (rc != .CURLE_OK) {
        const err_msg = curl.curl_easy_strerror(rc);
        std.debug.print("[agent] WebSocket error: {s}\n", .{std.mem.span(err_msg)});
        return error.ConnectionFailed;
    }
}

fn handleWsMessage(allocator: std.mem.Allocator, msg: []const u8, default_callback: ?[]const u8) void {
    // Parse {"type": "task"|"snapshot-task", "data": {...}}
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, msg, .{}) catch |err| {
        std.debug.print("[agent] failed to parse WS message: {}\n", .{err});
        return;
    };
    defer parsed.deinit();

    if (parsed.value != .object) return;
    const obj = parsed.value.object;

    const msg_type = blk: {
        if (obj.get("type")) |v| {
            if (v == .string) break :blk v.string;
        }
        break :blk "";
    };

    if (std.mem.eql(u8, msg_type, "task") or std.mem.eql(u8, msg_type, "snapshot-task")) {
        if (obj.get("data")) |data_val| {
            const task_json = std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(data_val, .{})}) catch return;
            defer allocator.free(task_json);
            handleTaskJson(allocator, task_json, default_callback);
        }
    }
}

// -- Watch (polling) mode --

fn runWatchMode(allocator: std.mem.Allocator, endpoint: []const u8, node_name: []const u8, interval_s: u32, default_callback: ?[]const u8) void {
    const display_endpoint = maskUrlPassword(allocator, endpoint);
    defer if (display_endpoint.ptr != endpoint.ptr) allocator.free(display_endpoint);
    std.debug.print("[agent] watch mode, node={s}, polling {s} every {d}s\n", .{ node_name, display_endpoint, interval_s });

    while (true) {
        pollOnce(allocator, endpoint, node_name, default_callback);
        std.Thread.sleep(@as(u64, interval_s) * std.time.ns_per_s);
    }
}

fn pollOnce(allocator: std.mem.Allocator, endpoint: []const u8, node_name: []const u8, default_callback: ?[]const u8) void {
    var resp = http.request(allocator, .GET, endpoint, .{
        .headers = .{
            .@"X-Hola-Node" = node_name,
            .@"X-Hola-Platform" = node_info.getOs(),
            .@"X-Hola-Arch" = node_info.getCpuArch(),
        },
    }) catch |err| {
        std.debug.print("[agent] poll failed: {}\n", .{err});
        return;
    };
    defer resp.deinit();

    if (resp.status < 200 or resp.status >= 300) {
        std.debug.print("[agent] poll returned HTTP {d}\n", .{resp.status});
        return;
    }

    if (resp.body.len == 0) return;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, resp.body, .{}) catch |err| {
        std.debug.print("[agent] failed to parse poll response: {}\n", .{err});
        return;
    };
    defer parsed.deinit();

    switch (parsed.value) {
        .array => |arr| {
            for (arr.items) |item| {
                if (item != .object) continue;
                const task_json = std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(item, .{})}) catch continue;
                defer allocator.free(task_json);
                handleTaskJson(allocator, task_json, default_callback);
            }
        },
        .object => {
            handleTaskJson(allocator, resp.body, default_callback);
        },
        else => {
            std.debug.print("[agent] poll response is not a JSON object or array\n", .{});
        },
    }
}

// -- Entry point --

fn getDefaultNodeName(allocator: std.mem.Allocator) []const u8 {
    return node_info.getHostname(allocator) catch "unknown";
}

pub fn run(allocator: std.mem.Allocator, iter: *std.process.ArgIterator) !void {
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, parsers, iter, .{
        .allocator = allocator,
        .diagnostic = &diag,
    }) catch |err| {
        try diag.reportToFile(std.fs.File.stderr(), err);
        return;
    };
    defer res.deinit();

    if (res.args.help != 0) return printHelp(null);

    const endpoint = res.positionals[0] orelse return printHelp("Missing endpoint URL.");

    const node_name = res.args.@"node-name" orelse getDefaultNodeName(allocator);
    const default_callback = res.args.callback;
    const interval = res.args.interval orelse DEFAULT_WATCH_INTERVAL;

    const agent_mode = res.args.mode orelse "ws";
    if (std.mem.eql(u8, agent_mode, "ws") or std.mem.eql(u8, agent_mode, "sse")) {
        runSseMode(allocator, endpoint, node_name, default_callback);
    } else if (std.mem.eql(u8, agent_mode, "watch")) {
        runWatchMode(allocator, endpoint, node_name, interval, default_callback);
    } else {
        std.debug.print("Invalid mode: {s}\n", .{agent_mode});
        std.debug.print("Valid modes: ws, watch\n", .{});
        return error.InvalidMode;
    }
}

fn printHelp(reason: ?[]const u8) !void {
    const out = std.fs.File.stdout();
    if (reason) |msg| {
        try out.writeAll(msg);
        try out.writeAll("\n\n");
    }
    try out.writeAll(
        \\agent
        \\  hola agent [OPTIONS] <endpoint>
        \\
        \\Connect to an endpoint and execute provision scripts as tasks arrive.
        \\Supports WebSocket (streaming) and watch (polling) modes.
        \\
        \\Options:
        \\  -n, --node-name NAME   Node name sent as X-Hola-Node header (default: hostname)
        \\  -m, --mode MODE        Mode: ws (default) or watch
        \\  -i, --interval SECS    Watch polling interval in seconds (default: 10)
        \\  -c, --callback URL     Default callback URL (overridden by event payload)
        \\
        \\Task JSON Format:
        \\  {"url": "https://r2.example.com/task.rb", "callback": "https://example.com/done", ...}
        \\
        \\  - url       (required) Provision script URL
        \\  - callback  (optional) Callback URL for this task (overrides --callback)
        \\  - ...       All other fields are passed through to callback
        \\
        \\Callback POST Body:
        \\  Original fields (minus url/callback) + result + node info
        \\  {"task_id": "abc", "result": {"status": "ok"}, "node": {"hostname": "...", ...}}
        \\
        \\WebSocket Mode (default):
        \\  hola agent https://hub.example.com/nodes/mynode/events
        \\  hola agent --node-name web-01 https://hub.example.com/nodes/web-01/events
        \\
        \\Watch Mode:
        \\  hola agent --mode watch https://worker.example.com/pending
        \\  hola agent --mode watch --interval 30 --node-name db-01 https://worker.example.com/pending
        \\
    );
}

test "buildCallbackBody with ProvisionResult" {
    const allocator = std.testing.allocator;

    var resource_results = std.ArrayList(provision.ResourceResult).empty;
    defer resource_results.deinit(allocator);

    const type1 = try allocator.dupe(u8, "file");
    const name1 = try allocator.dupe(u8, "/tmp/config");
    const action1 = try allocator.dupe(u8, "create");
    try resource_results.append(allocator, .{
        .type_name = type1,
        .name = name1,
        .action = action1,
        .was_updated = true,
        .skipped = false,
        .skip_reason = null,
        .error_name = null,
    });

    const type2 = try allocator.dupe(u8, "execute");
    const name2 = try allocator.dupe(u8, "reload");
    const action2 = try allocator.dupe(u8, "run");
    const skip2 = try allocator.dupe(u8, "up to date");
    try resource_results.append(allocator, .{
        .type_name = type2,
        .name = name2,
        .action = action2,
        .was_updated = false,
        .skipped = true,
        .skip_reason = skip2,
        .error_name = null,
    });

    var prov_result = provision.ProvisionResult{
        .executed_count = 2,
        .updated_count = 1,
        .skipped_count = 1,
        .failed_count = 0,
        .duration_ms = 142,
        .resource_results = resource_results,
    };

    const event_data =
        \\{"id":"task-1","url":"https://example.com/script.rb","callback":"https://example.com/done"}
    ;

    const body = try buildCallbackBody(allocator, event_data, "ok", null, &prov_result);
    defer allocator.free(body);

    // Verify key fields exist in the JSON output
    try std.testing.expect(std.mem.indexOf(u8, body, "\"status\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"executed\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"updated\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"skipped\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"failed\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"duration_ms\":142") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"resources\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"/tmp/config\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"skip_reason\":\"up to date\"") != null);
    // url and callback should be removed
    try std.testing.expect(std.mem.indexOf(u8, body, "\"url\":") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"callback\":") == null);

    // Free the duped strings
    allocator.free(type1);
    allocator.free(name1);
    allocator.free(action1);
    allocator.free(type2);
    allocator.free(name2);
    allocator.free(action2);
    allocator.free(skip2);
}
