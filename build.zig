const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---- 4a assembler (pure Zig) -------------------------------------------
    const assembler = b.addExecutable(.{
        .name = "4a",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/4a.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(assembler);

    const run_cmd = b.addRunArtifact(assembler);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const asm_step = b.step("4a", "Assemble with 4a");
    asm_step.dependOn(&run_cmd.step);
    b.step("assemble", "Alias for 4a").dependOn(asm_step);

    const unit_tests = b.addTest(.{ .root_module = assembler.root_module });
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
    const compiler = b.addExecutable(.{
        .name = "4c",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/4c.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(compiler);

    const run_c_cmd = b.addRunArtifact(compiler);
    run_c_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_c_cmd.addArgs(args);
    const compile_step = b.step("4c", "Compile with 4c");
    compile_step.dependOn(&run_c_cmd.step);
    b.step("compile", "Alias for 4c").dependOn(compile_step);

    const compiler_tests = b.addTest(.{ .root_module = compiler.root_module });
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

    if (!addRaylib(console.root_module, b.lazyDependency("raylib", .{
        .target = target,
        .optimize = optimize,
    }) orelse return)) return;

    console.root_module.linkLibrary(vm_lib);
    console.root_module.linkLibrary(asm_lib);
    console.root_module.linkLibrary(compile_lib);
    b.installArtifact(console);

    const run_console = b.addRunArtifact(console);
    run_console.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_console.addArgs(args);
    const console_step = b.step("4b", "Run ROM in the console");
    console_step.dependOn(&run_console.step);
    b.step("run", "Alias for 4b").dependOn(console_step);

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
        const assemble = b.addRunArtifact(assembler);
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
        const compile = b.addRunArtifact(compiler);
        compile.addFileArg(b.path(src));
        compile.addArgs(&.{ "-o", dst });
        examples_step.dependOn(&compile.step);
    }
}

/// Compile raylib (desktop GLFW backend) directly into the given module and
/// link its platform libraries, instead of linking the dependency's static
/// archive, which embeds resolved system libraries as archive members and
/// makes the linker emit warnings for each of them.
///
/// Returns false when the target platform is unsupported.
fn addRaylib(
    mod: *std.Build.Module,
    raylib_dep: *std.Build.Dependency,
) bool {
    const target = mod.resolved_target.?.result;

    const rl_src = raylib_dep.path("src");

    mod.addIncludePath(rl_src);
    mod.addIncludePath(raylib_dep.path("src/platforms"));
    mod.addIncludePath(raylib_dep.path("src/external/glfw/include"));

    mod.addCMacro("_GNU_SOURCE", "");
    mod.addCMacro("GL_SILENCE_DEPRECATION", "199309L");
    mod.addCMacro("SUPPORT_MODULE_RSHAPES", "1");
    mod.addCMacro("SUPPORT_MODULE_RTEXTURES", "1");
    mod.addCMacro("SUPPORT_MODULE_RTEXT", "1");
    mod.addCMacro("SUPPORT_MODULE_RMODELS", "1");
    mod.addCMacro("SUPPORT_MODULE_RAUDIO", "1");
    mod.addCMacro("PLATFORM_DESKTOP_GLFW", "");
    mod.addCMacro("GRAPHICS_API_OPENGL_33", "");

    switch (target.os.tag) {
        .linux => {
            mod.addCMacro("_GLFW_X11", "");
            inline for (.{ "GL", "X11", "Xrandr", "Xinerama", "Xi", "Xcursor" }) |lib| {
                mod.linkSystemLibrary(lib, .{});
            }
        },
        .windows => {
            inline for (.{ "opengl32", "winmm", "gdi32" }) |lib| {
                mod.linkSystemLibrary(lib, .{});
            }
        },
        .macos => {
            inline for (.{ "Foundation", "CoreServices", "CoreGraphics", "AppKit", "IOKit", "QuartzCore" }) |fw| {
                mod.linkFramework(fw, .{});
            }
        },
        else => return false,
    }

    mod.addCSourceFiles(.{
        .root = rl_src,
        .files = &.{
            "rcore.c",
            "rshapes.c",
            "rtextures.c",
            "rtext.c",
            "rmodels.c",
            "raudio.c",
        },
        .flags = &.{"-std=c99"},
    });

    // rglfw.c includes Objective-C on macOS and must be compiled separately.
    const glfw_flags: []const []const u8 = if (target.os.tag == .macos)
        &.{ "-std=c99", "-ObjC" }
    else
        &.{"-std=c99"};
    mod.addCSourceFile(.{
        .file = raylib_dep.path("src/rglfw.c"),
        .flags = glfw_flags,
    });

    return true;
}
