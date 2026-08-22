const std = @import("std");
const assembler = @import("assembler.zig");
const machine = @import("vm.zig");

const move_src =
    \\; move.4a       ; steer a single pixel with the arrow keys
    \\
    \\lda #8
    \\sta r0          ; x = 8
    \\sta r1          ; y = 8
    \\sta r7          ; "held" bit pattern
    \\
    \\lda #0
    \\sta r5          ; handler marker (cleared)
    \\
    \\                ; Handlers sit before the loop so their flags 
    \\                ; are recorded by the startup fall-through 
    \\                ; before any jmp can reference them. On that
    \\                ; first pass they cancel out: +1, -1, +1, -1.
    \\
    \\@hR:            ; x++
    \\  lda r0
    \\  inc
    \\  sta r0
    \\  lda r5
    \\  ifeq r7       ; entered from a detector?
    \\  jmp @loop     ; yes - back to the frame loop
    \\
    \\@hL:            ; x-- (mod 16)
    \\  lda r0
    \\  inc
    \\  inc
    \\  inc
    \\  inc
    \\  inc
    \\  inc
    \\  inc
    \\  inc
    \\  inc
    \\  inc
    \\  inc
    \\  inc
    \\  inc
    \\  inc
    \\  inc
    \\  sta r0
    \\  lda r5
    \\  ifeq r7
    \\  jmp @loop
    \\
    \\@hD:            ; y++
    \\  lda r1
    \\  inc
    \\  sta r1
    \\  lda r5
    \\  ifeq r7
    \\  jmp @loop
    \\
    \\@hU:            ; y-- (mod 16)
    \\  lda r1
    \\  inc
    \\  inc
    \\  inc
    \\  inc
    \\  inc
    \\  inc
    \\  inc
    \\  inc
    \\  inc
    \\  inc
    \\  inc
    \\  inc
    \\  inc
    \\  inc
    \\  inc
    \\  sta r1
    \\  lda r5
    \\  ifeq r7
    \\  jmp @loop
    \\
    \\@loop:
    \\  lda #0
    \\  sta r5        ; clear marker
    \\  cls
    \\
    \\  flip r0, r1
    \\  read
    \\  sta r2
    \\  
    \\  lda r2        ; left = buttons bit 0
    \\  shl
    \\  shl
    \\  shl
    \\  sta r5        ; marker = 8 if held
    \\  ifeq r7
    \\  jmp @hL
    \\  
    \\  lda r2        ; right = buttons bit 1
    \\  shr
    \\  shl
    \\  shl
    \\  shl
    \\  sta r5
    \\  ifeq r7
    \\  jmp @hR
    \\
    \\  lda r2        ; down = buttons bit 3
    \\  shr
    \\  shr
    \\  shr
    \\  shl
    \\  shl
    \\  shl
    \\  sta r5
    \\  ifeq r7
    \\  jmp @hD
    \\
    \\  lda r2        ; up = buttons bit 2
    \\  shr
    \\  shr
    \\  shl
    \\  shl
    \\  shl
    \\  sta r5
    \\  ifeq r7
    \\  jmp @hU
    \\  
    \\  jmp @loop
;

test "probe: move.4a boot trace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var diag = assembler.diagnostics.Diag.init(alloc, "<probe>", move_src);
    const image = try assembler.assemble(alloc, &diag, move_src);

    var vm: machine.VM = undefined;
    machine.vm_load_rom(&vm, &image, image.len);

    var visited: [256]bool = @splat(false);
    var pc_hist: [48]u8 = undefined;
    var hist_len: usize = 0;

    for (0..600) |_| {
        visited[vm.pc] = true;
        if (hist_len < pc_hist.len) {
            pc_hist[hist_len] = vm.pc;
            hist_len += 1;
        }
        machine.vm_tick(&vm);
    }

    std.debug.print("\npc history (first {d} ticks): ", .{hist_len});
    for (pc_hist[0..hist_len]) |pc| std.debug.print("{d} ", .{pc});
    std.debug.print("\n", .{});

    std.debug.print("flags:", .{});
    for (vm.flags, 0..) |f, s| std.debug.print(" [{d}]=pos{d}", .{ s, f });
    std.debug.print("\n", .{});

    std.debug.print("distinct pcs:", .{});
    var count: usize = 0;
    for (visited, 0..) |v, p| {
        if (v) {
            std.debug.print(" {d}", .{p});
            count += 1;
        }
    }
    std.debug.print(" ({d} distinct)\n", .{count});
    std.debug.print("regs: x={d} y={d}\n", .{ vm.regs[0], vm.regs[1] });
}
