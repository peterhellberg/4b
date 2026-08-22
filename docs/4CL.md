# 4C Language Specification

*Version 0.1 (draft). Companion to `docs/4BoD.md` and `docs/4AL.md`.*

4C is a small, C-flavored programming language for the 4BoD fantasy console.
A `.4c` source file is compiled by the 4C compiler (`4c`) into the same
384-byte program images that the 4A assembler (`4a`) produces — or, on
request, into readable `.4a` assembly text. 4C has no runtime: every
high-level construct compiles away. Variables become registers, control flow
becomes flag slots and jumps, and arithmetic becomes runs of `inc` and
`shl`/`shr` (plus, where two runtime values meet, small generated loops).

## 1. The 4BoD machine, in one paragraph

- Program memory: 256 instructions, each instruction exactly **12 bits**.
- RAM: 16 registers `r0`–`r15`, each holding one **4-bit** value (a nibble).
- A 4-bit **accumulator** (`acc`).
- Screen: 16×16, 1 bit per pixel (0 = off, 1 = on).
- 16 **flags**: fixed-size jump-target slots, numbered 0–15 (slot 15 is
  hard-wired to 0 on the hardware and unusable; 4C never touches it).
- Four buttons: left, right, up, down.

There is no add or subtract instruction, no indirect jump, and no call or
return. These absences shape the whole language; §7 states exactly what each
construct costs.

## 2. Design rules

1. One type: `u4`, an unsigned 4-bit integer. All arithmetic is modulo 16.
2. No functions. A program is a set of declarations plus one mandatory
   `main` body (the machine cannot call or return).
3. Variables live in registers; temporaries borrow two reserved registers.
4. Control flow is structured (`if`, `while`); each construct spends a
   fixed, documented number of the machine's 15 usable flag slots.
5. Nothing hidden: §7 lists the lowering of every operator, and how many
   flag slots and instructions it costs.

## 3. Lexical rules

- Source is ASCII/UTF-8 text; lines may end with LF or CRLF.
- `//` starts a comment that runs to end of line.
- Identifiers: `[A-Za-z_][A-Za-z0-9_]*`, **case-sensitive** (C convention,
  unlike 4A).
- Numbers: decimal (`10`), hex (`0xA`), binary (`0b1010`). Every literal
  must fit in 4 bits (`0`–`15`).
- Operators and punctuation:

  ```
  (  )  {  }  ;  ,  =  +=  -=  ==  !=  <  >  <=  >=  &&  ||  !  +  -  <<  >>  &
  ```

- Keywords: `u4 fn const if else while break continue true false`.
- Builtin names are reserved identifiers (§8): `cls flip peek buttons
  btn_left btn_right btn_up btn_down halt`.

## 4. Program structure

```ebnf
program    := { global } fndef
global     := vardecl | constdecl
vardecl    := "u4" IDENT [ "=" constexpr ] ";"
constdecl  := "const" IDENT "=" constexpr ";"
fndef      := "fn" "main" "(" ")" block
block      := "{" { stmt } "}"
```

- Variables are declared at top level only. There is one flat scope.
- `const NAME = V;` binds a name to a compile-time value, usable wherever a
  value is expected. Consts occupy no registers and no program space.
- `fn main() { ... }` is the entry point. Execution begins at position 0.
- Global initializers must be constant expressions; they are emitted as
  stores at the very start of the program, in declaration order.
  An uninitialized variable reads as `0`: the VM zero-fills registers on
  reset, before the first instruction executes.

### 4.1 Statements

```ebnf
stmt    := assign ";"
         | "if" "(" cond ")" stmt [ "else" stmt ]
         | "while" "(" cond ")" stmt
         | "break" ";" | "continue" ";"
         | voidcall ";"
         | block
         | ";"
assign  := IDENT ( "=" | "+=" | "-=" ) value
voidcall := "cls" "(" ")"
          | "flip" "(" value "," value ")"
          | "halt" "(" ")"
```

- `break` and `continue` are legal only inside a `while`.
- Expressions that produce a value (`peek`, `buttons`, `btn_*`) may not be
  used as statements; discarding a result is a compile error.
- There is no comma operator, no `++`/`--`, no `for`. `x += 1;` is the idiom.

### 4.2 Values

```ebnf
value   := addexpr
addexpr := bandexpr { ("+" | "-") bandexpr }
bandexpr:= shexpr [ "&" INT ]
shexpr  := unexpr { ("<<" | ">>") unexpr }
unexpr  := [ "-" ] prim
prim    := INT | "true" | "false" | IDENT | retcall | "(" value ")"
retcall := "peek" "(" value "," value ")"
         | "buttons" "(" ")"
         | "btn_left" "(" ")" | "btn_right" "(" ")"
         | "btn_up" "(" ")" | "btn_down" "(" ")"
```

Precedence, loosest to tightest: `+ -`, then `&`, then `<< >>`, then unary
`-`. Parentheses group as usual.

Three restrictions keep codegen within the machine's means (see §7):

- The right operand of `<<` / `>>` must be an integer literal or a bare
  variable — not a larger expression (consts count as literals; they fold
  first).
- The right operand of `&` must be an integer literal whose set bits are
  contiguous (`1`, `2`, `4`, `8`, `3`, `6`, `12`, `7`, `14`, `15`).
- Other bitwise operators (`|`, `^`, `~`) do not exist in v0.1.

### 4.3 Conditions

```ebnf
cond       := condb
condb      := conda { "||" conda }
conda      := condn { "&&" condn }
condn      := [ "!" ] condp
condp      := "(" cond ")" | comparison | value | "true" | "false"
comparison := value relop value
relop      := "==" | "!=" | "<" | ">" | "<=" | ">="
```

- Any `u4` value is a condition: nonzero means true, zero means false.
- `&&` and `||` **short-circuit**: the right operand is not evaluated when
  the left decides the result. `!` negates a condition. All three are legal
  only in condition position; booleans are not ordinary values in v0.1.
- `true` and `false` are the literals `1` and `0`.

## 5. Types and values

Every value is a `u4`: an unsigned nibble in `0..15`. Wraparound is normal
arithmetic, not an error: `15 + 1 == 0`, `0 - 1 == 15`, `8 << 1 == 0`,
`1 >> 1 == 0`. Unary `-x` is `16 - x` modulo 16 (`-0 == 0`).

## 6. Variables and registers

| Range       | Role                                          |
|-------------|-----------------------------------------------|
| `r0`–`r13`  | User variables, assigned in declaration order |
| `r14`–`r15` | Compiler scratch; never visible to 4C programs |
| `acc`       | Expression evaluator working register         |

- At most **14 variables**. A fifteenth declaration is a compile error.
- A variable's register is fixed for the whole program; taking its
  "address" is meaningless and impossible.
- Names must not collide with each other, with keywords, or with builtin
  names. A `const` may not shadow a variable and vice versa.

## 7. Semantics and lowering

This section is normative: a correct `4c` produces exactly these shapes.
Instruction counts assume the general form; constant cases are cheaper.

### 7.1 Arithmetic

| Expression form                  | Lowering                                         | Flag slots |
|----------------------------------|--------------------------------------------------|-----------:|
| `x + k` (literal)                | `k` × `inc`                                      | 0 |
| `x - k` (literal)                | `(16-k)` × `inc` (subtracting wraps to adding)   | 0 |
| `x << k` / `x >> k`              | `k` × `shl` / `shr`                              | 0 |
| `x & m` (mask literal)           | ≤ 6 × `shl`/`shr` (below)                        | 0 |
| `a + b`, `a - b` (both runtime)  | generated add/sub loop                           | 2 |
| `x << v`, `x >> v` (runtime)     | generated shift loop                             | 2 |
| `-v` (runtime)                   | subtract-from-zero loop                          | 2 |

Additive chains (`a + b - c + 1`) flatten into a left-to-right sequence of
these primitives, so arbitrary mixing of constants and variables works.
Modulo-16 addition is associative and commutative, so flattening preserves
results.

**Add loop** (`acc += b`, `b` in a register): a counter counts up to `b`
while the partial sum rides along through scratch; roughly 16 words,
2 flag slots. **Sub loop**: identical skeleton, but each pass decrements
the partial sum — decrementing is 15 × `inc` (mod 16) — so a runtime
subtraction costs about 30 words. Prefer constant operands: `x -= 1;` is
fifteen inline `inc`s and no loop.

**Masks.** `x & m` with set bits spanning `h..l` (lowest set bit `l`,
highest `h`) lowers to `shr × l; shl × l` (clear below `l`), then
`shl × (3-h); shr × (3-h)` (clear above `h`) — at most 6 operations, no
slots. Example: `b & 4` (the up button, bit 2) is
`shr shr shl shl shl shr`; `b & 15` vanishes entirely.

### 7.2 Conditions

Comparisons evaluate the left side into `acc` and the right side into a
register — a variable's own register, or a constant staged into scratch
beforehand — then use `ifeq`/`ifgt`/`iflt` (execute-next-iff). Each operator
maps to one opcode, choosing the polarity that makes "skip the exit jump"
mean "condition true":

| Operator | Opcode            | Operator | Opcode            |
|----------|-------------------|----------|-------------------|
| `==`     | `ifeq`            | `!=`     | `ifeq` (inverted) |
| `<`      | `iflt`            | `>=`     | `iflt` (inverted) |
| `>`      | `ifgt`            | `<=`     | `ifgt` (inverted) |

Inverted forms swap which branch falls through; no extra instructions.

`&&` / `||` compile to short-circuit branch chains that share the enclosing
construct's join slot — they cost no additional flag slots. `!` selects the
opposite row of the table above; also free.

### 7.3 Control flow

The machine's `flag N` records its own position; `jmp N` lands on that flag
instruction, which re-executes harmlessly and falls through. Labels
therefore cost one program word each, inside the flag slot they consume.

| Construct            | Flag slots | Shape                                          |
|----------------------|-----------:|------------------------------------------------|
| `if (c) s`           | 1          | test, `jmp` to join, body, join                |
| `if (c) s else t`    | 2          | test, `jmp` else, body, `jmp` join, else, join |
| `while (c) s`        | 2          | top, test, `jmp` exit, body, `jmp` top, exit   |
| `break` / `continue` | 0          | `jmp` to the enclosing loop's exit/top         |
| `halt()`             | 1          | `flag` immediately followed by `jmp` to it     |

Constant conditions fold before lowering: `if (false)` emits nothing,
`if (true)` emits its body directly, and `while (true)` needs only its top
slot unless the body contains `break` (which would need an exit slot).

Total flag-slot demand is computed at compile time; exceeding **15 slots**
is a compile error (§10). Slots are numbered in a deterministic preorder
walk, so compilation is reproducible.

### 7.4 Builtins

| Builtin                     | Returns | Effect                                       |
|-----------------------------|---------|----------------------------------------------|
| `cls()`                     | —       | Clear the screen.                            |
| `flip(x, y)`                | —       | Toggle the pixel at column `x`, row `y`.     |
| `peek(x, y)`                | `u4`    | Read the pixel at `(x, y)` (0 or 1).         |
| `buttons()`                 | `u4`    | Bitfield: bit 0 left, 1 right, 2 up, 3 down. |
| `btn_left()` … `btn_down()` | `u4`    | 1 while that button is held, else 0.         |
| `halt()`                    | —       | Never returns; spins forever.                |

Coordinates may be arbitrary value expressions; the compiler stages them
through scratch registers, since the machine reads `flip`/`peek`
coordinates from registers. `btn_*` helpers lower to `read` plus shifts
(e.g. `btn_up()` is `read; shr shr shl shl shl shr shr shr` — the idiom
`examples/move.4a` performs by hand).

### 7.5 Evaluation order and expression limits

Operands evaluate left to right, with the running result kept in `acc` and
at most two live temporaries in `r14`/`r15`. Additive chains flatten
(§7.1), so depth is bounded in practice; the restrictions in §4.2 remove
the cases that would need a third temporary. Anything else is a compile
error ("expression too complex"), not silent misbehavior.

## 8. Builtins and reserved names

The reserved identifier set is exactly:

```
cls flip peek buttons btn_left btn_right btn_up btn_down halt
```

plus the keywords from §3. None may be declared as a variable or const.

## 9. Examples

### 9.1 Bouncing pixel

```c
// bounce.4c - a pixel moving diagonally, wrapping at edges
u4 x  = 0;
u4 y  = 8;
u4 dx = 1;
u4 dy = 1;

fn main() {
    while (true) {
        flip(x, y);
        x += dx;
        y += dy;
        if (x == 15) { dx = 15; }   // 15 is -1 mod 16
        if (x == 0)  { dx = 1;  }
        if (y == 15) { dy = 15; }
        if (y == 0)  { dy = 1;  }
    }
}
```

Cost: 5 flag slots (1 for the folded `while (true)`, 1 per `if`) and
comfortably under 256 instructions.

### 9.2 Button steering

```c
// move.4c - steer a pixel with the arrow keys
u4 x = 8;
u4 y = 8;

fn main() {
    while (true) {
        cls();
        flip(x, y);
        if (btn_left())  { x -= 1; }
        if (btn_right()) { x += 1; }
        if (btn_up())    { y -= 1; }
        if (btn_down())  { y += 1; }
    }
}
```

Compare `examples/move.4a`, which expresses the same program in raw
assembly with hand-maintained flag slots and handler stubs.

### 9.3 Raw button field

```c
// updown.4c - flip a pixel while the up button is held
const UP = 4;
u4 px = 8;
u4 py = 8;
u4 b;

fn main() {
    b = buttons();
    if ((b & UP) != 0) {
        flip(px, py);
    }
    halt();
}
```

Cost: 2 flag slots (one for the `if`, one for `halt`). Note that `UP` is a
const, so `(b & UP)` satisfies the mask rule after folding.

## 10. Limits and compile-time errors

| Limit/rule                            | Value                   |
|---------------------------------------|-------------------------|
| Program size                          | ≤ 256 instructions      |
| Variables                             | ≤ 14 (registers r0–r13) |
| Flag slots (loops, branches, dynamic ops, `halt`) | ≤ 15 total  |
| Literals                              | 4-bit (0–15)            |
| `&` mask literals                     | contiguous set bits     |
| Shift right-hand side                 | literal or bare variable |

Compile-time errors: malformed or oversized number; unknown identifier;
duplicate variable or const; keyword or builtin used as a name; missing
`fn main`; assignment to a non-variable; wrong builtin arity; `break` /
`continue` outside a loop; non-constant global initializer; non-contiguous
or non-literal `&` mask; complex shift distance; discarded builtin result;
more than 14 variables; flag-slot exhaustion (with a per-construct tally);
program exceeding 256 instructions.

## 11. Files and tooling

- Source files: `.4c`
- Compiled images: `.4b` (raw 384-byte ROM, format identical to 4A output,
  see `docs/4AL.md` §8)
- Assembly dumps: `.4a` text, producible with `4c --emit-asm`, suitable for
  inspection or reassembly by `4a`
- Compiler: `4c` (see `docs/4CD.md`)
