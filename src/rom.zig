const std = @import("std");

pub const IMAGE_BYTES = 384;
pub const IMAGE_WORDS = 256;

pub const Image = [IMAGE_BYTES]u8;

pub fn pack(words: []const u16, out: *Image) void {
    std.debug.assert(words.len <= IMAGE_WORDS);
    @memset(out, 0);

    for (words, 0..) |w_raw, wi| {
        // Mask to low 12 bits: upper nibble is not part of the image.
        const w = w_raw & 0xFFF;
        const base: usize = wi * 12;
        for (0..12) |k| {
            if ((w >> @intCast(k)) & 1 != 0) {
                const g = base + k;
                out[g / 8] |= @as(u8, 1) << @intCast(g % 8);
            }
        }
    }
}

/// Unpack a 384-byte image into 256 12-bit words. The exact inverse of
/// `pack`, using the same LSB-first bit order as the VM's ROM loader.
pub fn unpack(image: *const Image, words: []u16) void {
    std.debug.assert(words.len >= IMAGE_WORDS);
    @memset(words[0..IMAGE_WORDS], 0);

    for (0..IMAGE_WORDS) |wi| {
        var word: u16 = 0;
        for (0..12) |k| {
            const g = wi * 12 + k;
            if ((image[g / 8] >> @intCast(g % 8)) & 1 != 0) {
                word |= @as(u16, 1) << @intCast(k);
            }
        }
        words[wi] = word;
    }
}

test "pack/unpack round-trip" {
    const original = [_]u16{
        0x000, 0x380, 0x210, 0xFFF, 0xB00, 0xC0F, 0x9AB, 0x512,
    };
    var img: Image = undefined;
    pack(&original, &img);

    var words: [IMAGE_WORDS]u16 = undefined;
    unpack(&img, &words);

    for (original, 0..) |w, i| try std.testing.expectEqual(w, words[i]);
    for (words[original.len..]) |w| try std.testing.expectEqual(0, w);
}

test "unpack lsb-first vectors" {
    var img: Image = @splat(0);
    img[0] = 0x80;
    img[1] = 0x03;
    img[2] = 0x21;

    var words: [IMAGE_WORDS]u16 = undefined;
    unpack(&img, &words);

    try std.testing.expectEqual(0x380, words[0]);
    try std.testing.expectEqual(0x210, words[1]);
    try std.testing.expectEqual(0, words[2]);
}

test "pack lda #8 sta r1" {
    const words = [_]u16{ 0x380, 0x210 };
    var img: Image = undefined;

    pack(&words, &img);

    try std.testing.expectEqual(0x80, img[0]);
    try std.testing.expectEqual(0x03, img[1]);
    try std.testing.expectEqual(0x21, img[2]);

    for (img[3..]) |b| try std.testing.expectEqual(0, b);
}

test "pack nop" {
    const words = [_]u16{0x000};
    var img: Image = undefined;

    pack(&words, &img);

    for (img) |b| try std.testing.expectEqual(0, b);
}

test "pack flag and jmp" {
    const words = [_]u16{ 0xB00, 0xC00 };
    var img: Image = undefined;

    pack(&words, &img);

    try std.testing.expectEqual(0x00, img[0]);
    try std.testing.expectEqual(0x0B, img[1]);
    try std.testing.expectEqual(0xC0, img[2]);
    try std.testing.expectEqual(0x00, img[3]);
}

test "pack masks upper nibble" {
    const words = [_]u16{0xFFFF};
    var img: Image = undefined;

    pack(&words, &img);

    try std.testing.expectEqual(0xFF, img[0]);
    try std.testing.expectEqual(0x0F, img[1]);
}
