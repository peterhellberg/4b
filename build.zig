const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---- 4a assembler (pure Zig) -------------------------------------------
    const exe = b.addExecutable(.{
        .name = "4a",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("compile", "Run 4a");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const vm_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/vm.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_vm_tests = b.addRunArtifact(vm_tests);
    test_step.dependOn(&run_vm_tests.step);

    const asm_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/asm.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_asm_tests = b.addRunArtifact(asm_tests);
    test_step.dependOn(&run_asm_tests.step);

    // ---- 4b console (Zig VM + C raylib) ------------------------------------
    const raylib_dep = b.lazyDependency("raylib", .{
        .target = target,
        .optimize = optimize,
    }) orelse return;

    const raylib = raylib_dep.artifact("raylib");

    const vm_lib = b.addLibrary(.{
        .name = "vm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/vm.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const asm_lib = b.addLibrary(.{
        .name = "asm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/asm.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const console = b.addExecutable(.{
        .name = "4b",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    console.root_module.addCSourceFile(.{
        .file = b.path("src/console.c"),
        .flags = &.{"-std=c23"},
    });
    console.root_module.addIncludePath(raylib_dep.path("src"));
    console.root_module.linkLibrary(raylib);
    console.root_module.linkLibrary(vm_lib);
    console.root_module.linkLibrary(asm_lib);
    b.installArtifact(console);

    const run_console = b.addRunArtifact(console);
    run_console.step.dependOn(b.getInstallStep());
    if (b.args) |a| run_console.addArgs(a);
    b.step("run", "Run 4b").dependOn(&run_console.step);

    // ---- assemble example ROMs ----------------------------------------------
    const compile_step = b.step("examples", "Assemble example .4b files");
    const example_files = [_][]const u8{
        "hello",
        "line",
        "fill",
        "move",
        "bounce",
    };
    for (example_files) |name| {
        const src = std.fmt.allocPrint(b.allocator, "examples/{s}.4a", .{name}) catch continue;
        const dst = std.fmt.allocPrint(b.allocator, "examples/{s}.4b", .{name}) catch continue;
        const compile = b.addRunArtifact(exe);
        compile.addFileArg(b.path(src));
        compile.addArgs(&.{ "-o", dst });
        compile_step.dependOn(&compile.step);
    }
}
