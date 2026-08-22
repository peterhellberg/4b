const std = @import("std");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const symbols = @import("symbols.zig");
const codegen = @import("codegen.zig");
const rom = @import("rom");

pub const dia = @import("dia");

pub const Image = rom.Image;

pub const AssembleError = error{ AssembleFailed, OutOfMemory };

pub fn assemble(alloc: std.mem.Allocator, diag: *dia.Diag, src: []const u8) AssembleError!Image {
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
    rom.pack(words.items, &image);

    return image;
}

/// Assemble 4A source into a 384-byte ROM image (C-ABI entry point used
/// when the assembler is embedded in the 4b box).
///
/// Returns 0 and fills `out` on success. On failure returns 1 and, when
/// `err_buf` is non-null, writes diagnostics ("path:line:col: error: msg\n"
/// per error, NUL-terminated, truncated to fit).
export fn fourb_assemble(
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

    const image = assemble(alloc, &diag, source) catch {
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

test "fourb_assemble assembles valid source and reports errors" {
    var out: [384]u8 = undefined;

    try std.testing.expectEqual(@as(c_int, 0), fourb_assemble("t.4a", "jmp @h\n@h:\nnop\n", 15, &out, null, 0));
    try std.testing.expectEqual(@as(u8, 0x00), out[0]);
    try std.testing.expectEqual(@as(u8, 0x0C), out[1]);

    var err_buf: [256]u8 = undefined;

    try std.testing.expectEqual(@as(c_int, 1), fourb_assemble("t.4a", "jmp @nowhere\n", 13, &out, &err_buf, err_buf.len));

    const msg = std.mem.sliceTo(&err_buf, 0);

    try std.testing.expect(std.mem.indexOf(u8, msg, "undefined label") != null);
    try std.testing.expect(std.mem.startsWith(u8, msg, "t.4a:1:"));
}

const line_src = @embedFile("test/golden/line.4a");
const buttons_src = @embedFile("test/golden/buttons.4a");
const forward_src = @embedFile("test/golden/forward.4a");
const rawflag_src = @embedFile("test/golden/rawflag.4a");
const orgdw_src = @embedFile("test/golden/orgdw.4a");

fn padBytes(comptime data: []const u8) [384]u8 {
    var img: [384]u8 = undefined;

    @memset(&img, 0);

    for (data, 0..) |b, i| img[i] = b;

    return img;
}

const line_expected = padBytes(&[_]u8{
    0x80, 0x03, 0x21, 0x00, 0x03, 0x22, 0x30, 0x02, 0xB0, 0x20, 0x01, 0x20,
    0x01, 0x0A, 0x50, 0x20, 0x02, 0xF3, 0x00, 0x0C, 0xB1, 0x10, 0x0C,
});

const buttons_expected = padBytes(&[_]u8{
    0x80, 0x03, 0x20, 0x10, 0x02, 0xB0, 0x00, 0x04, 0x80, 0x00, 0x08, 0x70,
    0x00, 0x07, 0x70, 0x40, 0x02, 0x38, 0x40, 0x1D, 0xA0, 0x00, 0x0C,
});

const forward_expected = padBytes(&[_]u8{
    0x10, 0x0C, 0xB0, 0x10, 0x03, 0xC0, 0x10, 0x0B,
});

const rawflag_expected = padBytes(&[_]u8{
    0x00, 0x0B, 0xC1, 0x20, 0x0B, 0xC0,
});

const orgdw_expected = padBytes(&[_]u8{
    0x00, 0x00, 0x00, 0xBC, 0x0A, 0x00, 0x00, 0x30, 0x12,
});

fn assembleAndCheck(src: []const u8, expected: *const [384]u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const alloc = arena.allocator();

    var diag = dia.Diag.init(alloc, "<test>", src);

    const image = try assemble(alloc, &diag, src);

    try std.testing.expectEqual(@as(usize, 0), diag.errors.items.len);
    try std.testing.expectEqualSlices(u8, expected, &image);
}

test "golden: line (horizontal line)" {
    try assembleAndCheck(line_src, &line_expected);
}

test "golden: buttons" {
    try assembleAndCheck(buttons_src, &buttons_expected);
}

test "golden: forward reference" {
    try assembleAndCheck(forward_src, &forward_expected);
}

test "golden: raw flag/jmp" {
    try assembleAndCheck(rawflag_src, &rawflag_expected);
}

test "golden: org/dw" {
    try assembleAndCheck(orgdw_src, &orgdw_expected);
}

const neg_undefined = "jmp @nope\n";
const neg_redefine = "@x:\n@x:\n";
const neg_slot15 = "flag 15\n";
const neg_reg_range = "lda r16\n";
const neg_imm_range = "lda #16\n";
const neg_bad_mnemonic = "foobar\n";
const neg_reserved_const = "const nop = 0\n";
const neg_dup_const = "const X = 1\nconst X = 2\n";

fn assembleExpectError(src: []const u8, expected_substr: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const alloc = arena.allocator();

    var diag = dia.Diag.init(alloc, "<test>", src);

    _ = assemble(alloc, &diag, src) catch {};

    try std.testing.expect(diag.hasErrors());

    var found = false;

    for (diag.errors.items) |e| {
        if (std.mem.indexOf(u8, e.msg, expected_substr) != null) {
            found = true;

            break;
        }
    }

    if (!found) {
        std.debug.print("expected error containing '{s}', got errors:\n", .{expected_substr});

        for (diag.errors.items) |e| {
            std.debug.print("  {s}\n", .{e.msg});
        }

        return error.TestUnexpectedError;
    }
}

test "negative: undefined label" {
    try assembleExpectError(neg_undefined, "undefined label");
}

test "negative: label redefined" {
    try assembleExpectError(neg_redefine, "already defined");
}

test "negative: flag slot 15" {
    try assembleExpectError(neg_slot15, "slot 15");
}

test "negative: register out of range" {
    try assembleExpectError(neg_reg_range, "out of range");
}

test "negative: immediate out of range" {
    try assembleExpectError(neg_imm_range, "out of range");
}

test "negative: unknown mnemonic" {
    try assembleExpectError(neg_bad_mnemonic, "unknown");
}

test "negative: reserved const name" {
    try assembleExpectError(neg_reserved_const, "reserved");
}

test "negative: duplicate const" {
    try assembleExpectError(neg_dup_const, "duplicate");
}
