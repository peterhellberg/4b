#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include "raylib.h"

#define SCREEN_W 16
#define SCREEN_H 16
#define ROM_SIZE  384
#define DEFAULT_SCALE 32
#define DEFAULT_SPEED 8

typedef struct {
    const char *name;
    Color bg;
    Color fg;
} Palette;

static const Palette PALETTES[] = {
    {"1bit-monitor-glow",      {0x22, 0x23, 0x23, 255}, {0xf0, 0xf6, 0xf0, 255}},
    {"obra-dinn-ibm-8503",     {0x2e, 0x30, 0x37, 255}, {0xeb, 0xe5, 0xce, 255}},
    {"pastelito2",             {0x4b, 0x47, 0x5c, 255}, {0xd7, 0xde, 0xdc, 255}},
    {"casio-basic",            {0x00, 0x00, 0x00, 255}, {0x83, 0xb0, 0x7e, 255}},
    {"note-2c",                {0x22, 0x2a, 0x3d, 255}, {0xed, 0xf2, 0xe2, 255}},
    {"ibm-51",                 {0x32, 0x3c, 0x39, 255}, {0xd3, 0xc9, 0xa1, 255}},
    {"gato-roboto-starboard",  {0x0a, 0x2e, 0x44, 255}, {0xfc, 0xff, 0xcc, 255}},
    {"paper-palette",          {0x3e, 0x3e, 0x3e, 255}, {0xf6, 0xe7, 0xc1, 255}},
};

static const Palette *find_palette(const char *name) {
    for (size_t i = 0; i < sizeof(PALETTES) / sizeof(PALETTES[0]); i++)
        if (strcmp(PALETTES[i].name, name) == 0)
            return &PALETTES[i];
    return NULL;
}

typedef struct {
    uint16_t program[256];
    uint8_t  regs[16];
    uint8_t  acc;
    uint8_t  screen[256];
    uint16_t flags[16];
    uint8_t  pc;
    uint8_t  buttons;
} VM;

extern void vm_init(VM *vm);
extern void vm_tick(VM *vm);
extern void vm_load_rom(VM *vm, const uint8_t *data, size_t len);

/* Embedded 4a assembler (src/asm.zig): assembles .4a source into a
 * 384-byte image. Returns 0 on success, non-zero with diagnostics in err. */
extern int bc_compile(const char *path, const char *src, size_t src_len,
                      uint8_t *out, char *err, size_t err_len);

static uint8_t *read_file(const char *path, size_t *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    if (n <= 0) { fclose(f); return NULL; }
    fseek(f, 0, SEEK_SET);
    uint8_t *buf = malloc((size_t)n);
    if (!buf || fread(buf, 1, (size_t)n, f) != (size_t)n) {
        free(buf); fclose(f); return NULL;
    }
    fclose(f);
    *out_len = (size_t)n;
    return buf;
}

static bool parse_color(const char *s, Color *out) {
    const char *p = s;
    if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) p += 2;
    unsigned long hex;
    char *end;
    hex = strtoul(p, &end, 16);
    if (end != p && *end == '\0' && hex <= 0xFFFFFF) {
        *out = (Color){
            (uint8_t)((hex >> 16) & 0xFF),
            (uint8_t)((hex >> 8) & 0xFF),
            (uint8_t)(hex & 0xFF),
            255,
        };
        return true;
    }
    int r, g, b;
    if (sscanf(s, "%d,%d,%d", &r, &g, &b) != 3) return false;
    if (r < 0 || r > 255 || g < 0 || g > 255 || b < 0 || b > 255) return false;
    *out = (Color){(uint8_t)r, (uint8_t)g, (uint8_t)b, 255};
    return true;
}

static bool ends_with(const char *s, const char *suffix) {
    size_t ls = strlen(s), lx = strlen(suffix);
    return ls >= lx && strcmp(s + ls - lx, suffix) == 0;
}

int main(int argc, char **argv) {
    const char *rom_path = NULL;
    int scale = DEFAULT_SCALE;
    int speed = DEFAULT_SPEED;
    Color fg = {0xd3, 0xc9, 0xa1, 255};
    Color bg = {0x32, 0x3c, 0x39, 255};
    bool help = false;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0)
            help = true;
        else if ((strcmp(argv[i], "-s") == 0 || strcmp(argv[i], "--scale") == 0) && i + 1 < argc)
            scale = atoi(argv[++i]);
        else if ((strcmp(argv[i], "-n") == 0 || strcmp(argv[i], "--speed") == 0) && i + 1 < argc)
            speed = atoi(argv[++i]);
        else if ((strcmp(argv[i], "-p") == 0 || strcmp(argv[i], "--palette") == 0)) {
            if (i + 1 >= argc || argv[i + 1][0] == '-') {
                fprintf(stderr, "available palettes:\n");
                for (size_t j = 0; j < sizeof(PALETTES) / sizeof(PALETTES[0]); j++)
                    fprintf(stderr, "  %s\n", PALETTES[j].name);
                return 0;
            }
            const Palette *p = find_palette(argv[++i]);
            if (!p) {
                fprintf(stderr, "4b: unknown palette: %s\n", argv[i]);
                fprintf(stderr, "available palettes:\n");
                for (size_t j = 0; j < sizeof(PALETTES) / sizeof(PALETTES[0]); j++)
                    fprintf(stderr, "  %s\n", PALETTES[j].name);
                return 1;
            }
            fg = p->fg;
            bg = p->bg;
        }
        else if ((strcmp(argv[i], "-f") == 0 || strcmp(argv[i], "--fg") == 0) && i + 1 < argc) {
            if (!parse_color(argv[++i], &fg)) {
                fprintf(stderr, "4b: invalid color: %s (expected R,G,B or hex)\n", argv[i]);
                return 1;
            }
        }
        else if ((strcmp(argv[i], "-b") == 0 || strcmp(argv[i], "--bg") == 0) && i + 1 < argc) {
            if (!parse_color(argv[++i], &bg)) {
                fprintf(stderr, "4b: invalid color: %s (expected R,G,B or hex)\n", argv[i]);
                return 1;
            }
        }
        else if (argv[i][0] != '-')
            rom_path = argv[i];
    }

    if (help || !rom_path) {
        fprintf(stderr, "usage: 4b [flags] <rom.4b | source.4a>\n");
        fprintf(stderr, "  -s, --scale N       pixel scale (default %d)\n", DEFAULT_SCALE);
        fprintf(stderr, "  -n, --speed  N      instructions per frame (default %d)\n", DEFAULT_SPEED);
        fprintf(stderr, "  -p, --palette NAME  use a named palette\n");
        fprintf(stderr, "  -f, --fg  COLOR     foreground color as R,G,B or hex (default d3c9a1)\n");
        fprintf(stderr, "  -b, --bg  COLOR     background color as R,G,B or hex (default 323c39)\n");
        fprintf(stderr, "\nA .4a source file is assembled at startup.\n");
        return help ? 0 : 1;
    }
    if (scale < 1) scale = 1;
    if (scale > 64) scale = 64;
    if (speed < 1) speed = 1;

    static uint8_t assembled[ROM_SIZE];
    size_t rom_len;
    uint8_t *rom;

    if (ends_with(rom_path, ".4a")) {
        /* Source file: assemble with the embedded 4a. */
        size_t src_len;
        char *src = (char *)read_file(rom_path, &src_len);
        if (!src) { fprintf(stderr, "4b: cannot read %s\n", rom_path); return 1; }
        char errs[4096];
        if (bc_compile(rom_path, src, src_len, assembled, errs, sizeof(errs)) != 0) {
            fprintf(stderr, "%s", errs);
            free(src);
            return 1;
        }
        free(src);
        rom = assembled;
        rom_len = ROM_SIZE;
    } else {
        rom = read_file(rom_path, &rom_len);
        if (!rom) { fprintf(stderr, "4b: cannot read %s\n", rom_path); return 1; }
        if (rom_len != ROM_SIZE) {
            fprintf(stderr, "4b: %s: expected %d bytes, got %zu\n", rom_path, ROM_SIZE, rom_len);
            free(rom); return 1;
        }
    }

    VM vm;
    vm_init(&vm);
    vm_load_rom(&vm, rom, rom_len);

    SetTraceLogLevel(LOG_ERROR);

    const char *base = strrchr(rom_path, '/');
    const char *sep = strrchr(rom_path, '\\');
    if (sep && (base == NULL || sep > base)) base = sep;
    base = base ? base + 1 : rom_path;
    char stem[256];
    snprintf(stem, sizeof(stem), "%s", base);
    char *dot = strstr(stem, ".4b.rom");
    if (dot == NULL) dot = strrchr(stem, '.');
    if (dot != NULL) *dot = '\0';
    char title[268];
    snprintf(title, sizeof(title), "4b: %s", stem);

    InitWindow(SCREEN_W * scale, SCREEN_H * scale, title);
    SetTargetFPS(60);

    while (!WindowShouldClose()) {
        if (IsKeyPressed(KEY_F)) {
            ToggleFullscreen();
            if (IsWindowFullscreen())
                SetWindowSize(GetMonitorWidth(GetCurrentMonitor()), GetMonitorHeight(GetCurrentMonitor()));
            else
                SetWindowSize(SCREEN_W * scale, SCREEN_H * scale);
        }

        if (IsKeyPressed(KEY_R)) vm_load_rom(&vm, rom, rom_len);

        uint8_t btns = 0;
        if (IsKeyDown(KEY_LEFT))  btns |= 1;
        if (IsKeyDown(KEY_RIGHT)) btns |= 2;
        if (IsKeyDown(KEY_UP))    btns |= 4;
        if (IsKeyDown(KEY_DOWN))  btns |= 8;

        vm.buttons = btns;

        for (int i = 0; i < speed; i++) vm_tick(&vm);

        int px = GetScreenHeight() / SCREEN_H;
        int ox = (GetScreenWidth() - SCREEN_W * px) / 2;
        int oy = (GetScreenHeight() - SCREEN_H * px) / 2;

        BeginDrawing();
        ClearBackground(bg);
        for (int y = 0; y < SCREEN_H; y++)
            for (int x = 0; x < SCREEN_W; x++)
                if (vm.screen[y * SCREEN_W + x])
                    DrawRectangle(ox + x * px, oy + y * px, px, px, fg);
        EndDrawing();
    }

    CloseWindow();
    return 0;
}
