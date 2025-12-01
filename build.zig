const std = @import("std");
const builtin = @import("builtin");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) !void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    const strip = b.option(bool, "strip", "Strip debug info");

    // Determine which hola_deps package to use based on target platform
    const hola_deps_name = if (target.result.os.tag == .linux)
        "hola_deps_linux_x86_64"
    else
        "hola_deps_macos_arm64";

    const hola_deps_dep = b.dependency(hola_deps_name, .{
        .target = target,
        .optimize = optimize,
    });
    const deps_path = hola_deps_dep.path(".").getPath(b);
    const final_mruby_path = b.fmt("{s}/mruby", .{deps_path});
    const final_libgit2_path = deps_path;

    const clap_dep = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    });
    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    const ansi_term_dep = b.dependency("ansi_term", .{
        .target = target,
        .optimize = optimize,
    });
    const toml_dep = b.dependency("toml", .{
        .target = target,
        .optimize = optimize,
    });
    const zeit_dep = b.dependency("zeit", .{
        .target = target,
        .optimize = optimize,
    });

    // Generate executable name with architecture
    // Format: hola-{os}-{arch} (e.g., hola-macos-aarch64, hola-linux-x86_64)
    const exe_name = b.fmt("hola-{s}-{s}", .{
        @tagName(target.result.os.tag),
        @tagName(target.result.cpu.arch),
    });

    // Create build options for version info
    const options = b.addOptions();

    // Add nightly build option
    const is_nightly = b.option(bool, "nightly", "Build as nightly version") orelse false;
    options.addOption(bool, "is_nightly", is_nightly);

    // Read version from build.zig.zon by parsing the file
    const version = blk: {
        const build_zig_zon = @embedFile("build.zig.zon") ++ "";
        var buffer: [10 * build_zig_zon.len]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buffer);
        const parsed = std.zon.parse.fromSlice(
            struct { version: []const u8 },
            fba.allocator(),
            build_zig_zon[0 .. :0],
            null,
            .{ .ignore_unknown_fields = true },
        ) catch break :blk "0.0.0";
        break :blk parsed.version;
    };
    options.addOption([]const u8, "version", version);

    // Get git commit hash
    const git_commit = blk: {
        const result = b.run(&.{ "git", "rev-parse", "--short=7", "HEAD" });
        const commit = std.mem.trim(u8, result, &std.ascii.whitespace);
        if (commit.len == 0) break :blk "unknown";
        break :blk b.dupe(commit);
    };
    options.addOption([]const u8, "git_commit", git_commit);

    // Define the main executable
    const exe = b.addExecutable(.{
        .name = exe_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            // List of external dependencies available for import
            .imports = &.{
                .{ .name = "clap", .module = clap_dep.module("clap") },
                .{ .name = "vaxis", .module = vaxis_dep.module("vaxis") },
                .{ .name = "ansi_term", .module = ansi_term_dep.module("ansi_term") },
                .{ .name = "toml", .module = toml_dep.module("toml") },
                .{ .name = "zeit", .module = zeit_dep.module("zeit") },
                .{ .name = "build_options", .module = options.createModule() },
            },
        }),
    });

    if (strip) |s| {
        exe.root_module.strip = s;
    }

    // Add mruby header file path
    exe.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{final_mruby_path}) });

    // Link mruby static library directly (no need to add library path since we specify full path)
    exe.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libmruby.a", .{final_mruby_path}) });
    exe.linkLibC();

    // For Linux cross-compilation, provide linker symbols that mruby expects
    if (target.result.os.tag == .linux) {
        exe.root_module.link_libc = true;
        exe.addAssemblyFile(b.path("src/linux_linker_shims.s"));
    }

    // Platform-specific configuration
    if (target.result.os.tag == .macos) {
        // macOS: Link Foundation framework for AppleScript support
        exe.linkFramework("Foundation");
        // Add Objective-C bridge file for runtime calls
        // Note: .m files are compiled as Objective-C
        exe.addCSourceFile(.{ .file = b.path("src/applescript_bridge.m"), .flags = &.{"-fobjc-arc"} });
        // Add CFPreferences C wrapper
        exe.addCSourceFile(.{ .file = b.path("src/cfprefs_wrapper.c"), .flags = &.{} });
    }

    // Add mruby helpers for array handling
    exe.addCSourceFile(.{ .file = b.path("src/mruby_helpers.c"), .flags = &.{} });
    configureLibGit2(exe, b, final_libgit2_path, target.result.os.tag);

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Create test executable for the main executable's root module
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    configureLibGit2(exe_tests, b, final_libgit2_path, target.result.os.tag);

    // Run step for the test executable
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // Top level step for running all tests
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}

fn configureLibGit2(step: *std.Build.Step.Compile, b: *std.Build, libgit2_path: []const u8, os_tag: std.Target.Os.Tag) void {
    // All platforms use hola_deps package with unified structure
    step.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{libgit2_path}) });

    // Add libgit2 and libcurl
    step.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libgit2.a", .{libgit2_path}) });
    step.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libcurl.a", .{libgit2_path}) });

    // Shared dependencies (needed by both libgit2 and libcurl)
    step.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libssl.a", .{libgit2_path}) });
    step.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libcrypto.a", .{libgit2_path}) });
    step.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libssh2.a", .{libgit2_path}) });
    step.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libz.a", .{libgit2_path}) });
    step.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libpcre2-8.a", .{libgit2_path}) });
    step.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libhttp_parser.a", .{libgit2_path}) });

    // curl-specific dependencies
    step.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libnghttp2.a", .{libgit2_path}) });
    step.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libnghttp3.a", .{libgit2_path}) });
    step.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libbrotlicommon.a", .{libgit2_path}) });
    step.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libbrotlidec.a", .{libgit2_path}) });
    step.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libbrotlienc.a", .{libgit2_path}) });
    step.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libzstd.a", .{libgit2_path}) });
    step.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libcares.a", .{libgit2_path}) });
    step.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libidn2.a", .{libgit2_path}) });
    step.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libpsl.a", .{libgit2_path}) });
    step.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libunistring.a", .{libgit2_path}) });

    // Platform-specific system libraries
    if (os_tag == .macos) {
        // On macOS, link system frameworks
        const result = b.run(&.{ "xcrun", "--show-sdk-path" });
        const sdk_path = std.mem.trim(u8, result, &std.ascii.whitespace);

        step.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{sdk_path}) });
        step.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sdk_path}) });
        step.addFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk_path}) });

        step.linkSystemLibrary("iconv");
        step.linkFramework("CoreFoundation");
        step.linkFramework("Security");
    }
}
