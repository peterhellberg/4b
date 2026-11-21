//! A disassembler for 4B ROM images: the inverse of `4a`.
//!
//! The module is deliberately I/O-free: give it a 384-byte image and it
//! returns 4A source text. Decoding reuses `isa.decode`, so the disassembler
//! and the VM/assembler cannot drift apart.
//!
//! ## Labels
//!
//! In 4A, a label `@foo:` is sugar for `flag @foo`: it emits a `flag` word
//! whose A nibble is the flag slot allocated to the label. A `jmp @foo`
//! emits `jmp` with the same slot. Slots are allocated in definition order,
//! starting at 0, which for ordinary `4a` output means flag words in address
//! order carry slots 0, 1, 2, ….
//!
//! A label can therefore only be emitted at a flag word whose slot equals
//! the number of labels already emitted (pass 1). Flag words with a
//! different slot — hand-written raw slots, or slot 15, which `4a` forbids —
//! are printed as raw instructions or `dw` instead. This keeps reassembly
//! byte-identical even for ROMs that do not follow the usual slot pattern;
//! it is the round-trip guarantee that matters, not pretty labels.
//!
//! Labels are named from control-flow roles and nearby operations by default
//! (`@halt`, `@loop`, `@draw`, `@frame`, `@inc_r3`, …). The optional
//! positional style uses stable slot-derived names (`@L00`, `@L01`, …).
//! Semantic names describe the code, not the original source identifiers,
//! which are not stored in the ROM.
//!
//! The output is a clean 4A listing: one instruction per line, with operand
//! alignment but no comments or address annotations. Labels stay in column
//! zero and following instructions are indented, as in the bundled examples.
//! Trailing zero padding is omitted because `4a` recreates it when packing
//! the image.

const std = @import("std");
const isa = @import("isa");
const rom = @import("rom");

/// How emitted labels are named.
pub const LabelStyle = enum {
    /// Deterministic names derived from the flag slot (`@L00`, `@L01`, …).
    positional,

    /// Infer names from the label's control-flow role. Labels whose role is
    /// unclear keep their positional name.
    semantic,
};

/// Formatting options for `disassemble`.
pub const Options = struct {
    /// Emit label definitions for reproducible flag slots and use them in
    /// `jmp` operands. When false, raw slot numbers are printed.
    labels: bool = true,

    /// Naming scheme for emitted labels. Ignored when `labels` is false.
    label_style: LabelStyle = .semantic,
};

pub const DisassembleError = std.mem.Allocator.Error || std.Io.Writer.Error ||
    error{NoSpaceLeft};

/// Width of the mnemonic column, excluding any body indentation.
const mnemonic_width = 6;

/// Indentation for instructions following a label definition.
const body_indent = 2;

/// Disassemble a 384-byte ROM into 4A source text. The returned slice is
/// owned by the caller.
pub fn disassemble(
    alloc: std.mem.Allocator,
    image: *const rom.Image,
    options: Options,
) DisassembleError![]u8 {
    var words: [rom.IMAGE_WORDS]u16 = undefined;
    rom.unpack(image, &words);

    // Trailing zero words are indistinguishable from 4a's automatic
    // padding, so stop at the last non-zero word. The image is packed from
    // exactly the emitted words, which reproduces the zero fill.
    var last: ?usize = null;
    for (words, 0..) |word, addr| {
        if (word != 0) last = addr;
    }
    const end = if (last) |addr| addr + 1 else 0;

    // Pass 1: find the flag words that can be reproduced as labels.
    const labels = LabelMap.init(&words, end, options);

    var aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();
    const w = &aw.writer;

    var in_label_body = false;
    for (0..end) |addr| {
        const is_label = labels.addr_slot[addr] != null;
        if (in_label_body and !is_label) {
            try w.splatByteAll(' ', body_indent);
        }

        try writeWord(w, addr, words[addr], &labels);
        if (is_label) in_label_body = true;
    }

    var list = aw.toArrayList();
    try list.shrinkToLen(alloc); // make the returned slice directly freeable
    return list.items;
}

/// Maximum length of a generated label, including the `@` sigil.
const max_label_name_len = 12;

const LabelName = struct {
    bytes: [max_label_name_len]u8 = undefined,
    len: usize = 0,

    fn setPositional(self: *LabelName, slot: u4) void {
        const text = std.fmt.bufPrint(&self.bytes, "@L{X:0>2}", .{slot}) catch unreachable;
        self.len = text.len;
    }

    fn setRole(self: *LabelName, role: []const u8, occurrence: usize) void {
        const text = if (occurrence == 1)
            std.fmt.bufPrint(&self.bytes, "@{s}", .{role}) catch unreachable
        else
            std.fmt.bufPrint(&self.bytes, "@{s}{d}", .{ role, occurrence }) catch unreachable;
        self.len = text.len;
    }

    fn get(self: *const LabelName) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// Control-flow evidence collected for one label slot.
const LabelFacts = struct {
    halt: bool = false,
    backward: bool = false,
    from_end: bool = false,
    forward_conditional: bool = false,
    has_clear: bool = false,
    has_read: bool = false,
    has_inc_dec: bool = false,
    is_targeted_conditionally: bool = false,
    is_targeted_unconditionally: bool = false,
    is_init_sequence: bool = false,
};

/// An operation found near the start of a label's block.
const LabelContent = union(enum) {
    frame,
    draw,
    clear,
    input,
    increment: u4,
    decrement: u4,
};

/// flag-slot → address and address → flag-slot maps for emitted labels.
const LabelMap = struct {
    addr_slot: [rom.IMAGE_WORDS]?u4 = @splat(null),
    slot_addr: [isa.MAX_SLOTS]?u8 = @splat(null),
    names: [isa.MAX_SLOTS]LabelName = undefined,
    bases: [isa.MAX_SLOTS][max_label_name_len]u8 = undefined,
    base_lens: [isa.MAX_SLOTS]usize = @splat(0),

    fn init(words: *const [rom.IMAGE_WORDS]u16, end: usize, options: Options) LabelMap {
        var map = LabelMap{};

        for (0..isa.MAX_SLOTS) |slot| {
            map.names[slot].setPositional(@intCast(slot));
        }
        if (!options.labels) return map;

        // A label emitted as the Nth one in source order gets slot N. Only
        // claim flag words whose slot matches that number.
        var next: u8 = 0;

        for (words[0..end], 0..) |word, addr| {
            const d = isa.decode(word);

            if (d.op != .flag) continue;
            if (d.b != 0) continue; // label syntax cannot express a B nibble
            if (d.a >= isa.MAX_SLOTS) continue; // slot 15 is forbidden
            if (d.a != next) continue; // slot would be renumbered

            map.addr_slot[addr] = d.a;
            map.slot_addr[d.a] = @intCast(addr);
            next += 1;
        }

        if (options.label_style == .semantic) {
            map.assignSemanticNames(words, end);
        }

        return map;
    }

    fn nameForSlot(self: *const LabelMap, slot: usize) []const u8 {
        return self.names[slot].get();
    }

    fn baseSlice(self: *const LabelMap, slot: usize) []const u8 {
        return self.bases[slot][0..self.base_lens[slot]];
    }

    /// Assign a role name, numbering it when the same role was already used.
    fn assignName(map: *LabelMap, slot: usize, role: []const u8) void {
        var occurrence: usize = 1;

        for (0..isa.MAX_SLOTS) |other| {
            if (other == slot or map.base_lens[other] == 0) continue;
            if (std.mem.eql(u8, map.baseSlice(other), role)) occurrence += 1;
        }

        @memcpy(map.bases[slot][0..role.len], role);
        map.base_lens[slot] = role.len;
        map.names[slot].setRole(role, occurrence);
    }

    /// Name labels from their role and nearby operations. Original source
    /// names are unavailable in a ROM, so these are deliberately generic.
    fn assignSemanticNames(
        map: *LabelMap,
        words: *const [rom.IMAGE_WORDS]u16,
        end: usize,
    ) void {
        var facts: [isa.MAX_SLOTS]LabelFacts = @splat(LabelFacts{});

        for (0..end) |addr| {
            const d = isa.decode(words[addr]);
            if (d.op != .jmp) continue;
            if (d.b != 0 or d.a >= isa.MAX_SLOTS) continue;

            const slot: usize = d.a;
            const target = map.slot_addr[slot] orelse continue;
            const target_addr: usize = target;
            const f = &facts[slot];

            if (isHaltLoop(words, map, target_addr, addr)) f.halt = true;
            if (target_addr <= addr) {
                f.backward = true;
                if (end - addr <= 2) f.from_end = true;
            }

            if (isConditionalJump(words, map, addr)) {
                f.is_targeted_conditionally = true;
                if (target_addr > addr) f.forward_conditional = true;
            } else {
                f.is_targeted_unconditionally = true;
            }

            // Inspect the target's block for semantic clues. lda_mem is a
            // phase guard or an ordinary load, not an init on its own; only
            // lda #k followed by sta rN is a reliable initialization.
            var at = target_addr + 1;
            while (at < end) : (at += 1) {
                if (map.addr_slot[at] != null) break;
                const d2 = isa.decode(words[at]);
                switch (d2.op) {
                    .cls => f.has_clear = true,
                    .read => {
                        f.has_read = true;
                        break;
                    },
                    .inc => {
                        f.has_inc_dec = true;
                        break;
                    },
                    .jmp => break,
                    .lda_imm => {
                        if (at + 1 < end) {
                            const next = isa.decode(words[at + 1]);
                            if (next.op == .sta and next.b == 0) {
                                f.is_init_sequence = true;
                                break;
                            }
                        }
                    },
                    else => {},
                }
            }
        }

        for (0..isa.MAX_SLOTS) |slot| {
            const label_addr = map.slot_addr[slot] orelse continue;
            const addr: usize = label_addr;
            const f = facts[slot];

            var role_buf: [max_label_name_len]u8 = undefined;
            var role: ?[]const u8 = null;

            if (f.halt) {
                role = "halt";
            } else if (addr == 0) {
                role = "start";
            } else if (isEmptyBody(words, map, addr, end)) {
                role = "entry";
            } else if (f.is_targeted_conditionally and
                !f.is_targeted_unconditionally and
                isHandler(words, map, addr, end, slot))
            {
                role = "handler";
            } else if (f.has_read and f.backward and !f.has_clear) {
                role = "poll";
            } else if (labelContent(words, map, addr, end)) |content| {
                role = switch (content) {
                    .frame => "frame",
                    .draw => "draw",
                    .clear => "clear",
                    .input => "input",
                    .increment => |reg| std.fmt.bufPrint(&role_buf, "inc_r{d}", .{reg}) catch unreachable,
                    .decrement => |reg| std.fmt.bufPrint(&role_buf, "dec_r{d}", .{reg}) catch unreachable,
                };
            } else if (f.from_end and f.backward) {
                role = "restart";
            } else if (f.has_inc_dec and f.backward) {
                role = "delay";
            } else if (f.is_init_sequence and !f.backward) {
                role = "init";
            } else if (f.backward) {
                role = "loop";
            } else if (f.is_targeted_unconditionally) {
                role = "target";
            } else if (f.forward_conditional) {
                role = "done";
            }

            if (role) |r| map.assignName(slot, r);
        }
    }
};

/// Does `addr`'s block contain a jump to `target`? With `conditional_only`,
/// count only jumps guarded by an `if*`, which is how a handler is invoked.
fn blockJumpsTo(
    words: *const [rom.IMAGE_WORDS]u16,
    labels: *const LabelMap,
    addr: usize,
    end: usize,
    target: usize,
    conditional_only: bool,
) bool {
    var at = addr + 1;
    while (at < end) : (at += 1) {
        if (labels.addr_slot[at] != null) break;
        const d = isa.decode(words[at]);
        if (d.op != .jmp or d.b != 0 or d.a != target) continue;
        if (conditional_only and !isConditionalJump(words, labels, at)) continue;
        return true;
    }

    return false;
}

/// The last jump in `addr`'s block, if any.
const LastJump = struct { addr: usize, slot: usize };

fn lastJump(
    words: *const [rom.IMAGE_WORDS]u16,
    labels: *const LabelMap,
    addr: usize,
    end: usize,
) ?LastJump {
    var found: ?LastJump = null;
    var at = addr + 1;
    while (at < end) : (at += 1) {
        if (labels.addr_slot[at] != null) break;
        const d = isa.decode(words[at]);
        if (d.op == .jmp and d.b == 0 and d.a < isa.MAX_SLOTS) {
            found = .{ .addr = at, .slot = d.a };
        }
    }

    return found;
}

/// A handler is a stub whose caller conditionally jumps into it and whose
/// last instruction conditionally jumps back to that caller. A loop head is
/// excluded because its last jump targets itself (or the next loop phase).
/// See the @hL/@hR stubs in examples/move.4a.
fn isHandler(
    words: *const [rom.IMAGE_WORDS]u16,
    labels: *const LabelMap,
    addr: usize,
    end: usize,
    slot: usize,
) bool {
    const ret = lastJump(words, labels, addr, end) orelse return false;
    if (ret.slot == slot or !isConditionalJump(words, labels, ret.addr)) return false;

    const caller_addr = labels.slot_addr[ret.slot] orelse return false;
    return blockJumpsTo(words, labels, caller_addr, end, slot, true);
}

/// A label with no body before the next label is usually a compiler entry
/// point whose flag is recorded during startup fall-through.
fn isEmptyBody(
    words: *const [rom.IMAGE_WORDS]u16,
    labels: *const LabelMap,
    addr: usize,
    end: usize,
) bool {
    var at = addr + 1;
    while (at < end) : (at += 1) {
        if (labels.addr_slot[at] != null) return true;
        if (isa.decode(words[at]).op != .nop) return false;
    }

    return false;
}

/// Find an operation that describes a label's block. Compiler phase guards
/// (`lda r14; ifgt r15`) are ignored because neither is a signal. A screen
/// clear followed by drawing or input is more specifically a frame.
fn labelContent(
    words: *const [rom.IMAGE_WORDS]u16,
    labels: *const LabelMap,
    addr: usize,
    end: usize,
) ?LabelContent {
    var first: ?ContentMatch = null;
    var has_clear = false;
    var has_input = false;
    var has_draw = false;

    var at = addr + 1;
    while (at < end) : (at += 1) {
        if (labels.addr_slot[at] != null) break;

        const d = isa.decode(words[at]);
        switch (d.op) {
            .cls => {
                has_clear = true;
                noteContent(&first, at, .clear);
            },
            .read => {
                has_input = true;
                noteContent(&first, at, .input);
            },
            .flip => {
                has_draw = true;
                noteContent(&first, at, .draw);
            },
            .jmp => break,
            .inc => {
                if (d.b != 0 or d.a > 1 or at == 0) continue;

                const prev = isa.decode(words[at - 1]);
                if (prev.op != .lda_mem or prev.b != 0) continue;
                if (at + 1 >= end) continue;

                const next = isa.decode(words[at + 1]);
                if (next.op != .sta or next.b != 0 or next.a != prev.a) continue;

                noteContent(&first, at, if (d.a == 1)
                    .{ .decrement = prev.a }
                else
                    .{ .increment = prev.a });
            },
            else => {},
        }
    }

    if (has_clear and (has_input or has_draw)) return .frame;
    if (first) |found| return found.content;
    return null;
}

const ContentMatch = struct {
    at: usize,
    content: LabelContent,
};

fn noteContent(
    first: *?ContentMatch,
    at: usize,
    content: LabelContent,
) void {
    if (first.* == null or at < first.*.?.at) {
        first.* = .{ .at = at, .content = content };
    }
}

/// A jump is a halt loop when it is the only non-label instruction between
/// its own address and the label it jumps to.
fn isHaltLoop(
    words: *const [rom.IMAGE_WORDS]u16,
    labels: *const LabelMap,
    target: usize,
    jump: usize,
) bool {
    if (jump <= target) return false;

    for (target + 1..jump) |addr| {
        if (labels.addr_slot[addr] != null) return false;
        if (isa.decode(words[addr]).op != .nop) return false;
    }

    return true;
}

/// Ignore label words between a conditional skip and the jump it guards.
fn isConditionalJump(
    words: *const [rom.IMAGE_WORDS]u16,
    labels: *const LabelMap,
    jump: usize,
) bool {
    var before = jump;
    while (before > 0 and labels.addr_slot[before - 1] != null) before -= 1;
    if (before == 0) return false;

    return switch (isa.decode(words[before - 1]).op) {
        .ifeq, .ifgt, .iflt => true,
        else => false,
    };
}

fn writeWord(
    w: *std.Io.Writer,
    addr: usize,
    word: u16,
    labels: *const LabelMap,
) DisassembleError!void {
    const d = isa.decode(word);

    // A designated label word is printed as a label definition; the
    // assembler recreates the very same flag word for it.
    if (labels.addr_slot[addr]) |slot| {
        var name_buf: [max_label_name_len + 1]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "{s}:", .{
            labels.nameForSlot(slot),
        });
        return writeLine(w, name, null);
    }

    var op_buf: [24]u8 = undefined;
    var mnemonic: []const u8 = undefined;
    var operand: ?[]const u8 = null;

    switch (d.op) {
        .nop, .read, .cls, .shl, .shr => {
            if (d.a != 0 or d.b != 0) return writeDw(w, word);
            mnemonic = switch (d.op) {
                .nop => "nop",
                .read => "read",
                .cls => "cls",
                .shl => "shl",
                .shr => "shr",
                else => unreachable,
            };
        },
        .lda_mem => {
            if (d.b != 0) return writeDw(w, word);
            mnemonic = "lda";
            operand = try std.fmt.bufPrint(&op_buf, "r{d}", .{d.a});
        },
        .sta, .ifeq, .ifgt, .iflt => {
            if (d.b != 0) return writeDw(w, word);
            mnemonic = switch (d.op) {
                .sta => "sta",
                .ifeq => "ifeq",
                .ifgt => "ifgt",
                .iflt => "iflt",
                else => unreachable,
            };
            operand = try std.fmt.bufPrint(&op_buf, "r{d}", .{d.a});
        },
        .lda_imm => {
            if (d.b != 0) return writeDw(w, word);
            mnemonic = "lda";
            operand = try std.fmt.bufPrint(&op_buf, "#{d}", .{d.a});
        },
        .inc => {
            // opcode 0x5 with A == 1 is the local `dec` extension; A == 0 is
            // `inc`. Any other A (and any B) needs the `dw` escape hatch.
            if (d.b != 0 or d.a > 1) return writeDw(w, word);
            mnemonic = if (d.a == 1) "dec" else "inc";
        },
        .peek, .flip => {
            mnemonic = if (d.op == .peek) "peek" else "flip";
            operand = try std.fmt.bufPrint(&op_buf, "r{d}, r{d}", .{ d.a, d.b });
        },
        .flag => {
            // `flag @name` defines a label in 4A, so a non-label flag word
            // must always use the raw numeric form — even when some other
            // address owns a label for this slot.
            if (d.b != 0 or d.a >= isa.MAX_SLOTS) return writeDw(w, word);
            mnemonic = "flag";
            operand = try std.fmt.bufPrint(&op_buf, "{d}", .{d.a});
        },
        .jmp => {
            if (d.b != 0 or d.a >= isa.MAX_SLOTS) return writeDw(w, word);
            mnemonic = "jmp";
            if (labels.slot_addr[d.a] != null) {
                const slot: usize = d.a;
                operand = try std.fmt.bufPrint(&op_buf, "{s}", .{
                    labels.nameForSlot(slot),
                });
            } else {
                operand = try std.fmt.bufPrint(&op_buf, "{d}", .{d.a});
            }
        },
    }

    try writeLine(w, mnemonic, operand);
}

/// Emit a `dw` line for a word that no 4A mnemonic can express exactly
/// (non-zero unused nibbles, or flag slot 15, which `4a` rejects).
fn writeDw(w: *std.Io.Writer, word: u16) DisassembleError!void {
    var buf: [8]u8 = undefined;
    const operand = try std.fmt.bufPrint(&buf, "0x{X:0>3}", .{word});
    try writeLine(w, "dw", operand);
}

/// `mnemonic operands`
///
/// A single valid 4A line, aligned to the same mnemonic column as `4c -S`.
fn writeLine(
    w: *std.Io.Writer,
    mnemonic: []const u8,
    operand: ?[]const u8,
) DisassembleError!void {
    try w.writeAll(mnemonic);

    if (operand) |o| {
        try w.splatByteAll(' ', mnemonic_width -| mnemonic.len);
        try w.writeAll(o);
    }

    try w.writeByte('\n');
}

// ---- tests ----------------------------------------------------------------

fn dis(alloc: std.mem.Allocator, words: []const u16, options: Options) ![]u8 {
    var image: rom.Image = undefined;
    rom.pack(words, &image);
    return disassemble(alloc, &image, options);
}

test "format: mnemonics and operands" {
    const alloc = std.testing.allocator;
    const text = try dis(alloc, &.{ 0x380, 0x210 }, .{ .labels = false });
    defer alloc.free(text);

    try std.testing.expectEqualStrings("lda   #8\nsta   r1\n", text);
    try std.testing.expect(std.mem.indexOfScalar(u8, text, ';') == null);
}

test "every opcode renders with a mnemonic" {
    const alloc = std.testing.allocator;
    const words = [_]u16{
        0x000, 0x120, 0x230, 0x380, 0x400, 0x500, 0x510, 0x600,
        0x700, 0x800, 0x912, 0xA34, 0xB00, 0xC00, 0xD50, 0xE60,
        0xF70,
    };
    const text = try dis(alloc, &words, .{ .labels = false });
    defer alloc.free(text);

    const expected = [_][]const u8{
        "nop",  "lda", "sta",  "lda",  "read", "inc", "dec",  "cls",
        "shl",  "shr", "peek", "flip", "flag", "jmp", "ifeq", "ifgt",
        "iflt",
    };
    for (expected) |m| {
        try std.testing.expect(std.mem.indexOf(u8, text, m) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, text, "r1, r2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "#8") != null);
}

test "labels: flag words become labels and jmp uses them" {
    const alloc = std.testing.allocator;
    const text = try dis(alloc, &.{ 0xB00, 0x380, 0xC00 }, .{
        .label_style = .positional,
    });
    defer alloc.free(text);

    try std.testing.expectEqualStrings("@L00:\n  lda   #8\n  jmp   @L00\n", text);
}

test "semantic labels are the default: self-loop becomes halt" {
    const alloc = std.testing.allocator;
    const text = try dis(alloc, &.{ 0xB00, 0xC00 }, .{});
    defer alloc.free(text);

    try std.testing.expectEqualStrings("@halt:\n  jmp   @halt\n", text);
}

test "semantic labels: backward branch with increment becomes delay" {
    const alloc = std.testing.allocator;
    const text = try dis(alloc, &.{ 0x000, 0xB00, 0x500, 0xC00, 0x600, 0x600 }, .{
        .label_style = .semantic,
    });
    defer alloc.free(text);

    try std.testing.expectEqualStrings("nop\n@delay:\n  inc\n  jmp   @delay\n  cls\n  cls\n", text);
}

test "semantic labels: plain backward branch becomes loop" {
    const alloc = std.testing.allocator;
    const text = try dis(alloc, &.{ 0x000, 0xB00, 0x700, 0xC00, 0x700, 0x700 }, .{
        .label_style = .semantic,
    });
    defer alloc.free(text);

    try std.testing.expectEqualStrings("nop\n@loop:\n  shl\n  jmp   @loop\n  shl\n  shl\n", text);
}

test "semantic labels: backward branch with read becomes poll" {
    const alloc = std.testing.allocator;
    const text = try dis(alloc, &.{ 0x000, 0xB00, 0x400, 0xC00, 0x400, 0x400 }, .{
        .label_style = .semantic,
    });
    defer alloc.free(text);

    try std.testing.expectEqualStrings("nop\n@poll:\n  read\n  jmp   @poll\n  read\n  read\n", text);
}

test "semantic labels: clear plus read stays frame, not poll" {
    const alloc = std.testing.allocator;
    const text = try dis(alloc, &.{ 0x000, 0xB00, 0x600, 0x400, 0xC00, 0x600 }, .{
        .label_style = .semantic,
    });
    defer alloc.free(text);

    try std.testing.expectEqualStrings("nop\n@frame:\n  cls\n  read\n  jmp   @frame\n  cls\n", text);
}

test "semantic labels: conditional call and return becomes handler" {
    const alloc = std.testing.allocator;
    const text = try dis(alloc, &.{ 0xB00, 0xD00, 0xC10, 0xB10, 0xD00, 0xC00 }, .{
        .label_style = .semantic,
    });
    defer alloc.free(text);

    try std.testing.expectEqualStrings(
        "@start:\n  ifeq  r0\n  jmp   @handler\n@handler:\n  ifeq  r0\n  jmp   @start\n",
        text,
    );
}

test "semantic labels: forward target starting with lda #k becomes init" {
    const alloc = std.testing.allocator;
    const text = try dis(alloc, &.{ 0xC00, 0x000, 0xB00, 0x380, 0x210 }, .{
        .label_style = .semantic,
    });
    defer alloc.free(text);

    try std.testing.expectEqualStrings(
        "jmp   @init\nnop\n@init:\n  lda   #8\n  sta   r1\n",
        text,
    );
}

test "semantic labels: forward conditional target becomes done" {
    const alloc = std.testing.allocator;
    const text = try dis(alloc, &.{ 0xB00, 0xD00, 0xC10, 0x000, 0xB10 }, .{
        .label_style = .semantic,
    });
    defer alloc.free(text);

    try std.testing.expectEqualStrings(
        "@start:\n  ifeq  r0\n  jmp   @done\n  nop\n@done:\n",
        text,
    );
}

test "semantic labels: forward unconditional target becomes target" {
    const alloc = std.testing.allocator;
    const text = try dis(alloc, &.{ 0xB00, 0xC10, 0x000, 0xB10 }, .{
        .label_style = .semantic,
    });
    defer alloc.free(text);

    try std.testing.expectEqualStrings(
        "@start:\n  jmp   @target\n  nop\n@target:\n",
        text,
    );
}

test "semantic labels: repeated roles get unique suffixes" {
    const alloc = std.testing.allocator;
    const text = try dis(alloc, &.{ 0xB00, 0xC00, 0xB10, 0xC10 }, .{
        .label_style = .semantic,
    });
    defer alloc.free(text);

    try std.testing.expectEqualStrings(
        "@halt:\n  jmp   @halt\n@halt2:\n  jmp   @halt2\n",
        text,
    );
}

test "semantic labels keep positional names for unclear roles" {
    const alloc = std.testing.allocator;
    const text = try dis(alloc, &.{ 0x000, 0xB00 }, .{ .label_style = .semantic });
    defer alloc.free(text);

    try std.testing.expectEqualStrings("nop\n@L00:\n", text);
}

test "semantic labels: body operations provide names" {
    const alloc = std.testing.allocator;

    const cases = [_]struct {
        words: []const u16,
        expected: []const u8,
    }{
        .{ .words = &.{ 0x000, 0xB00, 0xA00 }, .expected = "@draw:" },
        .{ .words = &.{ 0x000, 0xB00, 0x600 }, .expected = "@clear:" },
        .{
            .words = &.{ 0x000, 0xB00, 0x600, 0xA00 },
            .expected = "@frame:",
        },
        .{ .words = &.{ 0x000, 0xB00, 0x400 }, .expected = "@input:" },
        .{
            .words = &.{ 0x000, 0xB00, 0x130, 0x500, 0x230 },
            .expected = "@inc_r3:",
        },
        .{
            .words = &.{ 0x000, 0xB00, 0x130, 0x510, 0x230 },
            .expected = "@dec_r3:",
        },
    };

    for (cases) |c| {
        const text = try dis(alloc, c.words, .{ .label_style = .semantic });
        defer alloc.free(text);

        try std.testing.expect(std.mem.indexOf(u8, text, c.expected) != null);
    }
}

test "semantic labels: adjacent empty labels become entry points" {
    const alloc = std.testing.allocator;
    const text = try dis(alloc, &.{ 0x000, 0xB00, 0xB10 }, .{
        .label_style = .semantic,
    });
    defer alloc.free(text);

    try std.testing.expectEqualStrings("nop\n@entry:\n@L01:\n", text);
}

test "semantic labels: outer reset jump becomes restart" {
    const alloc = std.testing.allocator;
    const text = try dis(alloc, &.{ 0x000, 0xB00, 0x300, 0xC00 }, .{
        .label_style = .semantic,
    });
    defer alloc.free(text);

    try std.testing.expectEqualStrings("nop\n@restart:\n  lda   #0\n  jmp   @restart\n", text);
}

test "no-labels prints raw flag slots" {
    const alloc = std.testing.allocator;
    const text = try dis(alloc, &.{ 0xB00, 0xC00 }, .{ .labels = false });
    defer alloc.free(text);

    try std.testing.expectEqualStrings("flag  0\njmp   0\n", text);
}

test "non-canonical words fall back to dw" {
    const alloc = std.testing.allocator;
    // 0x9F1 has a non-zero B nibble on a no-operand op; 0xBF0 uses the
    // forbidden slot 15; 0x512 is `dec` with a non-zero B nibble.
    const text = try dis(alloc, &.{ 0x012, 0xBF0, 0x512, 0x3F1 }, .{});
    defer alloc.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "dw    0x012") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dw    0xBF0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dw    0x512") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dw    0x3F1") != null);
}

test "out-of-order flag slots stay raw" {
    const alloc = std.testing.allocator;
    // Slot 2 at word 0 cannot be the first label (it would be renumbered to
    // 0), so it must remain a raw flag. Slot 0 at word 1 can be a label.
    const text = try dis(alloc, &.{ 0xB20, 0xB00, 0xC20, 0xC00 }, .{
        .label_style = .positional,
    });
    defer alloc.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "flag  2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "@L00:") != null);
    // A raw jmp to slot 2 stays numeric even though slot 0 has a label.
    try std.testing.expect(std.mem.indexOf(u8, text, "jmp   2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "jmp   @L00") != null);
}

test "all-zero ROM emits no instructions" {
    const alloc = std.testing.allocator;
    const text = try dis(alloc, &.{}, .{});
    defer alloc.free(text);

    try std.testing.expectEqualStrings("", text);
}

test "last non-zero word sets the end of disassembly" {
    const alloc = std.testing.allocator;
    var words: [rom.IMAGE_WORDS]u16 = @splat(0);
    words[255] = 0x380;

    var image: rom.Image = undefined;
    rom.pack(&words, &image);

    const text = try disassemble(alloc, &image, .{});
    defer alloc.free(text);

    try std.testing.expect(std.mem.endsWith(u8, text, "lda   #8\n"));
    try std.testing.expectEqual(@as(usize, 256), std.mem.count(u8, text, "\n"));
}
