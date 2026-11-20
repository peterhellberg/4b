const std = @import("std");
const assembler = @import("assembler");
const disassembler = @import("disassembler");
const dia = @import("dia");
const rom = @import("rom");
const roms = @import("roms");

const Case = struct {
    name: []const u8,
    bytes: []const u8,
};

const example_roms = [_]Case{
    .{ .name = "halt", .bytes = roms.halt },
    .{ .name = "halt-4c", .bytes = roms.halt_4c },
    .{ .name = "line", .bytes = roms.line },
    .{ .name = "line-4c", .bytes = roms.line_4c },
    .{ .name = "fill", .bytes = roms.fill },
    .{ .name = "fill-4c", .bytes = roms.fill_4c },
    .{ .name = "diag", .bytes = roms.diag },
    .{ .name = "diag-4a", .bytes = roms.diag_4a },
    .{ .name = "move", .bytes = roms.move },
    .{ .name = "move-4a", .bytes = roms.move_4a },
    .{ .name = "dpad", .bytes = roms.dpad },
    .{ .name = "dpad-4a", .bytes = roms.dpad_4a },
};

fn roundTrip(alloc: std.mem.Allocator, image: *const rom.Image, labels: bool) !void {
    return roundTripStyle(alloc, image, labels, .positional);
}

fn roundTripStyle(
    alloc: std.mem.Allocator,
    image: *const rom.Image,
    labels: bool,
    style: disassembler.LabelStyle,
) !void {
    const text = try disassembler.disassemble(alloc, image, .{
        .labels = labels,
        .label_style = style,
    });

    var diag = dia.Diag.init(alloc, "<roundtrip>", text);
    defer diag.deinit();

    const rebuilt = assembler.assemble(alloc, &diag, text) catch {
        std.debug.print("reassembly failed for labels={}:\n{s}", .{ labels, text });
        for (diag.errors.items) |e| {
            std.debug.print("  {d}:{d}: {s}\n", .{ e.line, e.col, e.msg });
        }
        return error.RoundTripFailed;
    };

    if (!std.mem.eql(u8, image, &rebuilt)) {
        std.debug.print("round trip differs (labels={}, style={s}):\n{s}", .{
            labels,
            @tagName(style),
            text,
        });
        return error.RoundTripFailed;
    }
}

fn imageFrom(words: []const u16) rom.Image {
    var image: rom.Image = undefined;
    rom.pack(words, &image);
    return image;
}

test "round trip every example ROM" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    for (example_roms) |c| {
        var image: rom.Image = undefined;
        @memcpy(&image, c.bytes);

        try roundTrip(alloc, &image, true);
        try roundTrip(alloc, &image, false);
        try roundTripStyle(alloc, &image, true, .semantic);
    }
}

test "round trip assembler golden sources" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const sources = [_][]const u8{
        @embedFile("golden/line.4a"),
        @embedFile("golden/buttons.4a"),
        @embedFile("golden/forward.4a"),
        @embedFile("golden/rawflag.4a"),
        @embedFile("golden/orgdw.4a"),
        @embedFile("golden/dec.4a"),
    };

    for (sources) |src| {
        var diag = dia.Diag.init(alloc, "<golden>", src);
        const image = try assembler.assemble(alloc, &diag, src);
        try std.testing.expectEqual(0, diag.errors.items.len);

        try roundTrip(alloc, &image, true);
        try roundTrip(alloc, &image, false);
        try roundTripStyle(alloc, &image, true, .semantic);
    }
}

test "round trip edge cases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const edge_words = [_][]const u16{
        &.{}, // all-zero ROM
        &.{0xB00}, // label/branch at address 0
        &.{ 0xB00, 0xB10, 0xB20, 0xC00, 0xC12 }, // several labels
        &.{ 0xB00, 0xB20, 0xC10, 0xC00 }, // non-sequential flag slots
        &.{ 0xB00, 0xB00, 0xC00 }, // two flags with one slot
        &.{ 0xBF0, 0xCF0 }, // reserved slot 15
        &.{ 0x512, 0x500 }, // dec/inc extensions
        &.{ 0x9AB, 0xA01 }, // full peek/flip nibbles
        &.{ 0x012, 0x1F2, 0x2F0, 0x3F0, 0xD40, 0xE50, 0xF60 }, // unused nibbles
        &.{ 0xABC, 0x123 }, // raw dw data
        &.{ 0xFFF, 0x000, 0xEEE }, // arbitrary 12-bit words
    };

    for (edge_words) |words| {
        const image = imageFrom(words);
        try roundTrip(alloc, &image, true);
        try roundTrip(alloc, &image, false);
        try roundTripStyle(alloc, &image, true, .semantic);
    }

    // A branch target at the very last instruction.
    var far_words: [rom.IMAGE_WORDS]u16 = @splat(0);
    far_words[0] = 0xCE0;
    far_words[255] = 0xBE0;
    const far = imageFrom(&far_words);

    try roundTrip(alloc, &far, true);
    try roundTrip(alloc, &far, false);
    try roundTripStyle(alloc, &far, true, .semantic);

    // An operand value that collides with a label address must still print
    // as a numeric immediate rather than a label.
    const collide = imageFrom(&.{ 0xB00, 0x300, 0xC00 });
    try roundTrip(alloc, &collide, true);
    try roundTrip(alloc, &collide, false);
    try roundTripStyle(alloc, &collide, true, .semantic);
}
