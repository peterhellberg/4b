const std = @import("std");

pub const SCREEN_W = 16;
pub const SCREEN_H = 16;
pub const PROG_SIZE = 256;
pub const REG_COUNT = 16;
pub const FLAG_COUNT = 16;

pub const VM = struct {
    program: [PROG_SIZE]u16,
    regs: [REG_COUNT]u4,
    acc: u4,
    screen: [SCREEN_W * SCREEN_H]u8,
    flags: [FLAG_COUNT]u16,
    pc: u8,
    buttons: u8,
};

pub export fn vm_init(vm: *VM) void {
    @memset(&vm.program, 0);
    @memset(&vm.regs, 0);
    vm.acc = 0;
    @memset(&vm.screen, 0);
    @memset(&vm.flags, 0);
    vm.pc = 0;
    vm.buttons = 0;
}

pub export fn vm_tick(vm: *VM) void {
    const word = vm.program[vm.pc];
    const op: u4 = @intCast((word >> 8) & 0xF);
    const a: u4 = @intCast((word >> 4) & 0xF);
    const b: u4 = @intCast(word & 0xF);

    vm.pc +%= 1;

    switch (op) {
        0x0 => {},
        0x1 => vm.acc = vm.regs[a],
        0x2 => vm.regs[a] = vm.acc,
        0x3 => vm.acc = a,
        0x4 => vm.acc = @intCast(vm.buttons & 0x0F),
        0x5 => vm.acc +%= 1,
        0x6 => @memset(&vm.screen, 0),
        0x7 => vm.acc = @intCast((@as(u8, vm.acc) << 1) & 0x0F),
        0x8 => vm.acc >>= 1,
        0x9 => {
            const x: usize = vm.regs[a];
            const y: usize = vm.regs[b];
            vm.acc = @intCast(vm.screen[y * SCREEN_W + x]);
        },
        0xA => {
            const x: usize = vm.regs[a];
            const y: usize = vm.regs[b];
            const idx = y * SCREEN_W + x;
            vm.screen[idx] = if (vm.screen[idx] == 0) 1 else 0;
        },
        0xB => vm.flags[a] = vm.pc -% 1,
        0xC => vm.pc = @intCast(vm.flags[a]),
        0xD => {
            if (vm.regs[a] != vm.acc) vm.pc +%= 1;
        },
        0xE => {
            if (vm.regs[a] > vm.acc) vm.pc +%= 1;
        },
        0xF => {
            if (vm.regs[a] < vm.acc) vm.pc +%= 1;
        },
    }
}

pub export fn vm_load_rom(vm: *VM, data: [*]const u8, len: usize) void {
    vm_init(vm);
    const rom: []const u8 = data[0..len];
    var i: usize = 0;
    while (i < PROG_SIZE and i * 12 / 8 < rom.len) : (i += 1) {
        const base = i * 12;
        var word: u16 = 0;
        comptime var k: usize = 0;
        inline while (k < 12) : (k += 1) {
            const g = base + k;
            if (g / 8 < rom.len and (rom[g / 8] >> @intCast(g % 8)) & 1 != 0) {
                word |= @as(u16, 1) << @intCast(k);
            }
        }
        vm.program[i] = word;
    }
}
