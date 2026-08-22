const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---- 4a assembler (pure Zig) -------------------------------------------
    const exe = b.addExecutable(.{
        .name = "4a",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/4a.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("asm", "Run 4a");
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

    const compile_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/compile.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_compile_tests = b.addRunArtifact(compile_tests);
    test_step.dependOn(&run_compile_tests.step);

    // ---- 4c compiler (pure Zig) ---------------------------------------------
    const cexe = b.addExecutable(.{
        .name = "4c",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/4c.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(cexe);

    const run_c_cmd = b.addRunArtifact(cexe);
    run_c_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_c_cmd.addArgs(args);
    b.step("4c", "Run 4c").dependOn(&run_c_cmd.step);

    const compiler_tests = b.addTest(.{ .root_module = cexe.root_module });
    const run_compiler_tests = b.addRunArtifact(compiler_tests);
    test_step.dependOn(&run_compiler_tests.step);

    const compile_lib = b.addLibrary(.{
        .name = "compile",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/compile.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

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
        .file = b.path("src/4b.c"),
        .flags = &.{"-std=c23"},
    });
    console.root_module.addIncludePath(raylib_dep.path("src"));
    console.root_module.linkLibrary(raylib);
    console.root_module.linkLibrary(vm_lib);
    console.root_module.linkLibrary(asm_lib);
    console.root_module.linkLibrary(compile_lib);
    b.installArtifact(console);

    const run_console = b.addRunArtifact(console);
    run_console.step.dependOn(b.getInstallStep());
    if (b.args) |a| run_console.addArgs(a);
    b.step("run", "Run 4b").dependOn(&run_console.step);

    // ---- build example ROMs ---------------------------------------------------
    const examples_step = b.step("examples", "Assemble/compile example .4b files");
    const asm_examples = [_][]const u8{
        "hello",
        "line",
        "fill",
    };
    for (asm_examples) |name| {
        const src = std.fmt.allocPrint(b.allocator, "examples/{s}.4a", .{name}) catch continue;
        const dst = std.fmt.allocPrint(b.allocator, "examples/{s}.4b", .{name}) catch continue;
        const assemble = b.addRunArtifact(exe);
        assemble.addFileArg(b.path(src));
        assemble.addArgs(&.{ "-o", dst });
        examples_step.dependOn(&assemble.step);
    }

    const c_examples = [_][]const u8{
        "move",
        "bounce",
        "updown",
    };
    for (c_examples) |name| {
        const src = std.fmt.allocPrint(b.allocator, "examples/{s}.4c", .{name}) catch continue;
        const dst = std.fmt.allocPrint(b.allocator, "examples/{s}.4b", .{name}) catch continue;
        const compile = b.addRunArtifact(cexe);
        compile.addFileArg(b.path(src));
        compile.addArgs(&.{ "-o", dst });
        examples_step.dependOn(&compile.step);
    }
}
