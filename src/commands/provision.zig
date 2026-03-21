const std = @import("std");
const clap = @import("clap");
const provision = @import("../provision.zig");
const http = @import("../http.zig");

const params = clap.parseParamsComptime(
    \\-h, --help            Show help for provision
    \\-o, --output <MODE>   Output mode: pretty (default) or plain
    \\-p, --params <JSON>   JSON string to inject as data_bag
    \\-s, --secrets <JSON>  JSON string to inject as secrets_bag
    \\    --client-cert <PATH>   Client certificate for mTLS
    \\    --client-key <PATH>    Client private key for mTLS
    \\<path>                Path to provision file (.rb)
    \\
);

const parsers = .{
    .path = clap.parsers.string,
    .MODE = clap.parsers.string,
    .JSON = clap.parsers.string,
    .PATH = clap.parsers.string,
};

/// Download a remote script to a temp file, run provision, then clean up.
/// Accepts both local paths and HTTP(S) URLs.
/// params_json: optional JSON string to inject as data_bag (agent mode).
const TlsClientAuth = struct {
    cert: ?[]const u8 = null,
    key: ?[]const u8 = null,
};

pub fn runScript(allocator: std.mem.Allocator, script_path_or_url: []const u8, use_pretty_output: bool, params_json: ?[]const u8, secrets_json: ?[]const u8, tls_auth: TlsClientAuth) !provision.ProvisionResult {
    const is_url = std.mem.startsWith(u8, script_path_or_url, "http://") or
        std.mem.startsWith(u8, script_path_or_url, "https://");

    var temp_file_path: ?[]const u8 = null;
    defer if (temp_file_path) |path| {
        std.fs.deleteFileAbsolute(path) catch {};
        allocator.free(path);
    };

    const script_path = if (is_url) blk: {
        const uri = std.Uri.parse(script_path_or_url) catch |err| {
            std.debug.print("Error: Invalid URL: {}\n", .{err});
            return error.InvalidUrl;
        };

        const display_url = if (uri.password != null) display_blk: {
            const user_part = if (uri.user) |u| u.percent_encoded else "";
            const host_part = if (uri.host) |h| h.percent_encoded else "";
            break :display_blk try std.fmt.allocPrint(allocator, "{s}://{s}:***@{s}{s}", .{
                uri.scheme,
                user_part,
                host_part,
                uri.path.percent_encoded,
            });
        } else script_path_or_url;
        defer if (uri.password != null) allocator.free(display_url);

        std.debug.print("[fetch] Downloading provision script from {s}\n", .{display_url});

        const temp_dir = std.process.getEnvVarOwned(allocator, "TMPDIR") catch
            try allocator.dupe(u8, "/tmp");
        defer allocator.free(temp_dir);

        var rand_buf: [8]u8 = undefined;
        std.crypto.random.bytes(&rand_buf);
        const rand_hex = std.fmt.bytesToHex(rand_buf, .lower);
        const temp_file = try std.fmt.allocPrint(allocator, "{s}/provision-{d}-{s}.rb", .{ temp_dir, std.time.timestamp(), &rand_hex });
        temp_file_path = temp_file;

        const cfg = http.Config{
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
            std.debug.print("URL: {s}\n", .{display_url});
            std.debug.print("\nPossible reasons:\n", .{});
            std.debug.print("  • URL is not accessible\n", .{});
            std.debug.print("  • Network connectivity issues\n", .{});
            std.debug.print("  • Invalid credentials (if using Basic Auth)\n", .{});
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

        const file = try std.fs.cwd().createFile(temp_file, .{ .exclusive = true });
        defer file.close();
        try file.writeAll(response.body);

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

    const script_path_or_url = res.positionals[0] orelse return printHelp("Missing provision file path or URL.");

    var use_pretty_output = true;
    if (res.args.output) |output_mode| {
        if (std.mem.eql(u8, output_mode, "plain")) {
            use_pretty_output = false;
        } else if (std.mem.eql(u8, output_mode, "pretty")) {
            use_pretty_output = true;
        } else {
            std.debug.print("Invalid output mode: {s}\n", .{output_mode});
            std.debug.print("Valid modes: pretty, plain\n", .{});
            return error.InvalidOutputMode;
        }
    }

    const logger = @import("../logger.zig");
    const tls_auth = TlsClientAuth{
        .cert = res.args.@"client-cert",
        .key = res.args.@"client-key",
    };
    var result = runScript(allocator, script_path_or_url, use_pretty_output, res.args.params, res.args.secrets, tls_auth) catch |err| {
        std.debug.print("Provision failed: {}\n", .{err});
        if (logger.getLogPath()) |log_path| {
            std.debug.print("Log file: {s}\n", .{log_path});
        }
        return;
    };
    defer result.deinit(allocator);
}

fn printHelp(reason: ?[]const u8) !void {
    const out = std.fs.File.stdout();
    if (reason) |msg| {
        try out.writeAll(msg);
        try out.writeAll("\n\n");
    }
    try out.writeAll(
        \\provision
        \\  hola provision [OPTIONS] <file-or-url>
        \\
        \\Run a provisioning script that defines infrastructure resources.
        \\Supports both local files and remote URLs.
        \\
        \\Options:
        \\  -o, --output MODE        Output mode: pretty (default) or plain
        \\  -p, --params JSON        JSON string to inject as data_bag
        \\  -s, --secrets JSON       JSON string to inject as secrets_bag
        \\      --client-cert PATH   Client certificate for mTLS (PEM)
        \\      --client-key PATH    Client private key for mTLS (PEM)
        \\
        \\Examples
        \\  # Local file
        \\  hola provision provision.rb
        \\  hola provision ~/.config/hola/provision.rb
        \\
        \\  # Remote URL
        \\  hola provision https://example.com/provision.rb
        \\  hola provision https://username:password@example.com/provision.rb
        \\  hola provision https://raw.githubusercontent.com/user/dotfiles/master/.config/hola/provision.rb
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
