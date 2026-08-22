const std = @import("std");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const symbols = @import("symbols.zig");
const codegen = @import("codegen.zig");
const encoder = @import("encoder.zig");

pub const diagnostics = @import("diagnostics.zig");

pub const Image = encoder.Image;

pub const AssembleError = error{ AssembleFailed, OutOfMemory };

pub fn assemble(alloc: std.mem.Allocator, diag: *diagnostics.Diag, src: []const u8) AssembleError!Image {
    const tokens = lexer.lex(alloc, diag, src) catch {
        return error.AssembleFailed;
    };
    if (diag.hasErrors()) return error.AssembleFailed;

    const items = parser.parse(alloc, diag, tokens.items) catch {
        return error.AssembleFailed;
    };
    if (diag.hasErrors()) return error.AssembleFailed;

    var sym = symbols.analyze(alloc, diag, items.items) catch {
        return error.AssembleFailed;
    };
    if (diag.hasErrors()) return error.AssembleFailed;

    const words = codegen.generate(alloc, diag, &sym, items.items) catch {
        return error.AssembleFailed;
    };
    if (diag.hasErrors()) return error.AssembleFailed;

    var image: Image = undefined;
    encoder.pack(words.items, &image);

    return image;
}
