const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---- modules ------------------------------------------------------------
    //
    // Shared leaf modules. The 4a/4c implementations reach these through
    // named imports (not file paths) so that the same implementation file can
    // serve as the root of both a CLI executable and an embeddable static
    // library without any file belonging to two module graphs.
    const dia_mod = zigModule(b, "src/dia.zig", target, optimize);
    const isa_mod = zigModule(b, "src/isa.zig", target, optimize);
    const rom_mod = zigModule(b, "src/rom.zig", target, optimize);

    const shared_imports = [_]std.Build.Module.Import{
        .{ .name = "dia", .module = dia_mod },
        .{ .name = "isa", .module = isa_mod },
        .{ .name = "rom", .module = rom_mod },
    };

    const asm_mod = b.createModule(.{
        .root_source_file = b.path("src/assembler.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &shared_imports,
    });

    const com_mod = b.createModule(.{
        .root_source_file = b.path("src/4c/compiler.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &shared_imports,
    });

    // ---- 4a assembler -----------------------------------------------------------
    const assembler = b.addExecutable(.{
        .name = "4a",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/4a.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "assembler", .module = asm_mod },
                .{ .name = "dia", .module = dia_mod },
            },
        }),
    });
    b.installArtifact(assembler);

    // ---- 4b box (C + Zig VM/assembler/compiler + C raylib) ------------------
    const vm_lib = b.addLibrary(.{
        .name = "vm",
        .root_module = zigModule(b, "src/vm.zig", target, optimize),
    });

    const asm_lib = b.addLibrary(.{
        .name = "asm",
        .root_module = asm_mod,
    });

    const com_lib = b.addLibrary(.{
        .name = "compile",
        .root_module = com_mod,
    });

    const box = b.addExecutable(.{
        .name = "4b",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    box.root_module.addCSourceFile(.{
        .file = b.path("src/4b.c"),
        .flags = &.{"-std=c23"},
    });

    if (!addRaylib(box.root_module, b.lazyDependency("raylib", .{
        .target = target,
        .optimize = optimize,
    }) orelse return)) return;

    box.root_module.linkLibrary(vm_lib);
    box.root_module.linkLibrary(asm_lib);
    box.root_module.linkLibrary(com_lib);
    b.installArtifact(box);

    // ---- 4c compiler ------------------------------------------------------------
    const compiler = b.addExecutable(.{
        .name = "4c",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/4c.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "compiler", .module = com_mod },
                .{ .name = "dia", .module = dia_mod },
                .{ .name = "rom", .module = rom_mod },
            },
        }),
    });
    b.installArtifact(compiler);

    // ---- run steps ----------------------------------------------------------
    addRunStep(b, assembler, "4a", "Assemble with 4a", "assemble");
    addRunStep(b, compiler, "4c", "Compile with 4c", "compile");
    addRunStep(b, box, "4b", "Run with 4b", "run");

    // ---- tests ----------------------------------------------------------------
    const test_step = b.step("test", "Run unit tests");

    const suites = [_]*std.Build.Module{
        assembler.root_module, // CLI + golden/negative assembler tests
        asm_mod, // assembler pipeline tests
        rom_mod, // bit-packing tests
        compiler.root_module, // CLI tests
        com_mod, // compiler pipeline tests
        vm_lib.root_module, // VM opcode tests
    };

    for (suites) |suite| {
        const suite_tests = b.addTest(.{ .root_module = suite });
        const run_suite_tests = b.addRunArtifact(suite_tests);
        test_step.dependOn(&run_suite_tests.step);
    }

    // ---- examples ---------------------------------------------------------------
    const examples_step = b.step("examples", "Assemble/compile example ROMs");

    for ([_][]const u8{ "halt", "line", "fill" }) |name| {
        addExample(b, examples_step, assembler, name, "4a");
    }

    for ([_][]const u8{ "move", "diag", "dpad" }) |name| {
        addExample(b, examples_step, compiler, name, "4c");
    }
}

/// Create a plain Zig module for the given source file.
fn zigModule(
    b: *std.Build,
    root_source_file: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(root_source_file),
        .target = target,
        .optimize = optimize,
    });
}

/// Add a step that runs an installed executable with the command line args
/// given on the zig build invocation, plus an optional alias step.
fn addRunStep(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    name: []const u8,
    description: []const u8,
    alias: ?[]const u8,
) void {
    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);

    const step = b.step(name, description);
    step.dependOn(&run.step);

    if (alias) |a| {
        const alias_description = std.fmt.allocPrint(b.allocator, "Alias for {s}", .{name}) catch return;
        b.step(a, alias_description).dependOn(step);
    }
}

/// Add a step dependency that turns examples/<name>.<ext> into
/// examples/<name>.4b using the given tool.
fn addExample(
    b: *std.Build,
    step: *std.Build.Step,
    tool: *std.Build.Step.Compile,
    name: []const u8,
    ext: []const u8,
) void {
    const src = std.fmt.allocPrint(b.allocator, "examples/{s}.{s}", .{ name, ext }) catch return;
    const dst = std.fmt.allocPrint(b.allocator, "examples/{s}.4b", .{name}) catch return;

    const run = b.addRunArtifact(tool);
    run.addFileArg(b.path(src));
    run.addArgs(&.{ "-o", dst });
    step.dependOn(&run.step);
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
    mod.addCMacro("SUPPORT_MODULE_RTEXTURES", "0");
    mod.addCMacro("SUPPORT_MODULE_RTEXT", "0");
    mod.addCMacro("SUPPORT_MODULE_RMODELS", "0");
    mod.addCMacro("SUPPORT_MODULE_RAUDIO", "0");
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
