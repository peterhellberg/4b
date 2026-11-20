//! A disassembler for 4B ROM images: the inverse of `4a`.
//!
//! The module is deliberately I/O-free: give it a 384-byte image and it
//! returns 4A source text. Decoding reuses `isa.decode`, so the disassembler
//! and the VM/assembler cannot drift apart.
//!
//! ## Labels
//!
//! In 4A, a label `@foo:` is sugar for `flag @foo`: it emits a `flag` word
//! whose A nibble is the flag slot allocated to the label. A `jmp @foo`
//! emits `jmp` with the same slot. Slots are allocated in definition order,
//! starting at 0, which for ordinary `4a` output means flag words in address
//! order carry slots 0, 1, 2, ….
//!
//! A label can therefore only be emitted at a flag word whose slot equals
//! the number of labels already emitted (pass 1). Flag words with a
//! different slot — hand-written raw slots, or slot 15, which `4a` forbids —
//! are printed as raw instructions or `dw` instead. This keeps reassembly
//! byte-identical even for ROMs that do not follow the usual slot pattern;
//! it is the round-trip guarantee that matters, not pretty labels.
//!
//! The output is a clean 4A listing: one instruction per line, with operand
//! alignment but no comments or address annotations. Trailing zero padding
//! is omitted because `4a` recreates it when packing the image.

const std = @import("std");
const isa = @import("isa");
const rom = @import("rom");

/// Formatting options for `disassemble`.
pub const Options = struct {
    /// Emit `@Lxx:` label definitions for reproducible flag slots and use
    /// them in `jmp` operands. When false, raw slot numbers are printed.
    labels: bool = true,
};

pub const DisassembleError = std.mem.Allocator.Error || std.Io.Writer.Error ||
    error{NoSpaceLeft};

/// Width of the mnemonic/label column.
const mnemonic_width = 6;

/// Disassemble a 384-byte ROM into 4A source text. The returned slice is
/// owned by the caller.
pub fn disassemble(
    alloc: std.mem.Allocator,
    image: *const rom.Image,
    options: Options,
) DisassembleError![]u8 {
    var words: [rom.IMAGE_WORDS]u16 = undefined;
    rom.unpack(image, &words);

    // Pass 1: find the flag words that can be reproduced as labels.
    const labels = LabelMap.init(&words, options.labels);

    var aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();
    const w = &aw.writer;

    // Trailing zero words are indistinguishable from 4a's automatic
    // padding, so stop at the last non-zero word. The image is packed from
    // exactly the emitted words, which reproduces the zero fill.
    var last: ?usize = null;
    for (words, 0..) |word, addr| {
        if (word != 0) last = addr;
    }

    if (last) |end| {
        for (0..end + 1) |addr| {
            try writeWord(w, addr, words[addr], &labels);
        }
    }

    var list = aw.toArrayList();
    try list.shrinkToLen(alloc); // make the returned slice directly freeable
    return list.items;
}

/// flag-slot → address and address → flag-slot maps for emitted labels.
const LabelMap = struct {
    addr_slot: [rom.IMAGE_WORDS]?u4 = @splat(null),
    slot_addr: [isa.MAX_SLOTS]?u8 = @splat(null),

    fn init(words: *const [rom.IMAGE_WORDS]u16, enabled: bool) LabelMap {
        var map = LabelMap{};
        if (!enabled) return map;

        // A label emitted as the Nth one in source order gets slot N. Only
        // claim flag words whose slot matches that number.
        var next: u8 = 0;

        for (words, 0..) |word, addr| {
            const d = isa.decode(word);

            if (d.op != .flag) continue;
            if (d.b != 0) continue; // label syntax cannot express a B nibble
            if (d.a >= isa.MAX_SLOTS) continue; // slot 15 is forbidden
            if (d.a != next) continue; // slot would be renumbered

            map.addr_slot[addr] = d.a;
            map.slot_addr[d.a] = @intCast(addr);
            next += 1;
        }

        return map;
    }
};

fn writeWord(
    w: *std.Io.Writer,
    addr: usize,
    word: u16,
    labels: *const LabelMap,
) DisassembleError!void {
    const d = isa.decode(word);

    // A designated label word is printed as a label definition; the
    // assembler recreates the very same flag word for it.
    if (labels.addr_slot[addr]) |slot| {
        var name_buf: [8]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "@L{X:0>2}:", .{slot});
        return writeLine(w, name, null);
    }

    var op_buf: [24]u8 = undefined;
    var mnemonic: []const u8 = undefined;
    var operand: ?[]const u8 = null;

    switch (d.op) {
        .nop, .read, .cls, .shl, .shr => {
            if (d.a != 0 or d.b != 0) return writeDw(w, word);
            mnemonic = switch (d.op) {
                .nop => "nop",
                .read => "read",
                .cls => "cls",
                .shl => "shl",
                .shr => "shr",
                else => unreachable,
            };
        },
        .lda_mem => {
            if (d.b != 0) return writeDw(w, word);
            mnemonic = "lda";
            operand = try std.fmt.bufPrint(&op_buf, "r{d}", .{d.a});
        },
        .sta, .ifeq, .ifgt, .iflt => {
            if (d.b != 0) return writeDw(w, word);
            mnemonic = switch (d.op) {
                .sta => "sta",
                .ifeq => "ifeq",
                .ifgt => "ifgt",
                .iflt => "iflt",
                else => unreachable,
            };
            operand = try std.fmt.bufPrint(&op_buf, "r{d}", .{d.a});
        },
        .lda_imm => {
            if (d.b != 0) return writeDw(w, word);
            mnemonic = "lda";
            operand = try std.fmt.bufPrint(&op_buf, "#{d}", .{d.a});
        },
        .inc => {
            // opcode 0x5 with A == 1 is the local `dec` extension; A == 0 is
            // `inc`. Any other A (and any B) needs the `dw` escape hatch.
            if (d.b != 0 or d.a > 1) return writeDw(w, word);
            mnemonic = if (d.a == 1) "dec" else "inc";
        },
        .peek, .flip => {
            mnemonic = if (d.op == .peek) "peek" else "flip";
            operand = try std.fmt.bufPrint(&op_buf, "r{d}, r{d}", .{ d.a, d.b });
        },
        .flag => {
            // `flag @name` defines a label in 4A, so a non-label flag word
            // must always use the raw numeric form — even when some other
            // address owns a label for this slot.
            if (d.b != 0 or d.a >= isa.MAX_SLOTS) return writeDw(w, word);
            mnemonic = "flag";
            operand = try std.fmt.bufPrint(&op_buf, "{d}", .{d.a});
        },
        .jmp => {
            if (d.b != 0 or d.a >= isa.MAX_SLOTS) return writeDw(w, word);
            mnemonic = "jmp";
            if (labels.slot_addr[d.a] != null) {
                operand = try std.fmt.bufPrint(&op_buf, "@L{X:0>2}", .{d.a});
            } else {
                operand = try std.fmt.bufPrint(&op_buf, "{d}", .{d.a});
            }
        },
    }

    try writeLine(w, mnemonic, operand);
}

/// Emit a `dw` line for a word that no 4A mnemonic can express exactly
/// (non-zero unused nibbles, or flag slot 15, which `4a` rejects).
fn writeDw(w: *std.Io.Writer, word: u16) DisassembleError!void {
    var buf: [8]u8 = undefined;
    const operand = try std.fmt.bufPrint(&buf, "0x{X:0>3}", .{word});
    try writeLine(w, "dw", operand);
}

/// `mnemonic operands`
///
/// A single valid 4A line, aligned to the same mnemonic column as `4c -S`.
fn writeLine(
    w: *std.Io.Writer,
    mnemonic: []const u8,
    operand: ?[]const u8,
) DisassembleError!void {
    try w.writeAll(mnemonic);

    if (operand) |o| {
        try w.splatByteAll(' ', mnemonic_width -| mnemonic.len);
        try w.writeAll(o);
    }

    try w.writeByte('\n');
}

// ---- tests ----------------------------------------------------------------

fn dis(alloc: std.mem.Allocator, words: []const u16, options: Options) ![]u8 {
    var image: rom.Image = undefined;
    rom.pack(words, &image);
    return disassemble(alloc, &image, options);
}

test "format: mnemonics and operands" {
    const alloc = std.testing.allocator;
    const text = try dis(alloc, &.{ 0x380, 0x210 }, .{ .labels = false });
    defer alloc.free(text);

    try std.testing.expectEqualStrings("lda   #8\nsta   r1\n", text);
    try std.testing.expect(std.mem.indexOfScalar(u8, text, ';') == null);
}

test "every opcode renders with a mnemonic" {
    const alloc = std.testing.allocator;
    const words = [_]u16{
        0x000, 0x120, 0x230, 0x380, 0x400, 0x500, 0x510, 0x600,
        0x700, 0x800, 0x912, 0xA34, 0xB00, 0xC00, 0xD50, 0xE60,
        0xF70,
    };
    const text = try dis(alloc, &words, .{ .labels = false });
    defer alloc.free(text);

    const expected = [_][]const u8{
        "nop",  "lda", "sta",  "lda",  "read", "inc", "dec",  "cls",
        "shl",  "shr", "peek", "flip", "flag", "jmp", "ifeq", "ifgt",
        "iflt",
    };
    for (expected) |m| {
        try std.testing.expect(std.mem.indexOf(u8, text, m) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, text, "r1, r2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "#8") != null);
}

test "labels: flag words become labels and jmp uses them" {
    const alloc = std.testing.allocator;
    const text = try dis(alloc, &.{ 0xB00, 0x380, 0xC00 }, .{});
    defer alloc.free(text);

    try std.testing.expectEqualStrings("@L00:\nlda   #8\njmp   @L00\n", text);
}

test "no-labels prints raw flag slots" {
    const alloc = std.testing.allocator;
    const text = try dis(alloc, &.{ 0xB00, 0xC00 }, .{ .labels = false });
    defer alloc.free(text);

    try std.testing.expectEqualStrings("flag  0\njmp   0\n", text);
}

test "non-canonical words fall back to dw" {
    const alloc = std.testing.allocator;
    // 0x9F1 has a non-zero B nibble on a no-operand op; 0xBF0 uses the
    // forbidden slot 15; 0x512 is `dec` with a non-zero B nibble.
    const text = try dis(alloc, &.{ 0x012, 0xBF0, 0x512, 0x3F1 }, .{});
    defer alloc.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "dw    0x012") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dw    0xBF0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dw    0x512") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dw    0x3F1") != null);
}

test "out-of-order flag slots stay raw" {
    const alloc = std.testing.allocator;
    // Slot 2 at word 0 cannot be the first label (it would be renumbered to
    // 0), so it must remain a raw flag. Slot 0 at word 1 can be a label.
    const text = try dis(alloc, &.{ 0xB20, 0xB00, 0xC20, 0xC00 }, .{});
    defer alloc.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "flag  2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "@L00:") != null);
    // A raw jmp to slot 2 stays numeric even though slot 0 has a label.
    try std.testing.expect(std.mem.indexOf(u8, text, "jmp   2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "jmp   @L00") != null);
}

test "all-zero ROM emits no instructions" {
    const alloc = std.testing.allocator;
    const text = try dis(alloc, &.{}, .{});
    defer alloc.free(text);

    try std.testing.expectEqualStrings("", text);
}

test "last non-zero word sets the end of disassembly" {
    const alloc = std.testing.allocator;
    var words: [rom.IMAGE_WORDS]u16 = @splat(0);
    words[255] = 0x380;

    var image: rom.Image = undefined;
    rom.pack(&words, &image);

    const text = try disassemble(alloc, &image, .{});
    defer alloc.free(text);

    try std.testing.expect(std.mem.endsWith(u8, text, "lda   #8\n"));
    try std.testing.expectEqual(@as(usize, 256), std.mem.count(u8, text, "\n"));
}
