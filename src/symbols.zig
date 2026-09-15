const std = @import("std");
const isa = @import("isa");
const dia = @import("dia");

const Item = isa.Item;

const reserved_directives = [_][]const u8{ "const", "org", "dw" };

/// Hash context matching docs/4AL.md §3: all identifiers are
/// case-insensitive, so `@Foo` and `@foo` are the same label.
const CiContext = struct {
    pub fn hash(_: @This(), s: []const u8) u64 {
        var h: u64 = 1469598103934665603;
        for (s) |c| {
            h ^= std.ascii.toLower(c);
            h *%= 1099511628211;
        }
        return h;
    }

    pub fn eql(_: @This(), a: []const u8, b: []const u8) bool {
        return std.ascii.eqlIgnoreCase(a, b);
    }
};

pub const NameMap = std.HashMap([]const u8, u4, CiContext, std.hash_map.default_max_load_percentage);

pub const Symbols = struct {
    consts: NameMap,
    labels: NameMap,
    next_slot: u8 = 0,

    pub fn init(alloc: std.mem.Allocator) Symbols {
        return .{
            .consts = NameMap.init(alloc),
            .labels = NameMap.init(alloc),
        };
    }
};

pub fn isReserved(name: []const u8) bool {
    for (isa.specs) |s| {
        if (std.ascii.eqlIgnoreCase(name, s.mnemonic)) return true;
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

pub fn analyze(alloc: std.mem.Allocator, diag: *dia.Diag, items: []const Item) AnalyzeError!Symbols {
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
                        const flag_op: isa.Operand = inst.a orelse isa.Operand{ .flag_slot = 0 };
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
                } else {
                    pos = o.value;
                }
            },
            .dw => |d| {
                if (d.value > 0xFFF) {
                    diag.err(d.line, d.col, "dw value out of range (0-0xFFF)", .{});
                }
                pos += 1;
            },
        }
        if (pos == 257) {
            const span = switch (item) {
                .label => |l| .{ l.line, l.col },
                .inst => |i| .{ i.line, i.col },
                .const_def => |c| .{ c.line, c.col },
                .org => |o| .{ o.line, o.col },
                .dw => |d| .{ d.line, d.col },
            };
            diag.err(span[0], span[1], "program too long (exceeds 256 instructions)", .{});
        }
    }

    return sym;
}

fn defineLabel(sym: *Symbols, diag: *dia.Diag, name: []const u8, line: u32, col: u32) ?u4 {
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

    const slot: u4 = @intCast(sym.next_slot);

    sym.next_slot += 1;
    sym.labels.put(name, slot) catch return null;

    return slot;
}

test "analyze labels and consts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag = dia.Diag.init(arena.allocator(), "<test>", "");

    const src = "@start:\njmp @start\n";
    const tokens = try @import("lexer.zig").lex(arena.allocator(), &diag, src);
    const items = try @import("parser.zig").parse(arena.allocator(), &diag, tokens.items);
    const sym = try analyze(arena.allocator(), &diag, items.items);

    try std.testing.expectEqual(0, diag.errors.items.len);
    try std.testing.expectEqual(0, sym.labels.get("start").?);
    try std.testing.expectEqual(1, sym.next_slot);
}

test "reject reserved name as const" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag = dia.Diag.init(arena.allocator(), "<test>", "");

    const src = "const lda = 5\n";
    const tokens = try @import("lexer.zig").lex(arena.allocator(), &diag, src);
    const items = try @import("parser.zig").parse(arena.allocator(), &diag, tokens.items);

    _ = try analyze(arena.allocator(), &diag, items.items);

    try std.testing.expect(diag.hasErrors());
}

test "reject flag slot 15" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag = dia.Diag.init(arena.allocator(), "<test>", "");

    const src = "flag 15\n";
    const tokens = try @import("lexer.zig").lex(arena.allocator(), &diag, src);
    const items = try @import("parser.zig").parse(arena.allocator(), &diag, tokens.items);

    _ = try analyze(arena.allocator(), &diag, items.items);

    try std.testing.expect(diag.hasErrors());
}
