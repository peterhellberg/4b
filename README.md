# 4B

A tiny fantasy console with a 16×16 1-bit screen, 16 nibble-wide registers,
one accumulator, and 256 twelve-bit instructions — assembled with `4a` and
run with `4b`.
See `docs/4AL.md` for the assembly language, `docs/4AD.md` for the assembler
design notes, and `docs/4BoD.md` for the original 4BoD specification.

> [!NOTE]
> 4B is based on the 4BoD specification, but this is not the official 4BoD
> project — it is an independent reimplementation. 4BoD (4 Bits of DOOM) was
> created by puarsliburf games for the 2017 FC Dev jam; see `docs/4BoD.md`
> for the original description.

## Components

- **`4a`** — the assembler, written in Zig (`src/main.zig`,
  `src/compiler.zig`). It assembles `.4a` source into a 384-byte ROM image
  (`.4b`): 256 little-endian 12-bit words, padded with zeroes.
- **`4b`** — the console, a C program (`src/console.c`) using
  [raylib](https://www.raylib.com) for windowing and input. Both the VM
  (`src/vm.zig`) and the assembler (`src/asm.zig`, a C-ABI shim over
  `src/compiler.zig`) are compiled into static libraries that the console links
  against, so a `.4a` source file can be assembled at startup.

## Building

Everything is built with [Zig](https://ziglang.org) (0.17.0-dev); no separate
C build system is needed. raylib is fetched automatically via the Zig package
manager and built from source.

```
zig build                # build both binaries into zig-out/bin/
zig build test           # run assembler and VM unit tests
zig build examples       # assemble all example programs to examples/*.4b
zig build asm -- <args>       # run 4a directly
zig build run -- <args>       # run the 4b console directly
```

Standard Zig flags apply, e.g. `-Doptimize=ReleaseFast` or
`-Dtarget=x86_64-linux-gnu`.

## Assembler usage

```
4a [options] <input.4a>

Options:
  -o, --output <file>  output path (default: <input stem>.4b)
  -h, --help           print usage and exit
```

The `-o` prefix form (`-ofile`) also works. On error, diagnostics with file
position are printed and nothing is written.

## Console usage

```
4b [flags] <rom.4b | source.4a>

  -s, --scale N       pixel scale (default 32)
  -n, --speed  N      instructions per frame (default 8)
  -p, --palette NAME  use a named palette
  -f, --fg  COLOR     foreground color as R,G,B or hex (default d3c9a1)
  -b, --bg  COLOR     background color as R,G,B or hex (default 323c39)
```

A file ending in `.4a` is treated as source and assembled at startup;
anything else is loaded as a raw ROM image.

`-p` without a name lists the available palettes:
`1bit-monitor-glow`, `obra-dinn-ibm-8503`, `pastelito2`, `casio-basic`,
`note-2c`, `ibm-51`, `gato-roboto-starboard`, `paper-palette`.

While running:

| Key        | Action                                             |
| ---------- | -------------------------------------------------- |
| Arrow keys | held-button state readable with `read`             |
| `F`        | toggle fullscreen (aspect kept, scaled to fit height) |
| `R`        | restart the ROM                                    |

The window title shows the ROM name.

## Examples

| Program         | Description                                    |
| --------------- | ---------------------------------------------- |
| `examples/hello.4a`   | simplest possible program: an empty halt loop |
| `examples/line.4a`    | horizontal line across the middle             |
| `examples/fill.4a`    | fills the screen, then halts                  |
| `examples/bounce.4a`  | pixel moving diagonally, wrapping at edges    |
| `examples/move.4a`    | steer a single pixel with the arrow keys      |

Assemble and run one manually:

```
zig-out/bin/4a examples/bounce.4a
zig-out/bin/4b examples/bounce.4b
```

or run the source directly — the console assembles it on startup:

```
zig-out/bin/4b examples/bounce.4a
```

or let the build system do both:

```
zig build examples && zig build run -- examples/bounce.4b
```

## How the pieces fit together

The console executable is C, but everything that matters lives in Zig.
`src/vm.zig` exposes the VM state as an `extern struct` whose layout mirrors
the `VM4BoD` struct in `src/console.c` byte for byte — program at offset 0,
registers at 512, screen at 529, flag table at 786 — and exports `vm_init`,
`vm_tick` and `vm_load_rom` with C linkage. A unit test pins these offsets so
the two sides cannot drift apart. The same `vm.zig` module is reused verbatim
for the native test suite, which exercises every opcode against the
specification in `docs/4BoD.md` and `docs/4AL.md`. The assembler is embedded
the same way: `src/asm.zig` wraps the assembler behind a single C-ABI entry
point (`bc_compile`) that returns the 384-byte image and diagnostics.
