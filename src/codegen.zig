const std = @import("std");
const dia = @import("dia");
const rom = @import("rom");
const isa = @import("isa");
const symbols = @import("symbols.zig");

const Item = isa.Item;
const Operand = isa.Operand;

pub const CodegenError = error{ CodegenError, OutOfMemory };

pub fn generate(alloc: std.mem.Allocator, diag: *dia.Diag, sym: *const symbols.Symbols, items: []const Item) CodegenError!std.ArrayList(u16) {
    var words = std.ArrayList(u16).empty;
    var pos: u16 = 0;

    for (items) |item| {
        switch (item) {
            .label => |l| {
                if (sym.labels.get(l.name)) |slot| {
                    try words.append(alloc, isa.encode(.flag, slot, 0));
                }
                pos += 1;
            },
            .inst => |inst| {
                const a_val = resolveOperand(sym, inst.spec.a, inst.a, diag, inst.line, inst.col);
                const b_val = resolveOperand(sym, inst.spec.b, inst.b, diag, inst.line, inst.col);
                var op = inst.spec.op;
                if (inst.a) |a| {
                    if ((a == .imm or a == .const_ref) and op == .lda_mem) {
                        op = .lda_imm;
                    }
                }
                try words.append(alloc, isa.encode(op, a_val, b_val));
                pos += 1;
            },
            .const_def => {},
            .org => |o| {
                while (pos < o.value) : (pos += 1) {
                    try words.append(alloc, 0x000);
                }
            },
            .dw => |d| {
                try words.append(alloc, d.value);
                pos += 1;
            },
        }
        if (pos > rom.IMAGE_WORDS) {
            diag.err(1, 1, "program too long (exceeds 256 instructions)", .{});
            return error.CodegenError;
        }
    }

    return words;
}

fn resolveOperand(sym: *const symbols.Symbols, kind: isa.OperandKind, op: ?Operand, diag: *dia.Diag, line: u32, col: u32) u4 {
    if (op == null) return 0;
    const operand = op.?;
    if (operand == .const_ref) {
        return sym.consts.get(operand.const_ref) orelse blk: {
            diag.err(line, col, "undefined const '#{s}'", .{operand.const_ref});
            break :blk 0;
        };
    }
    switch (kind) {
        .none => return 0,
        .reg => return operand.reg,
        .imm => return operand.imm,
        .reg_or_imm => {
            return switch (operand) {
                .reg => |v| v,
                .imm => |v| v,
                else => 0,
            };
        },
        .label_or_slot => {
            return switch (operand) {
                .label_ref => |name| sym.labels.get(name) orelse blk: {
                    diag.err(line, col, "undefined label '@{s}'", .{name});
                    break :blk 0;
                },
                .flag_slot => |slot| slot,
                else => 0,
            };
        },
    }
}

fn generateSrc(src: []const u8) !std.ArrayList(u16) {
    const alloc = std.testing.allocator;
    var diag = dia.Diag.init(alloc, "<test>", src);
    defer diag.deinit();
    const tokens = try @import("lexer.zig").lex(alloc, &diag, src);
    defer {
        var t = tokens;
        t.deinit(alloc);
    }
    const items = try @import("parser.zig").parse(alloc, &diag, tokens.items);
    defer {
        var it = items;
        it.deinit(alloc);
    }
    var sym = try symbols.analyze(alloc, &diag, items.items);
    defer {
        sym.consts.deinit();
        sym.labels.deinit();
    }
    var words = try generate(alloc, &diag, &sym, items.items);
    errdefer words.deinit(alloc);
    try std.testing.expectEqual(0, diag.errors.items.len);
    return words;
}
test "encode nop" {
    var words = try generateSrc("nop\n");
    defer words.deinit(std.testing.allocator);
    try std.testing.expectEqual(1, words.items.len);
    try std.testing.expectEqual(0x000, words.items[0]);
}

test "encode lda #8" {
    var words = try generateSrc("lda #8\n");
    defer words.deinit(std.testing.allocator);
    try std.testing.expectEqual(1, words.items.len);
    try std.testing.expectEqual(0x380, words.items[0]);
}

test "encode label and jmp" {
    var words = try generateSrc("@start:\njmp @start\n");
    defer words.deinit(std.testing.allocator);
    try std.testing.expectEqual(2, words.items.len);
    try std.testing.expectEqual(0xB00, words.items[0]);
    try std.testing.expectEqual(0xC00, words.items[1]);
}

test "undefined label error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag = dia.Diag.init(arena.allocator(), "<test>", "");
    const src = "jmp @nope\n";
    const tokens = try @import("lexer.zig").lex(arena.allocator(), &diag, src);
    const items = try @import("parser.zig").parse(arena.allocator(), &diag, tokens.items);
    const sym = try symbols.analyze(arena.allocator(), &diag, items.items);
    _ = try generate(arena.allocator(), &diag, &sym, items.items);
    try std.testing.expect(diag.hasErrors());
}
