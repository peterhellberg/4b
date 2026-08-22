const std = @import("std");
const ast = @import("ast.zig");
const dia = @import("dia");

pub const Error = error{ SemaError, OutOfMemory };

pub const AssignOp = enum { assign, add_assign, sub_assign };

pub const ArithOp = enum { add, sub };

pub const CmpOp = enum { eq, ne, lt, gt, le, ge };

pub const Btn = enum(u2) { left = 0, right = 1, up = 2, down = 3 };

pub const ShiftDist = union(enum) {
    lit: u4,
    reg: u8,
};

pub const Expr = union(enum) {
    int: u4,
    variable: u8,
    buttons,
    btn: Btn,
    peek: struct { x: *Expr, y: *Expr },
    arith: struct { op: ArithOp, lhs: *Expr, rhs: *Expr },
    neg: *Expr,
    band: struct { operand: *Expr, mask: u4 },
    shift: struct { left: bool, operand: *Expr, dist: ShiftDist },

    pub fn isAtomic(self: *const Expr) bool {
        return switch (self.*) {
            .int, .variable => true,
            else => false,
        };
    }
};

pub const VoidCall = union(enum) {
    cls,
    halt,
    flip: struct { x: *Expr, y: *Expr },
};

pub const Cond = union(enum) {
    cmp: struct { op: CmpOp, lhs: *Expr, rhs: *Expr },
    truthy: *Expr,
    not_cond: *Cond,
    and_cond: struct { lhs: *Cond, rhs: *Cond },
    or_cond: struct { lhs: *Cond, rhs: *Cond },
};

pub const StmtKind = union(enum) {
    block: []*Stmt,
    assign: struct { reg: u8, op: AssignOp, value: *Expr },
    voidcall: VoidCall,
    if_stmt: struct { cond: *Cond, then_stmt: *Stmt, else_stmt: ?*Stmt },
    for_stmt: struct { body: *Stmt },
    brk,
    cont,
    empty,
};

pub const Stmt = struct {
    line: u32,
    col: u32,
    kind: StmtKind,
};

pub const VarSlot = struct {
    name: []const u8,
    reg: u8,
    init: u4,
};

pub const Prog = struct {
    vars: []VarSlot,
    body: *Stmt,
};

const Scope = std.StringHashMapUnmanaged(Symbol);

const Symbol = union(enum) {
    variable: u8,
    constant: u4,
};

const reserved = [_][]const u8{
    "cls",       "flip",   "peek",     "buttons", "btn_left",
    "btn_right", "btn_up", "btn_down", "halt",    "main",
};

fn isReserved(name: []const u8) bool {
    for (reserved) |r| {
        if (std.mem.eql(u8, name, r)) return true;
    }
    return false;
}

pub const Semer = struct {
    alloc: std.mem.Allocator,
    diag: *dia.Diag,
    consts: std.StringHashMapUnmanaged(u4),
    scopes: std.ArrayList(Scope) = .empty,
    next_reg: u8 = 0,

    fn err(self: *Semer, line: u32, col: u32, comptime fmt: []const u8, args: anytype) Error {
        self.diag.err(line, col, fmt, args);
        return error.SemaError;
    }

    fn pushScope(self: *Semer) Error!void {
        try self.scopes.append(self.alloc, .{});
    }

    fn popScope(self: *Semer) void {
        _ = self.scopes.pop();
    }

    fn declareVar(self: *Semer, name: []const u8, line: u32, col: u32) Error!u8 {
        if (isReserved(name)) {
            return self.err(line, col, "'{s}' is reserved", .{name});
        }
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].contains(name)) {
                return self.err(line, col, "duplicate or shadowed declaration '{s}'", .{name});
            }
        }
        if (self.next_reg >= 13) {
            return self.err(line, col, "too many variables (maximum 13)", .{});
        }
        const reg = self.next_reg;
        self.next_reg += 1;
        try self.scopes.items[self.scopes.items.len - 1].put(self.alloc, name, .{ .variable = reg });
        return reg;
    }

    fn lookup(self: *Semer, name: []const u8, line: u32, col: u32) Error!Symbol {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].get(name)) |sym| return sym;
        }
        return self.err(line, col, "undeclared identifier '{s}'", .{name});
    }

    // ---- constant folding ----

    fn evalConst(self: *Semer, e: *ast.Expr, depth: u32) Error!u4 {
        if (depth > 64) {
            return self.err(e.span.line, e.span.col, "constant expression too deeply nested", .{});
        }
        switch (e.kind) {
            .int => |v| {
                if (v > 15) return self.err(e.span.line, e.span.col, "value {d} out of range (0..15)", .{v});
                return @intCast(v);
            },
            .variable => |name| {
                if (self.consts.get(name)) |v| return v;
                // distinguish unknown vs non-const variable
                var found = false;
                for (self.scopes.items) |sc| {
                    if (sc.contains(name)) found = true;
                }
                if (found) {
                    return self.err(e.span.line, e.span.col, "'{s}' is not a compile-time constant", .{name});
                }
                return self.err(e.span.line, e.span.col, "undeclared identifier '{s}'", .{name});
            },
            .arith => |a| {
                const l = try self.evalConst(a.lhs, depth + 1);
                const r = try self.evalConst(a.rhs, depth + 1);
                return switch (a.op) {
                    .add => l +% r,
                    .sub => l -% r,
                };
            },
            .neg => |inner| {
                const v = try self.evalConst(inner, depth + 1);
                return 0 -% v;
            },
            .band => |b| {
                const v = try self.evalConst(b.lhs, depth + 1);
                const m = try self.evalConst(b.mask_expr, depth + 1);
                return v & m;
            },
            .shift => |s| {
                const v = try self.evalConst(s.operand, depth + 1);
                const d: u4 = switch (s.dist) {
                    .lit => |n| blk: {
                        if (n > 3) {
                            return self.err(e.span.line, e.span.col, "shift distance {d} out of range (0..3)", .{n});
                        }
                        break :blk @intCast(n);
                    },
                    .variable => |name| blk: {
                        const tmp = try self.alloc.create(ast.Expr);
                        tmp.* = .{ .span = e.span, .kind = .{ .variable = name } };
                        break :blk try self.evalConst(tmp, depth + 1);
                    },
                    .expr => |inner| try self.evalConst(inner, depth + 1),
                };
                return if (s.left) v << @as(u2, @intCast(d)) else v >> @as(u2, @intCast(d));
            },
            else => {
                return self.err(e.span.line, e.span.col, "expression is not a compile-time constant", .{});
            },
        }
    }

    // ---- expression conversion ----

    fn convExpr(self: *Semer, e: *ast.Expr) Error!*Expr {
        const out = switch (e.kind) {
            .int => |v| blk: {
                if (v > 15) {
                    return self.err(e.span.line, e.span.col, "value {d} out of range (0..15)", .{v});
                }
                break :blk Expr{ .int = @intCast(v) };
            },
            .variable => |name| blk: {
                switch (try self.lookup(name, e.span.line, e.span.col)) {
                    .variable => |reg| break :blk Expr{ .variable = reg },
                    .constant => |v| break :blk Expr{ .int = v },
                }
            },
            .buttons => Expr.buttons,
            .btn => |b| Expr{ .btn = switch (b) {
                .left => .left,
                .right => .right,
                .up => .up,
                .down => .down,
            } },
            .peek => |p| Expr{ .peek = .{ .x = try self.convExpr(p.x), .y = try self.convExpr(p.y) } },
            .arith => |a| blk: {
                const l = try self.convExpr(a.lhs);
                const r = try self.convExpr(a.rhs);
                const op: ArithOp = switch (a.op) {
                    .add => .add,
                    .sub => .sub,
                };
                if (l.* == .int and r.* == .int) {
                    const lv = l.int;
                    const rv = r.int;
                    const folded = try self.alloc.create(Expr);
                    folded.* = .{ .int = switch (op) {
                        .add => lv +% rv,
                        .sub => lv -% rv,
                    } };
                    break :blk folded.*;
                }
                break :blk Expr{ .arith = .{ .op = op, .lhs = l, .rhs = r } };
            },
            .neg => |inner| blk: {
                const v = try self.convExpr(inner);
                if (v.* == .int) {
                    const folded = try self.alloc.create(Expr);
                    folded.* = .{ .int = 0 -% v.int };
                    break :blk folded.*;
                }
                break :blk Expr{ .neg = v };
            },
            .band => |b| blk: {
                const m = try self.evalConst(b.mask_expr, 0);
                if (!isContiguous(m)) {
                    return self.err(e.span.line, e.span.col, "mask must be one contiguous run of bits", .{});
                }
                const operand = try self.convExpr(b.lhs);
                if (operand.* == .int) {
                    const folded = try self.alloc.create(Expr);
                    folded.* = .{ .int = operand.int & m };
                    break :blk folded.*;
                }
                break :blk Expr{ .band = .{ .operand = operand, .mask = m } };
            },
            .shift => |s| blk: {
                const operand = try self.convExpr(s.operand);
                const dist: ShiftDist = switch (s.dist) {
                    .lit => |v| blk2: {
                        if (v > 3) {
                            return self.err(e.span.line, e.span.col, "shift distance {d} out of range (0..3)", .{v});
                        }
                        break :blk2 .{ .lit = @intCast(v) };
                    },
                    .variable => |name| blk2: {
                        switch (try self.lookup(name, e.span.line, e.span.col)) {
                            .variable => |reg| break :blk2 .{ .reg = reg },
                            .constant => |cv| {
                                if (cv > 3) {
                                    return self.err(e.span.line, e.span.col, "shift distance {d} out of range (0..3)", .{cv});
                                }
                                break :blk2 .{ .lit = cv };
                            },
                        }
                    },
                    .expr => {
                        return self.err(e.span.line, e.span.col, "shift distance must be a literal or a bare variable", .{});
                    },
                };
                if (dist == .lit and dist.lit == 0) {
                    break :blk operand.*;
                }
                if (operand.* == .int) {
                    const d: u3 = @intCast(dist.lit);
                    const folded = try self.alloc.create(Expr);
                    folded.* = .{ .int = if (s.left) operand.int << @as(u2, @intCast(d)) else operand.int >> @as(u2, @intCast(d)) };
                    break :blk folded.*;
                }
                break :blk Expr{ .shift = .{ .left = s.left, .operand = operand, .dist = dist } };
            },
        };
        const node = try self.alloc.create(Expr);
        node.* = out;
        return node;
    }

    fn checkFlipArg(self: *Semer, e: *Expr, line: u32, col: u32) Error!void {
        switch (e.*) {
            .int, .variable => {},
            else => return self.err(line, col, "at most one flip argument may be a computed value", .{}),
        }
    }

    // ---- conditions ----

    fn convCond(self: *Semer, c: *ast.Cond) Error!*Cond {
        const out: Cond = switch (c.kind) {
            .cmp => |cm| blk: {
                const lhs = try self.convExpr(cm.lhs);
                const rhs = try self.convExpr(cm.rhs);
                break :blk .{ .cmp = .{
                    .op = switch (cm.op) {
                        .eq => .eq,
                        .ne => .ne,
                        .lt => .lt,
                        .gt => .gt,
                        .le => .le,
                        .ge => .ge,
                    },
                    .lhs = lhs,
                    .rhs = rhs,
                } };
            },
            .truthy => |e| blk: {
                const v = try self.convExpr(e);
                if (v.* == .int) break :blk .{ .truthy = v };
                break :blk .{ .truthy = v };
            },
            .not_cond => |inner| .{ .not_cond = try self.convCond(inner) },
            .and_cond => |a| .{ .and_cond = .{ .lhs = try self.convCond(a.lhs), .rhs = try self.convCond(a.rhs) } },
            .or_cond => |o| .{ .or_cond = .{ .lhs = try self.convCond(o.lhs), .rhs = try self.convCond(o.rhs) } },
        };
        const node = try self.alloc.create(Cond);
        node.* = out;
        return node;
    }

    // ---- statements ----

    fn convStmt(self: *Semer, s: *ast.Stmt) Error!*Stmt {
        const out: StmtKind = switch (s.kind) {
            .block => |stmts| blk: {
                try self.pushScope();
                defer self.popScope();
                var list = std.ArrayList(*Stmt).empty;
                for (stmts) |one| {
                    try list.append(self.alloc, try self.convStmt(one));
                }
                break :blk .{ .block = list.items };
            },
            .assign => |a| blk: {
                const sym = try self.lookup(a.target, s.span.line, s.span.col);
                const reg = switch (sym) {
                    .variable => |r| r,
                    .constant => return self.err(s.span.line, s.span.col, "cannot assign to constant '{s}'", .{a.target}),
                };
                const value = try self.convExpr(a.value);
                break :blk .{ .assign = .{
                    .reg = reg,
                    .op = switch (a.op) {
                        .assign => .assign,
                        .add_assign => .add_assign,
                        .sub_assign => .sub_assign,
                    },
                    .value = value,
                } };
            },
            .voidcall => |vc| blk: {
                switch (vc) {
                    .cls => break :blk .{ .voidcall = .cls },
                    .halt => break :blk .{ .voidcall = .halt },
                    .flip => |f| {
                        const x = try self.convExpr(f.x);
                        const y = try self.convExpr(f.y);
                        try self.checkFlipArg(x, f.x.span.line, f.x.span.col);
                        try self.checkFlipArg(y, f.y.span.line, f.y.span.col);
                        break :blk .{ .voidcall = .{ .flip = .{ .x = x, .y = y } } };
                    },
                }
            },
            .if_stmt => |i| .{ .if_stmt = .{
                .cond = try self.convCond(i.cond),
                .then_stmt = try self.convStmt(i.then_stmt),
                .else_stmt = if (i.else_stmt) |e| try self.convStmt(e) else null,
            } },
            .for_stmt => |f| .{ .for_stmt = .{ .body = try self.convStmt(f.body) } },
            .brk => .brk,
            .cont => .cont,
            .empty => .empty,
        };
        const node = try self.alloc.create(Stmt);
        node.* = .{ .line = s.span.line, .col = s.span.col, .kind = out };
        return node;
    }

    pub fn run(self: *Semer, prog: *ast.Program) Error!Prog {
        try self.pushScope(); // globals

        var slots = std.ArrayList(VarSlot).empty;

        // constants first pass (in declaration order; forward refs rejected by lookup order)
        for (prog.globals) |g| {
            switch (g) {
                .const_decl => |cd| {
                    if (isReserved(cd.name)) {
                        return self.err(cd.span.line, cd.span.col, "'{s}' is reserved", .{cd.name});
                    }
                    if (self.consts.contains(cd.name) or self.scopes.items[0].contains(cd.name)) {
                        return self.err(cd.span.line, cd.span.col, "duplicate declaration '{s}'", .{cd.name});
                    }
                    const v = try self.evalConst(cd.value_expr, 0);
                    try self.consts.put(self.alloc, cd.name, v);
                    try self.scopes.items[0].put(self.alloc, cd.name, .{ .constant = v });
                },
                .var_decl => {},
            }
        }

        // variables second pass (declaration order assigns registers)
        for (prog.globals) |g| {
            switch (g) {
                .var_decl => |vd| {
                    const reg = try self.declareVar(vd.name, vd.span.line, vd.span.col);
                    var init: u4 = 0;
                    if (vd.init_expr) |ie| {
                        init = try self.evalConst(ie, 0);
                    }
                    try slots.append(self.alloc, .{ .name = vd.name, .reg = reg, .init = init });
                },
                .const_decl => {},
            }
        }

        // main body in the global scope
        const body = try self.convStmt(prog.main_body);

        self.popScope();

        return .{ .vars = slots.items, .body = body };
    }
};

fn isContiguous(m: u4) bool {
    if (m == 0) return false;
    const wide: u8 = m;
    const t = wide >> @as(u3, @intCast(@ctz(wide)));
    return (t & (t +% 1)) == 0;
}
