const std = @import("std");
const isa = @import("isa");

/// Width of the mnemonic column; operands start here on every line.
const MNEMONIC_WIDTH = 6;

/// Render generated words as text assembly (for `--emit-asm`).
pub fn write(
    alloc: std.mem.Allocator,
    words: []const u16,
    out: *std.ArrayList(u8),
) (std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    var aw: std.Io.Writer.Allocating = .fromArrayList(alloc, out);

    const w = &aw.writer;

    for (words) |word| {
        const d = isa.decode(word);
        const op = d.op;
        const a = d.a;
        const b = d.b;

        const m = mnemonic(op);
        try w.writeAll(m);

        switch (op) {
            .nop, .read, .inc, .cls, .shl, .shr => {},
            .lda_imm => {
                try w.splatByteAll(' ', MNEMONIC_WIDTH -| m.len);
                try w.print("#{d}", .{a});
            },
            .lda_mem, .sta, .ifeq, .ifgt, .iflt => {
                try w.splatByteAll(' ', MNEMONIC_WIDTH -| m.len);
                try writeReg(w, a);
            },
            .peek, .flip => {
                try w.splatByteAll(' ', MNEMONIC_WIDTH -| m.len);
                try writeReg(w, a);
                try w.writeAll(", ");
                try writeReg(w, b);
            },
            .flag, .jmp => {
                try w.splatByteAll(' ', MNEMONIC_WIDTH -| m.len);
                try w.print("{d}", .{a});
            },
        }

        try w.writeByte('\n');
    }

    out.* = aw.toArrayList();
}

/// Look up the mnemonic for an opcode in the ISA signature table.
fn mnemonic(op: isa.Op) []const u8 {
    for (isa.specs) |s| {
        if (s.op == op) return s.mnemonic;
    }

    // The table folds both lda variants into one entry (.a = .reg_or_imm).
    if (op == .lda_imm) return "lda";

    unreachable;
}

fn writeReg(w: *std.Io.Writer, reg: u4) (std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    try w.print("r{d}", .{reg});
}

test "round-trip every opcode" {
    const alloc = std.testing.allocator;
    const ops = [_]isa.Op{
        .nop,  .lda_mem, .sta,  .lda_imm, .read, .inc,  .cls,  .shl, .shr,
        .peek, .flip,    .flag, .jmp,     .ifeq, .ifgt, .iflt,
    };
    for (ops) |op| {
        const words = [_]u16{isa.encode(op, 1, 2)};
        var text = std.ArrayList(u8).empty;
        defer text.deinit(alloc);
        try write(alloc, &words, &text);
        try std.testing.expect(text.items.len > "nop\n".len);
        try std.testing.expect(std.mem.startsWith(u8, text.items, mnemonic(op)));
    }
}
