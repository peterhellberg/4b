# 4B

A tiny fantasy console with a 16×16 1-bit screen, 16 nibble-wide registers,
one accumulator, and 256 twelve-bit instructions — assembled with `4a`,
compiled from 4C source with `4c`, and run with `4b`.

See `docs/4AL.md` for the assembly language, `docs/4AD.md` for the assembler
design notes, `docs/4CL.md` for the 4C language, `docs/4CD.md` for the
compiler design notes, and `docs/4BoD.md` for the original 4BoD
specification.

> [!NOTE]
> 4B is based on the 4BoD specification, but this is not the official 4BoD
> project — it is an independent reimplementation. 4BoD (4 Bits of DOOM) was
> created by puarsliburf games for the 2017 FC Dev jam; see `docs/4BoD.md`
> for the original description.

## Components

- **`4a`** — the assembler, written in Zig (`src/4a.zig`,
  `src/assembler.zig`). It assembles `.4a` source into a 384-byte ROM image
  (`.4b`): 256 little-endian 12-bit words, padded with zeroes.
- **`4b`** — the box, a C program (`src/4b.c`) using
  [raylib](https://www.raylib.com) for windowing and input. The VM
  (`src/vm.zig`), the assembler (`src/assembler.zig`) and the compiler
  (`src/4c/compiler.zig`) are compiled into static libraries that
  the box links against, so `.4a` source can be assembled and `.4c`
  source compiled at startup.
- **`4c`** — the 4C compiler (`src/4c.zig`, `src/4c/`). It compiles
  `.4c` source into the same 384-byte ROM image, or into equivalent `.4a`
  assembly text with `-S`.

## Building

Everything is built with [Zig](https://ziglang.org) (0.17.0-dev); no separate
C build system is needed. raylib is fetched automatically via the Zig package
manager and built from source.

### Getting Zig

The pinned compiler version is `0.17.0-dev.387+31f157d80`. It is no longer
available from the main Zig download server; download it from the hexops
community mirror instead:

| Platform        | Download                                                                                                                        |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| Linux x86_64    | [zig-x86_64-linux-0.17.0-dev.387+31f157d80.tar.xz](https://pkg.hexops.org/zig/zig-x86_64-linux-0.17.0-dev.387+31f157d80.tar.xz) |
| Linux aarch64   | [zig-aarch64-linux-0.17.0-dev.387+31f157d80.tar.xz](https://pkg.hexops.org/zig/zig-aarch64-linux-0.17.0-dev.387+31f157d80.tar.xz) |
| macOS x86_64    | [zig-x86_64-macos-0.17.0-dev.387+31f157d80.tar.xz](https://pkg.hexops.org/zig/zig-x86_64-macos-0.17.0-dev.387+31f157d80.tar.xz) |
| macOS aarch64   | [zig-aarch64-macos-0.17.0-dev.387+31f157d80.tar.xz](https://pkg.hexops.org/zig/zig-aarch64-macos-0.17.0-dev.387+31f157d80.tar.xz) |
| Windows x86_64  | [zig-x86_64-windows-0.17.0-dev.387+31f157d80.zip](https://pkg.hexops.org/zig/zig-x86_64-windows-0.17.0-dev.387+31f157d80.zip) |
| Windows aarch64 | [zig-aarch64-windows-0.17.0-dev.387+31f157d80.zip](https://pkg.hexops.org/zig/zig-aarch64-windows-0.17.0-dev.387+31f157d80.zip) |

Unpack the archive and put the `zig` binary on your `PATH`, e.g. on
Linux/macOS:

```
tar -xf zig-*-0.17.0-dev.387+31f157d80.tar.xz -C "$HOME/.local/"
export PATH="$HOME/.local/zig-x86_64-linux-0.17.0-dev.387+31f157d80:$PATH"
```

On Windows, unzip the archive and add the extracted folder to `PATH`.

Each download has a companion `.minisig` signature which can be verified
against the Zig Software Foundation public key
(`RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U`, see
<https://ziglang.org/download>):

```
curl -sSO https://pkg.hexops.org/zig/zig-x86_64-macos-0.17.0-dev.387+31f157d80.tar.xz.minisig
minisign -Vm zig-x86_64-macos-0.17.0-dev.387+31f157d80.tar.xz \
    -P RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U
```

### Commands

```
zig build                # build all three binaries into zig-out/bin/
zig build test           # run assembler, compiler and VM unit tests
zig build examples       # assemble/compile all example programs to examples/*.4b
zig build 4a -- <args>        # assemble with 4a
zig build 4c -- <args>        # compile with 4c
zig build 4b -- <args>        # run in the box
zig build assemble -- <args>  # alias for 4a
zig build compile -- <args>   # alias for 4c
zig build run -- <args>       # alias for 4b
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

## Compiler usage

```
4c [options] <input.4c>

Options:
  -o, --output <file>   output ROM path (default: <input stem>.4b)
  -S, --emit-asm <file> write text assembly too ('-' = stdout)
  -h, --help            print usage and exit
```

See `docs/4CL.md` for the 4C language itself.

## Console usage

```
4b [flags] <rom.4b | source.4a | source.4c>

  -s, --scale N       pixel scale (default 32)
  -n, --speed  N      instructions per frame (default 8)
  -p, --palette NAME  use a named palette
  -f, --fg  COLOR     foreground color as R,G,B or hex (default d3c9a1)
  -b, --bg  COLOR     background color as R,G,B or hex (default 323c39)
```

A file ending in `.4a` is treated as source and assembled at startup, a file
ending in `.4c` is compiled at startup; anything else is loaded as a raw ROM
image.

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

| Program                | Description                                    |
| ---------------------- | ---------------------------------------------- |
| `examples/hello.4a`    | simplest possible program: an empty halt loop |
| `examples/line.4a`     | horizontal line across the middle             |
| `examples/fill.4a`     | fills the screen, then halts                  |
| `examples/bounce.4a`   | pixel moving diagonally, wrapping at edges    |
| `examples/move.4a`     | steer a single pixel with the arrow keys      |

`bounce` and `move` also exist as 4C source (`examples/bounce.4c`,
`examples/move.4c`), plus `dpad.4c` — one blinking pixel per held direction button — and `hello.4c`, `line.4c` and `fill.4c` as direct translations of
their `.4a` counterparts.

Assemble and run one manually:

```
zig-out/bin/4a examples/bounce.4a
zig-out/bin/4b examples/bounce.4b
```

or run the source directly — the box assembles it on startup:

```
zig-out/bin/4b examples/bounce.4a
```

or let the build system do both:

```
zig build examples && zig build run -- examples/bounce.4b
```

## How the pieces fit together

The box executable is C (`src/4b.c`, raylib for windowing and
input), but everything that matters lives in Zig, linked in as static
libraries:

- **One VM, two frontends** — `src/vm.zig` is compiled both into the box
  and into the native test suite, which exercises every opcode against the
  specification in `docs/4BoD.md` and `docs/4AL.md`.
- **A pinned ABI** — the VM state is an `extern struct` whose layout mirrors
  the `VM` struct in `4b.c` byte for byte — program at offset 0,
  registers at 512, screen at 529, flag table at 786 — exposed through
  `fourb_vm_init`, `fourb_vm_tick` and
  `fourb_vm_load_rom`. A unit test pins these offsets so
  the two sides cannot drift apart.
- **An embedded assembler** — `src/assembler.zig` exposes a single C-ABI
  entry point (`fourb_assemble`) that returns the 384-byte image
  and diagnostics, letting the box assemble `.4a` sources at startup.
- **An embedded compiler** — `src/4c/compiler.zig` does the same for the 4C
  compiler (`fourb_compile`), letting the box compile `.4c` sources at
  startup.
