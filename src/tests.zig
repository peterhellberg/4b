const std = @import("std");
const assembler = @import("assembler.zig");

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

fn compileAndCheck(src: []const u8, expected: *const [384]u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var diag = assembler.diag_mod.Diag.init(alloc, "<test>", src);
    const image = try assembler.assemble(alloc, &diag, src);
    try std.testing.expectEqual(@as(usize, 0), diag.errors.items.len);
    try std.testing.expectEqualSlices(u8, expected, &image);
}

test "golden: line (horizontal line)" {
    try compileAndCheck(line_src, &line_expected);
}

test "golden: buttons" {
    try compileAndCheck(buttons_src, &buttons_expected);
}

test "golden: forward reference" {
    try compileAndCheck(forward_src, &forward_expected);
}

test "golden: raw flag/jmp" {
    try compileAndCheck(rawflag_src, &rawflag_expected);
}

test "golden: org/dw" {
    try compileAndCheck(orgdw_src, &orgdw_expected);
}

const neg_undefined = "jmp @nope\n";
const neg_redefine = "@x:\n@x:\n";
const neg_slot15 = "flag 15\n";
const neg_reg_range = "lda r16\n";
const neg_imm_range = "lda #16\n";
const neg_bad_mnemonic = "foobar\n";
const neg_reserved_const = "const nop = 0\n";
const neg_dup_const = "const X = 1\nconst X = 2\n";

fn compileExpectError(src: []const u8, expected_substr: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var diag = assembler.diag_mod.Diag.init(alloc, "<test>", src);
    _ = assembler.compile(alloc, &diag, src) catch {};
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
    try compileExpectError(neg_undefined, "undefined label");
}

test "negative: label redefined" {
    try compileExpectError(neg_redefine, "already defined");
}

test "negative: flag slot 15" {
    try compileExpectError(neg_slot15, "slot 15");
}

test "negative: register out of range" {
    try compileExpectError(neg_reg_range, "out of range");
}

test "negative: immediate out of range" {
    try compileExpectError(neg_imm_range, "out of range");
}

test "negative: unknown mnemonic" {
    try compileExpectError(neg_bad_mnemonic, "unknown");
}

test "negative: reserved const name" {
    try compileExpectError(neg_reserved_const, "reserved");
}

test "negative: duplicate const" {
    try compileExpectError(neg_dup_const, "duplicate");
}
