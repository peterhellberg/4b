const std = @import("std");
const compiler = @import("compiler.zig");
const diag_mod = @import("diag.zig");

comptime {
    _ = @import("tests.zig");
}

pub fn main(args: std.process.Init) u8 {
    var input: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var it = args.minimal.args.iterate();
    _ = it.next();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return 0;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            output = it.next() orelse {
                std.debug.print("error: missing argument for {s}\n", .{arg});
                return 1;
            };
        } else if (std.mem.startsWith(u8, arg, "-o") and arg.len > 2) {
            output = arg[2..];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("error: unknown option '{s}'\n", .{arg});
            return 1;
        } else if (input != null) {
            std.debug.print("error: multiple input files\n", .{});
            return 1;
        } else {
            input = arg;
        }
    }

    const input_path = input orelse {
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

    const output_path = output orelse defaultOutput(alloc, input_path);

    std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = output_path,
        .data = &image,
    }) catch |e| {
        std.debug.print("error: cannot write '{s}': {s}\n", .{ output_path, @errorName(e) });
        return 1;
    };

    return 0;
}

fn defaultOutput(alloc: std.mem.Allocator, input_path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, input_path, ".4a")) {
        return std.fmt.allocPrint(alloc, "{s}.4b", .{input_path[0 .. input_path.len - 3]}) catch return input_path;
    }
    return std.fmt.allocPrint(alloc, "{s}.4b", .{input_path}) catch return input_path;
}

fn printUsage() void {
    std.debug.print("Usage: 4a [options] <input.4a>\n\nOptions:\n  -o, --output <file>  output path (default: <input stem>.4b)\n  -h, --help           print usage and exit\n", .{});
}
