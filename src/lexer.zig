const std = @import("std");
const dia = @import("dia");

pub const Kind = enum {
    ident,
    number,
    at,
    hash,
    comma,
    colon,
    equals,
    eol,
    eof,
};

pub const Token = struct {
    kind: Kind,
    text: []const u8,
    value: u32,
    line: u32,
    col: u32,
};

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentCont(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isHexDigit(c: u8) bool {
    return std.ascii.isDigit(c) or
        (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn hexVal(c: u8) u8 {
    if (std.ascii.isDigit(c)) return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;

    return c - 'A' + 10;
}

fn pushSingle(tokens: *std.ArrayList(Token), alloc: std.mem.Allocator, src: []const u8, i: *usize, line: u32, col: *u32, kind: Kind) !void {
    try tokens.append(alloc, .{
        .kind = kind,
        .text = src[i.* .. i.* + 1],
        .value = 0,
        .line = line,
        .col = col.*,
    });
    i.* += 1;
    col.* += 1;
}

pub const LexError = error{ LexError, OutOfMemory };

pub fn lex(alloc: std.mem.Allocator, diag: *dia.Diag, src: []const u8) LexError!std.ArrayList(Token) {
    var tokens = std.ArrayList(Token).empty;
    var i: usize = 0;
    var line: u32 = 1;
    var col: u32 = 1;

    while (i < src.len) {
        const c = src[i];

        if (c == '\n') {
            try tokens.append(alloc, .{
                .kind = .eol,
                .text = src[i .. i + 1],
                .value = 0,
                .line = line,
                .col = col,
            });
            i += 1;
            line += 1;
            col = 1;
            continue;
        }

        if (c == '\r') {
            i += 1;
            col += 1;
            continue;
        }

        if (c == ';') {
            while (i < src.len and src[i] != '\n') i += 1;
            continue;
        }

        if (c == ' ' or c == '\t') {
            i += 1;
            col += 1;
            continue;
        }

        if (c == '@') {
            try pushSingle(&tokens, alloc, src, &i, line, &col, .at);
            continue;
        }

        if (c == '#') {
            try pushSingle(&tokens, alloc, src, &i, line, &col, .hash);
            continue;
        }

        if (c == ',') {
            try pushSingle(&tokens, alloc, src, &i, line, &col, .comma);
            continue;
        }

        if (c == ':') {
            try pushSingle(&tokens, alloc, src, &i, line, &col, .colon);
            continue;
        }

        if (c == '=') {
            try pushSingle(&tokens, alloc, src, &i, line, &col, .equals);
            continue;
        }

        if (std.ascii.isDigit(c)) {
            const start = i;
            const start_line = line;
            const start_col = col;

            var radix: u8 = 10;

            if (c == '0' and i + 1 < src.len) {
                const next = src[i + 1];
                if (next == 'x' or next == 'X') {
                    radix = 16;
                    i += 2;
                    col += 2;
                } else if (next == 'b' or next == 'B') {
                    radix = 2;
                    i += 2;
                    col += 2;
                }
            }

            var value: u32 = 0;
            var started = false;

            while (i < src.len) {
                const d = src[i];
                const valid = switch (radix) {
                    10 => std.ascii.isDigit(d),
                    16 => isHexDigit(d),
                    2 => d == '0' or d == '1',
                    else => unreachable,
                };
                if (!valid) break;
                started = true;
                const hi = @mulWithOverflow(value, @as(u32, radix));
                const lo = @addWithOverflow(hi[0], @as(u32, hexVal(d)));
                if (hi[1] != 0 or lo[1] != 0) {
                    diag.err(start_line, start_col, "numeric literal out of range", .{});
                    return error.LexError;
                }
                value = lo[0];
                i += 1;
                col += 1;
            }

            if (!started) {
                diag.err(start_line, start_col, "expected digits after '{s}'", .{src[start..i]});
                return error.LexError;
            }

            if (i < src.len and isIdentCont(src[i])) {
                diag.err(start_line, start_col, "invalid digit in numeric literal", .{});
                return error.LexError;
            }

            try tokens.append(alloc, .{
                .kind = .number,
                .text = src[start..i],
                .value = value,
                .line = start_line,
                .col = start_col,
            });

            continue;
        }

        if (isIdentStart(c)) {
            const start = i;
            const start_line = line;
            const start_col = col;
            while (i < src.len and isIdentCont(src[i])) {
                i += 1;
                col += 1;
            }
            try tokens.append(alloc, .{
                .kind = .ident,
                .text = src[start..i],
                .value = 0,
                .line = start_line,
                .col = start_col,
            });
            continue;
        }

        diag.err(line, col, "unexpected character '{c}'", .{c});
        return error.LexError;
    }

    if (tokens.items.len == 0 or tokens.items[tokens.items.len - 1].kind != .eol) {
        try tokens.append(alloc, .{
            .kind = .eol,
            .text = "",
            .value = 0,
            .line = line,
            .col = col,
        });
    }
    try tokens.append(alloc, .{
        .kind = .eof,
        .text = "",
        .value = 0,
        .line = line,
        .col = col,
    });

    return tokens;
}

fn expectTokens(src: []const u8, expected: []const Kind) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag = dia.Diag.init(arena.allocator(), "<test>", src);

    const tokens = try lex(arena.allocator(), &diag, src);

    var j: usize = 0;

    for (expected) |k| {
        try std.testing.expect(j < tokens.items.len);
        try std.testing.expectEqual(k, tokens.items[j].kind);

        j += 1;
    }

    try std.testing.expectEqual(expected.len, tokens.items.len);
}

test "basic tokens" {
    try expectTokens("lda #8", &.{ .ident, .hash, .number, .eol, .eof });
}

test "label syntax" {
    try expectTokens("@foo:", &.{ .at, .ident, .colon, .eol, .eof });
}

test "numbers hex and binary" {
    try expectTokens("0xF 0b1010", &.{ .number, .number, .eol, .eof });
}

test "comments ignored" {
    try expectTokens("lda ;comment\n", &.{ .ident, .eol, .eof });
}

test "empty line" {
    try expectTokens("\n", &.{ .eol, .eof });
}

fn expectLexError(src: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diag = dia.Diag.init(arena.allocator(), "<test>", src);

    const result = lex(arena.allocator(), &diag, src);
    try std.testing.expectError(error.LexError, result);
    try std.testing.expect(diag.hasErrors());
}

test "numeric literal overflow" {
    try expectLexError("99999999999\n");
    try expectLexError("0xFFFFFFFFF\n");
}

test "numeric literal errors" {
    try expectLexError("0x\n");
    try expectLexError("0b\n");
    try expectLexError("123abc\n");
    try expectLexError("`\n");
}
