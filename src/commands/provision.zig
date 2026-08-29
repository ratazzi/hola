const std = @import("std");
const clap = @import("clap");
const provision = @import("../provision.zig");
const http = @import("../http.zig");
const global_io = @import("../global_io.zig");
const common = @import("common.zig");

const params = clap.parseParamsComptime(
    \\-h, --help            Show help for provision
    \\-o, --output <MODE>   Output mode: pretty or plain (auto-detect: pretty if TTY)
    \\    --data-bag <JSON>        JSON string to inject as data_bag
    \\    --data-bag-url <URL>     Fetch data_bag JSON from URL
    \\    --secrets-bag <JSON>     JSON string to inject as secrets_bag
    \\    --secrets-bag-url <URL>  Fetch secrets_bag JSON from URL
    \\    --client-cert <PATH>     Client certificate for mTLS
    \\    --client-key <PATH>      Client private key for mTLS
    \\<path>                Path to provision file (.rb)
    \\
);

const parsers = .{
    .path = clap.parsers.string,
    .MODE = clap.parsers.string,
    .JSON = clap.parsers.string,
    .PATH = clap.parsers.string,
    .URL = clap.parsers.string,
};

/// Download a remote script to a temp file, run provision, then clean up.
/// Accepts both local paths and HTTP(S) URLs.
/// params_json: optional JSON string to inject as data_bag (agent mode).
pub const TlsClientAuth = common.TlsClientAuth;

pub fn runScript(allocator: std.mem.Allocator, script_path_or_url: []const u8, use_pretty_output: bool, params_json: ?[]const u8, secrets_json: ?[]const u8, tls_auth: TlsClientAuth) !provision.ProvisionResult {
    const is_url = std.mem.startsWith(u8, script_path_or_url, "http://") or
        std.mem.startsWith(u8, script_path_or_url, "https://");

    const io = global_io.io();

    var temp_file_path: ?[]const u8 = null;
    defer if (temp_file_path) |path| {
        std.Io.Dir.deleteFileAbsolute(io, path) catch {};
        allocator.free(path);
    };

    const script_path = if (is_url) blk: {
        _ = std.Uri.parse(script_path_or_url) catch |err| {
            std.debug.print("Error: Invalid URL: {}\n", .{err});
            return error.InvalidUrl;
        };

        var url_buf: [512]u8 = undefined;
        const display_url = http.maskUrlPassword(script_path_or_url, &url_buf);

        std.debug.print("[fetch] Downloading provision script from {s}\n", .{display_url});

        const temp_dir = global_io.getEnvOwned(allocator, "TMPDIR") catch
            try allocator.dupe(u8, "/tmp");
        defer allocator.free(temp_dir);

        var rand_buf: [8]u8 = undefined;
        io.random(&rand_buf);
        const rand_hex = std.fmt.bytesToHex(rand_buf, .lower);
        const temp_file = try std.fmt.allocPrint(allocator, "{s}/provision-{d}-{s}.rb", .{ temp_dir, std.Io.Timestamp.now(io, .real).toSeconds(), &rand_hex });
        temp_file_path = temp_file;

        const cfg = http.Config{
            .max_timeout_s = common.PROVISION_FETCH_TIMEOUT_S,
            .client_cert = tls_auth.cert,
            .client_key = tls_auth.key,
        };
        var client = http.Client.init(allocator, cfg) catch |err| {
            std.debug.print("\nError: Failed to initialize HTTP client: {}\n", .{err});
            return error.DownloadFailed;
        };
        defer client.deinit();

        const response = client.get(script_path_or_url, null) catch |err| {
            std.debug.print("\nError: Failed to download provision script: {}\n", .{err});
            if (http.getLastError()) |detail| {
                var detail_buf: [1024]u8 = undefined;
                std.debug.print("  {s}\n", .{http.redactPassword(script_path_or_url, detail, &detail_buf)});
            }
            std.debug.print("URL: {s}\n", .{display_url});
            std.debug.print("\nPossible reasons:\n", .{});
            std.debug.print("  • URL is not accessible\n", .{});
            std.debug.print("  • Network connectivity issues\n", .{});
            std.debug.print("  • Invalid credentials (if using Basic Auth)\n", .{});
            std.debug.print("  • Client certificate / key unreadable or invalid (if using mTLS)\n", .{});
            std.debug.print("  • Server returned an error\n", .{});
            return error.DownloadFailed;
        };
        defer {
            var mut_resp = response;
            mut_resp.deinit();
        }

        if (response.status >= 400) {
            std.debug.print("\nError: Server returned HTTP {d}\n", .{response.status});
            std.debug.print("URL: {s}\n", .{display_url});
            return error.DownloadFailed;
        }

        if (response.status < 200 or response.status >= 300) {
            std.debug.print("\nError: Unexpected HTTP status {d}\n", .{response.status});
            std.debug.print("URL: {s}\n", .{display_url});
            return error.DownloadFailed;
        }

        const file = try std.Io.Dir.cwd().createFile(io, temp_file, .{ .exclusive = true });
        defer file.close(io);
        try file.writeStreamingAll(io, response.body);

        std.debug.print("[fetch] Downloaded to {s}\n", .{temp_file});
        break :blk temp_file;
    } else script_path_or_url;

    return try provision.run(allocator, .{
        .script_path = script_path,
        .use_pretty_output = use_pretty_output,
        .params_json = params_json,
        .secrets_json = secrets_json,
    });
}

pub fn run(allocator: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, parsers, iter, .{
        .allocator = allocator,
        .diagnostic = &diag,
    }) catch |err| {
        try diag.reportToFile(global_io.io(), std.Io.File.stderr(), err);
        return;
    };
    defer res.deinit();

    if (res.args.help != 0) return printHelp(null);

    const script_path_or_url = res.positionals[0] orelse return printHelp("Missing provision file path or URL.");

    const use_pretty_output = try common.parseOutputMode(res.args.output);
    const logger = @import("../logger.zig");
    var bags = try common.resolveBags(allocator, .{
        .data_bag = res.args.@"data-bag",
        .data_bag_url = res.args.@"data-bag-url",
        .secrets_bag = res.args.@"secrets-bag",
        .secrets_bag_url = res.args.@"secrets-bag-url",
        .client_cert = res.args.@"client-cert",
        .client_key = res.args.@"client-key",
    });
    defer bags.deinit();

    var result = runScript(allocator, script_path_or_url, use_pretty_output, bags.data_bag, bags.secrets_bag, bags.tls_auth) catch |err| {
        if (err == error.MRubyException) {
            if (logger.getLogPath()) |log_path| {
                std.debug.print("\nLog file: {s}\n", .{log_path});
            }
            std.process.exit(1);
        }
        std.debug.print("Provision failed: {}\n", .{err});
        if (logger.getLogPath()) |log_path| {
            std.debug.print("Log file: {s}\n", .{log_path});
        }
        std.process.exit(1);
    };
    defer result.deinit(allocator);
}

fn printHelp(reason: ?[]const u8) !void {
    const io = global_io.io();
    const out = std.Io.File.stdout();
    if (reason) |msg| {
        try out.writeStreamingAll(io, msg);
        try out.writeStreamingAll(io, "\n\n");
    }
    try out.writeStreamingAll(io,
        \\provision
        \\  hola provision [OPTIONS] <file-or-url>
        \\
        \\Run a provisioning script that defines infrastructure resources.
        \\Supports both local files and remote URLs.
        \\
        \\Options:
        \\  -o, --output MODE          Output mode: pretty or plain (auto-detect: pretty if TTY)
        \\      --data-bag JSON        JSON string to inject as data_bag
        \\      --data-bag-url URL     Fetch data_bag JSON from URL
        \\      --secrets-bag JSON     JSON string to inject as secrets_bag
        \\      --secrets-bag-url URL  Fetch secrets_bag JSON from URL
        \\      --client-cert PATH     Client certificate for mTLS (PEM)
        \\      --client-key PATH      Client private key for mTLS (PEM)
        \\
        \\Examples
        \\  # Local file
        \\  hola provision provision.rb
        \\  hola provision ~/.config/hola/provision.rb
        \\
        \\  # Remote URL
        \\  hola provision https://example.com/provision.rb
        \\  hola provision https://username:password@example.com/provision.rb
        \\
        \\  # With data_bag / secrets_bag
        \\  hola provision --data-bag '{"env":"prod"}' provision.rb
        \\  hola provision --secrets-bag '{"token":"sk-xxx"}' provision.rb
        \\
        \\  # Fetch from URL (supports mTLS)
        \\  hola provision --data-bag-url https://config.example.com/params.json provision.rb
        \\  hola provision --secrets-bag-url https://vault.example.com/secrets.json \
        \\    --client-cert cert.pem --client-key key.pem provision.rb
        \\
        \\  # With output mode
        \\  hola provision --output plain provision.rb
        \\
        \\Ruby DSL:
        \\  file \"/tmp/config\" do
        \\    content \"hello\\n\"
        \\    mode \"0644\"
        \\    notifies :run, \"execute[reload]\", :delayed
        \\  end
        \\
        \\  execute \"deploy\" do
        \\    command \"bash deploy.sh\"
        \\    cwd \"/opt/app\"
        \\    only_if { File.exist?(\"/opt/app\") }
        \\  end
        \\
        \\  # Subscribes (alternative to notifies)
        \\  execute \"restart\" do
        \\    command \"systemctl restart app\"
        \\    action :nothing
        \\    subscribes :run, \"file[/etc/app/config]\", :delayed
        \\  end
        \\
    );
}
