const std = @import("std");

pub const Op = enum(u4) {
    nop = 0x0,
    lda_mem = 0x1,
    sta = 0x2,
    lda_imm = 0x3,
    read = 0x4,
    inc = 0x5,
    cls = 0x6,
    shl = 0x7,
    shr = 0x8,
    peek = 0x9,
    flip = 0xA,
    flag = 0xB,
    jmp = 0xC,
    ifeq = 0xD,
    ifgt = 0xE,
    iflt = 0xF,
};

pub const OperandKind = enum {
    none,
    reg,
    imm,
    reg_or_imm,
    label_or_slot,
};

/// Register roles shared by the 4c backend: sema allocates variables
/// below SCRATCH, codegen reserves the top three (see docs/4CL.md §6.1).
pub const SCRATCH: u4 = 13;
pub const ZERO: u4 = 14;
pub const PHASE: u4 = 15;

/// Flag slots 0..14 are usable; slot 15 is reserved (hardware bug).
pub const MAX_SLOTS: usize = 15;

pub const Spec = struct {
    mnemonic: []const u8,
    op: Op,
    a: OperandKind,
    b: OperandKind,
};

/// One mnemonic per spec; "lda" always parses as .lda_mem and codegen
/// rewrites it to .lda_imm when the operand is `#imm` (or `#CONST`).
/// There is deliberately no separate "lda" entry for opcode 0x3.
pub const specs = [_]Spec{
    .{ .mnemonic = "nop", .op = .nop, .a = .none, .b = .none },
    .{ .mnemonic = "lda", .op = .lda_mem, .a = .reg_or_imm, .b = .none },
    .{ .mnemonic = "sta", .op = .sta, .a = .reg, .b = .none },
    .{ .mnemonic = "read", .op = .read, .a = .none, .b = .none },
    .{ .mnemonic = "inc", .op = .inc, .a = .none, .b = .none },
    .{ .mnemonic = "cls", .op = .cls, .a = .none, .b = .none },
    .{ .mnemonic = "shl", .op = .shl, .a = .none, .b = .none },
    .{ .mnemonic = "shr", .op = .shr, .a = .none, .b = .none },
    .{ .mnemonic = "peek", .op = .peek, .a = .reg, .b = .reg },
    .{ .mnemonic = "flip", .op = .flip, .a = .reg, .b = .reg },
    .{ .mnemonic = "flag", .op = .flag, .a = .label_or_slot, .b = .none },
    .{ .mnemonic = "jmp", .op = .jmp, .a = .label_or_slot, .b = .none },
    .{ .mnemonic = "ifeq", .op = .ifeq, .a = .reg, .b = .none },
    .{ .mnemonic = "ifgt", .op = .ifgt, .a = .reg, .b = .none },
    .{ .mnemonic = "iflt", .op = .iflt, .a = .reg, .b = .none },
};

pub fn lookupSpec(name: []const u8) ?Spec {
    for (specs) |s| {
        if (std.ascii.eqlIgnoreCase(name, s.mnemonic)) return s;
    }

    return null;
}

pub const Operand = union(enum) {
    reg: u4,
    imm: u4,
    const_ref: []const u8,
    label_ref: []const u8,
    flag_slot: u4,
};

pub const Item = union(enum) {
    label: Label,
    inst: Inst,
    const_def: ConstDef,
    org: Org,
    dw: Dw,
};

pub const Label = struct {
    name: []const u8,
    line: u32,
    col: u32,
};

pub const Inst = struct {
    spec: Spec,
    a: ?Operand,
    b: ?Operand,
    line: u32,
    col: u32,
};

pub const ConstDef = struct {
    name: []const u8,
    value: u4,
    line: u32,
    col: u32,
};

pub const Org = struct {
    value: u16,
    line: u32,
    col: u32,
};

pub const Dw = struct {
    value: u16,
    line: u32,
    col: u32,
};

pub fn encode(op: Op, a: u4, b: u4) u16 {
    return (@as(u16, @intFromEnum(op)) << 8) | (@as(u16, a) << 4) | @as(u16, b);
}

test "all 16 opcodes covered exactly once" {
    var seen: [16]bool = @splat(false);
    for (specs) |s| {
        const i: usize = @intFromEnum(s.op);
        try std.testing.expect(!seen[i]);
        seen[i] = true;
    }
    // Only lda_imm shares its mnemonic; every other opcode has a spec.
    for (seen, 0..) |s, i| {
        if (i == @intFromEnum(Op.lda_imm)) continue;
        try std.testing.expect(s);
    }
}

test "lookupSpec is case-insensitive" {
    try std.testing.expectEqual(Op.lda_mem, lookupSpec("LDA").?.op);
    try std.testing.expectEqual(Op.peek, lookupSpec("Peek").?.op);
    try std.testing.expect(lookupSpec("nope") == null);
}

test "encode vectors" {
    try std.testing.expectEqual(0x000, encode(.nop, 0, 0));
    try std.testing.expectEqual(0x380, encode(.lda_imm, 8, 0));
    try std.testing.expectEqual(0x210, encode(.sta, 1, 0));
    try std.testing.expectEqual(0xC0F, encode(.jmp, 0, 0xF));
}
