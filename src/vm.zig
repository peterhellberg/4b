const std = @import("std");

pub const SCREEN_W = 16;
pub const SCREEN_H = 16;
pub const PROG_SIZE = 256;
pub const REG_COUNT = 16;
pub const FLAG_COUNT = 16;

pub const VM = extern struct {
    program: [PROG_SIZE]u16,
    regs: [REG_COUNT]u8,
    acc: u8,
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
        0x1 => vm.acc = vm.regs[a] & 0x0F,
        0x2 => vm.regs[a] = vm.acc & 0x0F,
        0x3 => vm.acc = a,
        0x4 => vm.acc = vm.buttons & 0x0F,
        0x5 => vm.acc = (vm.acc +% 1) & 0x0F,
        0x6 => @memset(&vm.screen, 0),
        0x7 => vm.acc = (vm.acc << 1) & 0x0F,
        0x8 => vm.acc >>= 1,
        0x9 => {
            const x: usize = vm.regs[a] & 0x0F;
            const y: usize = vm.regs[b] & 0x0F;
            vm.acc = vm.screen[y * SCREEN_W + x];
        },
        0xA => {
            const x: usize = vm.regs[a] & 0x0F;
            const y: usize = vm.regs[b] & 0x0F;
            const idx = y * SCREEN_W + x;
            vm.screen[idx] = if (vm.screen[idx] == 0) 1 else 0;
        },
        0xB => vm.flags[a] = vm.pc -% 1,
        0xC => vm.pc = @intCast(vm.flags[a]),
        0xD => {
            if (vm.regs[a] != vm.acc) vm.pc +%= 1;
        },
        0xE => {
            if (vm.regs[a] <= vm.acc) vm.pc +%= 1;
        },
        0xF => {
            if (vm.regs[a] >= vm.acc) vm.pc +%= 1;
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

fn tw(op: u4, a: u4, b: u4) u16 {
    return (@as(u16, op) << 8) | (@as(u16, a) << 4) | b;
}

test "vm: data movement and alu" {
    var vm: VM = undefined;
    vm_init(&vm);

    vm.program[0] = tw(0x0, 0xF, 0xF);
    vm_tick(&vm);
    try std.testing.expectEqual(@as(u8, 1), vm.pc);

    vm.program[1] = tw(0x3, 9, 0);
    vm_tick(&vm);
    try std.testing.expectEqual(@as(u8, 9), vm.acc);

    vm.program[2] = tw(0x2, 4, 0);
    vm_tick(&vm);
    try std.testing.expectEqual(@as(u8, 9), vm.regs[4]);

    vm.acc = 0;
    vm.program[3] = tw(0x1, 4, 0);
    vm_tick(&vm);
    try std.testing.expectEqual(@as(u8, 9), vm.acc);

    vm.buttons = 0b1010;
    vm.program[4] = tw(0x4, 0, 0);
    vm_tick(&vm);
    try std.testing.expectEqual(@as(u8, 0b1010), vm.acc);

    vm.acc = 15;
    vm.program[5] = tw(0x5, 0, 0);
    vm_tick(&vm);
    try std.testing.expectEqual(@as(u8, 0), vm.acc);

    vm.acc = 8;
    vm.program[6] = tw(0x7, 0, 0);
    vm_tick(&vm);
    try std.testing.expectEqual(@as(u8, 0), vm.acc);

    vm.acc = 15;
    vm.program[7] = tw(0x7, 0, 0);
    vm_tick(&vm);
    try std.testing.expectEqual(@as(u8, 14), vm.acc);

    vm.acc = 1;
    vm.program[8] = tw(0x8, 0, 0);
    vm_tick(&vm);
    try std.testing.expectEqual(@as(u8, 0), vm.acc);

    vm.acc = 15;
    vm.program[9] = tw(0x8, 0, 0);
    vm_tick(&vm);
    try std.testing.expectEqual(@as(u8, 7), vm.acc);
}

test "vm: peek flip cls" {
    var vm: VM = undefined;
    vm_init(&vm);
    vm.regs[2] = 3;
    vm.regs[3] = 5;

    vm.program[0] = tw(0xA, 2, 3);
    vm_tick(&vm);
    try std.testing.expectEqual(@as(u8, 1), vm.screen[5 * SCREEN_W + 3]);
    try std.testing.expectEqual(@as(u8, 0), vm.screen[5 * SCREEN_W + 2]);

    vm.program[1] = tw(0x9, 2, 3);
    vm_tick(&vm);
    try std.testing.expectEqual(@as(u8, 1), vm.acc);

    vm.program[2] = tw(0x6, 0, 0);
    vm_tick(&vm);
    try std.testing.expectEqual(@as(u8, 0), vm.screen[5 * SCREEN_W + 3]);
}

test "vm: flag records own position and jmp returns to it" {
    var vm: VM = undefined;
    vm_init(&vm);
    vm.program[13] = tw(0xB, 1, 0);
    vm.program[14] = tw(0xC, 1, 0);
    vm.pc = 13;

    vm_tick(&vm);
    try std.testing.expectEqual(@as(u16, 13), vm.flags[1]);
    try std.testing.expectEqual(@as(u8, 14), vm.pc);

    vm_tick(&vm);
    try std.testing.expectEqual(@as(u8, 13), vm.pc);

    vm_tick(&vm);
    try std.testing.expectEqual(@as(u8, 14), vm.pc);
    try std.testing.expectEqual(@as(u16, 13), vm.flags[1]);
}

fn expectSkip(comptime op: u4, r: u4, acc: u4, executes_next: bool) !void {
    var vm: VM = undefined;
    vm_init(&vm);
    vm.program[100] = tw(op, 9, 0);
    vm.program[101] = tw(0x3, 15, 0);
    vm.pc = 100;
    vm.acc = acc;
    vm.regs[9] = r;
    vm_tick(&vm);
    vm_tick(&vm);
    try std.testing.expectEqual(executes_next, vm.acc == 15);
}

test "vm: ifeq ifgt iflt conditional skip" {
    try expectSkip(0xD, 5, 5, true);
    try expectSkip(0xD, 4, 5, false);
    try expectSkip(0xD, 6, 5, false);
    try expectSkip(0xE, 6, 5, true);
    try expectSkip(0xE, 5, 5, false);
    try expectSkip(0xE, 4, 5, false);
    try expectSkip(0xF, 4, 5, true);
    try expectSkip(0xF, 5, 5, false);
    try expectSkip(0xF, 6, 5, false);
}

test "vm: pc wraps at 255" {
    var vm: VM = undefined;
    vm_init(&vm);
    vm.program[255] = tw(0xB, 2, 0);
    vm.pc = 255;
    vm_tick(&vm);
    try std.testing.expectEqual(@as(u16, 255), vm.flags[2]);
    try std.testing.expectEqual(@as(u8, 0), vm.pc);

    var vm2: VM = undefined;
    vm_init(&vm2);
    vm2.flags[3] = 255;
    vm2.program[0] = tw(0xC, 3, 0);
    vm2.program[255] = tw(0x5, 0, 0);
    vm_tick(&vm2);
    try std.testing.expectEqual(@as(u8, 255), vm2.pc);
    vm_tick(&vm2);
    try std.testing.expectEqual(@as(u8, 1), vm2.acc);
    try std.testing.expectEqual(@as(u8, 0), vm2.pc);
}

test "vm: load rom unpacks lsb-first 12-bit words" {
    var vm: VM = undefined;
    vm.acc = 9;
    const rom = [_]u8{ 0x80, 0x03, 0x21 };
    vm_load_rom(&vm, &rom, rom.len);
    try std.testing.expectEqual(@as(u16, 0x380), vm.program[0]);
    try std.testing.expectEqual(@as(u16, 0x210), vm.program[1]);
    try std.testing.expectEqual(@as(u16, 0), vm.program[2]);
    try std.testing.expectEqual(@as(u8, 0), vm.acc);
    try std.testing.expectEqual(@as(u8, 0), vm.pc);

    const truncated = [_]u8{ 0xFF, 0xFF };
    vm_load_rom(&vm, &truncated, truncated.len);
    try std.testing.expectEqual(@as(u16, 0xFFF), vm.program[0]);
    try std.testing.expectEqual(@as(u16, 0x00F), vm.program[1]);
    try std.testing.expectEqual(@as(u16, 0), vm.program[2]);
}

test "vm: c abi layout matches 4b.c" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(VM, "program"));
    try std.testing.expectEqual(@as(usize, 512), @offsetOf(VM, "regs"));
    try std.testing.expectEqual(@as(usize, 528), @offsetOf(VM, "acc"));
    try std.testing.expectEqual(@as(usize, 529), @offsetOf(VM, "screen"));
    try std.testing.expectEqual(@as(usize, 786), @offsetOf(VM, "flags"));
    try std.testing.expectEqual(@as(usize, 818), @offsetOf(VM, "pc"));
    try std.testing.expectEqual(@as(usize, 819), @offsetOf(VM, "buttons"));
    try std.testing.expectEqual(@as(usize, 820), @sizeOf(VM));
}
