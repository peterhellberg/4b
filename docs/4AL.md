# 4A Language Specification

*Version 0.1 (draft). Companion to `docs/4BoD.md`.*

4A is a small, assembly-style programming language for the 4B box.
A `.4a` source file is a sequence of instructions that map 1:1 onto
the 4B instruction set, plus a few conveniences (named constants, named
labels) that the 4A assembler (`4a`) resolves away at build time. Every 4B
machine instruction is expressible in 4A, and every 4A source file assembles to
exactly one 384-byte program image.

## 1. The 4B machine, in one paragraph

- Program memory: 256 instructions, each instruction exactly **12 bits**.
- RAM: 16 registers `r0`–`r15`, each holding one **4-bit** value (a nibble).
- A 4-bit **accumulator** (`acc`).
- Screen: 16×16, 1 bit per pixel (0 = off, 1 = on).
- 16 **flags**: fixed-size jump-target slots, numbered 0–15.
- Four buttons: left, right, up, down.

## 2. Values and operand kinds

Everything is a 4-bit value `0..15`.

| Kind     | Syntax        | Used by                              |
|----------|---------------|--------------------------------------|
| Register | `r0` … `r15`  | `lda`, `sta`, `peek`, `flip`, `ifeq`, `ifgt`, `iflt` |
| Immediate| `#0` … `#15`  | `lda`                                |
| Label    | `@name`       | `jmp`, `flag` (references)           |
| Flag slot| `0` … `15`    | `jmp`, `flag` (raw form)             |

Immediate literals may be written decimal (`#10`), hex (`#0xA`), or binary
(`#0b1010`).

## 3. Lexical rules

- Source is ASCII/UTF-8 text; lines may end with LF or CRLF.
- `;` starts a comment that runs to end of line.
- Identifiers: `[A-Za-z_][A-Za-z0-9_]*`, **case-insensitive**.
- Numbers: decimal `0`–`15`, hex `0x0`–`0xF`, binary `0b0`–`0b1111`.
  Every literal must fit in 4 bits.
- Reserved sigils: `@` (label), `#` (immediate), `,` (optional operand
  separator), `:` (label definition).
- Tokens are separated by whitespace.

## 4. Program structure

A program is a sequence of lines. Each line contains zero or more label
definitions, then **either one instruction or one directive**, then an
optional comment.

```ebnf
program     := line*
line        := ws* label* (instruction | directive)? ws* comment? nl
label       := '@' ident ':'
comment     := ';' any*
```

### 4.1 Directives

| Directive       | Meaning                                                            |
|-----------------|--------------------------------------------------------------------|
| `const N = V`   | Bind name `N` to the 4-bit value `V`. Usable where an immediate is expected. Takes no program space. |
| `org N`         | Set the position (instruction index `0..256`) for the next instruction. Default `0`. Rarely needed. |
| `dw N`          | Emit raw 12-bit word `N` (`0x000`–`0xFFF`) as one program instruction. Escape hatch. |

A `const` name must not collide with a mnemonic or a register name.

## 5. Labels and flags

The machine records the current program position into a flag slot with
`1011 AAAA` and jumps to that slot with `1100 AAAA`. 4A turns these slots into
named labels:

- `@name:` defines a label at the current position; it is sugar for
  `flag @name` and emits a `1011` instruction.
- `@name` references a label in `jmp @name`.
- `flag @name` defines a label; `flag N` and `jmp N` address a raw slot.
- The assembler assigns labels to slots `0..14` in order of first definition.
  **Slot 15 is reserved**: on the hardware it is hard-wired to `0` (a bug), so
  jumps to it land on instruction 0. `4a` refuses to use slot 15.
- At most **15 labels** may be defined.
- Forward references are allowed (`jmp` may precede the label's definition).
- Redefining a label is an error.

## 6. Instructions

Bits `[11:8]` of the 12-bit word are the opcode, bits `[7:4]` are operand `A`,
bits `[3:0]` are operand `B` (unused bits are `0`).

| Mnemonic | Operands            | Opcode | Machine operation                                    |
|----------|---------------------|:------:|------------------------------------------------------|
| `nop`    | —                   |  `0000`| No operation.                                        |
| `lda`    | `rN`                |  `0001`| `acc := rN`                                          |
| `sta`    | `rN`                |  `0010`| `rN := acc`                                          |
| `lda`    | `#k`                |  `0011`| `acc := k`                                           |
| `read`   | —                   |  `0100`| `acc := buttons` (bitfield, see §7)                  |
| `inc`    | —                   |  `0101`| `acc := (acc + 1) mod 16`                            |
| `cls`    | —                   |  `0110`| Clear the screen.                                    |
| `shl`    | —                   |  `0111`| `acc := (acc << 1) mod 16`                           |
| `shr`    | —                   |  `1000`| `acc := acc >> 1`                                    |
| `peek`   | `rX, rY`            |  `1001`| `acc := pixel(x = rX, y = rY)`  (0 or 1)             |
| `flip`   | `rX, rY`            |  `1010`| Toggle pixel at `(rX, rY)`.                          |
| `flag`   | `@name` \| `N`      |  `1011`| Record current position as a jump target.            |
| `jmp`    | `@name` \| `N`      |  `1100`| Jump to the flag target.                             |
| `ifeq`   | `rN`                |  `1101`| Execute the *next* instruction iff `rN == acc`; else skip it. |
| `ifgt`   | `rN`                |  `1110`| Execute the *next* instruction iff `rN > acc`.       |
| `iflt`   | `rN`                |  `1111`| Execute the *next* instruction iff `rN < acc`.       |

Per-mnemonic operand arity:

| Mnemonic | A                    | B       |
|----------|----------------------|---------|
| `nop`, `read`, `inc`, `cls`, `shl`, `shr` | — | — |
| `lda`    | `rN` **or** `#k`     | —       |
| `sta`, `ifeq`, `ifgt`, `iflt` | `rN` | — |
| `peek`, `flip` | `rX`           | `rY`    |
| `flag`, `jmp` | `@name` or `N` | —       |

## 7. Semantics

- **Wraparound.** All arithmetic is modulo 16. `inc` on 15 yields 0; `shl` on 8
  yields 0; `shr` on 1 yields 0.
- **Buttons.** `read` loads a bitfield: bit 0 = left, bit 1 = right, bit 2 = up,
  bit 3 = down. It returns 0 when no buttons are held.
- **Coordinates.** `peek`/`flip` take both coordinates from registers
  (`x = rX`, `y = rY`), each `0..15` and mapped directly to the 16×16 screen.
  Register operands are required; constants are rejected for these.
- **Conditional skip.** The `if*` instructions control a single *following*
  instruction: if the condition is false, the next instruction is skipped. The
  idiomatic branch is `ifeq rN` immediately followed by `jmp @target`. Skipping
  works even when the next instruction is a `jmp` or a label definition.
- **Start & padding.** Execution begins at position 0. If a program is shorter
  than 256 instructions, the image is zero-filled (`000` = `nop`).

## 8. Binary output format

The assembled image is **exactly 384 bytes** (256 × 12 bits = 3072 bits), no
header, no footer.

1. Each instruction becomes a 12-bit word:
   `word = (opcode << 8) | (A << 4) | B`.
2. Words are concatenated into one bitstream; word *n* occupies global bits
   `[12n, 12n+12)`.
3. Byte *i* holds global bits `[8i, 8i+8)`; the bit at global position *p* is
   stored at bit position `p - 8i` (LSB-first) of byte *i*.

Consequently byte 0 holds the low 8 bits of instruction 0, byte 1 holds the
high nibble of instruction 0 in its low nibble and the low nibble of
instruction 1 in its high nibble, and so on. **Example:**

```
lda #8          ; word 0x380 (0011 1000 0000)
sta r1          ; word 0x210 (0010 0001 0000)
```

produces bytes `80 03 21` then 0x00 padding to byte 383.

## 9. Full ISA coverage

Every 4B opcode has a 4A form, so no instruction is unreachable:

| 4B opcode   | 4A form            |
|:-----------:|--------------------|
| `0000`      | `nop`              |
| `0001`      | `lda rN`           |
| `0010`      | `sta rN`           |
| `0011`      | `lda #k`           |
| `0100`      | `read`             |
| `0101`      | `inc`              |
| `0110`      | `cls`              |
| `0111`      | `shl`              |
| `1000`      | `shr`              |
| `1001`      | `peek rX, rY`      |
| `1010`      | `flip rX, rY`      |
| `1011`      | `@name:` / `flag N` |
| `1100`      | `jmp @name` / `jmp N` |
| `1101`      | `ifeq rN`          |
| `1110`      | `ifgt rN`          |
| `1111`      | `iflt rN`          |

## 10. Example: 16-pixel horizontal line

```4b
; draw a horizontal line across the middle of the screen
lda #8
sta r1          ; y = 8
lda #0
sta r2          ; x = 0
sta r3          ; r3 = 0 (loop sentinel)

@draw:
lda r2
sta r0          ; x-coord = r2
flip r0, r1     ; flip pixel (x, 8)
inc             ; acc = x + 1 (wraps 15 -> 0)
sta r2          ; x = x + 1
iflt r3         ; loop while new x > 0; exit when it wraps to 0
jmp @draw

@halt:
jmp @halt       ; freeze (the classic 4BoD halt idiom)
```

The assembler assigns `@draw` → slot 0 and `@halt` → slot 1. The 15 emitted
words are `0x380 0x210 0x300 0x220 0x230 0xB00 0x120 0x200 0xA01 0x500 0x220
0xF30 0xC00 0xB10 0xC10`, packing to:

```
80 03 21 00 03 22 30 02 B0 20 01 20 01 0A 50 20 02 F3 00 0C B1 10 0C
```

…followed by 0x00 padding to byte 383. (Verify this with `4a`, then run it
under the 4b box: it should light the middle row of pixels.)

## 11. Example: button input

```4b
; flip a pixel at (8,8) while the up button is held
const UP    = 4
const EIGHT = 8

lda #8
sta r0          ; x = 8
sta r1          ; y = 8

@loop:
read
shr
shr             ; acc = buttons >> 2 (up button now in bit 0)
shl
shl
shl             ; acc = 8 if up held, else 0
sta r4
lda #8
ifeq r4         ; run the flip only when up is held
flip r0, r1
jmp @loop
```

## 12. Limits and assembly-time errors

| Limit/rule                          | Value          |
|-------------------------------------|----------------|
| Program size                        | ≤ 256 instructions |
| Labels (auto-assigned flag slots)   | ≤ 15 (slots 0–14) |
| Flag slot 15                        | forbidden (hardware bug) |
| Register / immediate / coordinate values | 4-bit (0–15) |
| `dw` word values                    | 12-bit (0–0xFFF) |

Assembly-time errors: undefined label, label redefined, too many labels, use of
flag slot 15, register index > 15, immediate > 15, coordinate operand that is
not a register, program longer than 256 instructions, `org` moving the position
backwards or past 256, unknown mnemonic, wrong operand count/kind, malformed
number, duplicate `const`, and `const` shadowing a mnemonic or register name.

## 13. Files and tooling

- Source files: `.4a`
- Assembled images: `.4b` (raw 384-byte ROM; loaders may name it anything)
- Assembler: `4a` (see `docs/4AD.md`)

## 14. Reserved words

`nop lda sta read inc cls shl shr peek flip flag jmp ifeq ifgt iflt const org
dw` — plus register names `r0`–`r15`. None may be used as `const` names or
label identifiers.
