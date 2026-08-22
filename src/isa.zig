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

pub const Spec = struct {
    mnemonic: []const u8,
    op: Op,
    a: OperandKind,
    b: OperandKind,
};

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
