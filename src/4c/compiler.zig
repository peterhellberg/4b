const std = @import("std");
const isa = @import("isa");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const sema_mod = @import("sema.zig");
const codegen_mod = @import("codegen.zig");
const rom = @import("rom");

pub const dia = @import("dia");

pub const emit_asm = @import("emit_asm.zig");

pub const Image = rom.Image;

pub const CompileError = error{ CompileFailed, OutOfMemory };

/// Compile 4C source to program words plus slot metadata.
pub fn compileWords(
    alloc: std.mem.Allocator,
    diag: *dia.Diag,
    src: []const u8,
) CompileError!codegen_mod.Result {
    const tokens = lexer.lex(alloc, diag, src) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.LexError => return error.CompileFailed,
    };

    if (diag.hasErrors()) return error.CompileFailed;

    const prog = parser.parse(alloc, diag, tokens.items) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseError => return error.CompileFailed,
    };

    if (diag.hasErrors()) return error.CompileFailed;

    var semer = sema_mod.Semer{ .alloc = alloc, .diag = diag, .consts = .empty };

    const sprog = semer.run(prog) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SemaError => return error.CompileFailed,
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
pub fn compile(alloc: std.mem.Allocator, diag: *dia.Diag, src: []const u8) CompileError!Image {
    const out = try compileWords(alloc, diag, src);

    var image: Image = undefined;

    rom.pack(out.words, &image);

    return image;
}

/// Compile 4C source into a 384-byte ROM image (C-ABI entry point used
/// when the compiler is embedded in the 4b box).
///
/// Returns 0 and fills `out` on success. On failure returns 1 and, when
/// `err_buf` is non-null, writes diagnostics ("path:line:col: error: msg\n"
/// per error, NUL-terminated, truncated to fit).
export fn fourb_compile(
    path: [*:0]const u8,
    src: [*]const u8,
    src_len: usize,
    out: [*]u8,
    err_buf: ?[*]u8,
    err_cap: usize,
) c_int {
    const source: []const u8 = src[0..src_len];

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const alloc = arena.allocator();

    var diag = dia.Diag.init(alloc, std.mem.span(path), source);

    const image = compile(alloc, &diag, source) catch {
        writeErrors(&diag, err_buf, err_cap);
        return 1;
    };

    if (diag.hasErrors()) {
        writeErrors(&diag, err_buf, err_cap);
        return 1;
    }

    @memcpy(out[0..image.len], &image);

    return 0;
}

fn writeErrors(diag: *const dia.Diag, buf: ?[*]u8, cap: usize) void {
    const b = buf orelse return;

    if (cap == 0) return;

    var off: usize = 0;

    for (diag.errors.items) |e| {
        const written = std.fmt.bufPrint(b[off..cap], "{s}:{d}:{d}: error: {s}\n", .{
            diag.path, e.line, e.col, e.msg,
        }) catch break;

        off += written.len;
    }

    b[@min(off, cap - 1)] = 0;
}

test "compile trivial 4c program" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const alloc = arena.allocator();

    var diag = dia.Diag.init(alloc, "t.4c", "");

    const image = try compile(alloc, &diag,
        \\u4 x = 3;
        \\fn main() { halt(); }
    );

    _ = image;
}

test "variable add emits bounded counter loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const alloc = arena.allocator();

    var diag = dia.Diag.init(alloc, "t.4c",
        \\u4 x = 2;
        \\u4 y = 3;
        \\fn main() { x += y; halt(); }
    );

    const out = try compileWords(alloc, &diag,
        \\u4 x = 2;
        \\u4 y = 3;
        \\fn main() { x += y; halt(); }
    );
    try std.testing.expectEqual(0, diag.errors.items.len);

    // Find the loop prologue: lda #0, sta SCRATCH, flag top,
    // lda y, ifeq SCRATCH, jmp end.
    var top: ?usize = null;
    for (out.words, 0..) |w, i| {
        if (i + 5 >= out.words.len) break;
        if (w == isa.encode(.lda_imm, 0, 0) and
            out.words[i + 1] == isa.encode(.sta, codegen_mod.SCRATCH, 0) and
            out.words[i + 3] == isa.encode(.lda_mem, 1, 0) and
            out.words[i + 4] == isa.encode(.ifeq, codegen_mod.SCRATCH, 0))
        {
            top = i;
            break;
        }
    }
    const t = top orelse return error.TestUnexpectedResult;

    const top_slot: u4 = @intCast((out.words[t + 2] >> 4) & 0xF);
    const end_slot: u4 = @intCast((out.words[t + 5] >> 4) & 0xF);
    try std.testing.expect(top_slot != end_slot);

    // The loop must close with a backedge to the top flag and, after it,
    // the end flag the exit jump targets.
    const back = isa.encode(.jmp, top_slot, 0);
    const end = isa.encode(.flag, end_slot, 0);
    var bi: ?usize = null;
    var ei: ?usize = null;
    for (out.words, 0..) |w, i| {
        if (bi == null and w == back) bi = i;
        if (bi != null and w == end) {
            ei = i;
            break;
        }
    }
    try std.testing.expect(bi != null and ei != null and ei.? > bi.?);
}

test "break outside loop is an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const alloc = arena.allocator();

    for ([_][]const u8{ "break;", "continue;" }) |kw| {
        const src = try std.fmt.allocPrint(alloc, "fn main() {{ {s} }}\n", .{kw});
        var diag = dia.Diag.init(alloc, "t.4c", src);
        const result = compileWords(alloc, &diag, src);
        try std.testing.expectError(error.CompileFailed, result);
        try std.testing.expect(diag.hasErrors());
    }
}

test "flip and peek reject two computed args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const alloc = arena.allocator();

    const bad = [_][]const u8{
        "u4 x = 1;\nu4 y = 2;\nfn main() { flip(x + 1, y + 1); halt(); }\n",
        "u4 x = 1;\nu4 y = 2;\nu4 p = 0;\nfn main() { p = peek(x + 1, y + 1); halt(); }\n",
    };
    for (bad) |src| {
        var diag = dia.Diag.init(alloc, "t.4c", src);
        const result = compileWords(alloc, &diag, src);
        try std.testing.expectError(error.CompileFailed, result);
        try std.testing.expect(diag.hasErrors());
    }

    const ok = "u4 x = 1;\nu4 y = 2;\nfn main() { flip(x + 1, y); halt(); }\n";
    var diag = dia.Diag.init(alloc, "t.4c", ok);
    _ = try compileWords(alloc, &diag, ok);
    try std.testing.expectEqual(0, diag.errors.items.len);
}

test "fourb_compile compiles valid source and reports errors" {
    var out: [384]u8 = undefined;

    const ok_src = "fn main() { halt(); }\n";

    try std.testing.expectEqual(0, fourb_compile("t.4c", ok_src, ok_src.len, &out, null, 0));

    const bad_src = "fn main() { nope(); }\n";

    var err_buf: [256]u8 = undefined;

    try std.testing.expectEqual(1, fourb_compile("t.4c", bad_src, bad_src.len, &out, &err_buf, err_buf.len));

    const msg = std.mem.sliceTo(&err_buf, 0);

    try std.testing.expect(msg.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, msg, "t.4c:"));
}
