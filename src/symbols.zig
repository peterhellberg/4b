const std = @import("std");
const model = @import("model.zig");
const diag_mod = @import("diag.zig");
const Item = model.Item;

const reserved_mnemonics = [_][]const u8{
    "nop", "lda", "sta", "read", "inc", "cls", "shl", "shr",
    "peek", "flip", "flag", "jmp", "ifeq", "ifgt", "iflt",
};

const reserved_directives = [_][]const u8{ "const", "org", "dw" };

pub const Symbols = struct {
    consts: std.StringHashMap(u4),
    labels: std.StringHashMap(u4),
    next_slot: u4 = 0,

    pub fn init(alloc: std.mem.Allocator) Symbols {
        return .{
            .consts = std.StringHashMap(u4).init(alloc),
            .labels = std.StringHashMap(u4).init(alloc),
        };
    }
};

pub fn isReserved(name: []const u8) bool {
    for (reserved_mnemonics) |m| {
        if (std.ascii.eqlIgnoreCase(name, m)) return true;
    }
    for (reserved_directives) |d| {
        if (std.ascii.eqlIgnoreCase(name, d)) return true;
    }
    if (name.len >= 2 and std.ascii.startsWithIgnoreCase(name, "r")) {
        const digits = name[1..];
        if (digits.len > 0) {
            var all_digit = true;
            for (digits) |c| {
                if (!std.ascii.isDigit(c)) {
                    all_digit = false;
                    break;
                }
            }
            if (all_digit) return true;
        }
    }
    return false;
}

pub const AnalyzeError = error{ AnalyzeError, OutOfMemory };

pub fn analyze(alloc: std.mem.Allocator, diag: *diag_mod.Diag, items: []const Item) AnalyzeError!Symbols {
    var sym = Symbols.init(alloc);
    var pos: u16 = 0;

    for (items) |item| {
        switch (item) {
            .label => |l| {
                _ = defineLabel(&sym, diag, l.name, l.line, l.col);
                pos += 1;
            },
            .inst => |inst| {
                switch (inst.spec.op) {
                    .flag => {
                        const flag_op: model.Operand = inst.a orelse model.Operand{ .flag_slot = 0 };
                        switch (flag_op) {
                            .label_ref => |name| {
                                _ = defineLabel(&sym, diag, name, inst.line, inst.col);
                            },
                            .flag_slot => |slot| {
                                if (slot == 15) {
                                    diag.err(inst.line, inst.col, "flag slot 15 is reserved (hardware bug)", .{});
                                }
                            },
                            else => {},
                        }
                        pos += 1;
                    },
                    .jmp => {
                        if (inst.a) |a| {
                            if (a == .flag_slot) {
                                if (a.flag_slot == 15) {
                                    diag.err(inst.line, inst.col, "flag slot 15 is reserved (hardware bug)", .{});
                                }
                            }
                        }
                        pos += 1;
                    },
                    else => pos += 1,
                }
            },
            .const_def => |c| {
                if (isReserved(c.name)) {
                    diag.err(c.line, c.col, "reserved name '{s}' cannot be used as a const name", .{c.name});
                } else if (sym.consts.contains(c.name)) {
                    diag.err(c.line, c.col, "duplicate const '{s}'", .{c.name});
                } else {
                    sym.consts.put(c.name, c.value) catch return error.OutOfMemory;
                }
            },
            .org => |o| {
                if (o.value > 256) {
                    diag.err(o.line, o.col, "org position out of range (0-256)", .{});
                } else if (o.value < pos) {
                    diag.err(o.line, o.col, "org moves position backwards", .{});
                }
                pos = o.value;
            },
            .dw => |d| {
                if (d.value > 0xFFF) {
                    diag.err(d.line, d.col, "dw value out of range (0-0xFFF)", .{});
                }
                pos += 1;
            },
        }
        if (pos > 256) {
            diag.err(0, 0, "program too long (exceeds 256 instructions)", .{});
        }
    }

    return sym;
}

fn defineLabel(sym: *Symbols, diag: *diag_mod.Diag, name: []const u8, line: u32, col: u32) ?u4 {
    if (isReserved(name)) {
        diag.err(line, col, "reserved name '{s}' cannot be used as a label identifier", .{name});
        return null;
    }
    if (sym.labels.get(name)) |existing| {
        diag.err(line, col, "label '@{s}' is already defined", .{name});
        return existing;
    }
    if (sym.next_slot > 14) {
        diag.err(line, col, "too many labels (max 15)", .{});
        return null;
    }
    const slot = sym.next_slot;
    sym.next_slot += 1;
    sym.labels.put(name, slot) catch return null;
    return slot;
}

test "analyze labels and consts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag = diag_mod.Diag.init(arena.allocator(), "<test>", "");
    const src = "@start:\njmp @start\n";
    const tokens = try @import("lexer.zig").lex(arena.allocator(), &diag, src);
    const items = try @import("parser.zig").parse(arena.allocator(), &diag, tokens.items);
    const sym = try analyze(arena.allocator(), &diag, items.items);
    try std.testing.expectEqual(@as(usize, 0), diag.errors.items.len);
    try std.testing.expectEqual(@as(u4, 0), sym.labels.get("start").?);
    try std.testing.expectEqual(@as(u4, 1), sym.next_slot);
}

test "reject reserved name as const" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag = diag_mod.Diag.init(arena.allocator(), "<test>", "");
    const src = "const lda = 5\n";
    const tokens = try @import("lexer.zig").lex(arena.allocator(), &diag, src);
    const items = try @import("parser.zig").parse(arena.allocator(), &diag, tokens.items);
    _ = try analyze(arena.allocator(), &diag, items.items);
    try std.testing.expect(diag.hasErrors());
}

test "reject flag slot 15" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag = diag_mod.Diag.init(arena.allocator(), "<test>", "");
    const src = "flag 15\n";
    const tokens = try @import("lexer.zig").lex(arena.allocator(), &diag, src);
    const items = try @import("parser.zig").parse(arena.allocator(), &diag, tokens.items);
    _ = try analyze(arena.allocator(), &diag, items.items);
    try std.testing.expect(diag.hasErrors());
}
