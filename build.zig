const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
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

    // Define paths for external libraries with platform defaults
    const mruby_path = b.option([]const u8, "mruby_path", "Path to mruby installation") orelse
        if (target.result.os.tag == .macos) "/opt/homebrew/Cellar/mruby/3.4.0" else "/usr";
    const libgit2_path = b.option([]const u8, "libgit2_path", "Path to libgit2 installation") orelse
        if (target.result.os.tag == .macos) "/opt/homebrew/opt/libgit2" else "/usr";

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

    // Define the main executable
    const exe = b.addExecutable(.{
        .name = "hola",
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
            },
        }),
    });

    // Add mruby header file path
    exe.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{mruby_path}) });

    // Add mruby library file path
    exe.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{mruby_path}) });

    // Link mruby static library
    exe.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libmruby.a", .{mruby_path}) });
    exe.linkLibC();

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
    configureLibGit2(exe, b, libgit2_path, target.result.os.tag);

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
    configureLibGit2(exe_tests, b, libgit2_path, target.result.os.tag);

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
    step.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{libgit2_path}) });

    if (os_tag == .macos) {
        // macOS: use static libraries from Homebrew
        step.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libgit2.a", .{libgit2_path}) });
        step.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libssh2.a", .{if (std.mem.eql(u8, libgit2_path, "/usr")) "/usr" else "/opt/homebrew/opt/libssh2"}) });
        step.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libssl.a", .{if (std.mem.eql(u8, libgit2_path, "/usr")) "/usr" else "/opt/homebrew/opt/openssl@3"}) });
        step.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libcrypto.a", .{if (std.mem.eql(u8, libgit2_path, "/usr")) "/usr" else "/opt/homebrew/opt/openssl@3"}) });
        step.linkSystemLibrary("z");
        step.linkSystemLibrary("iconv");
        step.linkFramework("CoreFoundation");
        step.linkFramework("Security");
    } else {
        // Linux: use static libraries (built from source)
        // Default paths assume libraries are in /usr/local/lib
        const static_lib_path = if (std.mem.eql(u8, libgit2_path, "/usr")) "/usr/local" else libgit2_path;
        step.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libgit2.a", .{static_lib_path}) });
        step.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libssh2.a", .{static_lib_path}) });
        step.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libssl.a", .{static_lib_path}) });
        step.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libcrypto.a", .{static_lib_path}) });
        step.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libz.a", .{static_lib_path}) });
        step.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libpcre2-8.a", .{static_lib_path}) });
        step.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libhttp_parser.a", .{static_lib_path}) });
    }
}
