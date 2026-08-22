# 4C Compiler Design

*Version 0.1. Companion to `docs/4CL.md`.*

`4c` compiles a 4C source file (`.4c`) into a raw 384-byte program image
(`.4b`) that the 4B box can run — or, on request, into equivalent `.4a`
assembly text that `4a` reassembles byte-for-byte. Implementation language:
**Zig 0.17.0-dev.387+31f157d80** (the pinned toolchain for this project).
Binary name: **`4c`**.

## 1. Goals

1. Faithfully implement every construct and documented lowering of
   `docs/4CL.md`.
2. Produce deterministic exactly-384-byte images using the same bit layout
   as 4A (`docs/4AL.md` §8).
3. Give clear diagnostics with file/line/column and a source snippet, in
   the same format as `4a`.
4. Stay small and std-only; reuse existing repo pieces (`isa.zig`,
   `Diag`) where they fit unchanged.
5. Guarantee the round trip: `--emit-asm` output reassembled by `4a` must
   equal the direct image byte for byte (tested, §16).

## 2. Non-goals

- Optimization beyond constant folding — and folding itself exists only
  because global initializers and cheap constant operands depend on it.
- Functions/recursion, pointers, arrays, multiplication/division: the
  machine has no call/return, no indirect jump, and no ALU ops beyond
  `inc`/shifts (`docs/4CL.md` §1–2).
- Warnings; multi-file compilation or linking.

## 3. Terminology

- **word** — one 12-bit instruction.
- **position** — the instruction index `0..255` where a word lands.
- **flag slot** — jump-target number `0..14` (slot 15 is forbidden).
- **site** — one expansion instance of a dynamic operation (an add/sub/shift
  loop); every site gets its own slots.
- **scratch** — registers `r14`/`r15`, reserved for the compiler.
- **image** — the 384-byte output.

## 4. CLI and I/O

```
4c [options] <input.4c>
  -o, --output <file>     output ROM path (default: <input stem>.4b)
  -S, --emit-asm <file>   also write .4a assembly ('-' = stdout)
  -h, --help              print usage and exit
```

Behavior mirrors `4a`: read the source, compile, write outputs. On any
error, diagnostics go to stderr, the exit code is non-zero, and **no files
are written** — neither ROM nor assembly dump appears unless compilation
fully succeeds. The `-o` prefix form (`-ofile`) works as in `4a`.

## 5. Repository layout

```
4b/
  src/
    4c/
      main.zig       CLI, driver, file I/O
      compiler.zig   pipeline driver: lex -> parse -> sema -> codegen -> pack
      lexer.zig      tokens for 4C surface syntax
      parser.zig     tokens -> AST
      ast.zig        AST node types
      sema.zig       decl tables, folding, register allocation, checks
      codegen.zig    flag-slot allocator + word emission
      emit_asm.zig   words -> .4a text
    rom.zig        reused as-is: pack(words) -> [384]u8
    dia.zig          reused as-is: Diag with line/col + caret snippets
  examples/*.4c      demo programs (added with the implementation)
  docs/              4BoD.md, 4AL.md, 4AD.md, 4CL.md, 4CD.md (this doc)
```

`build.zig` gains an executable named `4c` rooted at `src/4c.zig`, a
run step (`zig build 4c -- args`), extra suites joined into
`zig build test`, and an extended `examples` step that compiles
`examples/*.4c` next to the existing `*.4a` assemblies.

## 6. Build (Zig 0.17.0-dev.387+31f157d80)

Same pinned toolchain as the 4A design (`docs/4AD.md` §6); after this change
`zig build` installs `4a`, `4b`, and `4c` into `zig-out/bin/`.

| Step                       | What it does                                    |
| -------------------------- | ----------------------------------------------- |
| (default)                  | build all three binaries                        |
| `zig build 4c -- …`         | run `4c` directly                               |
| `zig build test`           | adds the 4C suites to the existing steps        |
| `zig build examples`       | also compiles every `examples/*.4c`             |

The std-API churn caveats from `docs/4AD.md` §16 apply unchanged; keep file
I/O isolated in `main.zig`.

## 7. Pipeline

```
source → lex → parse → sema → codegen → pack → 384-byte image
                                  └→ emit_asm → .4a text
```

One forward walk over the AST; **no backpatching**. A `jmp` encodes a
flag-slot *number*, not a position — position binding happens at runtime,
when the flag word executes. Join slots are therefore allocated at construct
entry, before their final position exists, which is harmless. This is
simpler than the assembler's two passes because structured control flow has
no textual forward references.

```zig
pub fn compile(alloc: std.mem.Allocator, diag: *Diag, src: []const u8) CompileError!Image {
    const tokens = try lexer.lex(alloc, diag, src);
    const prog = try parser.parse(alloc, diag, tokens.items);
    var analyzed = try sema.analyze(alloc, diag, prog);
    const words = try codegen.generate(alloc, diag, &analyzed);
    var image: Image = undefined;
    image.pack(words.items, &image);
    return image;
}
```

Within a stage all errors are collected; between stages the driver stops as
soon as any exist.

## 8. Lexer

Token kinds: identifiers; keywords (`u4 fn const for if else break
continue`); integer literals; multi-char operators
(`== != <= >= && || << >> += -=`); single-char sigils
`( ) { } ; , = + - ! < > &`. Maximal munch: two-char operators are tried
before their prefixes. Identifiers are case-sensitive. Number shape
(`0x`/`0b` prefixes) is validated here; range checks happen later, where
spans can name the offending operand.

## 9. Parser

Recursive descent following the grammar in `docs/4CL.md` §4 exactly;
precedence follows the grammar layers (additive < `&` < shifts < unary).
Every node carries line/col.

```zig
pub const Expr = union(enum) {
    lit: u4,
    variable: Spanned([]const u8),
    neg: *Expr,
    bin: struct { op: BinOp, l: *Expr, r: *Expr }, // + - << >> &
    call: RetCall,                                 // peek buttons btn_*
};

pub const Cond = union(enum) {
    cmp: struct { op: CmpOp, l: *Expr, r: *Expr },
    not: *Cond,
    land: struct { l: *Cond, r: *Cond },
    lor: struct { l: *Cond, r: *Cond },
    truthy: *Expr,                                 // value used as condition
};

pub const Stmt = union(enum) {
    assign: struct { target: Spanned([]const u8), op: AssignOp, value: *Expr },
    iff: struct { cond: *Cond, then: *Stmt, els: ?*Stmt },
    whil: struct { cond: *Cond, body: *Stmt },
    brk, cont,
    call: VoidCall,                                // cls flip halt
    block: []Stmt,
};
```

Shift-distance and mask restrictions are checked in sema rather than the
parser so diagnostics can quote the offending operand.

## 10. Semantic analysis

Sema walks the program once and produces the analyzed form:

1. **Declarations.** Collect consts (`name -> u4 value`) and variables
   (`name -> register index`, declaration order). Duplicate names, names
   colliding with keywords/builtins, and more than 14 variables are errors.
2. **Constant folding.** Global initializers must fold to literals using
   only literals and consts. Folding is applied everywhere opportunistically;
   folded leaves are marked so codegen takes the cheap path. Constant
   conditions fold too (`docs/4CL.md` §7.3).
3. **Expression checks.** `&` right operand is an integer literal with
   contiguous set bits; shift distance is a literal or bare variable;
   builtin arity per signature table.
4. **Control checks.** `break`/`continue` only inside `for` (loop depth
   tracked during the walk); exactly one `fn main` present.

## 11. Register allocation

Variables map to `r0..r12` in declaration order; `r13` is the single
scratch temporary; `r14` (`ZERO`) and `r15` (`PHASE`) are reserved by the
phase machinery (docs/4CL.md §6.1); `acc` is the evaluator's working
register. No spilling and no liveness analysis: the language restrictions
of `docs/4CL.md` §7.5 guarantee that one temporary suffices. The compiler
never writes `r14`, so it stays 0 from machine reset onward.

## 12. Code generation

State: `words: ArrayList(u16)`, `pos: u16`, `next_slot: u4`. Helpers:

```zig
fn emit(op: Op, a: u4, b: u4) void {
    words.append(isa.encode(op, a, b));
    pos += 1;
    if (pos > 256) diag.err(..., "program exceeds 256 instructions");
}

/// Gate pair + payload: skips `op` while PHASE is 0.
fn emitGated(op: Op, a: u4, b: u4) void {
    emit(.lda, 15, 0);          // lda r15   (PHASE)
    emit(.ifeq, 14, 0);         // ifeq r14  (ZERO) -> skip payload at boot
    emit(op, a, b);
}

fn slot() u4 {
    if (next_slot == 15) diag.err(..., "out of flag slots ({d}/15 used)");
    next_slot += 1;
    return next_slot - 1;
}
```

Only *forward* jumps are phase-guarded — they are the only words that can
outrun their target flag during the boot walk. Two guard forms exist:

- **Conditional exits** (`if` joins): `lda #1; ifgt r15; jmp S`.
  The condition's own skip decides whether the `lda #1` runs, so the jump
  fires iff the condition is false and `PHASE` is 1.
- **Unconditional forward jumps** (`break`, `continue`, the dynamic
  arithmetic helper loops' exits): `lda r14; ifgt r15; jmp S`, which fires
  iff `PHASE != 0` regardless of leftover `acc`.

Backward jumps (loop backedges, `halt`'s spin) stay unguarded: their
target flag was recorded earlier in the same linear pass, and the guard's
acc load would be wrong there. Effect words (`sta`, `flip`, `cls`,
`read`, `peek`) are also unguarded — they cannot divert control, and a
guard's acc load would corrupt every store. The boot walk therefore
*executes* all effects exactly once (one extra frame of work) while the
phase guards suppress every forward jump, keeping the walk strictly
linear until the epilogue (`lda #1; sta r15; jmp @entry`, emitted last,
ungated) latches `PHASE` and restarts execution for real.

Slot allocation is preorder and deterministic: a construct allocates its
slot(s) when entered, before emitting its body. Overflow errors list the
per-construct tally (loops/branches/dynamic sites/halt) so the user can
see what to trim.

Lowering catalog (normative shapes are in `docs/4CL.md` §7):

- **Load/store**: `lda #k` / `lda rv`; then an unguarded `sta rv`.
- **± literal k**: `k` × `inc`; subtraction uses `(16-k)` × `inc`.
- **Add loop** (`x += rd`, ~16 words, 2 slots): zero-guard, then a
  bottom-tested count-up loop whose exit is fall-through:

  ```
  lda #0
  ifgt rd        ; dx > 0 -> skip next
  G jmp FZ       ; dx == 0 -> done
  lda #0
  sta r13        ; counter = 0
  F1: flag       ; slot F1 (loop top)
  lda rx
  inc
  sta rx         ; x += 1 (ungated)
  lda r13
  inc
  sta r13        ; counter += 1 (ungated: scratch only)
  ifeq rd        ; counter == dx -> skip next
  G jmp F1       ; another pass
  FZ: flag       ; slot FZ (exit join)
  ```

- **Sub loop** (`x -= rd`): same skeleton; the body applies `15 × inc`
  between `lda rx`/`sta rx` (mod-16 decrement), ~24 words, 2 slots.
  Constant operands avoid loops entirely.
- **Shifts**: literal distance = run of `shl`/`shr`; variable distance =
  counting loop shaped like the add loop (~13 words, 2 slots).
- **Unary minus** (`-rv`): sum 15 into `acc` repeatedly, `rv` times
  (`15·v ≡ -v mod 16`), 2 slots.
- **Masks** (`x & m`): decompose `m` into lowest set bit `l` and highest
  `h`; emit `shr × l`, `shl × l` (clear below `l`), then
  `shl × (3-h)`, `shr × (3-h)` (clear above `h`) — at most 6 ops,
  no slots.
- **Comparisons**: stage the RHS into `r13` first when it is a literal
  (`lda #k; sta r13`), evaluate the LHS into `acc` last, then pick opcode
  and polarity per the `docs/4CL.md` §7.2 table through one helper:

  ```zig
  fn branchIfFalse(c: *const Cond, false_slot: u4) void
  ```

  which emits the predicate plus the guarded conditional-exit `jmp` for
  every condition shape; `&&`/`||` chains recurse with the *same*
  `false_slot`, which is what makes them free.
- **if / for / break / continue**: templates from `docs/4CL.md` §7.3;
  `break` emits a phase-guarded `jmp` to the enclosing loop's exit slot,
  `continue` to its top slot. Folded constants skip straight to the
  surviving template.
- **Builtins**: `cls()` → plain `cls`, `buttons()` → plain `read`
  (writes `acc` only); `peek`/`flip` stage each argument through `r13`
  unless it is already a plain variable, then emit one `peek`/`flip`
  word; `btn_k()` = `read`, `shl` × (3-k), `shr` × 3;
  `halt()` = `flag S` + plain self-jump `jmp S`.
- **Assignment**: evaluate the value expression (result in `acc`), then
  an unguarded `sta` of the target register. Compound forms expand
  through the catalog above.
- **Program shape**: global initializers first, in declaration order
  (ungated `lda #k; sta rv` — idempotent under replay), then `@entry`
  (slot 0) and the `main` body, then the ungated epilogue
  `lda #1; sta r15; jmp @entry`.

Scratch discipline mirrors `docs/4CL.md` §7.5: the running value lives in
`acc`; primitives borrow `r13` transiently and release it; additive
chains flatten before lowering.

## 13. Assembly output (--emit-asm)

Rendered after a successful compile, from the final word list:

1. Scan the words for `flag` instructions (opcode `0xB`) and record each
   slot's position.
2. Emit one line per word. At a flag position, print the synthetic label
   (`@fN:` for slot N) on its own line first.
3. Render instructions in 4A syntax: mnemonics lowercase, registers `rN`,
   immediates `#k`, jumps/flags as `@fN`.

The output deliberately stays inside 4A's rules (≤ 15 labels, case-
insensitive identifiers, `;` comments), so `4a` reassembles it byte-for-
byte identical to the direct image — the property tested in §16.

## 14. Error handling and diagnostics

`dia.zig` is imported directly from the 4a side and used unchanged:

```
game.4c:12:9: error: unknown identifier 'velo'
    x += velo;
         ...^
```

Errors carry `{ msg, line, col }` plus the shared line-start index for
snippets; all are printed in encounter order and `main` exits non-zero if
any exist. As in `4a`, there is no warning level; everything user-facing
is an error.

## 15. Memory and allocation

Same approach as `docs/4AD.md` §14: the CLI uses the process-provided arena
(`args.arena`) so nothing needs explicit teardown, ASTs and token lists
allocate from it, and the image is a fixed `[384]u8` returned by value.
Leak-free by construction.

## 16. Testing strategy

All run by `zig build test`:

1. **Unit tests** per module:
   - lexer: operator maximal-munch, number shapes, comments;
   - parser: precedence, compound assignment, condition nesting;
   - sema: duplicate names, reserved names, >13 variables, mask/distance
     rejections, initializer folding;
   - codegen: exact word sequences for every §12 catalog entry (golden
     fragments asserted inline);
   - emit_asm: label placement, `@fN` rendering.
2. **Golden tests**: the three `docs/4CL.md` §9 examples compiled to
   complete 384-byte images with expected bytes inline in `assembler.zig`.
3. **Round-trip tests**: for each golden, feed the `--emit-asm` text back
   through the existing 4A pipeline (`compiler.zig`) and assert the second
   image equals the first byte-for-byte.
4. **Negative tests**: every error class in `docs/4CL.md` §10 produces a
   diagnostic containing the expected substring (`out of flag slots`,
   `contiguous`, `exceeds 256 instructions`, …).
5. **VM behavior tests**: run compiled goldens under `vm.zig` and assert
   screen/register state — including boot-walk soundness (no PC restarts:
   after warm-up ticks every referenced slot is non-zero) and steady-state
   behavior (the bounce pixel toggles, `move` responds to a synthetic
   `buttons` value).

End-to-end sanity check (manual): `zig-out/bin/4c examples/move.4c` then
`zig-out/bin/4b examples/move.4b` steers the pixel with arrow keys.

## 17. Zig pin notes and risks

- Toolchain pinned to `0.17.0-dev.387+31f157d80`; std churn notes from
  `docs/4AD.md` §16 apply verbatim (keep I/O in `main.zig`; isolate layout
  knowledge).
- Reusing `rom.zig`/`dia.zig` across both tools is deliberate: one
  packing implementation, one diagnostic format, tested twice.
- The scratch-discipline proof rests on the §4.2 language restrictions;
  if those ever loosen (e.g. general `|`/`^`), revisit §11 first.

## 18. Status

Planned. This document precedes the implementation; notable deviations will
be recorded here once `4c` exists, as done for `4a` in `docs/4AD.md` §18.

## 19. Open questions

- Should constant folding extend further (e.g. strength-reducing
  `x * 2`-style idioms)? v0.1 has no multiplication, so moot for now.
- Warning-level diagnostics (unused variable/const, unreachable statements
  after `halt()`)? Easy to add; low urgency.
- Conditional `for` sugar — only if real programs feel the lack.
