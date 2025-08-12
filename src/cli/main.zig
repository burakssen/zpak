const std = @import("std");
const Encoder = @import("zpak").Encoder;
const Decoder = @import("zpak").Decoder;

const ArgumentType = @import("zarg").ArgumentType;
const Zarg = @import("zarg").Zarg;

const MyError = error{InvalidInput};

const MainArgs = enum {
    help,
    pub fn argType(self: @This()) ArgumentType {
        return switch (self) {
            .help => .Bool,
        };
    }
};

const EncodeArgs = enum {
    input_dir,
    output_file,
    algorithm,
    pub fn argType(self: @This()) ArgumentType {
        return switch (self) {
            .input_dir => .String,
            .output_file => .String,
            .algorithm => .String,
        };
    }
};

const DecodeArgs = enum {
    input_file,
    output_dir,
    pub fn argType(self: @This()) ArgumentType {
        return switch (self) {
            .input_file => .String,
            .output_dir => .String,
        };
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        const status = gpa.deinit();
        switch (status) {
            .ok => std.log.info("Allocator deinitialized successfully", .{}),
            .leak => std.log.err("Memory leak detected during allocator deinit", .{}),
        }
    }

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    var zarg = try Zarg(MainArgs).init(allocator);
    defer zarg.deinit();

    var encode_parser = try Zarg(EncodeArgs).init(allocator);
    defer encode_parser.deinit();

    var decode_parser = try Zarg(DecodeArgs).init(allocator);
    defer decode_parser.deinit();

    try zarg.addSubcommand("encode", &encode_parser);
    try zarg.addSubcommand("decode", &decode_parser);

    var argv = std.ArrayList([:0]u8).init(allocator);
    defer {
        for (argv.items) |item| {
            allocator.free(item);
        }
        argv.deinit();
    }

    while (args.next()) |arg| {
        const arg_str = try std.mem.concatWithSentinel(allocator, u8, &.{arg}, 0);
        try argv.append(arg_str);
    }

    try zarg.parse(argv.items);

    if (zarg.getValue(.help)) |_| {
        zarg.printHelp();
    }

    _ = try zarg.on("encode", Zarg(EncodeArgs), struct {
        pub fn handler(z: *Zarg(EncodeArgs), alloc: std.mem.Allocator) !void {
            var encoder = try Encoder.init(alloc);
            defer encoder.deinit();
            encoder.setDefaultAlgorithm(z.getValue(.algorithm) orelse "lz4");
            const input_dir = z.getValue(.input_dir) orelse return error.InvalidInput;
            const output_file = z.getValue(.output_file) orelse return error.InvalidInput;
            try encoder.encodeDir(input_dir, output_file);
        }
    });

    _ = try zarg.on("decode", Zarg(DecodeArgs), struct {
        pub fn handler(z: *Zarg(DecodeArgs), alloc: std.mem.Allocator) !void {
            var decoder = try Decoder.init(alloc);
            defer decoder.deinit();
            const input_file = z.getValue(.input_file) orelse return error.InvalidInput;
            const output_dir = z.getValue(.output_dir) orelse return error.InvalidInput;
            try decoder.decodeDir(input_file, output_dir);
        }
    });
}

fn printHelp() void {
    std.log.info("Usage: zpak <command> [options]", .{});
    std.log.info("Commands:", .{});
    std.log.info("  encode <input_dir> <output_file> [algorithm]", .{});
    std.log.info("    algorithms: lz4, zstd, zlib (default: lz4)", .{});
    std.log.info("  decode <input_file> <output_dir>", .{});
    std.log.info("", .{});
    std.log.info("Examples:", .{});
    std.log.info("  zpak encode my_folder archive.zpak zstd", .{});
    std.log.info("  zpak decode archive.zpak extracted_folder", .{});
}
