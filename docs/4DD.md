# 4D Disassembler Design

Companion to `docs/4AL.md` and `docs/4AD.md`.

`4d` turns a 384-byte `.4b` ROM image back into `.4a` source:

```
.4a --4a--> .4b --4d--> .4a --4a--> .4b
```

The last image must be byte-identical to the first. That round-trip property
is the definition of done and is enforced by tests over every bundled
example ROM.

## 1. Goals

1. Emit valid 4A source: the output of `4d` must be directly assembleable by
   `4a` with no manual edits.
2. Round-trip every ROM produced by `4a` byte-for-byte.
3. Decode with the shared ISA table (`isa.decode`) and the shared ROM
   unpacker (`rom.unpack`), so the disassembler, assembler and VM cannot
   drift apart.
4. Stay dependency-free and keep all file I/O in the CLI (`src/4d.zig`);
   the decoder/formatter is a plain library.

## 2. Non-goals

- No decompilation to 4C.
- No data/table detection. A data word that happens to decode as a branch
  only produces a harmless extra label or raw operand.
- No guarantee for arbitrary hand-built ROMs beyond faithful disassembly:
  every word is still rendered exactly, either as a mnemonic or as `dw`.

## 3. CLI and I/O

```
4d [options] <input.4b>
  -o, --output <file>   output assembly path (default: <input stem>.4a, or stdout if it exists)
                        use '-' to write to stdout explicitly
  -l, --labels          emit labels for branch targets (default: on)
  -L, --no-labels       emit raw flag slots instead of labels
  -s, --semantic-labels infer semantic names (default; alias: --heuristic-labels)
  -p, --positional-labels emit @Lxx names instead of inferred names
  -h, --help            print usage and exit
```

As with `4a`, output is written only after the input has been validated: on
error nothing is written and the exit status is non-zero.

Without `-o`, `4d` creates `<input stem>.4a` exclusively. If that file already
exists, it is left untouched and the assembly is written to stdout instead.
An explicit `-o` remains authoritative and may overwrite its target.

## 4. Repository layout

```
src/
  4d.zig              CLI: arguments, file I/O, validation
  disassembler.zig    decode + format library, unit tests
  test/roundtrip.zig  .4b -> .4a -> .4b byte-comparison tests
examples/roms.zig     @embedFile manifest of example ROMs for those tests
docs/4DD.md           this document
```

`disassembler.zig` exposes a single entry point:

```zig
pub fn disassemble(
    alloc: std.mem.Allocator,
    image: *const rom.Image,
    options: Options,
) DisassembleError![]u8
```

The returned slice is owned by the caller. No file names, diagnostics or
global state are involved, so the library could later be embedded in the box
alongside `fourb_assemble`.

## 5. Decoding

`rom.unpack` is the exact inverse of `rom.pack` and extracts 256 12-bit words
from the 384-byte image using the same LSB-first bit order as
`fourb_vm_load_rom`. `isa.decode(word)` splits a word into its opcode and two
nibbles. There is no separate decoder to keep in sync.

## 6. The label problem

4A does not have a "jump to address" instruction. `flag @name` records the
current address in a flag slot, and `jmp @name` jumps to whatever that slot
holds. The assembler allocates slots `0..14` in *definition order*, and a
label definition `@name:` is sugar for `flag @name` — it emits a `flag` word.

Consequences for disassembly:

- A flag word is a candidate label definition; its A nibble is the slot.
- A jmp word with that slot can print `@label`.
- Because slot numbers are assigned in source order, a label emitted as the
  Nth label gets slot N. A flag word whose original slot is not N cannot be
  printed as a label without changing the bytes.

Pass 1 therefore walks the words in address order and claims a flag word as
a label only when its slot equals the number of labels emitted so far.
Everything else stays raw. With `-L`, pass 1 is skipped entirely and all
branch operands print as raw slot numbers.

### 6.1 Label names

By default, a second pass infers a name from the label's control-flow role.
`-s`/`--semantic-labels` requests this explicitly; `-p`/`--positional-labels`
selects deterministic `@L00`, `@L01`, … names matching the slot number.

| Evidence | Name | Meaning |
| -------- | ---- | ------- |
| Jump to the label is its only non-`nop` body | `@halt` | Infinite idle loop |
| Label is at address 0 | `@start` | Program entry point |
| Label has no body before the next label | `@entry` | Compiler entry flag |
| Block has `cls` plus `flip` or `read` | `@frame` | Clear-and-redraw frame |
| First operation is `flip` | `@draw` | Pixel drawing block |
| First operation is `cls` | `@clear` | Screen clear block |
| First operation is `read` | `@input` | Button input block |
| Block starts `lda rN; inc; sta rN` | `@inc_rN` | Register increment |
| Block starts `lda rN; dec; sta rN` | `@dec_rN` | Register decrement |
| Backward jump from the final instruction | `@restart` | Outer reset loop |
| Any other backward jump | `@loop` | Back edge |
| Unconditional forward jump targets it | `@target` | Generic jump target |
| Forward jump guarded by `if*` targets it | `@done` | Conditional skip exit |
| No recognized incoming jump or operation | `@Lxx` | Positional fallback |

Repeated roles are numbered from 2 (`@loop2`, `@done2`, …). These names are
heuristics: ROMs do not store source identifiers, so the names describe the
jump structure, not the original author's intent. They never affect the
assembled bytes because only the label spelling changes.

One further subtlety: `flag @name` *defines* a label in 4A, so a non-label
flag word must always use the numeric `flag N` form, even if another address
owns a label for that slot. Only `jmp` may use a label reference.

## 7. Emitting a word

Most words have a direct mnemonic form; unused nibbles are zero in anything
`4a` produces:

| Word shape | Source |
| ---------- | ------ |
| opcode 0x5, A=0 | `inc` |
| opcode 0x5, A=1 | `dec` (local 4B extension) |
| opcode 0x1 / 0x3 | `lda rN` / `lda #k` |
| opcode 0x9 / 0xA | `peek rX, rY` / `flip rX, rY` |
| opcode 0xB / 0xC | `flag N` / `jmp N` (or a label where possible) |
| any other word with non-zero unused nibbles, or slot 15 | `dw 0xNNN` |

`dw` is the escape hatch that makes the fallback exact: it emits the raw
12-bit word, so even reserved slot 15, non-zero B nibbles and arbitrary data
round-trip unchanged.

The output is a clean 4A listing: one line per word, no comments or address
annotations, and operands aligned to a six-column mnemonic field (the same
style as `4c -S`). Labels stay in column zero and following instructions are
indented two spaces, matching the bundled source examples:

```
@L00:
  lda   #7
  jmp   @L00
```

## 8. Padding

Zero words past the program are indistinguishable from `4a`'s automatic zero
fill. Emission stops after the last non-zero word, with no comment or marker.
Reassembly packs only the emitted words, so the image is padded to 384 bytes
again — byte-identically, with no need to emit hundreds of `nop`s.

## 9. Validation

The box loader accepts only exactly 384 bytes, so `4d` does too. A file of
any other size is rejected with a diagnostic naming the path and the byte
count, and nothing is written. There are no undefined opcodes: every value
of the 4-bit opcode field is a defined instruction in `isa.zig`, and the VM
handles all sixteen. Words with unusual nibble patterns are rendered via
`dw` rather than being rejected.

## 10. Tests and build steps

| Step | What it does |
| ---- | ------------ |
| `zig build test` | all suites, including the disassembly suite and round-trip tests |
| `zig build dis-roundtrip` | only the round-trip tests |
| `zig build 4d -- …` | run the disassembler (alias: `zig build disassemble -- …`) |

The round-trip suite covers every `examples/*.4b` image (with positional
labels, semantic labels and `-L`), every assembler golden source, and
hand-written edge cases:
all-zero ROM, branch at address 0 and 255, non-sequential flag slots, two
flags sharing a slot, reserved slot 15, `dec`/`inc` extensions, non-zero
unused nibbles, raw `dw` data, and an immediate value colliding with a label
address. If `4a`'s encoding ever changes, these fail loudly.

## 11. Status and open questions

The v0.1 implementation covers the full ISA and the round-trip guarantee.
Possible follow-ups (not part of this project):

- A `4b -D` flag that dumps the disassembly of the loaded ROM.
- A `--data` heuristic that emits untouched word runs as `dw` directives.
- A side-by-side address/word/source/VM-state tracing view.
