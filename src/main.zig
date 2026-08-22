const std = @import("std");
const compiler = @import("compiler.zig");
const compiler_4c = @import("4c/compiler.zig");
const asmout_4c = @import("4c/asmout.zig");
const diag_mod = @import("diag.zig");

comptime {
    _ = @import("tests.zig");
}

const Options = struct {
    input: ?[]const u8,
    output: ?[]const u8,
    emit_asm: ?[]const u8,
};

pub fn main(args: std.process.Init) u8 {
    var opts = Options{ .input = null, .output = null, .emit_asm = null };
    var it = args.minimal.args.iterate();
    _ = it.next();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return 0;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            opts.output = it.next() orelse {
                std.debug.print("error: missing argument for {s}\n", .{arg});
                return 1;
            };
        } else if (std.mem.startsWith(u8, arg, "-o") and arg.len > 2) {
            opts.output = arg[2..];
        } else if (std.mem.eql(u8, arg, "-S") or std.mem.eql(u8, arg, "--emit-asm")) {
            opts.emit_asm = it.next() orelse {
                std.debug.print("error: missing argument for {s}\n", .{arg});
                return 1;
            };
        } else if (std.mem.startsWith(u8, arg, "-S") and arg.len > 2) {
            opts.emit_asm = arg[2..];
        } else if (std.mem.startsWith(u8, arg, "--emit-asm=")) {
            opts.emit_asm = arg["--emit-asm=".len..];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("error: unknown option '{s}'\n", .{arg});
            return 1;
        } else if (opts.input != null) {
            std.debug.print("error: multiple input files\n", .{});
            return 1;
        } else {
            opts.input = arg;
        }
    }

    const input_path = opts.input orelse {
        std.debug.print("error: no input file\n\n", .{});
        printUsage();
        return 1;
    };

    const alloc = args.arena.allocator();
    const io = args.io;

    const src = std.Io.Dir.cwd().readFileAlloc(io, input_path, alloc, .limited(1 << 20)) catch |e| {
        std.debug.print("error: cannot read '{s}': {s}\n", .{ input_path, @errorName(e) });
        return 1;
    };

    var diag = diag_mod.Diag.init(alloc, input_path, src);

    const is_4c = std.mem.endsWith(u8, input_path, ".4c");

    if (is_4c) {
        const out = compiler_4c.compileWords(alloc, &diag, src) catch |e| switch (e) {
            error.CompileFailed => {
                diag.printAll();
                return 1;
            },
            error.OutOfMemory => {
                std.debug.print("error: out of memory\n", .{});
                return 1;
            },
        };

        if (diag.hasErrors()) {
            diag.printAll();
            return 1;
        }

        if (opts.emit_asm) |path| {
            var text = std.ArrayList(u8).empty;
            asmout_4c.write(alloc, out.words, &text) catch {
                std.debug.print("error: out of memory\n", .{});
                return 1;
            };
            writeOutput(io, path, text.items) catch |e| {
                std.debug.print("error: cannot write '{s}': {s}\n", .{ path, @errorName(e) });
                return 1;
            };
        }

        var image: [384]u8 = undefined;
        @import("encoder.zig").pack(out.words, &image);
        const output_path = opts.output orelse defaultOutput(alloc, input_path);
        std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = output_path,
            .data = &image,
        }) catch |e| {
            std.debug.print("error: cannot write '{s}': {s}\n", .{ output_path, @errorName(e) });
            return 1;
        };
    } else {
        const image = compiler.compile(alloc, &diag, src) catch |e| switch (e) {
            error.CompileFailed => {
                diag.printAll();
                return 1;
            },
            error.OutOfMemory => {
                std.debug.print("error: out of memory\n", .{});
                return 1;
            },
        };

        if (diag.hasErrors()) {
            diag.printAll();
            return 1;
        }

        const output_path = opts.output orelse defaultOutput(alloc, input_path);
        std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = output_path,
            .data = &image,
        }) catch |e| {
            std.debug.print("error: cannot write '{s}': {s}\n", .{ output_path, @errorName(e) });
            return 1;
        };
    }

    return 0;
}

fn writeOutput(io: std.Io, path: []const u8, data: []const u8) !void {
    if (std.mem.eql(u8, path, "-")) {
        try std.Io.File.stdout().writeStreamingAll(io, data);
        return;
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

fn defaultOutput(alloc: std.mem.Allocator, input_path: []const u8) []const u8 {
    const stem_len = if (std.mem.lastIndexOfScalar(u8, input_path, '.')) |dot|
        dot
    else
        input_path.len;
    return std.fmt.allocPrint(alloc, "{s}.4b", .{input_path[0..stem_len]}) catch return input_path;
}

fn printUsage() void {
    std.debug.print(
        \\Usage: 4a [options] <input.4a|.4c>
        \\
        \\Options:
        \\  -o, --output <file>   output ROM path (default: <input stem>.4b)
        \\  -S, --emit-asm <file> write text assembly too ('-' = stdout)
        \\  -h, --help            print usage and exit
        \\
    , .{});
}
