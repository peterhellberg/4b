const std = @import("std");
const diagnostics = @import("diagnostics.zig");
const lexer = @import("lexer.zig");
const model = @import("model.zig");

const Operand = model.Operand;
const Item = model.Item;
const Token = lexer.Token;
const Kind = lexer.Kind;

pub const ParseError = error{
    ParseError,
    OutOfMemory,
};

pub fn parse(alloc: std.mem.Allocator, diag: *diagnostics.Diag, tokens: []const Token) ParseError!std.ArrayList(Item) {
    var items = std.ArrayList(Item).empty;
    var idx: usize = 0;

    while (idx < tokens.len) {
        const tok = tokens[idx];
        switch (tok.kind) {
            .eol => {
                idx += 1;
                continue;
            },
            .eof => break,
            else => {},
        }
        try parseLine(alloc, diag, tokens, &idx, &items);
    }

    return items;
}

fn peek(tokens: []const Token, idx: usize) Token {
    if (idx < tokens.len) return tokens[idx];
    return tokens[tokens.len - 1];
}

fn parseLine(alloc: std.mem.Allocator, diag: *diagnostics.Diag, tokens: []const Token, idx: *usize, items: *std.ArrayList(Item)) ParseError!void {
    while (true) {
        const t = peek(tokens, idx.*);
        if (t.kind == .eol or t.kind == .eof) break;
        if (t.kind == .at) {
            idx.* += 1;
            const name_tok = expectToken(tokens, idx, .ident, diag, "expected label name after '@'") orelse return error.ParseError;

            _ = expectToken(tokens, idx, .colon, diag, "expected ':' after label name") orelse return error.ParseError;

            try items.append(alloc, .{ .label = .{ .name = name_tok.text, .line = name_tok.line, .col = name_tok.col } });
        } else if (t.kind == .ident) {
            try parseStatement(alloc, diag, tokens, idx, items);

            break;
        } else {
            diag.err(t.line, t.col, "unexpected token '{s}'", .{t.text});
            skipToEol(tokens, idx);

            return error.ParseError;
        }
    }

    if (peek(tokens, idx.*).kind == .eol) idx.* += 1;
}

fn parseStatement(alloc: std.mem.Allocator, diag: *diagnostics.Diag, tokens: []const Token, idx: *usize, items: *std.ArrayList(Item)) ParseError!void {
    const tok = tokens[idx.*];
    const name = toLower(alloc, tok.text);

    if (std.mem.eql(u8, name, "const")) {
        idx.* += 1;
        const name_tok = expectToken(tokens, idx, .ident, diag, "expected const name") orelse return error.ParseError;

        _ = expectToken(tokens, idx, .equals, diag, "expected '=' after const name") orelse return error.ParseError;

        const val_tok = expectToken(tokens, idx, .number, diag, "expected numeric value") orelse return error.ParseError;
        if (val_tok.value > 15) {
            diag.err(val_tok.line, val_tok.col, "const value out of range (0-15)", .{});
            return error.ParseError;
        }

        try items.append(alloc, .{ .const_def = .{ .name = name_tok.text, .value = @intCast(val_tok.value), .line = name_tok.line, .col = name_tok.col } });

        return;
    }

    if (std.mem.eql(u8, name, "org")) {
        idx.* += 1;

        const val_tok = expectToken(tokens, idx, .number, diag, "expected position value for org") orelse return error.ParseError;
        if (val_tok.value > 256) {
            diag.err(val_tok.line, val_tok.col, "org position out of range (0-256)", .{});
            return error.ParseError;
        }

        try items.append(alloc, .{ .org = .{ .value = @intCast(val_tok.value), .line = val_tok.line, .col = val_tok.col } });

        return;
    }

    if (std.mem.eql(u8, name, "dw")) {
        idx.* += 1;

        const val_tok = expectToken(tokens, idx, .number, diag, "expected word value for dw") orelse return error.ParseError;
        if (val_tok.value > 0xFFF) {
            diag.err(val_tok.line, val_tok.col, "dw value out of range (0-0xFFF)", .{});
            return error.ParseError;
        }

        try items.append(alloc, .{ .dw = .{ .value = @intCast(val_tok.value), .line = val_tok.line, .col = val_tok.col } });

        return;
    }

    const spec = model.lookupSpec(tok.text) orelse {
        diag.err(tok.line, tok.col, "unknown mnemonic or directive '{s}'", .{tok.text});
        skipToEol(tokens, idx);

        return error.ParseError;
    };
    idx.* += 1;

    var a: ?Operand = null;
    var b: ?Operand = null;

    if (spec.a != .none) {
        a = parseOperand(tokens, idx, spec.a, diag);
        if (a == null) return error.ParseError;
    }

    if (spec.b != .none) {
        if (peek(tokens, idx.*).kind == .comma) idx.* += 1;

        b = parseOperand(tokens, idx, spec.b, diag);

        if (b == null) return error.ParseError;
    }

    const t2 = peek(tokens, idx.*);

    if (t2.kind != .eol and t2.kind != .eof) {
        diag.err(t2.line, t2.col, "unexpected token after instruction", .{});
        skipToEol(tokens, idx);

        return error.ParseError;
    }

    try items.append(alloc, .{ .inst = .{
        .spec = spec,
        .a = a,
        .b = b,
        .line = tok.line,
        .col = tok.col,
    } });
}

fn parseOperand(tokens: []const Token, idx: *usize, kind: model.OperandKind, diag: *diagnostics.Diag) ?Operand {
    const tok = peek(tokens, idx.*);

    switch (kind) {
        .reg => {
            if (tok.kind == .ident) {
                if (parseRegisterIndex(tok.text)) |reg_idx| {
                    idx.* += 1;

                    return .{ .reg = reg_idx };
                }

                if (std.ascii.startsWithIgnoreCase(tok.text, "r") and isAllDigits(tok.text[1..])) {
                    diag.err(tok.line, tok.col, "register index out of range (r0-r15)", .{});

                    idx.* += 1;

                    return null;
                }
            }

            diag.err(tok.line, tok.col, "expected register (r0-r15)", .{});

            return null;
        },
        .imm => {
            if (tok.kind == .hash) {
                idx.* += 1;

                const val_tok = expectToken(tokens, idx, .number, diag, "expected immediate value after '#'") orelse return null;

                if (val_tok.value > 15) {
                    diag.err(val_tok.line, val_tok.col, "immediate value out of range (0-15)", .{});

                    return null;
                }

                return .{ .imm = @intCast(val_tok.value) };
            }

            diag.err(tok.line, tok.col, "expected '#value' for immediate operand", .{});

            return null;
        },
        .reg_or_imm => {
            if (tok.kind == .hash) {
                idx.* += 1;

                const val_tok = expectToken(tokens, idx, .number, diag, "expected immediate value after '#'") orelse return null;

                if (val_tok.value > 15) {
                    diag.err(val_tok.line, val_tok.col, "immediate value out of range (0-15)", .{});

                    return null;
                }

                return .{ .imm = @intCast(val_tok.value) };
            }
            if (tok.kind == .ident) {
                if (parseRegisterIndex(tok.text)) |reg_idx| {
                    idx.* += 1;

                    return .{
                        .reg = reg_idx,
                    };
                }

                if (std.ascii.startsWithIgnoreCase(tok.text, "r") and isAllDigits(tok.text[1..])) {
                    diag.err(tok.line, tok.col, "register index out of range (r0-r15)", .{});

                    idx.* += 1;

                    return null;
                }
            }

            diag.err(tok.line, tok.col, "expected register or '#value' for operand", .{});

            return null;
        },
        .label_or_slot => {
            if (tok.kind == .at) {
                idx.* += 1;

                const name_tok = expectToken(tokens, idx, .ident, diag, "expected label name after '@'") orelse return null;

                return .{ .label_ref = name_tok.text };
            }
            if (tok.kind == .number) {
                idx.* += 1;

                if (tok.value > 15) {
                    diag.err(tok.line, tok.col, "flag slot out of range (0-15)", .{});

                    return null;
                }

                return .{ .flag_slot = @intCast(tok.value) };
            }

            diag.err(tok.line, tok.col, "expected '@name' or number for flag/jmp", .{});

            return null;
        },
        .none => return null,
    }
}

fn expectToken(tokens: []const Token, idx: *usize, comptime expected: Kind, diag: *diagnostics.Diag, comptime msg: []const u8) ?Token {
    const tok = peek(tokens, idx.*);

    if (tok.kind == expected) {
        idx.* += 1;
        return tok;
    }

    diag.err(tok.line, tok.col, msg, .{});

    return null;
}

fn skipToEol(tokens: []const Token, idx: *usize) void {
    while (idx.* < tokens.len and
        tokens[idx.*].kind != .eol and
        tokens[idx.*].kind != .eof)
    {
        idx.* += 1;
    }
}

fn toLower(alloc: std.mem.Allocator, s: []const u8) []const u8 {
    const buf = alloc.alloc(u8, s.len) catch return s;

    for (s, 0..) |c, i| {
        buf[i] = std.ascii.toLower(c);
    }

    return buf;
}

fn parseRegisterIndex(text: []const u8) ?u4 {
    if (text.len < 2) return null;

    if (!std.ascii.startsWithIgnoreCase(text, "r")) return null;

    const digits = text[1..];
    if (digits.len == 0 or !isAllDigits(digits)) return null;

    var v: u32 = 0;
    for (digits) |c| v = v * 10 + (c - '0');
    if (v > 15) return null;

    return @intCast(v);
}

fn isAllDigits(s: []const u8) bool {
    if (s.len == 0) return false;

    for (s) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }

    return true;
}

test "parse lda #8 sta r1" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag = diagnostics.Diag.init(arena.allocator(), "<test>", "lda #8\nsta r1\n");

    const tokens = try lexer.lex(arena.allocator(), &diag, "lda #8\nsta r1\n");
    const items = try parse(arena.allocator(), &diag, tokens.items);

    try std.testing.expectEqual(@as(usize, 2), items.items.len);
    try std.testing.expectEqual(@as(usize, 0), diag.errors.items.len);

    const inst0 = items.items[0].inst;

    try std.testing.expectEqual(model.Op.lda_mem, inst0.spec.op);
    try std.testing.expectEqual(@as(u4, 8), inst0.a.?.imm);

    const inst1 = items.items[1].inst;

    try std.testing.expectEqual(model.Op.sta, inst1.spec.op);
    try std.testing.expectEqual(@as(u4, 1), inst1.a.?.reg);
}

test "parse label definition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag = diagnostics.Diag.init(arena.allocator(), "<test>", "@foo:\n");

    const tokens = try lexer.lex(arena.allocator(), &diag, "@foo:\n");
    const items = try parse(arena.allocator(), &diag, tokens.items);

    try std.testing.expectEqual(@as(usize, 1), items.items.len);
    try std.testing.expectEqual(@as(usize, 0), diag.errors.items.len);
    try std.testing.expectEqualStrings("foo", items.items[0].label.name);
}

test "parse jmp @label" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag = diagnostics.Diag.init(arena.allocator(), "<test>", "jmp @start\n");

    const tokens = try lexer.lex(arena.allocator(), &diag, "jmp @start\n");
    const items = try parse(arena.allocator(), &diag, tokens.items);

    try std.testing.expectEqual(@as(usize, 0), diag.errors.items.len);

    const inst = items.items[0].inst;

    try std.testing.expectEqual(model.Op.jmp, inst.spec.op);
    try std.testing.expectEqualStrings("start", inst.a.?.label_ref);
}

test "parse const" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag = diagnostics.Diag.init(arena.allocator(), "<test>", "const X = 5\n");

    const tokens = try lexer.lex(arena.allocator(), &diag, "const X = 5\n");
    const items = try parse(arena.allocator(), &diag, tokens.items);

    try std.testing.expectEqual(@as(usize, 0), diag.errors.items.len);
    try std.testing.expectEqualStrings("X", items.items[0].const_def.name);
    try std.testing.expectEqual(@as(u4, 5), items.items[0].const_def.value);
}

test "parse peek r0, r1" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag = diagnostics.Diag.init(arena.allocator(), "<test>", "peek r0, r1\n");

    const tokens = try lexer.lex(arena.allocator(), &diag, "peek r0, r1\n");
    const items = try parse(arena.allocator(), &diag, tokens.items);

    try std.testing.expectEqual(@as(usize, 0), diag.errors.items.len);

    const inst = items.items[0].inst;

    try std.testing.expectEqual(model.Op.peek, inst.spec.op);
    try std.testing.expectEqual(@as(u4, 0), inst.a.?.reg);
    try std.testing.expectEqual(@as(u4, 1), inst.b.?.reg);
}
