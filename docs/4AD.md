# 4A Assembler Design

*Version 0.2. Companion to `docs/4AL.md`.*

`4a` assembles a `4A` source file (`.4a`) into a raw 384-byte program image
(`.4b`) that a 4BoD machine can run. Implementation language: **Zig
0.17.0-dev.387+31f157d80** (the pinned toolchain for this project). Binary
name: **`4a`**.

## 1. Goals

1. Faithfully translate every construct of `docs/4AL.md` — including all 16
   machine instructions, label/flag assignment, and `const`/`org`/`dw`.
2. Produce a **deterministic, exactly-384-byte** image whose bit layout is
   defined in `docs/4AL.md` §8 and verified by golden tests.
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
4a [options] <input.4a>
  -o, --output <file>   output path (default: <input stem>.4b)
  -h, --help            print usage and exit
```

Behavior: read the source, assemble, write the image. On error, print
diagnostics to stderr and exit non-zero; **no output file is written** on
failure — the image is written only after assembly succeeds.

The assembler is also embedded in the `4b` console as a static library
(see §17), so the console can assemble `.4a` sources at startup.

## 5. Repository layout

```
4bc/
  build.zig
  build.zig.zon
  README.md
  docs/               # 4BoD.md (machine), 4AL.md (language), 4AD.md (this doc)
  examples/           # *.4a demo programs; zig build examples emits *.4b
  src/
    main.zig          # CLI, driver, file I/O
    compiler.zig      # pipeline driver: lex -> parse -> pass 1 -> pass 2 -> pack
    diag.zig          # diagnostics: errors with line/col and source snippets
    lexer.zig         # tokens
    parser.zig        # tokens -> items
    model.zig         # Op enum, Operand, Item, ISA signature table
    symbols.zig       # label/const tables, flag-slot allocation (pass 1)
    codegen.zig       # word emission (pass 2)
    encoder.zig       # 12-bit words -> 384-byte image
    asm.zig           # C-ABI wrapper embedding the assembler in the console
    vm.zig            # the 4BoD VM, shared with the console
    console.c         # raylib console (C)
    tests.zig         # golden + negative tests
    test/golden/      # *.4a golden sources; expected bytes live in tests.zig
```

## 6. Build (Zig 0.17.0-dev.387+31f157d80)

The toolchain is pinned to **`0.17.0-dev.387+31f157d80`**; recorded in
`build.zig.zon`. `zig build` installs both binaries (`4a`, `4b`) into
`zig-out/bin/`. Steps:

| Step                    | What it does                                        |
| ----------------------- | --------------------------------------------------- |
| (default)               | build `4a` and the raylib console `4b`              |
| `zig build compile -- …`| run `4a` directly                                   |
| `zig build run -- …`    | run the `4b` console                                |
| `zig build test`        | three suites: compiler module tests, VM tests, embedded-assembler tests |
| `zig build examples`    | assemble every `examples/*.4a` to `examples/*.4b`   |

The console links against two Zig static libraries built from this repo:
`vm.zig` (the machine) and `asm.zig` (this assembler's C-ABI wrapper); raylib
is fetched by the Zig package manager and built from source.

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
pub fn compile(alloc: std.mem.Allocator, diag: *Diag, src: []const u8) CompileError!Image {
    const tokens = try lexer.lex(alloc, diag, src);
    const items  = try parser.parse(alloc, diag, tokens.items);
    var sym      = try symbols.analyze(alloc, diag, items.items);   // pass 1
    const words  = try codegen.generate(alloc, diag, &sym, items.items); // pass 2
    var image: Image = undefined;
    encoder.pack(words.items, &image);
    return image;
}
```

Every stage reports diagnostics through the shared `Diag`; after each stage
the driver stops with `CompileFailed` as soon as errors exist.

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

Rules (`docs/4AL.md` §3): `;` line comments, case-insensitive identifiers,
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
const OperandKind = enum { none, reg, imm, reg_or_imm, label_or_slot };
const Spec = struct { mnemonic: []const u8, op: Op, a: OperandKind, b: OperandKind };
const specs = [_]Spec{
    .{ .mnemonic = "nop",  .op = .nop,  .a = .none, .b = .none },
    .{ .mnemonic = "lda",  .op = .lda_mem, .a = .reg_or_imm, .b = .none },
    .{ .mnemonic = "sta",  .op = .sta,  .a = .reg,  .b = .none },
    .{ .mnemonic = "peek", .op = .peek, .a = .reg,  .b = .reg  },
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

`docs/4AL.md` §8 defines the layout: word *n* occupies global bits
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
file.4a:12:7: error: undefined label '@start'
   lda #0
   ...^
```

- Errors are collected during the passes in encounter order; `main.zig` prints
  them all and exits non-zero if any exist.
- `Diag` owns the error list (`{ msg, line, col }`) and a line-start index
  built at init, so snippets never require re-scanning the source.
- There is no warning level today; everything user-facing is an error.

## 14. Memory and allocation

The CLI uses the process-provided arena (`args.arena`), so no explicit
allocator teardown is needed in `main`. The embedded entry point
(`asm.zig`) creates its own `std.heap.ArenaAllocator` over
`std.heap.page_allocator` per call and deinitializes it before returning.
The image is a fixed `[384]u8` passed by value; arena allocation makes the
pipeline leak-free by construction.

## 15. Testing strategy

Three layers, all run by `zig build test`:

1. **Unit tests** per module:
   - lexer: token streams for representative lines;
   - parser: label definitions, operands, `const`;
   - symbols: slot allocation, reserved names, slot 15 rejection;
   - codegen: encoding of instructions and label resolution;
   - encoder: packing of known words.
2. **Golden tests**: the §10 example in `docs/4AL.md` is `test/golden/line.4a`
   with expected bytes (inline in `tests.zig`) `80 03 21 00 03 22 30 02 B0 20
   01 20 01 0A 50 20 02 F3 00 0C B1 10 0C` + 361 zero bytes. Other goldens:
   the §11 button program, a forward-reference `jmp`, a `flag N`/`jmp N`
   program, and an `org`/`dw` program.
3. **Negative tests**: each §12 error condition must produce the expected
   diagnostic text (assert substrings like `undefined label`, `slot 15`).

The VM (`vm.zig`) and the embedded-assembler wrapper (`asm.zig`) contribute
their own suites to the same `zig build test` step.

An end-to-end sanity check (manual): run a golden ROM in the console and
confirm the middle row of pixels lights up.

## 16. Zig 0.17.0-dev.387+31f157d80 notes and risks

- Toolchain is pinned to **`0.17.0-dev.387+31f157d80`** (recorded in
  `build.zig.zon`); std APIs are churning (`std.Io` writer/reader types,
  `std.ArrayList` unmanaged/managed merge, build API). Keep I/O in `main.zig`
  and the ISA/bit layout in `model.zig`/`encoder.zig` so churn is localized.
- **ROM byte-order**: the canonical packing (§12) is LSB-first and is
  confirmed by the bundled VM (`vm_load_rom` unpacks the same layout) and by
  golden tests; if another 4BoD reimplementation differs, flip it inside
  `encoder.zig` only.
- Two-pass position tracking must be identical in both passes; guard with
  `std.debug.assert` in pass 2.

## 17. Embedding in the console

`asm.zig` wraps the pipeline behind one C-ABI entry point:

```zig
export fn bc_compile(path: [*:0]const u8, src: [*]const u8, src_len: usize,
                     out: [*]u8, err_buf: ?[*]u8, err_cap: usize) c_int
```

It returns 0 and fills `out` (384 bytes) on success; on failure it returns 1
and writes `path:line:col: error: msg` lines into `err_buf`, NUL-terminated
and truncated to fit. The console links this library and assembles any `.4a`
path at startup before opening the window; a unit test covers both paths.

## 18. Status

The v0.1 design has been implemented in full; notable deviations from the
original plan:

- Output is written directly after success instead of via temp-file + rename.
- Golden expected bytes live inline in `tests.zig` rather than in separate
  `.expected` files.
- The assembler ships embedded in the console (`asm.zig`) in addition to the
  standalone CLI.

## 19. Open questions

- Should a warning level exist, e.g. for a label that is defined but never
  jumped to? (Low value; easy to add.)
- Multi-file includes would ease large games but are out of scope for v0.1.
