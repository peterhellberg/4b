const std = @import("std");

pub const Error = struct {
    msg: []const u8,
    line: u32,
    col: u32,
};

pub const Diag = struct {
    alloc: std.mem.Allocator,
    path: []const u8,
    src: []const u8,
    errors: std.ArrayList(Error),
    line_starts: std.ArrayList(usize),
    oom: bool = false,

    pub fn init(alloc: std.mem.Allocator, path: []const u8, src: []const u8) Diag {
        var ls = std.ArrayList(usize).empty;
        ls.append(alloc, 0) catch unreachable;
        for (src, 0..) |c, i| {
            if (c == '\n') {
                ls.append(alloc, i + 1) catch unreachable;
            }
        }
        return .{
            .alloc = alloc,
            .path = path,
            .src = src,
            .errors = std.ArrayList(Error).empty,
            .line_starts = ls,
        };
    }

    pub fn deinit(self: *Diag) void {
        for (self.errors.items) |e| self.alloc.free(e.msg);
        self.errors.deinit(self.alloc);
        self.line_starts.deinit(self.alloc);
    }

    pub fn err(self: *Diag, line: u32, col: u32, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.alloc, fmt, args) catch {
            self.oom = true;
            return;
        };
        self.errors.append(self.alloc, .{ .msg = msg, .line = line, .col = col }) catch {
            self.alloc.free(msg);
            self.oom = true;
        };
    }

    pub fn hasErrors(self: *const Diag) bool {
        return self.oom or self.errors.items.len > 0;
    }

    pub fn printAll(self: *const Diag) void {
        for (self.errors.items) |e| {
            std.debug.print("{s}:{d}:{d}: error: {s}\n", .{
                self.path,
                e.line,
                e.col,
                e.msg,
            });

            if (e.line > 0 and e.line - 1 < self.line_starts.items.len) {
                const start = self.line_starts.items[e.line - 1];
                var end: usize = start;
                while (end < self.src.len and self.src[end] != '\n') end += 1;
                const line_text = std.mem.trimEnd(u8, self.src[start..end], "\r");
                // Caret buffer is 64 wide; truncate long lines so it aligns.
                const shown = line_text[0..@min(line_text.len, 64)];
                std.debug.print("    {s}\n", .{shown});
                if (e.col > 0) {
                    var caret: [64]u8 = undefined;
                    const spaces = @min(e.col - 1, 63);
                    @memset(caret[0..spaces], ' ');
                    caret[spaces] = '^';

                    std.debug.print("    {s}\n", .{caret[0 .. spaces + 1]});
                }
            }
        }
    }
};

test "line starts handle lf, crlf and trailing newline" {
    var diag = Diag.init(std.testing.allocator, "<test>", "a\nb\r\nc\n");
    defer diag.deinit();
    try std.testing.expectEqualSlices(usize, &.{ 0, 2, 5, 7 }, diag.line_starts.items);
}

test "err records message and oom sticks" {
    var diag = Diag.init(std.testing.allocator, "<test>", "nop\n");
    defer diag.deinit();
    try std.testing.expect(!diag.hasErrors());
    diag.err(1, 1, "boom {d}", .{7});
    try std.testing.expect(diag.hasErrors());
    try std.testing.expectEqualStrings("boom 7", diag.errors.items[0].msg);

    diag.alloc = std.testing.failing_allocator;
    diag.err(1, 1, "lost", .{});
    try std.testing.expect(diag.oom);
    try std.testing.expect(diag.hasErrors());
    diag.alloc = std.testing.allocator;
}
