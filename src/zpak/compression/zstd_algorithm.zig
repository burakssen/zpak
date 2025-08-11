const std = @import("std");
const algorithm = @import("algorithm.zig");
const zstd_c = @cImport(@cInclude("zstd.h"));

const CompressionLevel = algorithm.CompressionLevel;
const CompressionError = algorithm.CompressionError;

pub const ZstdAlgorithm = @This();
const ALGORITHM_ID: u8 = 2;
const NAME = "zstd";
const MAGIC_NUMBER = [4]u8{ 0x28, 0xB5, 0x2F, 0xFD };

pub fn compress(self: *ZstdAlgorithm, allocator: std.mem.Allocator, data: []const u8, level: CompressionLevel) CompressionError![]u8 {
    _ = self;
    if (data.len == 0) return try allocator.alloc(u8, 0);

    const max_size = zstd_c.ZSTD_compressBound(data.len);
    const buffer = try allocator.alloc(u8, max_size);
    errdefer allocator.free(buffer);

    const compression_level: c_int = switch (level) {
        .low => 1,
        .medium => 5,
        .high => 9,
    };

    const compressed_size = zstd_c.ZSTD_compress(
        buffer.ptr,
        buffer.len,
        data.ptr,
        data.len,
        compression_level,
    );

    if (zstd_c.ZSTD_isError(compressed_size) != 0) {
        return error.CompressionFailed;
    }

    return try allocator.realloc(buffer, compressed_size);
}

pub fn decompress(self: *ZstdAlgorithm, allocator: std.mem.Allocator, data: []const u8, original_size: ?usize) CompressionError![]u8 {
    _ = self;
    _ = original_size; // ZSTD can determine size from frame

    const decompressed_size = zstd_c.ZSTD_getFrameContentSize(data.ptr, data.len);

    // Check for error constants using raw hex values
    if (decompressed_size == 0xFFFFFFFFFFFFFFFE) {
        return error.InvalidData;
    }
    if (decompressed_size == 0xFFFFFFFFFFFFFFFF) {
        return error.UnknownSize;
    }

    const buffer = try allocator.alloc(u8, @intCast(decompressed_size));
    errdefer allocator.free(buffer);

    const result_size = zstd_c.ZSTD_decompress(
        buffer.ptr,
        buffer.len,
        data.ptr,
        data.len,
    );

    if (zstd_c.ZSTD_isError(result_size) != 0) {
        return error.DecompressionFailed;
    }

    return try allocator.realloc(buffer, result_size);
}

pub fn getBound(self: *ZstdAlgorithm, input_size: usize) usize {
    _ = self;
    return zstd_c.ZSTD_compressBound(input_size);
}

pub fn getId(self: *ZstdAlgorithm) u8 {
    _ = self;
    return ALGORITHM_ID;
}

pub fn getName(self: *ZstdAlgorithm) []const u8 {
    _ = self;
    return NAME;
}

pub fn detectFormat(self: *ZstdAlgorithm, data: []const u8) bool {
    _ = self;
    if (data.len < 4) return false;
    return std.mem.eql(u8, data[0..4], &MAGIC_NUMBER);
}
