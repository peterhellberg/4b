const std = @import("std");
const dia = @import("dia");
const isa = @import("isa");
const sema = @import("sema.zig");

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
    diag: *dia.Diag,

    words: std.ArrayList(u16) = .empty,
    slots: std.ArrayList(SlotInfo) = .empty,
    loops: std.ArrayList(LoopCtx) = .empty,

    fn err(self: *Codegen, line: u32, col: u32, comptime fmt: []const u8, args: anytype) Error {
        self.diag.err(line, col, fmt, args);

        return error.CodegenError;
    }

    fn w(self: *Codegen, op: isa.Op, a: u4, b: u4) Error!usize {
        if (self.words.items.len >= 256) {
            return self.err(1, 1, "program exceeds 256 words", .{});
        }

        try self.words.append(self.alloc, isa.encode(op, a, b));

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

    /// Gate pair for conditional-exit jumps: the enclosing conditional skips
    /// the `lda #1` iff the condition holds, leaving acc = 0 (from the
    /// truthiness staging); falling through sets acc = 1. `ifgt r15` then
    /// executes the jump iff PHASE > acc — i.e. the jump is taken only when
    /// the condition is false and the boot walk has completed.
    fn gatedJmp(self: *Codegen, patch_idx: *usize) Error!void {
        _ = try self.w(.lda_imm, 1, 0);
        _ = try self.w(.ifgt, PHASE, 0);

        patch_idx.* = try self.w(.jmp, 0, 0);
    }

    /// Guard for screen/input effects: skips the next word while PHASE == 0
    /// so the boot walk leaves no visual artifacts. Safe to use here because
    /// these words do not consume the acc value the guard overwrites.
    fn effectGuard(self: *Codegen) Error!void {
        _ = try self.w(.lda_mem, ZERO, 0);
        _ = try self.w(.ifgt, PHASE, 0);
    }

    fn patchJmp(self: *Codegen, idx: usize, slot: usize) void {
        self.words.items[idx] = isa.encode(.jmp, @intCast(slot), 0);
    }

    /// Unconditional jump that fires only once PHASE != 0 (i.e. after the
    /// boot walk has latched the phase). Normalizes acc first so behavior
    /// never depends on leftover expression state. Used for backedges,
    /// break and continue.
    fn phaseJump(self: *Codegen, patch_idx: *usize) Error!void {
        _ = try self.w(.lda_mem, ZERO, 0);
        _ = try self.w(.ifgt, PHASE, 0);

        patch_idx.* = try self.w(.jmp, 0, 0);
    }

    // ---- expressions (result left in acc) ----

    fn evalExpr(self: *Codegen, e: *const Expr, line: u32, col: u32) Error!void {
        switch (e.*) {
            .int => |k| _ = try self.w(.lda_imm, k, 0),
            .variable => |r| _ = try self.w(.lda_mem, @intCast(r), 0),
            .buttons => {
                try self.effectGuard();
                _ = try self.w(.read, 0, 0);
            },
            .btn => |side| {
                try self.effectGuard();
                _ = try self.w(.read, 0, 0);
                // Isolate bit N into acc (see docs/4CL.md §7.4):
                // shl x(3-N) moves bit N to the top of the nibble,
                // then shr x3 drops everything but that bit.
                var i: u4 = 0;
                const up: u4 = 3 - @intFromEnum(side);
                while (i < up) : (i += 1) _ = try self.w(.shl, 0, 0);
                i = 0;
                while (i < 3) : (i += 1) _ = try self.w(.shr, 0, 0);
            },
            .peek => |p| {
                const xa = p.x.*;
                const ya = p.y.*;
                if (xa == .variable and ya == .variable) {
                    try self.effectGuard();
                    _ = try self.w(.peek, @intCast(xa.variable), @intCast(ya.variable));
                } else if (xa == .variable) {
                    try self.evalExpr(p.y, line, col);
                    _ = try self.w(.sta, SCRATCH, 0);
                    try self.effectGuard();
                    _ = try self.w(.peek, @intCast(xa.variable), SCRATCH);
                } else if (ya == .variable) {
                    try self.evalExpr(p.x, line, col);
                    _ = try self.w(.sta, SCRATCH, 0);
                    try self.effectGuard();
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
        const op: isa.Op = if (left) .shl else .shr;

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
            .truthy => |e| {
                // Fast path: btn_*() leaves acc = 0/1, so the phase guard
                // alone selects — `ifgt r15` fires the exit iff PHASE(1) is
                // greater than acc, i.e. iff the button is clear (and always
                // while walking, when PHASE is 0). No staging needed.
                if (e.* == .btn) {
                    try self.evalExpr(e, line, col);
                    _ = try self.w(.ifgt, PHASE, 0);

                    var idx: usize = undefined;
                    idx = try self.w(.jmp, 0, 0);
                    try patches.append(self.alloc, idx);

                    return;
                }

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
            const mop: isa.Op = switch (op) {
                .eq => .ifeq,
                .lt => .iflt,
                .gt => .ifgt,
                else => unreachable,
            };
            _ = try self.w(mop, @intCast(lhs.variable), 0);
        } else if (rhs.* == .variable) {
            const mirrored: isa.Op = switch (op) {
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
                    const mop: isa.Op = if (op == .gt) isa.Op.ifgt else isa.Op.iflt;
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
            .for_stmt => |f| try self.forStmt(f.body),
            .brk => {
                var idx: usize = undefined;
                try self.phaseJump(&idx);
                const lctx = &self.loops.items[self.loops.items.len - 1];
                try lctx.brk_patches.append(self.alloc, idx);
            },
            .cont => {
                var idx: usize = undefined;
                try self.phaseJump(&idx);
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

                        _ = try self.w(.sta, r, 0);

                        try self.shiftMutateLoop(r, @intCast(dr), s.left, line, col);

                        return;
                    },
                    else => {},
                }

                try self.evalExpr(value, line, col);

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
    /// regs[target] ±= regs[amount] as a test-first counter loop: one
    /// increment per pass while the counter is below the amount, so a zero
    /// amount applies nothing and the loop always terminates by
    /// fall-through - sound in every phase, no guards needed.
    /// regs[target] ±= regs[amount] as a test-first counter loop with raw
    /// forward skip-jumps: the loop is bounded purely by the counter (a
    /// zero amount skips it entirely), so it is sound in every phase with
    /// no phase machinery whatsoever.
    fn mutateLoop(self: *Codegen, target: u4, amount_reg: u8, mode: sema.ArithOp, line: u32, col: u32) Error!void {
        const areg: u4 = @intCast(amount_reg);

        const skip = try self.flag(line, col);

        _ = try self.w(.lda_imm, 0, 0);
        _ = try self.w(.ifeq, areg, 0);

        const over = try self.w(.jmp, 0, 0);

        self.patchJmp(over, @intCast(skip));

        const top = try self.flag(line, col);

        _ = try self.w(.lda_mem, target, 0);
        _ = try self.w(.inc, 0, 0);

        if (mode == .sub) {
            var i: u4 = 0;
            while (i < 14) : (i += 1) _ = try self.w(.inc, 0, 0);
        }

        _ = try self.w(.sta, target, 0);

        _ = try self.w(.lda_mem, SCRATCH, 0);
        _ = try self.w(.inc, 0, 0);
        _ = try self.w(.sta, SCRATCH, 0);

        const back = try self.w(.jmp, 0, 0);

        self.patchJmp(back, top);
    }

    /// regs[target] <<= / >>= regs[dist], same counter-loop skeleton as
    /// mutateLoop but each pass shifts once.
    fn shiftMutateLoop(self: *Codegen, target: u4, dist_reg: u8, left: bool, line: u32, col: u32) Error!void {
        const areg: u4 = @intCast(dist_reg);
        const op: isa.Op = if (left) .shl else .shr;

        const skip = try self.flag(line, col);

        _ = try self.w(.lda_imm, 0, 0);
        _ = try self.w(.ifeq, areg, 0);

        const over = try self.w(.jmp, 0, 0);

        self.patchJmp(over, @intCast(skip));

        const top = try self.flag(line, col);

        _ = try self.w(.lda_mem, target, 0);
        _ = try self.w(op, 0, 0);
        _ = try self.w(.sta, target, 0);

        _ = try self.w(.lda_mem, SCRATCH, 0);
        _ = try self.w(.inc, 0, 0);
        _ = try self.w(.sta, SCRATCH, 0);
        _ = try self.w(.lda_mem, areg, 0);
        _ = try self.w(.ifgt, SCRATCH, 0);

        const back = try self.w(.jmp, 0, 0);

        self.patchJmp(back, top);
    }

    fn voidCall(self: *Codegen, vc: sema.VoidCall, line: u32, col: u32) Error!void {
        switch (vc) {
            .cls => {
                try self.effectGuard();
                _ = try self.w(.cls, 0, 0);
            },
            .halt => {
                const h = try self.flag(line, col);

                const idx = try self.w(.jmp, 0, 0);

                self.patchJmp(idx, h);
            },
            .flip => |f| {
                const xa = f.x.*;
                const ya = f.y.*;

                if (xa == .variable and ya == .variable) {
                    try self.effectGuard();
                    _ = try self.w(.flip, @intCast(xa.variable), @intCast(ya.variable));
                } else if (xa == .variable) {
                    try self.evalExpr(f.y, line, col);
                    _ = try self.w(.sta, SCRATCH, 0);
                    try self.effectGuard();
                    _ = try self.w(.flip, @intCast(xa.variable), SCRATCH);
                } else {
                    try self.evalExpr(f.x, line, col);
                    _ = try self.w(.sta, SCRATCH, 0);
                    try self.effectGuard();
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

    fn forStmt(self: *Codegen, body: *const Stmt) Error!void {
        // The only loop form: `for { ... }` — an infinite loop. Its exit
        // flag exists only when the body contains break.
        const top = try self.flag(body.line, body.col);

        try self.loops.append(self.alloc, .{ .top_slot = top });
        try self.stmt(body);

        const done = self.loops.pop() orelse unreachable;

        var back_idx: usize = undefined;
        try self.phaseJump(&back_idx);
        self.patchJmp(back_idx, top);

        if (done.brk_patches.items.len > 0) {
            const exit = try self.flag(body.line, body.col);

            for (done.brk_patches.items) |idx| self.patchJmp(idx, exit);
        }
    }
};

pub fn generate(
    alloc: std.mem.Allocator,
    diag: *dia.Diag,
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

    // epilogue: latch the phase, restore the initial variable values (the
    // boot walk executes the body's effects once, which may have mutated
    // them), then restart from the entry flag. All ungated.
    _ = try cg.w(.lda_imm, 1, 0);
    _ = try cg.w(.sta, PHASE, 0);

    for (prog.vars) |v| {
        _ = try cg.w(.lda_imm, v.init, 0);
        _ = try cg.w(.sta, @intCast(v.reg), 0);
    }

    _ = try cg.w(.jmp, 0, 0);

    return .{
        .words = cg.words.items,
        .slots = cg.slots.items,
    };
}
