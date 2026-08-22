const std = @import("std");

pub const Span = struct {
    line: u32,
    col: u32,
};

pub const ArithOp = enum { add, sub };
pub const CmpOp = enum { eq, ne, lt, gt, le, ge };
pub const AssignOp = enum { assign, add_assign, sub_assign };
pub const Btn = enum(u2) { left = 0, right = 1, up = 2, down = 3 };

pub const ShiftDist = union(enum) {
    lit: u64,
    variable: []const u8,
    expr: *Expr,
};

pub const Expr = struct {
    span: Span,
    kind: ExprKind,
};

pub const ExprKind = union(enum) {
    int: u64,
    boolean: bool,
    variable: []const u8,
    peek: struct { x: *Expr, y: *Expr },
    buttons,
    btn: Btn,
    arith: struct { op: ArithOp, lhs: *Expr, rhs: *Expr },
    band: struct { lhs: *Expr, mask_expr: *Expr },
    shift: struct { left: bool, operand: *Expr, dist: ShiftDist },
    neg: *Expr,
};

pub const Cond = struct {
    span: Span,
    kind: CondKind,
};

pub const CondKind = union(enum) {
    or_cond: struct { lhs: *Cond, rhs: *Cond },
    and_cond: struct { lhs: *Cond, rhs: *Cond },
    not_cond: *Cond,
    cmp: struct { op: CmpOp, lhs: *Expr, rhs: *Expr },
    truthy: *Expr,
};

pub const VoidCall = union(enum) {
    cls,
    halt,
    flip: struct { x: *Expr, y: *Expr },
};

pub const Stmt = struct {
    span: Span,
    kind: StmtKind,
};

pub const StmtKind = union(enum) {
    assign: struct { target: []const u8, op: AssignOp, value: *Expr },
    if_stmt: struct { cond: *Cond, then_stmt: *Stmt, else_stmt: ?*Stmt },
    while_stmt: struct { cond: *Cond, body: *Stmt },
    brk,
    cont,
    voidcall: VoidCall,
    block: []*Stmt,
    empty,
};

pub const VarDecl = struct {
    name: []const u8,
    init_expr: ?*Expr,
    span: Span,
};

pub const ConstDecl = struct {
    name: []const u8,
    value_expr: *Expr,
    span: Span,
};

pub const Global = union(enum) {
    var_decl: VarDecl,
    const_decl: ConstDecl,
};

pub const Program = struct {
    globals: []Global,
    main_body: *Stmt,
};
