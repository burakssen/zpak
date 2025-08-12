const std = @import("std");
const Encoder = @import("zpak").Encoder;
const Decoder = @import("zpak").Decoder;
const MyError = error{InvalidInput};

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

    // Skip program name
    _ = args.next();
    const command = args.next();
    const first_arg = args.next();
    const second_arg = args.next();
    const algorithm_arg = args.next();

    if (command) |cmd| {
        if (std.mem.eql(u8, cmd, "encode")) {
            if (first_arg == null or second_arg == null) {
                std.log.err("Usage: encode <input_dir> <output_file> [algorithm]", .{});
                return MyError.InvalidInput;
            }

            var encoder = try Encoder.init(allocator);
            defer encoder.deinit();

            // Set the algorithm if provided
            if (algorithm_arg) |algo| {
                if (std.mem.eql(u8, algo, "zstd")) {
                    encoder.setDefaultAlgorithm("zstd");
                } else if (std.mem.eql(u8, algo, "lz4")) {
                    encoder.setDefaultAlgorithm("lz4");
                } else if (std.mem.eql(u8, algo, "zlib")) {
                    encoder.setDefaultAlgorithm("zlib");
                } else if (std.mem.eql(u8, algo, "lzma")) {
                    encoder.setDefaultAlgorithm("lzma");
                } else if (std.mem.eql(u8, algo, "brotli")) {
                    encoder.setDefaultAlgorithm("brotli");
                } else {
                    std.log.err("Unknown algorithm: {s}. Available: lz4, zstd, zlib", .{algo});
                    return MyError.InvalidInput;
                }
            }

            // Encode the directory
            try encoder.encodeDir(first_arg.?, second_arg.?);
            std.log.info("Successfully encoded directory '{s}' to '{s}'", .{ first_arg.?, second_arg.? });
        } else if (std.mem.eql(u8, cmd, "decode")) {
            if (first_arg == null or second_arg == null) {
                std.log.err("Usage: decode <input_file> <output_dir>", .{});
                return MyError.InvalidInput;
            }

            var decoder = try Decoder.init(allocator);
            defer decoder.deinit();
            try decoder.decodeDir(first_arg.?, second_arg.?);
            std.log.info("Successfully decoded '{s}' to directory '{s}'", .{ first_arg.?, second_arg.? });
        } else {
            std.log.err("Unknown command: {s}", .{cmd});
            printHelp();
            return MyError.InvalidInput;
        }
    } else {
        std.log.warn("No command provided", .{});
        printHelp();
        return MyError.InvalidInput;
    }
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
