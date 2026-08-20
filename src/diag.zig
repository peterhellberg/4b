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

    pub fn init(alloc: std.mem.Allocator, path: []const u8, src: []const u8) Diag {
        var ls = std.ArrayList(usize).empty;
        ls.append(alloc, 0) catch unreachable;
        for (src, 0..) |c, i| {
            if (c == '\n') {
                const next = i + 1;
                if (next <= src.len) ls.append(alloc, next) catch unreachable;
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

    pub fn err(self: *Diag, line: u32, col: u32, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.alloc, fmt, args) catch return;
        self.errors.append(self.alloc, .{ .msg = msg, .line = line, .col = col }) catch return;
    }

    pub fn hasErrors(self: *const Diag) bool {
        return self.errors.items.len > 0;
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
                std.debug.print("    {s}\n", .{line_text});
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
