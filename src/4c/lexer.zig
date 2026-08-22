const std = @import("std");
const dia = @import("dia");

pub const Kind = enum {
    ident,
    number,
    // keywords
    kw_u4,
    kw_fn,
    kw_const,
    kw_if,
    kw_else,
    kw_for,
    kw_break,
    kw_continue,
    // punctuation and operators
    lparen,
    rparen,
    lbrace,
    rbrace,
    semi,
    comma,
    assign, // =
    plus_assign, // +=
    minus_assign, // -=
    eq, // ==
    neq, // !=
    lt, // <
    gt, // >
    le, // <=
    ge, // >=
    amp_amp, // &&
    bar_bar, // ||
    bang, // !
    plus, // +
    minus, // -
    shl, // <<
    shr, // >>
    amp, // &
    eof,
};

pub const Token = struct {
    kind: Kind,
    text: []const u8,
    value: u64,
    line: u32,
    col: u32,
};

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentCont(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn keywordKind(text: []const u8) ?Kind {
    const map = .{
        .{ "u4", Kind.kw_u4 },
        .{ "fn", Kind.kw_fn },
        .{ "const", Kind.kw_const },
        .{ "if", Kind.kw_if },
        .{ "else", Kind.kw_else },
        .{ "for", Kind.kw_for },
        .{ "break", Kind.kw_break },
        .{ "continue", Kind.kw_continue },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, text, entry[0])) return entry[1];
    }
    return null;
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
            i += 1;
            line += 1;
            col = 1;
            continue;
        }

        if (c == '\r' or c == ' ' or c == '\t') {
            i += 1;
            col += 1;
            continue;
        }

        if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
            while (i < src.len and src[i] != '\n') i += 1;
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
            var value: u64 = 0;
            var started = false;
            while (i < src.len) {
                const d = src[i];
                const dv: ?u64 = switch (radix) {
                    10 => if (std.ascii.isDigit(d)) d - '0' else null,
                    16 => std.fmt.charToDigit(d, 16) catch null,
                    2 => if (d == '0') @as(u64, 0) else if (d == '1') @as(u64, 1) else null,
                    else => unreachable,
                };
                if (dv == null) break;
                started = true;
                value = value *% radix +% dv.?;
                i += 1;
                col += 1;
            }
            if (!started) {
                diag.err(start_line, start_col, "expected digits after '{s}'", .{src[start..i]});
                return error.LexError;
            }
            if (i < src.len and isIdentCont(src[i])) {
                diag.err(start_line, start_col, "malformed number literal '{s}'", .{src[start .. i + 1]});
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
            const text = src[start..i];
            const kind = keywordKind(text) orelse Kind.ident;
            try tokens.append(alloc, .{ .kind = kind, .text = text, .value = 0, .line = start_line, .col = start_col });
            continue;
        }

        // two-character operators first (maximal munch)
        if (i + 1 < src.len) {
            const pair = src[i .. i + 2];
            const pair_kind: ?Kind = blk: {
                if (std.mem.eql(u8, pair, "==")) break :blk Kind.eq;
                if (std.mem.eql(u8, pair, "!=")) break :blk Kind.neq;
                if (std.mem.eql(u8, pair, "<=")) break :blk Kind.le;
                if (std.mem.eql(u8, pair, ">=")) break :blk Kind.ge;
                if (std.mem.eql(u8, pair, "&&")) break :blk Kind.amp_amp;
                if (std.mem.eql(u8, pair, "||")) break :blk Kind.bar_bar;
                if (std.mem.eql(u8, pair, "<<")) break :blk Kind.shl;
                if (std.mem.eql(u8, pair, ">>")) break :blk Kind.shr;
                if (std.mem.eql(u8, pair, "+=")) break :blk Kind.plus_assign;
                if (std.mem.eql(u8, pair, "-=")) break :blk Kind.minus_assign;
                break :blk null;
            };
            if (pair_kind) |k| {
                try tokens.append(alloc, .{ .kind = k, .text = pair, .value = 0, .line = line, .col = col });
                i += 2;
                col += 2;
                continue;
            }
        }

        const single: ?Kind = switch (c) {
            '(' => Kind.lparen,
            ')' => Kind.rparen,
            '{' => Kind.lbrace,
            '}' => Kind.rbrace,
            ';' => Kind.semi,
            ',' => Kind.comma,
            '=' => Kind.assign,
            '<' => Kind.lt,
            '>' => Kind.gt,
            '!' => Kind.bang,
            '+' => Kind.plus,
            '-' => Kind.minus,
            '&' => Kind.amp,
            else => null,
        };
        if (single) |k| {
            try tokens.append(alloc, .{ .kind = k, .text = src[i .. i + 1], .value = 0, .line = line, .col = col });
            i += 1;
            col += 1;
            continue;
        }

        diag.err(line, col, "unexpected character '{c}'", .{c});
        return error.LexError;
    }

    try tokens.append(alloc, .{ .kind = .eof, .text = "", .value = 0, .line = line, .col = col });
    return tokens;
}
