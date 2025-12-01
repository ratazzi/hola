// Main HTTP module - unified interface
const std = @import("std");

// Re-export core types
pub const types = @import("http/types.zig");
pub const Method = types.Method;
pub const Request = types.Request;
pub const Response = types.Response;
pub const Error = types.Error;
pub const StreamCallback = types.StreamCallback;
pub const ProgressCallback = types.ProgressCallback;

// Re-export config
pub const config = @import("http/config.zig");
pub const Config = config.Config;
pub const getUserAgent = config.getUserAgent;

// Re-export client
pub const client = @import("http/client.zig");
pub const Client = client.Client;

// Re-export utilities
pub const utils = @import("http/utils.zig");
pub const parseHeadersFromJson = utils.parseHeadersFromJson;
pub const formatSize = utils.formatSize;
pub const formatSizeBuf = utils.formatSizeBuf;
pub const formatSizeRange = utils.formatSizeRange;
pub const slugifyPath = utils.slugifyPath;
pub const calculateSha256 = utils.calculateSha256;

// Re-export download module
pub const download = struct {
    pub const Task = @import("http/download/task.zig").Task;
    pub const Status = @import("http/download/task.zig").Status;
    pub const Manager = @import("http/download/manager.zig").Manager;
    pub const downloader = @import("http/download/downloader.zig");
    pub const Options = downloader.Options;
    pub const Result = downloader.Result;
};

// Convenience: direct download function
pub const downloadFile = download.downloader.downloadFile;

// Re-export mruby bindings
pub const mruby_bindings = @import("http/mruby_bindings.zig");
pub const mruby_module_def = mruby_bindings.mruby_module_def;

// Simple request functions - use anonymous struct for options
pub fn request(allocator: std.mem.Allocator, method: Method, url: []const u8, opts: anytype) !Response {
    const cfg = Config{};
    var c = try Client.init(allocator, cfg);
    defer c.deinit();

    var req = try Request.build(allocator, method, url, opts);
    defer req.deinit();
    return c.request(req);
}

// Convenience shortcuts
pub fn get(allocator: std.mem.Allocator, url: []const u8, opts: anytype) !Response {
    return request(allocator, .GET, url, opts);
}

pub fn post(allocator: std.mem.Allocator, url: []const u8, opts: anytype) !Response {
    return request(allocator, .POST, url, opts);
}

pub fn put(allocator: std.mem.Allocator, url: []const u8, opts: anytype) !Response {
    return request(allocator, .PUT, url, opts);
}

pub fn delete(allocator: std.mem.Allocator, url: []const u8, opts: anytype) !Response {
    return request(allocator, .DELETE, url, opts);
}
