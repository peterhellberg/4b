const std = @import("std");
const assembler = @import("assembler");
const dia = @import("dia");

const Options = struct {
    input: ?[]const u8,
    output: ?[]const u8,
};

pub fn main(args: std.process.Init) !u8 {
    var opts = Options{
        .input = null,
        .output = null,
    };

    var it = try args.minimal.args.iterateAllocator(args.arena.allocator());
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

    var diag = dia.Diag.init(alloc, input_path, src);

    const image = assembler.assemble(alloc, &diag, src) catch |e| switch (e) {
        error.AssembleFailed => {
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
        std.debug.print("error: cannot write '{s}': {s}\n", .{
            output_path,
            @errorName(e),
        });
        return 1;
    };

    return 0;
}

fn defaultOutput(alloc: std.mem.Allocator, input_path: []const u8) []const u8 {
    const stem_len = if (std.mem.lastIndexOfScalar(u8, input_path, '.')) |dot|
        dot
    else
        input_path.len;

    return std.fmt.allocPrint(alloc, "{s}.4b", .{
        input_path[0..stem_len],
    }) catch return input_path;
}

fn printUsage() void {
    std.debug.print(
        \\Usage: 4a [options] <input.4a>
        \\
        \\Options:
        \\  -o, --output <file>   output ROM path (default: <input stem>.4b)
        \\  -h, --help            print usage and exit
        \\
    , .{});
}
