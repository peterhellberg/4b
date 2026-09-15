#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "raylib.h"

#define SCREEN_W 16
#define SCREEN_H 16
#define ROM_SIZE 384
#define DEFAULT_SCALE 32
#define MIN_SCALE 8
#define MAX_SCALE 64
#define DEFAULT_SPEED 8

typedef struct {
  const char *name;
  Color bg;
  Color fg;
} Palette;

static const Palette PALETTES[] = {
    {"1bit-monitor-glow", {0x22, 0x23, 0x23, 255}, {0xf0, 0xf6, 0xf0, 255}},
    {"obra-dinn-ibm-8503", {0x2e, 0x30, 0x37, 255}, {0xeb, 0xe5, 0xce, 255}},
    {"pastelito2", {0x4b, 0x47, 0x5c, 255}, {0xd7, 0xde, 0xdc, 255}},
    {"casio-basic", {0x00, 0x00, 0x00, 255}, {0x83, 0xb0, 0x7e, 255}},
    {"note-2c", {0x22, 0x2a, 0x3d, 255}, {0xed, 0xf2, 0xe2, 255}},
    {"ibm-51", {0x32, 0x3c, 0x39, 255}, {0xd3, 0xc9, 0xa1, 255}},
    {"gato-roboto-starboard", {0x0a, 0x2e, 0x44, 255}, {0xfc, 0xff, 0xcc, 255}},
    {"paper-palette", {0x3e, 0x3e, 0x3e, 255}, {0xf6, 0xe7, 0xc1, 255}},
};

static const Palette *find_palette(const char *name) {
  for (size_t i = 0; i < sizeof(PALETTES) / sizeof(PALETTES[0]); i++)
    if (strcmp(PALETTES[i].name, name) == 0)
      return &PALETTES[i];

  return NULL;
}

typedef struct {
  uint16_t program[256];
  uint8_t regs[16];
  uint8_t acc;
  uint8_t screen[256];
  uint8_t flags[16];
  uint8_t pc;
  uint8_t buttons;
} VM;

_Static_assert(sizeof(VM) == 804, "VM layout drifted from src/vm.zig");
_Static_assert(offsetof(VM, program) == 0, "VM.program offset");
_Static_assert(offsetof(VM, regs) == 512, "VM.regs offset");
_Static_assert(offsetof(VM, screen) == 529, "VM.screen offset");
_Static_assert(offsetof(VM, flags) == 785, "VM.flags offset");
_Static_assert(offsetof(VM, pc) == 801, "VM.pc offset");

extern void fourb_vm_init(VM *vm);
extern void fourb_vm_tick(VM *vm);
extern void fourb_vm_load_rom(VM *vm, const uint8_t *rom, size_t len);

/* Embedded 4a assembler (src/assembler.zig): assembles .4a source into a
 * 384-byte image. Returns 0 on success, non-zero with diagnostics in err. */
extern int fourb_assemble(const char *path, const char *src, size_t src_len,
                          uint8_t *out, char *err, size_t err_len);

/* Embedded 4c compiler (src/4c/compiler.zig): compiles .4c source into a
 * 384-byte image. Returns 0 on success, non-zero with diagnostics in err. */
extern int fourb_compile(const char *path, const char *src, size_t src_len,
                         uint8_t *out, char *err, size_t err_len);

static uint8_t *read_file(const char *path, size_t *out_len) {
  FILE *f = fopen(path, "rb");

  if (!f)
    return NULL;

  fseek(f, 0, SEEK_END);

  long n = ftell(f);

  if (n <= 0) {
    fclose(f);
    return NULL;
  }

  fseek(f, 0, SEEK_SET);

  uint8_t *buf = malloc((size_t)n);

  if (!buf || fread(buf, 1, (size_t)n, f) != (size_t)n) {
    free(buf);
    fclose(f);

    return NULL;
  }

  fclose(f);
  *out_len = (size_t)n;

  return buf;
}

static bool parse_color(const char *s, Color *out) {
  const char *p = s;
  if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X'))
    p += 2;

  unsigned long hex;
  char *end;
  hex = strtoul(p, &end, 16);

  if (end != p && *end == '\0' && (size_t)(end - p) == 6 && hex <= 0xFFFFFF) {
    *out = (Color){
        (uint8_t)((hex >> 16) & 0xFF),
        (uint8_t)((hex >> 8) & 0xFF),
        (uint8_t)(hex & 0xFF),
        255,
    };

    return true;
  }

  int r, g, b, n = 0;

  if (sscanf(s, "%d,%d,%d%n", &r, &g, &b, &n) != 3 || s[n] != '\0')
    return false;

  if (r < 0 || r > 255 || g < 0 || g > 255 || b < 0 || b > 255)
    return false;

  *out = (Color){(uint8_t)r, (uint8_t)g, (uint8_t)b, 255};

  return true;
}

static bool ends_with(const char *s, const char *suffix) {
  size_t ls = strlen(s), lx = strlen(suffix);

  return ls >= lx && strcmp(s + ls - lx, suffix) == 0;
}

/* Headless debugging: run N instructions with a fixed button mask, then
 * dump the VM state to stdout. */
static void dump_vm(const VM *vm, long steps, unsigned buttons) {
  printf("after %ld instruction%s (buttons=0x%X = 0b", steps,
          steps == 1 ? "" : "s", buttons);

  for (int bit = 3; bit >= 0; bit--)
    printf("%u", (buttons >> bit) & 1);

  printf(")\n");
  printf("pc=%u acc=%u\n", vm->pc, vm->acc);

  for (int i = 0; i < 4; i++) {
    for (int j = 0; j < 4; j++) {
      int r = i * 4 + j;
      printf("r%-2d=%-2u ", r, vm->regs[r] & 0x0F);
    }
    printf("\n");
  }

  printf("\n");
  printf("flags:");
  for (int i = 0; i < 16; i++)
    printf(" %d=%u", i, vm->flags[i]);
  printf("\n\n");

  printf("screen:\n");
  int lit = 0;

  for (int y = 0; y < SCREEN_H; y++) {
    for (int x = 0; x < SCREEN_W; x++) {
      int on = vm->screen[y * SCREEN_W + x] != 0;
      lit += on;
      printf("%c", on ? '#' : '.');
    }
    printf("\n");
  }

  printf("\n");
  printf("lit=%d/%d\n", lit, SCREEN_W * SCREEN_H);
}

static void trace_tick(const VM *vm, long n) {
  printf("%4ld: pc=%3u acc=%u\n", n, vm->pc, vm->acc);
}

typedef struct {
  const char *rom_path;
  int scale;
  int speed;
  long debug_steps;
  unsigned buttons_mask;
  int trace;
  Color fg;
  Color bg;
  bool help;
} Options;

static void print_usage(void) {
  fprintf(stderr, "Usage: 4b [options] <rom.4b | source.4a | source.4c>\n");
  fprintf(stderr, "\n");
  fprintf(stderr, "Options:\n");
  fprintf(stderr,
          "  -d, --debug N       run N instructions headless, then dump state\n");
  fprintf(stderr,
          "  -B, --buttons M     held-button mask for the debug run\n");
  fprintf(stderr,
          "  -t, --trace         print pc/acc before every tick (with -d)\n");
  fprintf(stderr, "  -s, --scale N       window scale %d-%d (default %d)\n",
          MIN_SCALE, MAX_SCALE, DEFAULT_SCALE);
  fprintf(stderr,
          "  -n, --speed N       instructions per frame (default %d)\n",
          DEFAULT_SPEED);
  fprintf(stderr, "  -p, --palette NAME  use a named palette\n");
  fprintf(stderr, "  -f, --fg COLOR      foreground color as R,G,B or hex "
                  "(default d3c9a1)\n");
  fprintf(stderr, "  -b, --bg COLOR      background color as R,G,B or hex "
                  "(default 323c39)\n");
  fprintf(stderr, "  -h, --help          print usage and exit\n");
  fprintf(stderr, "\nA .4a source file is assembled and a .4c source file"
                  " is compiled at startup.\n");
}

/* Parse argv into opts. Returns 0 to continue, 1 after printing an
 * error, or 2 when the answer is already printed (exit 0). */
static int parse_args(int argc, char **argv, Options *opts) {
  opts->rom_path = NULL;
  opts->scale = DEFAULT_SCALE;
  opts->speed = DEFAULT_SPEED;
  opts->debug_steps = -1;
  opts->buttons_mask = 0;
  opts->trace = 0;
  opts->fg = (Color){0xd3, 0xc9, 0xa1, 255};
  opts->bg = (Color){0x32, 0x3c, 0x39, 255};
  opts->help = false;

  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0)
      opts->help = true;
    else if ((strcmp(argv[i], "-s") == 0 || strcmp(argv[i], "--scale") == 0) &&
             i + 1 < argc)
      opts->scale = atoi(argv[++i]);
    else if ((strcmp(argv[i], "-n") == 0 || strcmp(argv[i], "--speed") == 0) &&
             i + 1 < argc)
      opts->speed = atoi(argv[++i]);
    else if ((strcmp(argv[i], "-d") == 0 ||
              strcmp(argv[i], "--debug") == 0)) {
      if (i + 1 >= argc) {
        fprintf(stderr, "4b: -d/--debug requires a step count\n");

        return 1;
      }

      char *end = NULL;

      opts->debug_steps = strtol(argv[++i], &end, 10);

      if (end == argv[i] || *end != '\0' || opts->debug_steps < 0) {
        fprintf(stderr, "4b: invalid step count: %s\n", argv[i]);

        return 1;
      }
    } else if (strcmp(argv[i], "-t") == 0 || strcmp(argv[i], "--trace") == 0) {
      opts->trace = 1;
    } else if ((strcmp(argv[i], "-B") == 0 ||
                strcmp(argv[i], "--buttons") == 0) &&
               i + 1 < argc)
      opts->buttons_mask = (unsigned)strtoul(argv[++i], NULL, 0) & 0xF;
    else if ((strcmp(argv[i], "-p") == 0 ||
              strcmp(argv[i], "--palette") == 0)) {
      if (i + 1 >= argc || argv[i + 1][0] == '-') {
        fprintf(stderr, "available palettes:\n");

        for (size_t j = 0; j < sizeof(PALETTES) / sizeof(PALETTES[0]); j++)
          fprintf(stderr, "  %s\n", PALETTES[j].name);

        return 2;
      }
      const Palette *p = find_palette(argv[++i]);
      if (!p) {
        fprintf(stderr, "4b: unknown palette: %s\n", argv[i]);
        fprintf(stderr, "available palettes:\n");

        for (size_t j = 0; j < sizeof(PALETTES) / sizeof(PALETTES[0]); j++)
          fprintf(stderr, "  %s\n", PALETTES[j].name);

        return 1;
      }

      opts->fg = p->fg;
      opts->bg = p->bg;
    } else if ((strcmp(argv[i], "-f") == 0 || strcmp(argv[i], "--fg") == 0) &&
               i + 1 < argc) {
      if (!parse_color(argv[++i], &opts->fg)) {
        fprintf(stderr, "4b: invalid color: %s (expected R,G,B or hex)\n",
                argv[i]);

        return 1;
      }
    } else if ((strcmp(argv[i], "-b") == 0 || strcmp(argv[i], "--bg") == 0) &&
               i + 1 < argc) {
      if (!parse_color(argv[++i], &opts->bg)) {
        fprintf(stderr, "4b: invalid color: %s (expected R,G,B or hex)\n",
                argv[i]);

        return 1;
      }
    } else if (argv[i][0] != '-') {
      if (opts->rom_path) {
        fprintf(stderr, "4b: multiple input files\n");
        return 1;
      }
      opts->rom_path = argv[i];
    } else {
      fprintf(stderr, "4b: unknown option: %s\n", argv[i]);
      return 1;
    }
  }

  return 0;
}

/* Load a ROM file, or assemble/compile a source file with the embedded
 * toolchain. On success sets rom, rom_len and heap_rom and returns 0
 * (heap_rom is 1 when rom must be freed by the caller). Prints an
 * error and returns 1 on failure. */
static int load_rom(const char *rom_path, uint8_t *assembled,
                    const uint8_t **rom, size_t *rom_len, int *heap_rom) {
  if (ends_with(rom_path, ".4a") || ends_with(rom_path, ".4c")) {
    /* Source file: assemble/compile with the embedded toolchain. */
    int is_4c = ends_with(rom_path, ".4c");
    size_t src_len;
    char *src = (char *)read_file(rom_path, &src_len);

    if (!src) {
      fprintf(stderr, "4b: cannot read %s\n", rom_path);

      return 1;
    }

    char errs[4096];

    int rc = is_4c ? fourb_compile(rom_path, src, src_len, assembled, errs,
                                   sizeof(errs))
                   : fourb_assemble(rom_path, src, src_len, assembled, errs,
                                    sizeof(errs));

    if (rc != 0) {
      fprintf(stderr, "%s", errs);
      free(src);

      return 1;
    }

    free(src);

    *rom = assembled;
    *rom_len = ROM_SIZE;
    *heap_rom = 0;

    return 0;
  }

  uint8_t *file_rom = read_file(rom_path, rom_len);
  *heap_rom = 1;
  if (!file_rom) {
    fprintf(stderr, "4b: cannot read %s\n", rom_path);

    return 1;
  }

  if (*rom_len != ROM_SIZE) {
    fprintf(stderr, "4b: %s: expected %d bytes, got %zu\n", rom_path,
            ROM_SIZE, *rom_len);
    free(file_rom);

    return 1;
  }

  *rom = file_rom;

  return 0;
}

/* Headless debug run: hold the button mask, tick N times, dump state. */
static int run_headless(VM *vm, const Options *opts) {
  for (long s = 0; s < opts->debug_steps; s++) {
    vm->buttons = (uint8_t)opts->buttons_mask;

    if (opts->trace)
      trace_tick(vm, s);

    fourb_vm_tick(vm);
  }

  dump_vm(vm, opts->debug_steps, opts->buttons_mask);

  return 0;
}

static int run_gui(VM *vm, const char *rom_path, const uint8_t *rom,
                   size_t rom_len, const Options *opts) {
  SetTraceLogLevel(LOG_ERROR);

  const char *base = strrchr(rom_path, '/');
  const char *sep = strrchr(rom_path, '\\');

  if (sep && (base == NULL || sep > base))
    base = sep;

  base = base ? base + 1 : rom_path;
  char stem[256];

  snprintf(stem, sizeof(stem), "%s", base);

  char *dot = strstr(stem, ".4b.rom");

  if (dot == NULL)
    dot = strrchr(stem, '.');

  if (dot != NULL)
    *dot = '\0';

  char title[268];
  snprintf(title, sizeof(title), "4b: %s", stem);

  InitWindow(SCREEN_W * opts->scale, SCREEN_H * opts->scale, title);
  SetTargetFPS(60);

  while (!WindowShouldClose()) {
    if (IsKeyPressed(KEY_F)) {
      ToggleFullscreen();

      if (IsWindowFullscreen())
        SetWindowSize(GetMonitorWidth(GetCurrentMonitor()),
                      GetMonitorHeight(GetCurrentMonitor()));
      else
        SetWindowSize(SCREEN_W * opts->scale, SCREEN_H * opts->scale);
    }

    if (IsKeyPressed(KEY_R))
      fourb_vm_load_rom(vm, rom, rom_len);

    uint8_t btns = 0;

    if (IsKeyDown(KEY_LEFT))
      btns |= 1;
    if (IsKeyDown(KEY_RIGHT))
      btns |= 2;
    if (IsKeyDown(KEY_UP))
      btns |= 4;
    if (IsKeyDown(KEY_DOWN))
      btns |= 8;

    vm->buttons = btns;

    for (int i = 0; i < opts->speed; i++)
      fourb_vm_tick(vm);

    int px = GetScreenHeight() / SCREEN_H;
    int ox = (GetScreenWidth() - SCREEN_W * px) / 2;
    int oy = (GetScreenHeight() - SCREEN_H * px) / 2;

    BeginDrawing();
    ClearBackground(opts->bg);

    for (int y = 0; y < SCREEN_H; y++)
      for (int x = 0; x < SCREEN_W; x++)
        if (vm->screen[y * SCREEN_W + x])
          DrawRectangle(ox + x * px, oy + y * px, px, px, opts->fg);

    EndDrawing();
  }

  CloseWindow();

  return 0;
}

int main(int argc, char **argv) {
  Options opts;

  int arg_rc = parse_args(argc, argv, &opts);
  if (arg_rc == 2)
    return 0;
  if (arg_rc != 0)
    return arg_rc;

  if (opts.help || !opts.rom_path) {
    print_usage();

    return opts.help ? 0 : 1;
  }

  if (opts.scale < MIN_SCALE)
    opts.scale = MIN_SCALE;

  if (opts.scale > MAX_SCALE)
    opts.scale = MAX_SCALE;

  if (opts.speed < 1)
    opts.speed = 1;

  static uint8_t assembled[ROM_SIZE];
  size_t rom_len;
  const uint8_t *rom;
  int heap_rom = 0;

  if (load_rom(opts.rom_path, assembled, &rom, &rom_len, &heap_rom) != 0)
    return 1;

  if (opts.trace && opts.debug_steps < 0) {
    fprintf(stderr, "4b: -t/--trace requires -d/--debug N\n");
    if (heap_rom)
      free((void *)rom);

    return 1;
  }

  VM vm;

  fourb_vm_load_rom(&vm, rom, rom_len);

  int rc;
  if (opts.debug_steps >= 0)
    rc = run_headless(&vm, &opts);
  else
    rc = run_gui(&vm, opts.rom_path, rom, rom_len, &opts);

  if (heap_rom)
    free((void *)rom);

  return rc;
}
