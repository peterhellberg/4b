const std = @import("std");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const symbols_mod = @import("symbols.zig");
const codegen_mod = @import("codegen.zig");
const encoder = @import("encoder.zig");
pub const diag_mod = @import("diag.zig");

pub const Image = encoder.Image;

pub const CompileError = error{ CompileFailed, OutOfMemory };

pub fn compile(alloc: std.mem.Allocator, diag: *diag_mod.Diag, src: []const u8) CompileError!Image {
    const tokens = lexer.lex(alloc, diag, src) catch {
        return error.CompileFailed;
    };
    if (diag.hasErrors()) return error.CompileFailed;

    const items = parser.parse(alloc, diag, tokens.items) catch {
        return error.CompileFailed;
    };
    if (diag.hasErrors()) return error.CompileFailed;

    var sym = symbols_mod.analyze(alloc, diag, items.items) catch {
        return error.CompileFailed;
    };
    if (diag.hasErrors()) return error.CompileFailed;

    const words = codegen_mod.generate(alloc, diag, &sym, items.items) catch {
        return error.CompileFailed;
    };
    if (diag.hasErrors()) return error.CompileFailed;

    var image: Image = undefined;
    encoder.pack(words.items, &image);

    return image;
}
