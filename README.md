<div align="center">

# 4B

[![CI](https://github.com/peterhellberg/4b/actions/workflows/ci.yml/badge.svg)](https://github.com/peterhellberg/4b/actions/workflows/ci.yml)

**A tiny fantasy console** with a 16×16 1-bit screen, 16 nibble-wide
registers, one accumulator, and 256 twelve-bit instructions.

Assemble with `4a` · Run with `4b` · Compile with `4c` · Disassemble with `4d`

</div>

---

> [!NOTE]
> 4B is based on the 4BoD specification, but this is not the official 4BoD
> project — it is an independent reimplementation. 4BoD (4 Bits of DOOM) was
> created by [puarsliburf games](https://puarsliburf.itch.io/4bod-fantaly-console) for the 2017
> FC Dev jam; see [`docs/4BoD.md`](docs/4BoD.md) for the original
> description.

## Components

| Binary | What it is | Sources |
| ------ | ---------- | ------- |
| **`4a`** | The assembler. Turns `.4a` source into a 384-byte ROM image (`.4b`): 256 little-endian 12-bit words, padded with zeroes. | `src/4a.zig`, `src/assembler.zig` |
| **`4b`** | The box: a C program using [raylib](https://www.raylib.com) for windowing and input. Assembles `.4a` and compiles `.4c` sources at startup through embedded toolchain libraries. | `src/4b.c`, `src/vm.zig`, `src/assembler.zig`, `src/4c/compiler.zig` |
| **`4c`** | The compiler for 4C, a small C-flavored language. Compiles `.4c` source into the same ROM image — or into equivalent `.4a` assembly text with `-S`. | `src/4c.zig`, `src/4c/` |
| **`4d`** | The disassembler. Turns a 384-byte ROM back into `.4a` source that reassembles byte-identically. | `src/4d.zig`, `src/disassembler.zig` |

## Quick start

Build the toolchain and every example ROM:

```console
$ zig build examples
```

Then run one in the box:

```console
$ zig build run -- examples/diag.4b
```

A window opens showing a diagonal line wrapping around the screen. Hold an
arrow key in `move.4b` to steer its pixel, or try `dpad.4b` — one blinking
pixel per held direction button. Every example lives in
[`examples/`](examples/), as both `.4a` assembly and `.4c` source.

No need to build ROMs by hand: point the box at a source file and it is
compiled on startup.

```console
$ zig build run -- examples/move.4c
```

## Building

Everything is built with [Zig](https://ziglang.org); no separate C build
system is needed. Install Zig 0.17.1 or newer from
<https://ziglang.org/download>. raylib is fetched automatically via the Zig
package manager and built from source.

### Commands

```console
zig build                      # build all four binaries into zig-out/bin/
zig build test                 # run all unit tests

zig build 4a -- <args>         # assemble with 4a
zig build 4c -- <args>         # compile with 4c
zig build 4b -- <args>         # run with 4b
zig build 4d -- <args>         # disassemble with 4d

zig build assemble -- <args>   # alias for 4a
zig build compile -- <args>    # alias for 4c
zig build run -- <args>        # alias for 4b
zig build disassemble -- <args> # alias for 4d

zig build examples             # build all example programs to examples/*.4b
zig build dis-roundtrip        # 4b -> 4d -> 4a -> compare, for every example
```

Standard Zig flags apply, e.g. `-Doptimize=ReleaseFast` or
`-Dtarget=x86_64-linux-gnu`.

## Tool usage

### `4a` — assembler

```text
Usage: 4a [options] <input.4a>

Options:
  -o, --output <file>   output ROM path (default: <input stem>.4b)
  -h, --help            print usage and exit
```

The `-o` prefix form (`-ofile`) also works. On error, diagnostics with file
position are printed and nothing is written.

### `4c` — compiler

```text
Usage: 4c [options] <input.4c>

Options:
  -o, --output <file>   output ROM path (default: <input stem>.4b)
  -S, --emit-asm <file> write text assembly too ('-' = stdout)
  -h, --help            print usage and exit
```

The language itself is specified in [`docs/4CL.md`](docs/4CL.md).

### `4d` — disassembler

```text
Usage: 4d [options] <input.4b>

Options:
  -o, --output <file>   output assembly path (default: <input stem>.4a, or stdout if it exists)
                        use '-' to write to stdout explicitly
  -l, --labels          emit labels for branch targets (default: on)
  -L, --no-labels       emit raw flag slots instead of labels
  -s, --semantic-labels infer semantic names (default; alias: --heuristic-labels)
  -p, --positional-labels emit @Lxx names instead of inferred names
  -h, --help            print usage and exit
```

The output is clean, valid 4A and reassembles to a byte-identical ROM. Labels
use inferred names by default: control-flow roles (`@halt`, `@loop`, `@done`,
`@target`, `@restart`) and block operations (`@frame`, `@draw`, `@clear`,
`@input`, `@inc_rN`, `@dec_rN`). These are hints from the code, not original
source identifiers. Use `-p` for positional `@L00`, `@L01`, … names. Trailing
zero padding is omitted.
If the inferred `<input stem>.4a` already exists, the assembly is printed to
stdout instead of overwriting it; use `-o` to choose a destination explicitly.
The design and round-trip guarantees are described in
[`docs/4DD.md`](docs/4DD.md).

### `4b` — box

```text
Usage: 4b [options] <rom.4b | source.4a | source.4c>

Options:
  -s, --scale N       window scale (default 32)
  -n, --speed N       instructions per frame (default 8)
  -p, --palette NAME  use a named palette
  -f, --fg COLOR      foreground color as R,G,B or hex (default d3c9a1)
  -b, --bg COLOR      background color as R,G,B or hex (default 323c39)
  -d, --debug N       run N instructions headless, then dump state
  -B, --buttons M     held-button mask for the debug run
  -t, --trace         print pc/acc before every tick (with -d)
```

A file ending in `.4a` is treated as source and assembled at startup, a file
ending in `.4c` is compiled at startup; anything else is loaded as a raw ROM
image.

`-p` without a name lists the available palettes:
`1bit-monitor-glow`, `obra-dinn-ibm-8503`, `pastelito2`, `casio-basic`,
`note-2c`, `ibm-51`, `gato-roboto-starboard`, `paper-palette`.

#### Debug mode

```console
$ zig-out/bin/4b -d 2550 examples/fill.4c
after 2550 instructions (buttons=0x0 = 0b0000)

pc=11 acc=163
r0 =163 r1 =10 r2 =0  r3 =0
...

screen:
################
################
################
################
################
################
################
################
################
################
###.............
................
................
................
................
................

lit=163/256
```

Runs the ROM headless for exactly N instructions — no window — then prints
the machine state: program counter, accumulator, all sixteen registers,
the recorded flag slots and the screen as a 16×16 grid with a lit-pixel
count. `-B` holds a fixed button mask during the run (`-B 2` simulates
holding right), and `-t` prints one line per tick before it executes.

#### While running

| Key        | Action                                                |
| ---------- | ----------------------------------------------------- |
| Arrow keys | held-button state readable with `read`                |
| `F`        | toggle fullscreen (aspect kept, scaled to fit height) |
| `R`        | restart the ROM                                       |

The window title shows the ROM name.

## Examples

| Program               | Description                                   |
| --------------------- | --------------------------------------------- |
| `examples/halt.4a`    | simplest possible program: an empty halt loop |
| `examples/line.4a`    | horizontal line across the middle             |
| `examples/fill.4a`    | fills the screen                              |
| `examples/diag.4a`    | diagonal line moving down-right, wrapping     |
| `examples/move.4a`    | steer a single pixel with the arrow keys      |
| `examples/dpad.4a`    | one lit pixel per held direction button       |

Every program above also exists as 4C source (`examples/*.4c`)
— same behavior, compiled by `4c`.

The checked-in `examples/<name>.4b` ROMs are not all assembled from the
matching `.4a` source; some are compiled from `.4c`. Cross-built variants use
`-4a` or `-4c` suffixes. For example, `examples/diag.4b` is the 4C build, while
`examples/diag-4a.4b` is assembled from `examples/diag.4a`. Avoid relying on
`4a`'s default output name here, since it would overwrite the canonical ROM.

Ways to run the 4A version:

```console
zig-out/bin/4b examples/diag-4a.4b      # checked-in 4A-built ROM
zig-out/bin/4b examples/diag.4a         # the box assembles it at startup
zig-out/bin/4a examples/diag.4a -o /tmp/diag.4b
zig-out/bin/4b /tmp/diag.4b             # assemble explicitly
```

To run the canonical checked-in ROM (compiled from `diag.4c`):

```console
zig build examples && zig build run -- examples/diag.4b
```

## How the pieces fit together

The box executable is C (`src/4b.c`, raylib for windowing and input),
but everything that matters lives in Zig, linked in as static
libraries:

- **One VM, two frontends** — `src/vm.zig` is compiled both into the box
  and into the native test suite, which exercises every opcode against the
  specification in `docs/4BoD.md` and `docs/4AL.md`.
- **A pinned ABI** — the VM state is an `extern struct` whose layout mirrors
  the `VM` struct in `4b.c` byte for byte — program at offset 0,
  registers at 512, screen at 529, flag table at 786 — exposed through
  `fourb_vm_init`, `fourb_vm_tick` and `fourb_vm_load_rom`. A unit test
  pins these offsets so the two sides cannot drift apart.
- **An embedded assembler** — `src/assembler.zig` exposes a single C-ABI
  entry point (`fourb_assemble`) that returns the 384-byte image and
  diagnostics, letting the box assemble `.4a` sources at startup.
- **A matching disassembler** — `src/disassembler.zig` reuses `isa.decode`
  and `rom.unpack` to turn ROMs back into 4A, with a round-trip suite that
  keeps the two tools in lockstep (`zig build dis-roundtrip`).
- **An embedded compiler** — `src/4c/compiler.zig` does the same for the
  4C compiler (`fourb_compile`), letting the box compile `.4c` sources at
  startup.

## Documentation

| Document                          | Contents                                    |
| --------------------------------- | ------------------------------------------- |
| [`docs/4BoD.md`](docs/4BoD.md)    | the original 4BoD specification             |
| [`docs/4AL.md`](docs/4AL.md)      | 4A assembly language                        |
| [`docs/4AD.md`](docs/4AD.md)      | assembler design notes                      |
| [`docs/4DD.md`](docs/4DD.md)      | disassembler design notes                   |
| [`docs/4CL.md`](docs/4CL.md)      | 4C language                                 |
| [`docs/4CD.md`](docs/4CD.md)      | compiler design notes                       |

## License

[MIT](LICENSE)
