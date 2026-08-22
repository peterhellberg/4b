const std = @import("std");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const sema_mod = @import("sema.zig");
const codegen_mod = @import("codegen.zig");
const encoder = @import("../encoder.zig");

pub const diagnostics = @import("../diagnostics.zig");

pub const Image = encoder.Image;

pub const CompileError = error{ CompileFailed, OutOfMemory };

/// Compile 4C source to program words plus slot metadata.
pub fn compileWords(
    alloc: std.mem.Allocator,
    diag: *diagnostics.Diag,
    src: []const u8,
) CompileError!codegen_mod.Result {
    const tokens = lexer.lex(alloc, diag, src) catch {
        return error.CompileFailed;
    };

    if (diag.hasErrors()) return error.CompileFailed;

    const prog = parser.parse(alloc, diag, tokens.items) catch {
        return error.CompileFailed;
    };

    if (diag.hasErrors()) return error.CompileFailed;

    var semer = sema_mod.Semer{ .alloc = alloc, .diag = diag, .consts = .empty };

    const sprog = semer.run(prog) catch {
        return error.CompileFailed;
    };

    if (diag.hasErrors()) return error.CompileFailed;

    return codegen_mod.generate(alloc, diag, sprog) catch |e| switch (e) {
        error.CodegenError => {
            if (!diag.hasErrors()) diag.err(1, 1, "code generation failed", .{});
            return error.CompileFailed;
        },
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Compile 4C source to a packed ROM image.
pub fn compile(alloc: std.mem.Allocator, diag: *diagnostics.Diag, src: []const u8) CompileError!Image {
    const out = try compileWords(alloc, diag, src);

    var image: Image = undefined;

    encoder.pack(out.words, &image);

    return image;
}

test "compile trivial 4c program" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const alloc = arena.allocator();

    var diag = diagnostics.Diag.init(alloc, "t.4c", "");

    const image = try compile(alloc, &diag,
        \\u4 x = 3;
        \\fn main() { halt(); }
    );

    _ = image;
}
