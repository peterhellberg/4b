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
        const op: isa.Op = @enumFromInt(@as(u4, @intCast((word >> 8) & 0xF)));
        const a: u4 = @intCast((word >> 4) & 0xF);
        const b: u4 = @intCast(word & 0xF);

        const m = mnemonic(op);
        try w.writeAll(m);

        switch (op) {
            .nop, .read, .inc, .cls, .shl, .shr => {},
            .lda_imm => {
                try w.splatByteAll(' ', MNEMONIC_WIDTH - m.len);
                try w.print("#{d}", .{a});
            },
            .lda_mem, .sta, .ifeq, .ifgt, .iflt => {
                try w.splatByteAll(' ', MNEMONIC_WIDTH - m.len);
                try writeReg(w, a);
            },
            .peek, .flip => {
                try w.splatByteAll(' ', MNEMONIC_WIDTH - m.len);
                try writeReg(w, a);
                try w.writeAll(", ");
                try writeReg(w, b);
            },
            .flag, .jmp => {
                try w.splatByteAll(' ', MNEMONIC_WIDTH - m.len);
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
