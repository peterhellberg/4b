//! C-ABI wrapper around the 4a assembler, embedded into the 4b console
//! the same way src/vm.zig is.
const std = @import("std");
const compiler = @import("compiler.zig");
const diag_mod = @import("diag.zig");

/// Assemble 4A source into a 384-byte ROM image.
///
/// Returns 0 and fills `out` on success. On failure returns 1 and, when
/// `err_buf` is non-null, writes diagnostics ("path:line:col: error: msg\n"
/// per error, NUL-terminated, truncated to fit).
export fn bc_compile(
    path: [*:0]const u8,
    src: [*]const u8,
    src_len: usize,
    out: [*]u8,
    err_buf: ?[*]u8,
    err_cap: usize,
) c_int {
    const source: []const u8 = src[0..src_len];

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var diag = diag_mod.Diag.init(alloc, std.mem.span(path), source);
    const image = compiler.compile(alloc, &diag, source) catch {
        writeErrors(&diag, err_buf, err_cap);
        return 1;
    };
    if (diag.hasErrors()) {
        writeErrors(&diag, err_buf, err_cap);
        return 1;
    }

    @memcpy(out[0..image.len], &image);
    return 0;
}

fn writeErrors(diag: *const diag_mod.Diag, buf: ?[*]u8, cap: usize) void {
    const b = buf orelse return;
    if (cap == 0) return;
    var off: usize = 0;
    for (diag.errors.items) |e| {
        const written = std.fmt.bufPrint(b[off..cap], "{s}:{d}:{d}: error: {s}\n", .{
            diag.path, e.line, e.col, e.msg,
        }) catch break;
        off += written.len;
    }
    b[@min(off, cap - 1)] = 0;
}

test "bc_compile assembles valid source and reports errors" {
    var out: [384]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), bc_compile("t.4a", "jmp @h\n@h:\nnop\n", 15, &out, null, 0));
    try std.testing.expectEqual(@as(u8, 0x00), out[0]);
    try std.testing.expectEqual(@as(u8, 0x0C), out[1]);

    var err_buf: [256]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 1), bc_compile("t.4a", "jmp @nowhere\n", 13, &out, &err_buf, err_buf.len));
    const msg = std.mem.sliceTo(&err_buf, 0);
    try std.testing.expect(std.mem.indexOf(u8, msg, "undefined label") != null);
    try std.testing.expect(std.mem.startsWith(u8, msg, "t.4a:1:"));
}
