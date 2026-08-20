const std = @import("std");
const model = @import("model.zig");
const diag_mod = @import("diag.zig");
const symbols = @import("symbols.zig");
const encoder = @import("encoder.zig");
const Item = model.Item;
const Operand = model.Operand;

pub const CodegenError = error{ CodegenError, OutOfMemory };

pub fn generate(alloc: std.mem.Allocator, diag: *diag_mod.Diag, sym: *const symbols.Symbols, items: []const Item) CodegenError!std.ArrayList(u16) {
    var words = std.ArrayList(u16).empty;
    var pos: u16 = 0;

    for (items) |item| {
        switch (item) {
            .label => |l| {
                if (sym.labels.get(l.name)) |slot| {
                    try words.append(alloc, model.encode(.flag, slot, 0));
                }
                pos += 1;
            },
            .inst => |inst| {
                const a_val = resolveOperand(sym, inst.spec.a, inst.a, diag, inst.line, inst.col);
                const b_val = resolveOperand(sym, inst.spec.b, inst.b, diag, inst.line, inst.col);
                var op = inst.spec.op;
                if (inst.a) |a| {
                    if (a == .imm and op == .lda_mem) {
                        op = .lda_imm;
                    }
                }
                try words.append(alloc, model.encode(op, a_val, b_val));
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
        std.debug.assert(pos <= encoder.IMAGE_WORDS);
    }

    return words;
}

fn resolveOperand(sym: *const symbols.Symbols, kind: model.OperandKind, op: ?Operand, diag: *diag_mod.Diag, line: u32, col: u32) u4 {
    if (op == null) return 0;
    const operand = op.?;
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

test "encode nop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag = diag_mod.Diag.init(arena.allocator(), "<test>", "");
    const sym = symbols.Symbols.init(arena.allocator());
    const src = "nop\n";
    const tokens = try @import("lexer.zig").lex(arena.allocator(), &diag, src);
    const items = try @import("parser.zig").parse(arena.allocator(), &diag, tokens.items);
    const words = try generate(arena.allocator(), &diag, &sym, items.items);
    try std.testing.expectEqual(@as(usize, 1), words.items.len);
    try std.testing.expectEqual(@as(u16, 0x000), words.items[0]);
}

test "encode lda #8" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag = diag_mod.Diag.init(arena.allocator(), "<test>", "");
    const sym = symbols.Symbols.init(arena.allocator());
    const src = "lda #8\n";
    const tokens = try @import("lexer.zig").lex(arena.allocator(), &diag, src);
    const items = try @import("parser.zig").parse(arena.allocator(), &diag, tokens.items);
    const words = try generate(arena.allocator(), &diag, &sym, items.items);
    try std.testing.expectEqual(@as(usize, 1), words.items.len);
    try std.testing.expectEqual(@as(u16, 0x380), words.items[0]);
}

test "encode label and jmp" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag = diag_mod.Diag.init(arena.allocator(), "<test>", "");
    const src = "@start:\njmp @start\n";
    const tokens = try @import("lexer.zig").lex(arena.allocator(), &diag, src);
    const items = try @import("parser.zig").parse(arena.allocator(), &diag, tokens.items);
    const sym = try symbols.analyze(arena.allocator(), &diag, items.items);
    const words = try generate(arena.allocator(), &diag, &sym, items.items);
    try std.testing.expectEqual(@as(usize, 2), words.items.len);
    try std.testing.expectEqual(@as(u16, 0xB00), words.items[0]);
    try std.testing.expectEqual(@as(u16, 0xC00), words.items[1]);
}

test "undefined label error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag = diag_mod.Diag.init(arena.allocator(), "<test>", "");
    const src = "jmp @nope\n";
    const tokens = try @import("lexer.zig").lex(arena.allocator(), &diag, src);
    const items = try @import("parser.zig").parse(arena.allocator(), &diag, tokens.items);
    const sym = try symbols.analyze(arena.allocator(), &diag, items.items);
    _ = try generate(arena.allocator(), &diag, &sym, items.items);
    try std.testing.expect(diag.hasErrors());
}
