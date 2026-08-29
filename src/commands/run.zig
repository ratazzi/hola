const std = @import("std");
const clap = @import("clap");
const provision = @import("../provision.zig");
const modern_display = @import("../modern_provision_display.zig");
const global_io = @import("../global_io.zig");
const common = @import("common.zig");
const mruby = @import("../mruby.zig");

const params = clap.parseParamsComptime(
    \\-h, --help                   Show help for run
    \\-f, --rakefile <PATH>        Use PATH as the Rakefile
    \\-T, --tasks                  List described tasks
    \\-P, --prerequisites          Show task prerequisites
    \\-n, --dry-run                Show tasks without executing actions
    \\-t, --trace                  Trace task invocation and execution
    \\-o, --output <MODE>          Output mode: pretty or plain
    \\    --data-bag <JSON>        JSON string to inject as data_bag
    \\    --data-bag-url <URL>     Fetch data_bag JSON from URL
    \\    --secrets-bag <JSON>     JSON string to inject as secrets_bag
    \\    --secrets-bag-url <URL>  Fetch secrets_bag JSON from URL
    \\    --client-cert <PATH>     Client certificate for mTLS
    \\    --client-key <PATH>      Client private key for mTLS
    \\<task>...
    \\
);

const parsers = .{
    .PATH = clap.parsers.string,
    .MODE = clap.parsers.string,
    .JSON = clap.parsers.string,
    .URL = clap.parsers.string,
    .task = clap.parsers.string,
};

pub const RAKEFILE_NAMES = [_][]const u8{ "Rakefile", "rakefile", "Rakefile.rb", "rakefile.rb" };
pub const RunError = error{ NoRakefile, TaskFailed };

pub const Located = struct {
    allocator: std.mem.Allocator,
    dir: []const u8,
    path: []const u8,

    pub fn deinit(self: *Located) void {
        self.allocator.free(self.dir);
        self.allocator.free(self.path);
        self.* = undefined;
    }
};

const RunArgs = struct {
    rakefile: ?[]const u8,
    list_tasks: bool,
    list_prerequisites: bool,
    dry_run: bool,
    trace: bool,
    output: ?[]const u8,
    data_bag: ?[]const u8,
    data_bag_url: ?[]const u8,
    secrets_bag: ?[]const u8,
    secrets_bag_url: ?[]const u8,
    client_cert: ?[]const u8,
    client_key: ?[]const u8,
    tasks: []const []const u8,
};

pub fn run(allocator: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    var diag = clap.Diagnostic{};
    var parsed = clap.parseEx(clap.Help, &params, parsers, iter, .{
        .allocator = allocator,
        .diagnostic = &diag,
    }) catch |err| {
        try diag.reportToFile(global_io.io(), std.Io.File.stderr(), err);
        std.process.exit(1);
    };
    defer parsed.deinit();

    if (parsed.args.help != 0) return printHelp();
    const args = fromParsed(parsed);
    const exit_code = runWithArgs(allocator, args, null) catch |err| switch (err) {
        error.NoRakefile => blk: {
            printNoRakefile();
            break :blk @as(u8, 1);
        },
        else => return err,
    };
    if (exit_code != 0) std.process.exit(exit_code);
}

pub fn runImplicit(allocator: std.mem.Allocator, first_task: []const u8, iter: *std.process.Args.Iterator) RunError!void {
    var diag = clap.Diagnostic{};
    var parsed = clap.parseEx(clap.Help, &params, parsers, iter, .{
        .allocator = allocator,
        .diagnostic = &diag,
    }) catch |err| {
        diag.reportToFile(global_io.io(), std.Io.File.stderr(), err) catch {};
        return error.TaskFailed;
    };
    defer parsed.deinit();

    if (parsed.args.help != 0) {
        printHelp() catch {};
        return;
    }
    const exit_code = runWithArgs(allocator, fromParsed(parsed), first_task) catch |err| switch (err) {
        error.NoRakefile => return error.NoRakefile,
        else => {
            std.debug.print("hola run failed: {}\n", .{err});
            return error.TaskFailed;
        },
    };
    if (exit_code != 0) return error.TaskFailed;
}

fn fromParsed(parsed: anytype) RunArgs {
    return .{
        .rakefile = parsed.args.rakefile,
        .list_tasks = parsed.args.tasks != 0,
        .list_prerequisites = parsed.args.prerequisites != 0,
        .dry_run = parsed.args.@"dry-run" != 0,
        .trace = parsed.args.trace != 0,
        .output = parsed.args.output,
        .data_bag = parsed.args.@"data-bag",
        .data_bag_url = parsed.args.@"data-bag-url",
        .secrets_bag = parsed.args.@"secrets-bag",
        .secrets_bag_url = parsed.args.@"secrets-bag-url",
        .client_cert = parsed.args.@"client-cert",
        .client_key = parsed.args.@"client-key",
        .tasks = parsed.positionals[0],
    };
}

fn runWithArgs(allocator: std.mem.Allocator, args: RunArgs, leading_task: ?[]const u8) !u8 {
    const io = global_io.io();
    const use_pretty_output = try common.parseOutputMode(args.output);
    var bags = try common.resolveBags(allocator, .{
        .data_bag = args.data_bag,
        .data_bag_url = args.data_bag_url,
        .secrets_bag = args.secrets_bag,
        .secrets_bag_url = args.secrets_bag_url,
        .client_cert = args.client_cert,
        .client_key = args.client_key,
    });
    defer bags.deinit();

    const original_cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
    defer allocator.free(original_cwd);

    var located = if (args.rakefile) |rakefile| blk: {
        const canonical_path = try std.Io.Dir.cwd().realPathFileAlloc(io, rakefile, allocator);
        defer allocator.free(canonical_path);
        const path = try allocator.dupe(u8, canonical_path);
        errdefer allocator.free(path);
        const parent = std.fs.path.dirname(path) orelse original_cwd;
        break :blk Located{
            .allocator = allocator,
            .dir = try allocator.dupe(u8, parent),
            .path = path,
        };
    } else (try findRakefile(allocator, io, original_cwd)) orelse return error.NoRakefile;
    defer located.deinit();

    try std.Io.Threaded.chdir(located.dir);
    if (!std.mem.eql(u8, original_cwd, located.dir)) {
        std.debug.print("(in {s})\n", .{located.dir});
    }

    const session = try provision.Session.open(allocator, .{
        .params_json = bags.data_bag,
        .secrets_json = bags.secrets_bag,
        .mode = .task,
    });
    defer session.close();
    const mrb = session.mrb.mrb orelse return error.MRubyNotInitialized;
    session.mrb.setGlobal("$hola_run_list", if (args.list_tasks) mruby.zig_mrb_true_value() else mruby.zig_mrb_false_value());
    session.mrb.setGlobal("$hola_run_prerequisites", if (args.list_prerequisites) mruby.zig_mrb_true_value() else mruby.zig_mrb_false_value());
    session.mrb.setGlobal("$hola_run_dry", if (args.dry_run) mruby.zig_mrb_true_value() else mruby.zig_mrb_false_value());
    session.mrb.setGlobal("$hola_run_trace", if (args.trace) mruby.zig_mrb_true_value() else mruby.zig_mrb_false_value());
    session.mrb.setGlobal("$hola_run_pretty", if (use_pretty_output) mruby.zig_mrb_true_value() else mruby.zig_mrb_false_value());
    session.mrb.setGlobal("$hola_run_capture_output", if (!args.list_tasks and !args.list_prerequisites) mruby.zig_mrb_true_value() else mruby.zig_mrb_false_value());
    try session.loadTaskPrelude();

    const argv = mrubyArgv(mrb, allocator, leading_task, args.tasks);
    session.mrb.setGlobal("$hola_run_argv", argv);
    session.mrb.setGlobal("$hola_rakefile", mruby.mrb_str_new(mrb, located.path.ptr, @intCast(located.path.len)));

    var display: ?modern_display.ModernProvisionDisplay = null;
    if (!args.list_tasks and !args.list_prerequisites) {
        display = try modern_display.ModernProvisionDisplay.init(allocator, use_pretty_output);
        session.runner.attachDisplay(&display.?);
        display.?.setTotalResources(0);
        session.runner.start_time = std.Io.Timestamp.now(io, .real).toNanoseconds();
        try display.?.startTimer(session.runner.start_time);
    }
    defer if (display) |*active_display| {
        session.runner.detachDisplay();
        active_display.deinit();
    };

    session.evalScript(located.path) catch {
        std.debug.print("rake aborted!\nFailed to load {s}\n", .{located.path});
        return 1;
    };
    session.evalString("Hola::Rake.main") catch return 1;

    const status = session.mrb.getGlobal("$hola_run_status");
    const exit_code: u8 = if (!mruby.mrb_test(status)) 1 else @intCast(mruby.mrb_fixnum(mrb, status));
    if (display) |*active_display| {
        if (exit_code != 0) active_display.markRunFailed();
        try active_display.showTaskSummaryWithDuration(0, 0);
    }
    return exit_code;
}

fn mrubyArgv(mrb: *mruby.mrb_state, allocator: std.mem.Allocator, leading_task: ?[]const u8, tasks: []const []const u8) mruby.mrb_value {
    _ = allocator;
    const count = tasks.len + @intFromBool(leading_task != null);
    const argv = mruby.mrb_ary_new_capa(mrb, @intCast(count));
    if (leading_task) |task_name| {
        mruby.mrb_ary_push(mrb, argv, mruby.mrb_str_new(mrb, task_name.ptr, @intCast(task_name.len)));
    }
    for (tasks) |task_name| {
        mruby.mrb_ary_push(mrb, argv, mruby.mrb_str_new(mrb, task_name.ptr, @intCast(task_name.len)));
    }
    return argv;
}

pub fn findRakefile(allocator: std.mem.Allocator, io: std.Io, start_dir: []const u8) !?Located {
    var current = try allocator.dupe(u8, start_dir);
    errdefer allocator.free(current);

    while (true) {
        for (RAKEFILE_NAMES) |name| {
            const candidate = try std.fs.path.join(allocator, &.{ current, name });
            std.Io.Dir.cwd().access(io, candidate, .{}) catch {
                allocator.free(candidate);
                continue;
            };
            return .{ .allocator = allocator, .dir = current, .path = candidate };
        }

        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }
    allocator.free(current);
    return null;
}

fn printNoRakefile() void {
    std.debug.print("No Rakefile found (looking for: Rakefile, rakefile, Rakefile.rb, rakefile.rb)\n", .{});
}

fn printHelp() !void {
    try std.Io.File.stdout().writeStreamingAll(global_io.io(),
        \\run
        \\  hola run [OPTIONS] [TASK[ARGS] ...]
        \\
        \\Run Rake-compatible tasks backed by hola resources and embedded mruby.
        \\
        \\Options:
        \\  -h, --help           Show this help
        \\  -f, --rakefile PATH  Use an explicit Rakefile
        \\  -T, --tasks          List tasks with descriptions
        \\  -P, --prerequisites  Show task prerequisites
        \\  -n, --dry-run        Trace tasks without executing their actions
        \\  -t, --trace          Trace task invocation and execution
        \\  -o, --output MODE    Output mode: pretty or plain
        \\      --data-bag JSON        Inject data_bag JSON
        \\      --data-bag-url URL     Fetch data_bag JSON
        \\      --secrets-bag JSON     Inject secrets_bag JSON
        \\      --secrets-bag-url URL  Fetch secrets_bag JSON
        \\      --client-cert PATH     Client certificate for mTLS bag URLs
        \\      --client-key PATH      Client private key for mTLS bag URLs
        \\
        \\Examples:
        \\  hola run
        \\  hola run build
        \\  hola run "db:migrate[production]"
        \\  hola build                 # implicit task fallback
        \\
        \\Compatibility notes:
        \\  file and directory use standard Rake semantics in task mode. Hola's
        \\  provision variants are Hola::Resources.file and .directory.
        \\  file_task remains available as a compatibility alias for file.
        \\  Dir.glob, FileList, suffix rules, local require/require_relative, and
        \\  rake/clean are supported. Regexp, native gems, backticks, exit, and the
        \\  sh block form are not available in the embedded mruby runtime.
        \\
    );
}

test "findRakefile searches parent directories in precedence order" {
    const allocator = std.testing.allocator;
    const io = global_io.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "project", .default_dir);
    try tmp.dir.createDir(io, "project/nested", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "project/Rakefile", .data = "task :default" });
    const nested = try tmp.dir.realPathFileAlloc(io, "project/nested", allocator);
    defer allocator.free(nested);

    var located = (try findRakefile(allocator, io, nested)) orelse return error.TestExpectedRakefile;
    defer located.deinit();
    try std.testing.expect(std.mem.endsWith(u8, located.path, "/project/Rakefile"));
}
