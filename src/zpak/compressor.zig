const std = @import("std");
const lz4 = @cImport(@cInclude("lz4.h"));
const lz4hc = @cImport(@cInclude("lz4hc.h"));
const zstd_c = @cImport(@cInclude("zstd.h"));

const Compressor = @This();

pub const Algorithm = enum(u8) {
    lz4,
    zstd,
};

const log = std.log.scoped(.compressor);

allocator: std.mem.Allocator,

const COMPRESSION_ESTIMATE_RATIO = 4;

pub const CompressionLevel = enum {
    low, // Fastest compression, larger output
    medium, // Balanced compression
    high, // Best compression, slower

    pub fn getAcceleration(self: CompressionLevel) c_int {
        return switch (self) {
            .low => 4, // Higher acceleration = faster, less compression
            .medium => 1, // Default acceleration
            .high => 1, // Will use HC mode instead
        };
    }

    pub fn getHCLevel(self: CompressionLevel) c_int {
        return switch (self) {
            .low => unreachable, // Won't use HC mode
            .medium => unreachable, // Won't use HC mode
            .high => 9, // LZ4HC compression level (1-12, 9 is good balance)
        };
    }
};

pub const CompressionError = error{
    CompressionBoundError,
    CompressionFailed,
    DecompressionFailed,
} || std.mem.Allocator.Error;

pub fn init(allocator: std.mem.Allocator) Compressor {
    return .{ .allocator = allocator };
}

pub fn deinit(_: *Compressor) void {
    log.debug("Deinitializing compressor", .{});
}

pub fn compress(self: *Compressor, data: []const u8) CompressionError![]u8 {
    return self.compressWithAlgorithm(data, .lz4, .medium);
}

pub fn compressWithAlgorithm(self: *Compressor, data: []const u8, algorithm: Algorithm, level: CompressionLevel) CompressionError![]u8 {
    log.debug("Compressing {d} bytes with {s} compression using {s}", .{ data.len, @tagName(level), @tagName(algorithm) });

    if (data.len == 0) return try self.allocator.alloc(u8, 0);

    const result = switch (algorithm) {
        .lz4 => {
            const max_size = lz4.LZ4_compressBound(@intCast(data.len));
            if (max_size <= 0) return error.CompressionBoundError;

            const buffer = try self.allocator.alloc(u8, @intCast(max_size));
            errdefer self.allocator.free(buffer);

            const compressed_size = if (level == .high) blk: {
                const hc_level = level.getHCLevel();
                break :blk lz4hc.LZ4_compress_HC(data.ptr, buffer.ptr, @intCast(data.len), @intCast(max_size), hc_level);
            } else blk: {
                const acceleration = level.getAcceleration();
                break :blk lz4.LZ4_compress_fast(data.ptr, buffer.ptr, @intCast(data.len), @intCast(max_size), acceleration);
            };

            if (compressed_size <= 0) {
                return error.CompressionFailed;
            }

            return try self.allocator.realloc(buffer, @intCast(compressed_size));
        },
        .zstd => {
            const max_size = zstd_c.ZSTD_compressBound(data.len);
            const buffer = try self.allocator.alloc(u8, max_size);
            errdefer self.allocator.free(buffer);

            const compressed_size = zstd_c.ZSTD_compress(
                buffer.ptr, // pointer to first byte
                buffer.len, // capacity in bytes
                data.ptr, // pointer to input
                data.len, // size of input
                switch (level) {
                    .low => 1,
                    .medium => 5,
                    .high => 9,
                },
            );

            if (zstd_c.ZSTD_isError(compressed_size) != 0) {
                log.err("Zstandard compression failed: {s}", .{
                    zstd_c.ZSTD_getErrorName(compressed_size),
                });
                return error.CompressionFailed;
            }

            return try self.allocator.realloc(buffer, compressed_size);
        },
    };

    const ratio = @as(f64, @floatFromInt(result.len)) / @as(f64, @floatFromInt(data.len));
    log.debug("Compressed to {d} bytes (ratio: {d:.2}, level: {s}, algorithm: {s})", .{ result.len, ratio, @tagName(level), @tagName(algorithm) });

    return result;
}

pub fn decompress(self: *Compressor, compressed: []const u8) CompressionError![]u8 {
    std.debug.print("Decompressing {d} bytes", .{compressed.len});
    const algorithm = self.detectCompressionAlgorithm(compressed) catch return error.DecompressionFailed;
    return self.decompressWithAlgorithm(compressed, algorithm);
}

pub fn decompressWithAlgorithm(self: *Compressor, compressed: []const u8, algorithm: Algorithm) CompressionError![]u8 {
    log.debug("Decompressing {d} bytes with {s}", .{ compressed.len, @tagName(algorithm) });

    return switch (algorithm) {
        .lz4 => {
            // The LZ4 logic needs a similar fix to avoid guessing buffer size,
            // but we'll focus on the ZSTD error for now.
            // A more robust LZ4 decompressor would also read the original size from a header.
            var size = compressed.len * COMPRESSION_ESTIMATE_RATIO;
            while (size <= compressed.len * 16) : (size *= 2) {
                const buffer = self.allocator.alloc(u8, size) catch continue;
                defer self.allocator.free(buffer);

                const result_size = lz4.LZ4_decompress_safe(compressed.ptr, buffer.ptr, @intCast(compressed.len), @intCast(size));

                if (result_size > 0) {
                    const result = try self.allocator.alloc(u8, @intCast(result_size));
                    @memcpy(result, buffer[0..@intCast(result_size)]);
                    log.debug("Decompressed to {d} bytes", .{result.len});
                    return result;
                }
            }
            return error.DecompressionFailed;
        },
        .zstd => {
            // Zstd's C API defines certain constants in a way that causes an integer
            // overflow error when Zig imports them. To fix this, we'll compare the
            // decompressed size to the raw hexadecimal values directly, bypassing
            // the problematic constants.

            // Use ZSTD_getFrameContentSize to get the exact decompressed size.
            const decompressed_size = zstd_c.ZSTD_getFrameContentSize(compressed.ptr, compressed.len);

            // Check if the size is valid. ZSTD_CONTENTSIZE_ERROR is equivalent to 0xFFFFFFFFFFFFFFFE.
            if (decompressed_size == 0xFFFFFFFFFFFFFFFE) {
                log.err("Zstandard decompression failed: Invalid compressed data", .{});
                return error.DecompressionFailed;
            }
            // ZSTD_CONTENTSIZE_UNKNOWN is equivalent to 0xFFFFFFFFFFFFFFFF.
            if (decompressed_size == 0xFFFFFFFFFFFFFFFF) {
                log.err("Zstandard decompression failed: Unknown decompressed size", .{});
                return error.DecompressionFailed;
            }

            const buffer = try self.allocator.alloc(u8, @intCast(decompressed_size));
            errdefer self.allocator.free(buffer);

            const result_size = zstd_c.ZSTD_decompress(
                buffer.ptr,
                buffer.len,
                compressed.ptr,
                compressed.len,
            );

            if (zstd_c.ZSTD_isError(result_size) != 0) {
                // The `std.fmt.auto` function does not exist in your Zig version.
                // We can use the `%s` format specifier to print a C string directly.
                log.err("Zstandard decompression failed: {s}", .{
                    zstd_c.ZSTD_getErrorName(result_size),
                });
                return error.DecompressionFailed;
            }

            log.debug("Decompressed to {d} bytes", .{result_size});
            return try self.allocator.realloc(buffer, result_size);
        },
    };
}

// Convenience methods for different compression levels
pub fn compressLow(self: *Compressor, data: []const u8, algorithm: Algorithm) CompressionError![]u8 {
    return self.compressWithAlgorithm(data, algorithm, .low);
}

pub fn compressMedium(self: *Compressor, data: []const u8, algorithm: Algorithm) CompressionError![]u8 {
    return self.compressWithAlgorithm(data, algorithm, .medium);
}

pub fn compressHigh(self: *Compressor, data: []const u8, algorithm: Algorithm) CompressionError![]u8 {
    return self.compressWithAlgorithm(data, algorithm, .high);
}

pub fn detectCompressionAlgorithm(_: *Compressor, data: []const u8) CompressionError!Algorithm {
    if (data.len < 4) return error.CompressionFailed;

    std.log.info("Detecting compression algorithm for data", .{});

    // Check for Zstandard magic number
    if (std.mem.eql(u8, data[0..4], "\x28\xB5\x2F\xFD")) {
        return .zstd;
    }

    // Default to LZ4
    return .lz4;
}
