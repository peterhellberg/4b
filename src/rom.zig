const std = @import("std");

pub const IMAGE_BYTES = 384;
pub const IMAGE_WORDS = 256;

pub const Image = [IMAGE_BYTES]u8;

pub fn pack(words: []const u16, out: *Image) void {
    @memset(out, 0);

    for (words, 0..) |w, wi| {
        const base: usize = wi * 12;
        comptime var k: usize = 0;
        inline while (k < 12) : (k += 1) {
            if ((w >> @intCast(k)) & 1 != 0) {
                const g = base + k;
                out[g / 8] |= @as(u8, 1) << @intCast(g % 8);
            }
        }
    }
}

test "pack lda #8 sta r1" {
    const words = [_]u16{ 0x380, 0x210 };
    var img: Image = undefined;

    pack(&words, &img);

    try std.testing.expectEqual(@as(u8, 0x80), img[0]);
    try std.testing.expectEqual(@as(u8, 0x03), img[1]);
    try std.testing.expectEqual(@as(u8, 0x21), img[2]);

    for (img[3..]) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "pack nop" {
    const words = [_]u16{0x000};
    var img: Image = undefined;

    pack(&words, &img);

    for (img) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "pack flag and jmp" {
    const words = [_]u16{ 0xB00, 0xC00 };
    var img: Image = undefined;

    pack(&words, &img);

    try std.testing.expectEqual(@as(u8, 0x00), img[0]);
    try std.testing.expectEqual(@as(u8, 0x0B), img[1]);
    try std.testing.expectEqual(@as(u8, 0xC0), img[2]);
    try std.testing.expectEqual(@as(u8, 0x00), img[3]);
}
