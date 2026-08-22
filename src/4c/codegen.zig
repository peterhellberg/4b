const std = @import("std");
const model = @import("../model.zig");
const sema = @import("sema.zig");
const diag_mod = @import("../diag.zig");

const Expr = sema.Expr;
const Cond = sema.Cond;
const Stmt = sema.Stmt;

pub const Error = error{ CodegenError, OutOfMemory };

pub const SCRATCH: u4 = 13;
pub const ZERO: u4 = 14;
pub const PHASE: u4 = 15;

/// Slots 0..14 are usable; slot 15 is reserved (hardware bug).
pub const MAX_SLOTS: usize = 15;

pub const SlotInfo = struct { line: u32, col: u32 };

pub const Result = struct {
    words: []u16,
    slots: []SlotInfo,
};

fn capturesBreak(s: *const Stmt) bool {
    switch (s.kind) {
        .brk => return true,
        .block => |list| {
            for (list) |one| {
                if (capturesBreak(one)) return true;
            }
            return false;
        },
        .if_stmt => |i| {
            if (capturesBreak(i.then_stmt)) return true;
            return if (i.else_stmt) |e| capturesBreak(e) else false;
        },
        else => return false,
    }
}

const LoopCtx = struct {
    top_slot: usize,
    brk_patches: std.ArrayList(usize) = .empty,
};

pub const Codegen = struct {
    alloc: std.mem.Allocator,
    diag: *diag_mod.Diag,

    words: std.ArrayList(u16) = .empty,
    slots: std.ArrayList(SlotInfo) = .empty,
    loops: std.ArrayList(LoopCtx) = .empty,

    fn err(self: *Codegen, line: u32, col: u32, comptime fmt: []const u8, args: anytype) Error {
        self.diag.err(line, col, fmt, args);
        return error.CodegenError;
    }

    fn w(self: *Codegen, op: model.Op, a: u4, b: u4) Error!usize {
        if (self.words.items.len >= 256) {
            return self.err(1, 1, "program exceeds 256 words", .{});
        }
        try self.words.append(self.alloc, model.encode(op, a, b));
        return self.words.items.len - 1;
    }

    fn flag(self: *Codegen, line: u32, col: u32) Error!usize {
        const slot = self.slots.items.len;
        if (slot >= MAX_SLOTS) {
            return self.err(line, col, "program needs more than {d} flag slots", .{MAX_SLOTS});
        }
        try self.slots.append(self.alloc, .{ .line = line, .col = col });
        _ = try self.w(.flag, @intCast(slot), 0);
        return slot;
    }

    /// Gate pair: skips the next word while PHASE == 0 (during the boot walk).
    /// ifeq fires (skips payload) iff ZERO(0) == PHASE, i.e. before the latch.
    fn gate(self: *Codegen) Error!void {
        _ = try self.w(.lda_mem, PHASE, 0);
        _ = try self.w(.ifeq, ZERO, 0);
    }

    fn gatedJmp(self: *Codegen, patch_idx: *usize) Error!void {
        try self.gate();
        patch_idx.* = try self.w(.jmp, 0, 0);
    }

    fn patchJmp(self: *Codegen, idx: usize, slot: usize) void {
        self.words.items[idx] = model.encode(.jmp, @intCast(slot), 0);
    }

    // ---- expressions (result left in acc) ----

    fn evalExpr(self: *Codegen, e: *const Expr, line: u32, col: u32) Error!void {
        switch (e.*) {
            .int => |k| _ = try self.w(.lda_imm, k, 0),
            .boolean => |b| _ = try self.w(.lda_imm, @intFromBool(b), 0),
            .variable => |r| _ = try self.w(.lda_mem, @intCast(r), 0),
            .buttons => {
                try self.gate();
                _ = try self.w(.read, 0, 0);
            },
            .btn => |side| {
                try self.gate();
                _ = try self.w(.read, 0, 0);
                var i: u4 = 0;
                const shifts: u4 = @as(u4, @intFromEnum(side)) + 1;
                while (i < shifts) : (i += 1) _ = try self.w(.shr, 0, 0);
                i = 0;
                while (i < 3) : (i += 1) _ = try self.w(.shl, 0, 0);
                i = 0;
                while (i < 3) : (i += 1) _ = try self.w(.shr, 0, 0);
            },
            .peek => |p| {
                const xa = p.x.*;
                const ya = p.y.*;
                if (xa == .variable and ya == .variable) {
                    try self.gate();
                    _ = try self.w(.peek, @intCast(xa.variable), @intCast(ya.variable));
                } else if (xa == .variable) {
                    try self.evalExpr(p.y, line, col);
                    _ = try self.w(.sta, SCRATCH, 0);
                    try self.gate();
                    _ = try self.w(.peek, @intCast(xa.variable), SCRATCH);
                } else if (ya == .variable) {
                    try self.evalExpr(p.x, line, col);
                    _ = try self.w(.sta, SCRATCH, 0);
                    try self.gate();
                    _ = try self.w(.peek, SCRATCH, @intCast(ya.variable));
                } else {
                    return self.err(line, col, "at most one peek coordinate may be a computed value", .{});
                }
            },
            .arith => |a| try self.evalArith(a.op, a.lhs, a.rhs, line, col),
            .neg => |inner| try self.evalNeg(inner, line, col),
            .band => |bnd| {
                try self.evalExpr(bnd.operand, line, col);
                const m: u4 = bnd.mask;
                const low: u4 = @ctz(m);
                const high: u4 = 3 - @clz(m);
                const pad: u4 = 3 - high + low; // 4 - field width
                var i: u4 = 0;
                while (i < low) : (i += 1) _ = try self.w(.shr, 0, 0);
                i = 0;
                while (i < pad) : (i += 1) _ = try self.w(.shl, 0, 0);
                i = 0;
                while (i < pad) : (i += 1) _ = try self.w(.shr, 0, 0);
            },
            .shift => |s| try self.evalShift(s.left, s.operand, s.dist, line, col),
        }
    }

    fn evalArith(self: *Codegen, op: sema.ArithOp, lhs: *const Expr, rhs: *const Expr, line: u32, col: u32) Error!void {
        // Fast path: constant amount -> inc chain.
        if (rhs.* == .int) {
            const k: u4 = rhs.int;
            const n: u4 = if (op == .add) k else 0 -% k;
            try self.evalExpr(lhs, line, col);
            var i: u4 = 0;
            while (i < n) : (i += 1) _ = try self.w(.inc, 0, 0);
            return;
        }

        // Addition commutes, so a constant on the left works too.
        if (op == .add and lhs.* == .int) {
            const k: u4 = lhs.int;
            try self.evalExpr(rhs, line, col);
            var i: u4 = 0;
            while (i < k) : (i += 1) _ = try self.w(.inc, 0, 0);
            return;
        }

        // Runtime +/- runtime needs a mutable target register; assignments
        // get one (see assignStmt), arbitrary expressions do not.
        return self.err(line, col, "expression too complex: runtime arithmetic needs an assignment target (assign to a variable first)", .{});
    }

    /// acc = -(v). Constant cases fold in sema; runtime negation mutates an
    /// assignment target instead (see assignStmt), so value position errors.
    fn evalNeg(self: *Codegen, inner: *const Expr, line: u32, col: u32) Error!void {
        _ = inner;
        return self.err(line, col, "expression too complex: unary minus on a runtime value needs an assignment target", .{});
    }

    fn evalShift(self: *Codegen, left: bool, operand: *const Expr, dist: sema.ShiftDist, line: u32, col: u32) Error!void {
        const op: model.Op = if (left) .shl else .shr;
        switch (dist) {
            .lit => |n| {
                try self.evalExpr(operand, line, col);
                var i: u4 = 0;
                while (i < n) : (i += 1) _ = try self.w(op, 0, 0);
            },
            .reg => {
                return self.err(line, col, "expression too complex: a variable shift distance needs an assignment target", .{});
            },
        }
    }

    // ---- conditions ----

    const zero_expr: Expr = .{ .int = 0 };

    const ZeroNorm = union(enum) {
        keep,
        always_true,
        always_false,
        new_op: sema.CmpOp,
    };

    /// Unsigned special cases for comparisons against literal zero.
    fn zeroNormalize(op: sema.CmpOp, rhs: *const Expr) ZeroNorm {
        if (rhs.* != .int or rhs.int != 0) return .keep;
        return switch (op) {
            .ne => .{ .new_op = .gt },
            .le => .{ .new_op = .eq },
            .ge => .always_true,
            .lt => .always_false,
            else => .keep,
        };
    }

    /// Emit words that skip the trailing gated jump(s) iff cond holds.
    /// Every emitted jmp word index lands in `patches` for later fixup.
    fn branchTrue(self: *Codegen, c: *const Cond, patches: *std.ArrayList(usize), line: u32, col: u32) Error!void {
        switch (c.*) {
            .boolean => |b| {
                if (b) try self.uncondPatch(patches);
            },
            .truthy => |e| {
                // e != 0 is unsigned gt(e, 0)
                try self.cmpBranch(.gt, e, &zero_expr, patches, line, col);
            },
            .cmp => |cm| {
                switch (zeroNormalize(cm.op, cm.rhs)) {
                    .always_true => {},
                    .always_false => try self.uncondPatch(patches),
                    .new_op => |op2| try self.expandCmp(op2, cm.lhs, cm.rhs, patches, line, col),
                    .keep => try self.expandCmp(cm.op, cm.lhs, cm.rhs, patches, line, col),
                }
            },
            .not_cond => |inner| try self.branchFalse(inner, patches, line, col),
            .and_cond => |a| {
                // fires past both branches only when both hold
                try self.branchTrue(a.lhs, patches, line, col);
                try self.branchTrue(a.rhs, patches, line, col);
            },
            .or_cond => |o| {
                // short-circuit join slot:
                //   [JF(a)][G jmp T][JT(b) -> X][T flag]
                var t_patches = std.ArrayList(usize).empty;
                try self.branchFalse(o.lhs, &t_patches, line, col);
                var t_jmp: usize = undefined;
                try self.gatedJmp(&t_jmp);
                try self.branchTrue(o.rhs, patches, line, col);
                const t_slot = try self.flag(line, col);
                self.patchJmp(t_jmp, t_slot);
                for (t_patches.items) |idx| self.patchJmp(idx, t_slot);
            },
        }
    }

    fn branchFalse(self: *Codegen, c: *const Cond, patches: *std.ArrayList(usize), line: u32, col: u32) Error!void {
        switch (c.*) {
            .boolean => |b| {
                if (!b) try self.uncondPatch(patches);
            },
            .truthy => |e| {
                // !(e != 0) is e == 0
                try self.cmpBranch(.eq, e, &zero_expr, patches, line, col);
            },
            .cmp => |cm| {
                const inverted: sema.CmpOp = switch (cm.op) {
                    .eq => .ne,
                    .ne => .eq,
                    .lt => .ge,
                    .gt => .le,
                    .le => .gt,
                    .ge => .lt,
                };
                switch (zeroNormalize(inverted, cm.rhs)) {
                    .always_true => {},
                    .always_false => try self.uncondPatch(patches),
                    .new_op => |op2| try self.expandCmp(op2, cm.lhs, cm.rhs, patches, line, col),
                    .keep => try self.expandCmp(inverted, cm.lhs, cm.rhs, patches, line, col),
                }
            },
            .not_cond => |inner| try self.branchTrue(inner, patches, line, col),
            .and_cond => |a| {
                // !(a && b) == !a || !b: sequential free lowering
                try self.branchTrue(a.lhs, patches, line, col);
                try self.branchTrue(a.rhs, patches, line, col);
            },
            .or_cond => |o| {
                // !(a || b) == !a && !b: sequential free lowering
                try self.branchFalse(o.lhs, patches, line, col);
                try self.branchFalse(o.rhs, patches, line, col);
            },
        }
    }

    fn uncondPatch(self: *Codegen, patches: *std.ArrayList(usize)) Error!void {
        var idx: usize = undefined;
        try self.gatedJmp(&idx);
        try patches.append(self.alloc, idx);
    }

    /// Expand ne / le / ge into sequences of primitive comparisons.
    /// Each disjunct emits its own branch; first match wins (skip semantics).
    fn expandCmp(self: *Codegen, op: sema.CmpOp, lhs: *const Expr, rhs: *const Expr, patches: *std.ArrayList(usize), line: u32, col: u32) Error!void {
        switch (op) {
            .ne => {
                try self.cmpBranch(.lt, lhs, rhs, patches, line, col);
                try self.cmpBranch(.gt, lhs, rhs, patches, line, col);
            },
            .le => {
                try self.cmpBranch(.lt, lhs, rhs, patches, line, col);
                try self.cmpBranch(.eq, lhs, rhs, patches, line, col);
            },
            .ge => {
                try self.cmpBranch(.gt, lhs, rhs, patches, line, col);
                try self.cmpBranch(.eq, lhs, rhs, patches, line, col);
            },
            else => try self.cmpBranch(op, lhs, rhs, patches, line, col),
        }
    }

    /// Single primitive comparison (eq / gt / lt). Fires iff (lhs OP rhs).
    fn cmpBranch(self: *Codegen, op: sema.CmpOp, lhs: *const Expr, rhs: *const Expr, patches: *std.ArrayList(usize), line: u32, col: u32) Error!void {
        if (lhs.* == .variable) {
            try self.evalExpr(rhs, line, col);
            const mop: model.Op = switch (op) {
                .eq => .ifeq,
                .lt => .iflt,
                .gt => .ifgt,
                else => unreachable,
            };
            _ = try self.w(mop, @intCast(lhs.variable), 0);
        } else if (rhs.* == .variable) {
            const mirrored: model.Op = switch (op) {
                .eq => .ifeq,
                .lt => .ifgt, // lhs < rhs == rhs > lhs
                .gt => .iflt,
                else => unreachable,
            };
            try self.evalExpr(lhs, line, col);
            _ = try self.w(mirrored, @intCast(rhs.variable), 0);
        } else {
            switch (op) {
                .eq => {
                    try self.evalExpr(rhs, line, col);
                    _ = try self.w(.sta, SCRATCH, 0);
                    try self.evalExpr(lhs, line, col);
                    _ = try self.w(.ifeq, SCRATCH, 0);
                },
                .gt, .lt => {
                    try self.evalExpr(lhs, line, col);
                    _ = try self.w(.sta, SCRATCH, 0);
                    try self.evalExpr(rhs, line, col);
                    const mop: model.Op = if (op == .gt) model.Op.ifgt else model.Op.iflt;
                    _ = try self.w(mop, SCRATCH, 0);
                },
                else => unreachable,
            }
        }

        var idx: usize = undefined;
        try self.gatedJmp(&idx);
        try patches.append(self.alloc, idx);
    }

    // ---- statements ----

    fn stmt(self: *Codegen, s: *const Stmt) Error!void {
        switch (s.kind) {
            .empty => {},
            .block => |list| {
                for (list) |one| try self.stmt(one);
            },
            .assign => |a| try self.assignStmt(a.reg, a.op, a.value, s.line, s.col),
            .voidcall => |vc| try self.voidCall(vc, s.line, s.col),
            .if_stmt => |i| try self.ifStmt(i.cond, i.then_stmt, i.else_stmt, s.line, s.col),
            .while_stmt => |wh| try self.whileStmt(wh.cond, wh.body, s.line, s.col),
            .brk => {
                var idx: usize = undefined;
                try self.gatedJmp(&idx);
                const lctx = &self.loops.items[self.loops.items.len - 1];
                try lctx.brk_patches.append(self.alloc, idx);
            },
            .cont => {
                var idx: usize = undefined;
                try self.gatedJmp(&idx);
                const top = self.loops.items[self.loops.items.len - 1].top_slot;
                self.patchJmp(idx, top);
            },
        }
    }

    fn assignStmt(self: *Codegen, reg: u8, op: sema.AssignOp, value: *const Expr, line: u32, col: u32) Error!void {
        const r: u4 = @intCast(reg);
        switch (op) {
            .assign => {
                switch (value.*) {
                    // Flatten additive chains through the target register:
                    // x = a - b + c becomes x = a; x -= b; x += c.
                    .arith => |a| blk: {
                        const vr = switch (a.rhs.*) {
                            .variable => |v| v,
                            else => break :blk,
                        };
                        try self.assignStmt(reg, .assign, a.lhs, line, col);
                        try self.mutateLoop(r, @intCast(vr), if (a.op == .add) .add else .sub, line, col);
                        return;
                    },
                    // x = -B: zero the target, then subtract B times.
                    .neg => |inner| blk: {
                        const vr = switch (inner.*) {
                            .variable => |v| v,
                            else => break :blk,
                        };
                        _ = try self.w(.lda_imm, 0, 0);
                        try self.gate();
                        _ = try self.w(.sta, r, 0);
                        try self.mutateLoop(r, @intCast(vr), .sub, line, col);
                        return;
                    },
                    // x = e << v / x = e >> v with e atomic.
                    .shift => |s| blk: {
                        const dr = switch (s.dist) {
                            .reg => |dr| dr,
                            else => break :blk,
                        };
                        try self.evalExpr(s.operand, line, col);
                        try self.gate();
                        _ = try self.w(.sta, r, 0);
                        try self.shiftMutateLoop(r, @intCast(dr), s.left, line, col);
                        return;
                    },
                    else => {},
                }
                try self.evalExpr(value, line, col);
                try self.gate();
                _ = try self.w(.sta, r, 0);
            },
            .add_assign, .sub_assign => {
                switch (value.*) {
                    .int => |k| {
                        if (k != 0) {
                            const n: u4 = if (op == .add_assign) k else 0 -% k;
                            _ = try self.w(.lda_mem, r, 0);
                            var i: u4 = 0;
                            while (i < n) : (i += 1) _ = try self.w(.inc, 0, 0);
                            try self.gate();
                            _ = try self.w(.sta, r, 0);
                        }
                    },
                    .variable => |vr| {
                        const mode: sema.ArithOp = if (op == .add_assign) .add else .sub;
                        try self.mutateLoop(r, @intCast(vr), mode, line, col);
                    },
                    else => {
                        return self.err(line, col, "compound assignment needs a constant or variable amount", .{});
                    },
                }
            },
        }
    }

    /// regs[target] ±= regs[amount] by mutating the target in place:
    /// zero-guarded count-up loop with the counter in scratch and a
    /// bottom-tested exit when counter == amount.
    fn mutateLoop(self: *Codegen, target: u4, amount_reg: u8, mode: sema.ArithOp, line: u32, col: u32) Error!void {
        const areg: u4 = @intCast(amount_reg);
        _ = try self.w(.lda_imm, 0, 0);
        _ = try self.w(.ifgt, areg, 0);
        var exit_patch: usize = undefined;
        try self.gatedJmp(&exit_patch);

        _ = try self.w(.lda_imm, 0, 0);
        _ = try self.w(.sta, SCRATCH, 0);

        const top = try self.flag(line, col);
        _ = try self.w(.lda_mem, target, 0);
        _ = try self.w(.inc, 0, 0);
        if (mode == .sub) {
            var i: u4 = 0;
            while (i < 14) : (i += 1) _ = try self.w(.inc, 0, 0);
        }
        try self.gate();
        _ = try self.w(.sta, target, 0);

        _ = try self.w(.lda_mem, SCRATCH, 0);
        _ = try self.w(.inc, 0, 0);
        _ = try self.w(.sta, SCRATCH, 0);
        _ = try self.w(.ifeq, areg, 0);
        var back_patch: usize = undefined;
        try self.gatedJmp(&back_patch);
        self.patchJmp(back_patch, top);

        const exit = try self.flag(line, col);
        self.patchJmp(exit_patch, exit);
    }

    /// regs[target] <<= / >>= regs[dist] by shifting the target in place,
    /// same skeleton as mutateLoop but each pass shifts once.
    fn shiftMutateLoop(self: *Codegen, target: u4, dist_reg: u8, left: bool, line: u32, col: u32) Error!void {
        const areg: u4 = @intCast(dist_reg);
        const op: model.Op = if (left) .shl else .shr;

        _ = try self.w(.lda_imm, 0, 0);
        _ = try self.w(.ifgt, areg, 0);
        var exit_patch: usize = undefined;
        try self.gatedJmp(&exit_patch);

        _ = try self.w(.lda_imm, 0, 0);
        _ = try self.w(.sta, SCRATCH, 0);

        const top = try self.flag(line, col);
        _ = try self.w(.lda_mem, target, 0);
        _ = try self.w(op, 0, 0);
        try self.gate();
        _ = try self.w(.sta, target, 0);

        _ = try self.w(.lda_mem, SCRATCH, 0);
        _ = try self.w(.inc, 0, 0);
        _ = try self.w(.sta, SCRATCH, 0);
        _ = try self.w(.ifeq, areg, 0);
        var back_patch: usize = undefined;
        try self.gatedJmp(&back_patch);
        self.patchJmp(back_patch, top);

        const exit = try self.flag(line, col);
        self.patchJmp(exit_patch, exit);
    }

    fn voidCall(self: *Codegen, vc: sema.VoidCall, line: u32, col: u32) Error!void {
        switch (vc) {
            .cls => {
                try self.gate();
                _ = try self.w(.cls, 0, 0);
            },
            .halt => {
                const h = try self.flag(line, col);
                var idx: usize = undefined;
                try self.gatedJmp(&idx);
                self.patchJmp(idx, h);
            },
            .flip => |f| {
                const xa = f.x.*;
                const ya = f.y.*;
                if (xa == .variable and ya == .variable) {
                    try self.gate();
                    _ = try self.w(.flip, @intCast(xa.variable), @intCast(ya.variable));
                } else if (xa == .variable) {
                    try self.evalExpr(f.y, line, col);
                    _ = try self.w(.sta, SCRATCH, 0);
                    try self.gate();
                    _ = try self.w(.flip, @intCast(xa.variable), SCRATCH);
                } else {
                    try self.evalExpr(f.x, line, col);
                    _ = try self.w(.sta, SCRATCH, 0);
                    try self.gate();
                    _ = try self.w(.flip, SCRATCH, @intCast(ya.variable));
                }
            },
        }
    }

    fn jumpIfTrue(self: *Codegen, cond: *const Cond, line: u32, col: u32) Error!std.ArrayList(usize) {
        var patches = std.ArrayList(usize).empty;
        try self.branchTrue(cond, &patches, line, col);
        return patches;
    }

    fn ifStmt(self: *Codegen, cond: *const Cond, then_s: *const Stmt, else_s: ?*const Stmt, line: u32, col: u32) Error!void {
        if (cond.* == .boolean) {
            if (cond.boolean) {
                try self.stmt(then_s);
            } else if (else_s) |e| {
                try self.stmt(e);
            }
            return;
        }

        if (else_s) |e| {
            // [test][G jmp B][THEN][G jmp J][B flag][ELSE][J flag]
            const patches = try self.jumpIfTrue(cond, line, col);
            try self.stmt(then_s);
            var join_patch: usize = undefined;
            try self.gatedJmp(&join_patch);
            const else_slot = try self.flag(e.line, e.col);
            try self.stmt(e);
            const join_slot = try self.flag(line, col);
            for (patches.items) |idx| self.patchJmp(idx, else_slot);
            self.patchJmp(join_patch, join_slot);
        } else {
            // [test][G jmp J][THEN][J flag]
            const patches = try self.jumpIfTrue(cond, line, col);
            try self.stmt(then_s);
            const join_slot = try self.flag(line, col);
            for (patches.items) |idx| self.patchJmp(idx, join_slot);
        }
    }

    fn whileStmt(self: *Codegen, cond: *const Cond, body: *const Stmt, line: u32, col: u32) Error!void {
        const folded_true = cond.* == .boolean and cond.boolean;
        const folded_false = cond.* == .boolean and !cond.boolean;

        // T flag (continue target)
        const top = try self.flag(body.line, body.col);

        // test -> exit jump (EXIT slot allocated after body/backedge)
        var exit_patches = std.ArrayList(usize).empty;
        if (!folded_true) {
            if (folded_false) {
                try self.uncondPatch(&exit_patches);
            } else {
                try self.branchTrue(cond, &exit_patches, line, col);
            }
        }

        try self.loops.append(self.alloc, .{ .top_slot = top });
        try self.stmt(body);
        const done = self.loops.pop() orelse unreachable;

        // backedge
        var back_patch: usize = undefined;
        try self.gatedJmp(&back_patch);
        self.patchJmp(back_patch, top);

        // EXIT flag: needed unless while(true) without break
        const has_breaks = done.brk_patches.items.len > 0;
        if (!folded_true or has_breaks) {
            const exit = try self.flag(body.line, body.col);
            for (exit_patches.items) |idx| self.patchJmp(idx, exit);
            for (done.brk_patches.items) |idx| self.patchJmp(idx, exit);
        }
    }
};

pub fn generate(
    alloc: std.mem.Allocator,
    diag: *diag_mod.Diag,
    prog: sema.Prog,
) Error!Result {
    var cg = Codegen{ .alloc = alloc, .diag = diag };

    // global initializers: ungated idempotent stores
    for (prog.vars) |v| {
        _ = try cg.w(.lda_imm, v.init, 0);
        _ = try cg.w(.sta, @intCast(v.reg), 0);
    }

    // program entry: slot 0
    _ = try cg.flag(1, 1);

    try cg.stmt(prog.body);

    // epilogue: latch phase, restart from entry (both ungated)
    _ = try cg.w(.lda_imm, 1, 0);
    _ = try cg.w(.sta, PHASE, 0);
    _ = try cg.w(.jmp, 0, 0);

    return .{
        .words = cg.words.items,
        .slots = cg.slots.items,
    };
}
