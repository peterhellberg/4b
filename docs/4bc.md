# 4bc — Compiler Design for the 4B Language

*Version 0.1 (draft). Companion to `docs/4B.md`.*

`4bc` compiles a `4B` source file (`.4b`) into a raw 384-byte program image
(`.4brom`) that a 4BoD machine can run. Implementation language: **Zig
0.17.0-dev.387+31f157d80** (the pinned toolchain for this project). Binary
name: **`4bc`**.

## 1. Goals

1. Faithfully compile every construct of `docs/4B.md` — including all 16
   machine instructions, label/flag assignment, and `const`/`org`/`dw`.
2. Produce a **deterministic, exactly-384-byte** image whose bit layout is
   defined in `docs/4B.md` §8 and verified by golden tests.
3. Give **clear diagnostics** with file/line/column and a source snippet.
4. Stay small and dependency-free (std-only), so the tool builds and runs
   anywhere Zig does.

## 2. Non-goals

- Optimization (the ISA is 1:1; there is nothing to optimize at word level).
- Macros or a richer syntax — deliberately out of scope.
- A runtime, interpreter, or emulator.
- Linking multiple files.

## 3. Terminology

- **word** — one 12-bit instruction.
- **position** — the instruction index `0..255` where a word lands.
- **flag slot** — a `0..14` slot backing a named label (15 is forbidden).
- **image** — the 384-byte output.

## 4. CLI and I/O

```
4bc [options] <input.4b>
  -o, --output <file>   output path (default: <input stem>.4brom)
  -h, --help            print usage and exit
```

Behavior: read the source, compile, write the image. On error, print
diagnostics to stderr and exit non-zero; **no output file is written** on
failure (write to a temp path, then rename, to avoid leaving a partial ROM).

## 5. Repository layout

```
4bc/
  build.zig
  build.zig.zon
  src/
    main.zig       # CLI, driver, allocator setup
    diag.zig       # diagnostics: error/warn with source snippets
    lexer.zig      # tokens
    parser.zig     # tokens -> items
    model.zig      # Op enum, Operand, Item, Signature (ISA table)
    symbols.zig    # label/const tables, flag-slot allocation
    codegen.zig    # two passes: positions, labels, word emission
    encoder.zig    # 12-bit words -> 384-byte image
  test/
    golden/        # *.4b sources + *.expected byte files
```

## 6. Build (Zig 0.17.0-dev.387+31f157d80)

The toolchain is pinned to **`0.17.0-dev.387+31f157d80`**; record it in
`build.zig.zon` and the README so all builds use the same std API surface.
`build.zig` follows the standard module-based layout:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "4bc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run 4bc").dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_tests = b.addRunArtifact(unit_tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);
}
```

> **Note.** `0.17.0-dev.387+31f157d80` sits mid-stream of the `std.Io`
> rewrite and the `ArrayList` unmanaged/managed merge; std APIs can shift
> between dev builds. The pin above is the contract: code against it, and keep
> file I/O isolated in `main.zig` so any future bump touches one file. `zig
> build`, `zig build test`, and `zig build run -- file.4b` should "just work".

## 7. Pipeline

```
source → lex → parse → pass 1 (positions, consts, labels, slots)
                      → pass 2 (resolve + emit words) → pack → 384-byte image
```

A two-pass design is used because `jmp` may reference labels defined later:
pass 1 must know all label→slot assignments before pass 2 can resolve
references.

```
pub fn compile(alloc: std.mem.Allocator, path: []const u8, src: []const u8) !Image {
    const tokens = try lexer.lex(alloc, src);
    const items  = try parser.parse(alloc, tokens);
    var sym      = try symbols.analyze(alloc, items);   // pass 1
    const words  = try codegen.generate(alloc, &sym, items); // pass 2
    var image: encoder.Image = undefined;
    encoder.pack(words.items, &image);
    return image;
}
```

## 8. Lexer

Token model:

```zig
pub const Kind = enum { ident, number, at, hash, comma, colon, eol };

pub const Token = struct {
    kind: Kind,
    text: []const u8, // slice into src
    line: u32,
    col:  u32,
};
```

Rules (`docs/4B.md` §3): `;` line comments, case-insensitive identifiers,
decimal/hex/binary numbers, the sigils `@ # , :`. The lexer validates number
shape (`0x`/`0b` prefixes) but not range — range checks happen in the parser
so diagnostics can name the offending operand. Each line terminates with an
`eol` token; lexer errors report `line:col`.

## 9. Parser

Line-oriented. Each line yields zero or more `label` items and at most one
`instruction` or `directive` item.

```zig
pub const Operand = union(enum) {
    reg:  u4,          // r0..r15
    imm:  u4,          // #0..#15
    label_ref: []const u8,
    flag_slot: u4,     // raw N for flag/jmp
};

pub const Item = union(enum) {
    label:   struct { name: []const u8 },   // '@name:' -> emits flag
    inst:    struct { op: Op, a: ?Operand, b: ?Operand },
    const_:  struct { name: []const u8, value: u4 },
    org:     u16,
    dw:      u16,                            // 0..0xFFF
};
```

Operand validation uses a per-opcode signature table:

```zig
const OpKind = enum { none, reg, imm_or_reg, label_or_slot };
const Signature = struct { op: Op, a: OpKind, b: OpKind };
const ISA = [_]Signature{
    .{ .op = .nop,  .a = .none,            .b = .none },
    .{ .op = .lda,  .a = .imm_or_reg,      .b = .none },
    .{ .op = .sta,  .a = .reg,             .b = .none },
    .{ .op = .peek, .a = .reg,             .b = .reg  },
    // ... one entry per mnemonic
};
```

`lda` with `#k` maps to opcode `0011`; `lda rN` maps to `0001`. `@name:` is
rewritten by the parser to `flag` with a `label_ref` operand. Register names
(`r0`–`r15`) are recognized during parsing so `r16` is rejected with a clear
message.

## 10. Symbol tables and flag-slot allocation (pass 1)

```zig
pub const Symbols = struct {
    consts: std.StringHashMap(u4),
    labels: std.StringHashMap(u4),   // name -> slot
    slot_pos: [15]u16,               // slot -> position (-1 if unset)
    next_slot: u4,
    errors: std.ArrayList(Error),
};
```

Pass 1 walks the items in order, maintaining the current **position**
(`u16`), which `org` may set and which every word advances by 1:

1. **Consts** are collected (duplicate or reserved-name → error).
2. **Labels** (`@name:` / `flag @name`) get the next free slot `0..14`
   in first-definition order; the label's *position* is the current position
   (the slot of the `flag` word being emitted). Redefinition or more than 15
   labels → error.
3. **`flag N` / `jmp N`** with explicit slots: slot 15 → error; otherwise
   recorded for pass 2.
4. **`org N`** sets the position; must not move backwards or exceed 256.
5. Every instruction/`dw` advances the position by 1; exceeding 256 → error.

## 11. Code generation (pass 2)

Pass 2 re-walks the items with the populated `Symbols`:

```zig
fn encode(op: Op, a: u4, b: u4) u16 {
    return (@as(u16, @intFromEnum(op)) << 8) | (@as(u16, a) << 4) | b;
}
```

- `nop/read/inc/cls/shl/shr` → `encode(op, 0, 0)`.
- register/immediate operands → value directly into `A`/`B`.
- `label_ref` → the slot from `Symbols.labels` (forward refs now resolve;
  undefined label → error).
- `flag @name` / `@name:` → `encode(.flag, slot, 0)`; `jmp @name` →
  `encode(.jmp, slot, 0)`; raw `flag N` / `jmp N` → the explicit slot.
- `dw V` → emit `V` unchanged.
- Position tracking mirrors pass 1; word indices must agree (an internal
  assertion catches divergence — this is the main invariant of the two passes).

The conditional `if*` instructions need no special codegen: the skip is a
*runtime* property of the machine; pass 2 simply emits the `if*` word and the
following word.

## 12. Encoder (word → image)

`docs/4B.md` §8 defines the layout: word *n* occupies global bits
`[12n, 12n+12)`; byte *i* holds bits `[8i, 8i+8)` LSB-first.

```zig
pub const IMAGE_BYTES = 384;

pub fn pack(words: []const u16, out: *[IMAGE_BYTES]u8) void {
    @memset(out, 0);
    for (words, 0..) |w, wi| {
        const base: usize = wi * 12;
        var k: u5 = 0;
        while (k < 12) : (k += 1) {
            if (((w >> k) & 1) == 0) continue;
            const g = base + k;
            out[g / 8] |= @as(u8, 1) << @intCast(g % 8);
        }
    }
}
```

Zero-initialization is deliberate: unused program memory is `000` = `nop`, and
programs shorter than 256 words are padded to a full 384-byte image. The
packing is intentionally isolated in this one function so that, if a
particular 4BoD reimplementation's ROM loader expects a different bit/byte
order, only `encoder.zig` needs to change (see §16).

## 13. Error handling and diagnostics

`diag.zig` owns all user-facing output:

```
file.4b:12:7: error: undefined label '@start'
   lda #0
   ...^
```

- Errors are collected during the passes; `main.zig` prints them all (sorted by
  position) and exits non-zero if any exist.
- `Symbols.errors` carries `{ msg, line, col }`; source lines are looked up
  from a line-index built by the lexer, so snippets never require re-scanning.
- `warn` (non-fatal) is available for future use; today nothing warns.

## 14. Memory and allocation

One `std.heap.ArenaAllocator` over `std.heap.page_allocator` for the whole
compile (source copy, tokens, items, symbols, words). The image is a fixed
`[384]u8` on the stack. `ArenaAllocator` makes the pipeline leak-free by
construction; `defer arena.deinit()` in `main`.

## 15. Testing strategy

Three layers, all run by `zig build test`:

1. **Unit tests** per module:
   - lexer: token streams and error positions for representative lines;
   - parser: valid operands, wrong count/kind, out-of-range values;
   - encoder: pack→decode round-trip for random 12-bit words.
2. **Golden tests**: the §10 example in `docs/4B.md` is `test/golden/line.4b`
   with `line.expected` bytes `80 03 21 00 03 22 30 02 B0 20 01 20 01 0A 50 20
   02 D3 00 0C B1 10 0C` + 361 zero bytes. Compile and compare with
   `std.testing.expectEqualSlices`. Other goldens: the §11 button program, a
   forward-reference `jmp`, a `flag N`/`jmp N` program, an `org`/`dw` program,
   and an all-16-instructions coverage program.
3. **Negative tests**: each §12 error condition must produce the expected
   diagnostic text (assert substrings like `undefined label`, `slot 15`).

An end-to-end sanity check (manual, not CI): run the golden ROM in a 4BoD
emulator and confirm the middle row of pixels lights up.

## 16. Zig 0.17.0-dev.387+31f157d80 notes and risks

- Toolchain is pinned to **`0.17.0-dev.387+31f157d80`** (recorded in
  `build.zig.zon`); std APIs are churning (`std.Io` writer/reader types,
  `std.ArrayList` unmanaged/managed merge, build API). Keep I/O in `main.zig`
  and the ISA/bit layout in `model.zig`/`encoder.zig` so churn is localized.
- Verify the std APIs used (file read/write, args, `ArrayList`, hash maps)
  against this exact snapshot before writing code; the build snippet in §6 is
  illustrative and must be confirmed against `zig build -h` on the pin.
- **ROM byte-order risk**: the canonical packing (§12) is defined by this
  project; if the target 4BoD reimplementation loads nibbles or words in a
  different order, flip it inside `encoder.zig` only. Flag this in the README.
- Two-pass position tracking must be identical in both passes; guard with
  `std.debug.assert` in pass 2.

## 17. Milestones

1. Skeleton: `build.zig`, `main.zig` CLI, `--help`, empty compile.
2. Lexer + unit tests.
3. Parser + ISA signature table + unit tests.
4. Pass 1 symbols + pass 2 codegen (labels, consts, forward refs).
5. Encoder + file output (temp-file + rename).
6. Diagnostics polish (multi-error, snippets).
7. Golden + negative test suite; `zig build test` green.
8. README with usage, `0.17.0-dev.387+31f157d80` pin, and byte-order caveat.

## 18. Open questions

- Should `warn` be surfaced for e.g. a label that is defined but never jumped
  to? (Low value; easy to add.)
- Multi-file includes would ease large games but are out of scope for v0.1.
- Confirm byte-order against the specific emulator(s) in use before release.