const std = @import("std");
const model = @import("../model.zig");

/// Render generated words as text assembly (for `--emit-asm`).
pub fn write(
    alloc: std.mem.Allocator,
    words: []const u16,
    out: *std.ArrayList(u8),
) (std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    var aw: std.Io.Writer.Allocating = .fromArrayList(alloc, out);

    const w = &aw.writer;

    for (words, 0..) |word, i| {
        const op: u4 = @intCast((word >> 8) & 0xF);
        const a: u4 = @intCast((word >> 4) & 0xF);
        const b: u4 = @intCast(word & 0xF);

        try w.print("    ; {d: >3}\n    ", .{i});

        switch (@as(model.Op, @enumFromInt(op))) {
            .nop => try w.print("nop", .{}),
            .lda_mem => {
                try w.print("lda ", .{});
                try writeReg(w, a);
            },
            .sta => {
                try w.print("sta ", .{});
                try writeReg(w, a);
            },
            .lda_imm => try w.print("lda #{d}", .{a}),
            .read => try w.print("read", .{}),
            .inc => try w.print("inc", .{}),
            .cls => try w.print("cls", .{}),
            .shl => try w.print("shl", .{}),
            .shr => try w.print("shr", .{}),
            .peek => {
                try w.print("peek ", .{});
                try writeReg(w, a);
                try w.print(", ", .{});
                try writeReg(w, b);
            },
            .flip => {
                try w.print("flip ", .{});
                try writeReg(w, a);
                try w.print(", ", .{});
                try writeReg(w, b);
            },
            .flag => try w.print("flag @{d}", .{a}),
            .jmp => try w.print("jmp @{d}", .{a}),
            .ifeq => {
                try w.print("ifeq ", .{});
                try writeReg(w, a);
            },
            .ifgt => {
                try w.print("ifgt ", .{});
                try writeReg(w, a);
            },
            .iflt => {
                try w.print("iflt ", .{});
                try writeReg(w, a);
            },
        }

        try w.print("\n", .{});
    }

    out.* = aw.toArrayList();
}

fn writeReg(w: *std.Io.Writer, reg: u4) (std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    switch (reg) {
        13 => try w.writeAll("scratch"),
        14 => try w.writeAll("zero"),
        15 => try w.writeAll("phase"),
        else => try w.print("r{d}", .{reg}),
    }
}
