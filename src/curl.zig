// libcurl C API bindings for Zig
const std = @import("std");

pub const CURL = opaque {};
pub const curl_off_t = c_longlong;
pub const curl_slist = extern struct {
    data: [*:0]u8,
    next: ?*curl_slist,
};

pub const CURLcode = enum(c_int) {
    CURLE_OK = 0,
    CURLE_UNSUPPORTED_PROTOCOL = 1,
    CURLE_FAILED_INIT = 2,
    CURLE_URL_MALFORMAT = 3,
    CURLE_COULDNT_RESOLVE_PROXY = 5,
    CURLE_COULDNT_RESOLVE_HOST = 6,
    CURLE_COULDNT_CONNECT = 7,
    CURLE_OPERATION_TIMEDOUT = 28,
    CURLE_HTTP_RETURNED_ERROR = 22,
    CURLE_WRITE_ERROR = 23,
    CURLE_SSL_CONNECT_ERROR = 35,
    CURLE_PEER_FAILED_VERIFICATION = 51,
    CURLE_ABORTED_BY_CALLBACK = 42,
    _,
};

pub const CURLoption = enum(c_int) {
    CURLOPT_URL = 10002,
    CURLOPT_WRITEFUNCTION = 20011,
    CURLOPT_WRITEDATA = 10001,
    CURLOPT_HEADERFUNCTION = 20079,
    CURLOPT_HEADERDATA = 10029,
    CURLOPT_USERAGENT = 10018,
    CURLOPT_HTTPHEADER = 10023,
    CURLOPT_FOLLOWLOCATION = 52,
    CURLOPT_MAXREDIRS = 68,
    CURLOPT_NOSIGNAL = 99,
    CURLOPT_HTTP_VERSION = 84,
    CURLOPT_ACCEPT_ENCODING = 10102,

    // HTTP methods
    CURLOPT_POST = 47,
    CURLOPT_NOBODY = 44,
    CURLOPT_CUSTOMREQUEST = 10036,
    CURLOPT_POSTFIELDS = 10015,
    CURLOPT_POSTFIELDSIZE = 60,

    // Proxy support
    CURLOPT_PROXY = 10004,
    CURLOPT_PROXYTYPE = 101,
    CURLOPT_PROXYUSERPWD = 10006,
    CURLOPT_NOPROXY = 10177,

    // Authentication
    CURLOPT_USERPWD = 10005,
    CURLOPT_HTTPAUTH = 107,

    // AWS Signature V4
    CURLOPT_AWS_SIGV4 = 10305,

    // Resume/Range
    CURLOPT_RESUME_FROM_LARGE = 30116,
    CURLOPT_RANGE = 10007,

    // Timeout
    CURLOPT_CONNECTTIMEOUT = 78,
    CURLOPT_TIMEOUT = 13,
    CURLOPT_LOW_SPEED_LIMIT = 19,
    CURLOPT_LOW_SPEED_TIME = 20,

    // Speed limit
    CURLOPT_MAX_RECV_SPEED_LARGE = 30146,
    CURLOPT_MAX_SEND_SPEED_LARGE = 30145,

    // Progress callback
    CURLOPT_XFERINFOFUNCTION = 20219,
    CURLOPT_XFERINFODATA = 10057,
    CURLOPT_NOPROGRESS = 43,

    // SSL/TLS
    CURLOPT_CAINFO = 10065,
    CURLOPT_CAPATH = 10097,
    CURLOPT_SSL_VERIFYPEER = 64,
    CURLOPT_SSL_VERIFYHOST = 81,

    // Debug
    CURLOPT_VERBOSE = 41,

    _,
};

pub const CURLINFO = enum(c_int) {
    CURLINFO_RESPONSE_CODE = 0x200002,
    _,
};

pub const CURL_HTTP_VERSION = enum(c_long) {
    CURL_HTTP_VERSION_NONE = 0,
    CURL_HTTP_VERSION_1_0 = 1,
    CURL_HTTP_VERSION_1_1 = 2,
    CURL_HTTP_VERSION_2_0 = 3,
    CURL_HTTP_VERSION_2TLS = 4,
    CURL_HTTP_VERSION_2_PRIOR_KNOWLEDGE = 5,
    CURL_HTTP_VERSION_3 = 30,
};

// Version information structure
pub const curl_version_info_data = extern struct {
    age: c_int, // CURLVERSION_NOW
    version: [*:0]const u8, // Version string (e.g., "8.5.0")
    version_num: c_uint, // Version as 24-bit number: 0xXXYYZZ (major, minor, patch)
    host: [*:0]const u8, // Human readable host info
    features: c_int, // Bitmask of features
    ssl_version: ?[*:0]const u8, // SSL version string
    ssl_version_num: c_long, // SSL version number
    libz_version: ?[*:0]const u8, // zlib version string
    protocols: [*:null]const ?[*:0]const u8, // List of supported protocols (NULL-terminated)
    // ... other fields we may add later if needed
};

pub const CURLVERSION_NOW = 10; // Current version of curl_version_info_data

pub extern fn curl_version() [*:0]const u8;
pub extern fn curl_version_info(age: c_int) *curl_version_info_data;

pub extern fn curl_global_init(flags: c_long) CURLcode;
pub extern fn curl_global_cleanup() void;
pub extern fn curl_easy_init() ?*CURL;
pub extern fn curl_easy_cleanup(curl: *CURL) void;
pub extern fn curl_easy_setopt(curl: *CURL, option: CURLoption, ...) CURLcode;
pub extern fn curl_easy_perform(curl: *CURL) CURLcode;
pub extern fn curl_easy_getinfo(curl: *CURL, info: CURLINFO, ...) CURLcode;
pub extern fn curl_easy_strerror(code: CURLcode) [*:0]const u8;
pub extern fn curl_slist_append(list: ?*curl_slist, string: [*:0]const u8) ?*curl_slist;
pub extern fn curl_slist_free_all(list: ?*curl_slist) void;

// Callback signatures
pub const WriteCallback = *const fn (ptr: [*]const u8, size: usize, nmemb: usize, userdata: *anyopaque) callconv(.c) usize;
pub const HeaderCallback = *const fn (ptr: [*]const u8, size: usize, nmemb: usize, userdata: *anyopaque) callconv(.c) usize;
pub const ProgressCallback = *const fn (clientp: *anyopaque, dltotal: c_longlong, dlnow: c_longlong, ultotal: c_longlong, ulnow: c_longlong) callconv(.c) c_int;

// Proxy types
pub const CURLproxytype = enum(c_long) {
    CURLPROXY_HTTP = 0,
    CURLPROXY_HTTPS = 2,
    CURLPROXY_SOCKS4 = 4,
    CURLPROXY_SOCKS5 = 5,
    CURLPROXY_SOCKS4A = 6,
    CURLPROXY_SOCKS5_HOSTNAME = 7,
};

// Auth types
pub const CURLAUTH = enum(c_long) {
    CURLAUTH_NONE = 0,
    CURLAUTH_BASIC = 1,
    CURLAUTH_DIGEST = 2,
    CURLAUTH_NEGOTIATE = 4,
    CURLAUTH_NTLM = 8,
    CURLAUTH_ANY = ~@as(c_long, 0),
};

// Helper functions for version information

/// Get curl version as a human-readable string (e.g., "libcurl/8.5.0 ...")
pub fn getVersionString() []const u8 {
    const ver = curl_version();
    return std.mem.span(ver);
}

/// Get detailed version information
pub fn getVersionInfo() *curl_version_info_data {
    return curl_version_info(CURLVERSION_NOW);
}

/// Parse version_num into major.minor.patch components
pub fn parseVersion(version_num: c_uint) struct { major: u8, minor: u8, patch: u8 } {
    return .{
        .major = @intCast((version_num >> 16) & 0xFF),
        .minor = @intCast((version_num >> 8) & 0xFF),
        .patch = @intCast(version_num & 0xFF),
    };
}

/// Get version as "major.minor.patch" string
pub fn getVersionNumber(allocator: std.mem.Allocator) ![]const u8 {
    const info = getVersionInfo();
    const ver = parseVersion(info.version_num);
    return std.fmt.allocPrint(allocator, "{d}.{d}.{d}", .{ ver.major, ver.minor, ver.patch });
}
