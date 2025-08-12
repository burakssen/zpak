const std = @import("std");
const zpak = @import("zpak");
const Encoder = zpak.Encoder;
const Decoder = zpak.Decoder;
const CompressionLevel = zpak.core.Compression.CompressionLevel;

const UsageError = error{InvalidArgs};

fn printUsage() void {
    _ = std.io.getStdErr().writer().print(
        \\Usage:
        \\  zpak encode <input_dir> <output_file> [--algo <lz4|zstd|lzma|brotli>] [--level <low|medium|high>]
        \\  zpak decode <archive_file> <output_dir>
        \\
    , .{}) catch {};
}

fn parseLevel(s: []const u8) ?CompressionLevel {
    inline for (.{ .low, .medium, .high }) |lvl| {
        if (std.ascii.eqlIgnoreCase(s, @tagName(lvl))) return lvl;
    }
    return null;
}

fn expectArg(it: *std.process.ArgIterator, msg: []const u8) ![]const u8 {
    return it.next() orelse {
        std.log.err("{s}", .{msg});
        printUsage();
        return UsageError.InvalidArgs;
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var it = try std.process.argsWithAllocator(alloc);
    defer it.deinit();
    _ = it.next(); // skip program name

    const cmd = try expectArg(&it, "Missing command");

    if (std.mem.eql(u8, cmd, "encode")) {
        const input = try expectArg(&it, "Missing input dir");
        const output = try expectArg(&it, "Missing output file");

        var algo: []const u8 = "lz4";
        var level: CompressionLevel = .medium;

        while (it.next()) |arg| {
            if (std.mem.eql(u8, arg, "--algo")) {
                algo = try expectArg(&it, "Missing algo value");
            } else if (std.mem.eql(u8, arg, "--level")) {
                const lvl = try expectArg(&it, "Missing level value");
                level = parseLevel(lvl) orelse {
                    std.log.err("Unknown level: {s}", .{lvl});
                    return UsageError.InvalidArgs;
                };
            } else {
                std.log.warn("Ignoring unknown arg: {s}", .{arg});
            }
        }

        var enc = try Encoder.init(alloc);
        defer enc.deinit();
        try enc.encodeDirWithAlgorithm(input, output, algo, level);
    } else if (std.mem.eql(u8, cmd, "decode")) {
        const archive = try expectArg(&it, "Missing archive file");
        const outdir = try expectArg(&it, "Missing output dir");

        var dec = try Decoder.init(alloc);
        defer dec.deinit();
        try dec.decodeDir(archive, outdir);
    } else {
        std.log.err("Unknown command: {s}", .{cmd});
        printUsage();
        return UsageError.InvalidArgs;
    }
}
