const std = @import("std");
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");
const dia = @import("dia");

const Token = lexer.Token;
const Kind = lexer.Kind;
const Span = ast.Span;

pub const ParseError = error{ ParseError, OutOfMemory };

pub fn parse(
    alloc: std.mem.Allocator,
    diag: *dia.Diag,
    tokens: []const Token,
) ParseError!*ast.Program {
    var p = Parser{ .alloc = alloc, .diag = diag, .tokens = tokens, .pos = 0 };
    return p.parseProgram();
}

pub const Parser = struct {
    alloc: std.mem.Allocator,
    diag: *dia.Diag,
    tokens: []const Token,
    pos: usize,

    fn peek(self: *Parser) Token {
        return self.tokens[self.pos];
    }

    fn advance(self: *Parser) Token {
        const t = self.tokens[self.pos];
        if (self.pos + 1 < self.tokens.len) self.pos += 1;
        return t;
    }

    fn errAt(self: *Parser, t: Token, comptime fmt: []const u8, args: anytype) ParseError {
        self.diag.err(t.line, t.col, fmt, args);
        return error.ParseError;
    }

    fn expect(self: *Parser, kind: Kind) ParseError!Token {
        const t = self.peek();
        if (t.kind != kind) {
            return self.errAt(t, "expected {s}, found '{s}'", .{ kindName(kind), t.text });
        }
        return self.advance();
    }

    fn mkExpr(self: *Parser, span: Span, kind: ast.ExprKind) ParseError!*ast.Expr {
        const e = try self.alloc.create(ast.Expr);
        e.* = .{ .span = span, .kind = kind };
        return e;
    }

    fn mkCond(self: *Parser, span: Span, kind: ast.CondKind) ParseError!*ast.Cond {
        const c = try self.alloc.create(ast.Cond);
        c.* = .{ .span = span, .kind = kind };
        return c;
    }

    fn mkStmt(self: *Parser, span: Span, kind: ast.StmtKind) ParseError!*ast.Stmt {
        const s = try self.alloc.create(ast.Stmt);
        s.* = .{ .span = span, .kind = kind };
        return s;
    }

    // ---- top level ----

    pub fn parseProgram(self: *Parser) ParseError!*ast.Program {
        var globals = std.ArrayList(ast.Global).empty;

        while (true) {
            switch (self.peek().kind) {
                .kw_u4 => {
                    const g = try self.parseVarDecl();
                    try globals.append(self.alloc, .{ .var_decl = g });
                },
                .kw_const => {
                    const g = try self.parseConstDecl();
                    try globals.append(self.alloc, .{ .const_decl = g });
                },
                .kw_fn => break,
                .eof => return self.errAt(self.peek(), "expected 'fn main', found end of file", .{}),
                else => {
                    const t = self.advance();
                    self.diag.err(t.line, t.col, "expected declaration, found '{s}'", .{t.text});
                    self.syncTopLevel();
                },
            }
        }

        const main_body = try self.parseFnMain();

        if (self.peek().kind != .eof) {
            const t = self.peek();
            self.diag.err(t.line, t.col, "unexpected '{s}' after 'fn main'", .{t.text});
            return error.ParseError;
        }

        const prog = try self.alloc.create(ast.Program);
        prog.* = .{ .globals = globals.items, .main_body = main_body };
        return prog;
    }

    fn parseVarDecl(self: *Parser) ParseError!ast.VarDecl {
        const start = self.expect(.kw_u4) catch unreachable;
        const name_tok = try self.expect(.ident);
        var init_expr: ?*ast.Expr = null;
        if (self.peek().kind == .assign) {
            _ = self.advance();
            init_expr = try self.parseValue();
        }
        _ = try self.expect(.semi);
        return .{ .name = name_tok.text, .init_expr = init_expr, .span = .{ .line = start.line, .col = start.col } };
    }

    fn parseConstDecl(self: *Parser) ParseError!ast.ConstDecl {
        const start = self.expect(.kw_const) catch unreachable;
        const name_tok = try self.expect(.ident);
        _ = try self.expect(.assign);
        const value_expr = try self.parseValue();
        _ = try self.expect(.semi);
        return .{ .name = name_tok.text, .value_expr = value_expr, .span = .{ .line = start.line, .col = start.col } };
    }

    fn parseFnMain(self: *Parser) ParseError!*ast.Stmt {
        _ = try self.expect(.kw_fn);
        const name_tok = try self.expect(.ident);
        if (!std.mem.eql(u8, name_tok.text, "main")) {
            return self.errAt(name_tok, "expected 'main', found '{s}'", .{name_tok.text});
        }
        _ = try self.expect(.lparen);
        _ = try self.expect(.rparen);
        return self.parseBlock();
    }

    // ---- statements ----

    fn parseBlock(self: *Parser) ParseError!*ast.Stmt {
        const start = try self.expect(.lbrace);
        var stmts = std.ArrayList(*ast.Stmt).empty;
        while (self.peek().kind != .rbrace) {
            if (self.peek().kind == .eof) {
                return self.errAt(self.peek(), "expected '}}', found end of file", .{});
            }
            const s: ?*ast.Stmt = self.parseStmt() catch |e| switch (e) {
                error.OutOfMemory => return e,
                error.ParseError => blk: {
                    self.syncStmt();
                    break :blk null;
                },
            };
            if (s) |one| try stmts.append(self.alloc, one);
        }
        _ = try self.expect(.rbrace);
        return self.mkStmt(.{ .line = start.line, .col = start.col }, .{ .block = stmts.items });
    }

    fn syncStmt(self: *Parser) void {
        while (true) {
            switch (self.peek().kind) {
                .semi => {
                    _ = self.advance();
                    return;
                },
                .rbrace, .eof => return,
                else => _ = self.advance(),
            }
        }
    }

    fn syncTopLevel(self: *Parser) void {
        while (true) {
            switch (self.peek().kind) {
                .kw_u4, .kw_const, .kw_fn, .eof => return,
                else => _ = self.advance(),
            }
        }
    }

    fn parseStmt(self: *Parser) ParseError!*ast.Stmt {
        const t = self.peek();
        switch (t.kind) {
            .kw_if => return self.parseIf(),
            .kw_while => return self.parseWhile(),
            .kw_break => {
                _ = self.advance();
                _ = try self.expect(.semi);
                return self.mkStmt(.{ .line = t.line, .col = t.col }, .brk);
            },
            .kw_continue => {
                _ = self.advance();
                _ = try self.expect(.semi);
                return self.mkStmt(.{ .line = t.line, .col = t.col }, .cont);
            },
            .lbrace => return self.parseBlock(),
            .semi => {
                _ = self.advance();
                return self.mkStmt(.{ .line = t.line, .col = t.col }, .empty);
            },
            .ident => {
                const s = try self.parseIdentStmt();
                _ = try self.expect(.semi);
                return s;
            },
            else => return self.errAt(t, "expected statement, found '{s}'", .{t.text}),
        }
    }

    fn parseIdentStmt(self: *Parser) ParseError!*ast.Stmt {
        const name_tok = self.advance();
        switch (self.peek().kind) {
            .lparen => return self.parseVoidCall(name_tok),
            .assign, .plus_assign, .minus_assign => {
                const op: ast.AssignOp = switch (self.advance().kind) {
                    .assign => .assign,
                    .plus_assign => .add_assign,
                    else => .sub_assign,
                };
                const value = try self.parseValue();
                return self.mkStmt(
                    .{ .line = name_tok.line, .col = name_tok.col },
                    .{ .assign = .{ .target = name_tok.text, .op = op, .value = value } },
                );
            },
            else => {
                return self.errAt(self.peek(), "expected '=', '+=', '-=' or '(' after '{s}'", .{name_tok.text});
            },
        }
    }

    fn parseVoidCall(self: *Parser, name_tok: Token) ParseError!*ast.Stmt {
        const span = Span{ .line = name_tok.line, .col = name_tok.col };
        _ = try self.expect(.lparen);

        var call: ast.VoidCall = undefined;
        if (std.mem.eql(u8, name_tok.text, "cls")) {
            _ = try self.expect(.rparen);
            call = .cls;
        } else if (std.mem.eql(u8, name_tok.text, "halt")) {
            _ = try self.expect(.rparen);
            call = .halt;
        } else if (std.mem.eql(u8, name_tok.text, "flip")) {
            const x = try self.parseValue();
            _ = try self.expect(.comma);
            const y = try self.parseValue();
            _ = try self.expect(.rparen);
            call = .{ .flip = .{ .x = x, .y = y } };
        } else {
            if (isValueBuiltin(name_tok.text)) {
                return self.errAt(name_tok, "result of '{s}()' cannot be discarded", .{name_tok.text});
            }
            return self.errAt(name_tok, "unknown call '{s}'", .{name_tok.text});
        }
        return self.mkStmt(span, .{ .voidcall = call });
    }

    fn parseIf(self: *Parser) ParseError!*ast.Stmt {
        const start = self.advance(); // kw_if
        _ = try self.expect(.lparen);
        const cond = try self.parseCond();
        _ = try self.expect(.rparen);
        const then_stmt = try self.parseStmt();
        var else_stmt: ?*ast.Stmt = null;
        if (self.peek().kind == .kw_else) {
            _ = self.advance();
            else_stmt = try self.parseStmt();
        }
        return self.mkStmt(
            .{ .line = start.line, .col = start.col },
            .{ .if_stmt = .{ .cond = cond, .then_stmt = then_stmt, .else_stmt = else_stmt } },
        );
    }

    fn parseWhile(self: *Parser) ParseError!*ast.Stmt {
        const start = self.advance(); // kw_while
        _ = try self.expect(.lparen);
        const cond = try self.parseCond();
        _ = try self.expect(.rparen);
        const body = try self.parseStmt();
        return self.mkStmt(
            .{ .line = start.line, .col = start.col },
            .{ .while_stmt = .{ .cond = cond, .body = body } },
        );
    }

    // ---- conditions ----

    fn isRelop(k: Kind) bool {
        return switch (k) {
            .eq, .neq, .lt, .gt, .le, .ge => true,
            else => false,
        };
    }

    fn relopOf(k: Kind) ast.CmpOp {
        return switch (k) {
            .eq => .eq,
            .neq => .ne,
            .lt => .lt,
            .gt => .gt,
            .le => .le,
            .ge => .ge,
            else => unreachable,
        };
    }

    fn parseCond(self: *Parser) ParseError!*ast.Cond {
        var lhs = try self.parseCondAnd();
        while (self.peek().kind == .bar_bar) {
            _ = self.advance();
            const rhs = try self.parseCondAnd();
            const span = lhs.span;
            lhs = try self.mkCond(span, .{ .or_cond = .{ .lhs = lhs, .rhs = rhs } });
        }
        return lhs;
    }

    fn parseCondAnd(self: *Parser) ParseError!*ast.Cond {
        var lhs = try self.parseCondNot();
        while (self.peek().kind == .amp_amp) {
            _ = self.advance();
            const rhs = try self.parseCondNot();
            const span = lhs.span;
            lhs = try self.mkCond(span, .{ .and_cond = .{ .lhs = lhs, .rhs = rhs } });
        }
        return lhs;
    }

    fn parseCondNot(self: *Parser) ParseError!*ast.Cond {
        if (self.peek().kind == .bang) {
            const t = self.advance();
            const inner = try self.parseCondNot();
            return self.mkCond(.{ .line = t.line, .col = t.col }, .{ .not_cond = inner });
        }
        return self.parseCondP();
    }

    fn parseCondP(self: *Parser) ParseError!*ast.Cond {
        // "( cond )" vs comparison over a parenthesized value: speculate.
        if (self.peek().kind == .lparen) {
            const saved_pos = self.pos;
            const saved_errors = self.diag.errors.items.len;
            _ = self.advance(); // (

            var ok = false;
            var inner: ?*ast.Cond = null;
            if (self.parseCond()) |c| {
                if (self.peek().kind == .rparen) {
                    _ = self.advance();
                    if (!isRelop(self.peek().kind)) {
                        inner = c;
                        ok = true;
                    }
                }
            } else |_| {}

            if (ok) return inner.?;

            self.pos = saved_pos;
            self.diag.errors.shrinkRetainingCapacity(saved_errors);
        }

        const lhs = try self.parseValue();
        if (isRelop(self.peek().kind)) {
            const op = relopOf(self.advance().kind);
            const rhs = try self.parseValue();
            return self.mkCond(lhs.span, .{ .cmp = .{ .op = op, .lhs = lhs, .rhs = rhs } });
        }
        return self.mkCond(lhs.span, .{ .truthy = lhs });
    }

    // ---- values ----

    fn parseValue(self: *Parser) ParseError!*ast.Expr {
        return self.parseAdd();
    }

    fn parseAdd(self: *Parser) ParseError!*ast.Expr {
        var lhs = try self.parseBand();
        while (true) {
            const op: ?ast.ArithOp = switch (self.peek().kind) {
                .plus => .add,
                .minus => .sub,
                else => null,
            };
            const o = op orelse return lhs;
            _ = self.advance();
            const rhs = try self.parseBand();
            const span = lhs.span;
            lhs = try self.mkExpr(span, .{ .arith = .{ .op = o, .lhs = lhs, .rhs = rhs } });
        }
    }

    fn parseBand(self: *Parser) ParseError!*ast.Expr {
        const lhs = try self.parseShift();
        if (self.peek().kind == .amp) {
            _ = self.advance();
            const mt = self.peek();
            if (mt.kind != .number and mt.kind != .ident) {
                return self.errAt(mt, "expected number or constant after '&', found '{s}'", .{mt.text});
            }
            _ = self.advance();
            const mask_expr: *ast.Expr = if (mt.kind == .number)
                try self.mkExpr(.{ .line = mt.line, .col = mt.col }, .{ .int = mt.value })
            else
                try self.mkExpr(.{ .line = mt.line, .col = mt.col }, .{ .variable = mt.text });
            return self.mkExpr(lhs.span, .{ .band = .{ .lhs = lhs, .mask_expr = mask_expr } });
        }
        return lhs;
    }

    fn parseShift(self: *Parser) ParseError!*ast.Expr {
        var operand = try self.parseUnary();
        while (true) {
            const left: ?bool = switch (self.peek().kind) {
                .shl => true,
                .shr => false,
                else => null,
            };
            const l = left orelse return operand;
            _ = self.advance();
            const dist = try self.parseUnary();
            const span = operand.span;
            const d: ast.ShiftDist = switch (dist.kind) {
                .int => |v| .{ .lit = v },
                .variable => |name| .{ .variable = name },
                else => .{ .expr = dist },
            };
            operand = try self.mkExpr(span, .{ .shift = .{ .left = l, .operand = operand, .dist = d } });
        }
    }

    fn parseUnary(self: *Parser) ParseError!*ast.Expr {
        if (self.peek().kind == .minus) {
            const t = self.advance();
            const inner = try self.parseUnary();
            return self.mkExpr(.{ .line = t.line, .col = t.col }, .{ .neg = inner });
        }
        return self.parsePrim();
    }

    fn parsePrim(self: *Parser) ParseError!*ast.Expr {
        const t = self.peek();
        switch (t.kind) {
            .number => {
                _ = self.advance();
                return self.mkExpr(spanOf(t), .{ .int = t.value });
            },
            .kw_true => {
                _ = self.advance();
                return self.mkExpr(spanOf(t), .{ .boolean = true });
            },
            .kw_false => {
                _ = self.advance();
                return self.mkExpr(spanOf(t), .{ .boolean = false });
            },
            .lparen => {
                _ = self.advance();
                const inner = try self.parseValue();
                _ = try self.expect(.rparen);
                return inner;
            },
            .ident => {
                _ = self.advance();
                if (self.peek().kind == .lparen) {
                    return self.parseRetcall(t);
                }
                return self.mkExpr(spanOf(t), .{ .variable = t.text });
            },
            else => return self.errAt(t, "expected value, found '{s}'", .{t.text}),
        }
    }

    fn parseRetcall(self: *Parser, name_tok: Token) ParseError!*ast.Expr {
        const span = spanOf(name_tok);
        _ = try self.expect(.lparen);

        if (std.mem.eql(u8, name_tok.text, "buttons")) {
            _ = try self.expect(.rparen);
            return self.mkExpr(span, .buttons);
        }
        if (builtinBtn(name_tok.text)) |btn| {
            _ = try self.expect(.rparen);
            return self.mkExpr(span, .{ .btn = btn });
        }
        if (std.mem.eql(u8, name_tok.text, "peek")) {
            const x = try self.parseValue();
            _ = try self.expect(.comma);
            const y = try self.parseValue();
            _ = try self.expect(.rparen);
            return self.mkExpr(span, .{ .peek = .{ .x = x, .y = y } });
        }
        return self.errAt(name_tok, "unknown call '{s}'", .{name_tok.text});
    }
};

fn spanOf(t: Token) Span {
    return .{ .line = t.line, .col = t.col };
}

fn isValueBuiltin(name: []const u8) bool {
    const names = [_][]const u8{
        "peek", "buttons", "btn_left", "btn_right", "btn_up", "btn_down",
    };
    for (names) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

fn builtinBtn(name: []const u8) ?ast.Btn {
    if (std.mem.eql(u8, name, "btn_left")) return .left;
    if (std.mem.eql(u8, name, "btn_right")) return .right;
    if (std.mem.eql(u8, name, "btn_up")) return .up;
    if (std.mem.eql(u8, name, "btn_down")) return .down;
    return null;
}

fn kindName(k: Kind) []const u8 {
    return switch (k) {
        .ident => "identifier",
        .number => "number",
        .eof => "end of file",
        .semi => "';'",
        .rparen => "')'",
        .rbrace => "'}}'",
        else => "token",
    };
}
