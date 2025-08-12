const std = @import("std");
const algorithm = @import("algorithm.zig");
const lz4_c = @cImport({
    @cInclude("lz4.h");
    @cInclude("lz4hc.h");
});

const CompressionLevel = algorithm.CompressionLevel;
const CompressionError = algorithm.CompressionError;

const Lz4 = @This();

const ALGORITHM_ID: u8 = 1;
const NAME = "lz4";

pub fn compress(self: *Lz4, allocator: std.mem.Allocator, data: []const u8, level: CompressionLevel) CompressionError![]u8 {
    _ = self;
    if (data.len == 0) return try allocator.alloc(u8, 0);

    const max_size = lz4_c.LZ4_compressBound(@intCast(data.len));
    if (max_size <= 0) return error.CompressionBoundError;

    const buffer = try allocator.alloc(u8, @intCast(max_size));
    errdefer allocator.free(buffer);

    const compressed_size = switch (level) {
        .high => lz4_c.LZ4_compress_HC(data.ptr, buffer.ptr, @intCast(data.len), @intCast(max_size), 9 // HC level
        ),
        .medium => lz4_c.LZ4_compress_fast(data.ptr, buffer.ptr, @intCast(data.len), @intCast(max_size), 1 // acceleration
        ),
        .low => lz4_c.LZ4_compress_fast(data.ptr, buffer.ptr, @intCast(data.len), @intCast(max_size), 4 // acceleration
        ),
    };

    if (compressed_size <= 0) {
        return error.CompressionFailed;
    }

    return try allocator.realloc(buffer, @intCast(compressed_size));
}

pub fn decompress(self: *Lz4, allocator: std.mem.Allocator, data: []const u8, original_size: ?usize) CompressionError![]u8 {
    _ = self;

    if (original_size) |size| {
        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);

        const result_size = lz4_c.LZ4_decompress_safe(data.ptr, buffer.ptr, @intCast(data.len), @intCast(size));

        if (result_size <= 0) {
            return error.DecompressionFailed;
        }

        return try allocator.realloc(buffer, @intCast(result_size));
    }

    // Fallback: try increasing buffer sizes
    var size = data.len * 4;
    while (size <= data.len * 16) : (size *= 2) {
        const buffer = allocator.alloc(u8, size) catch continue;
        defer allocator.free(buffer);

        const result_size = lz4_c.LZ4_decompress_safe(data.ptr, buffer.ptr, @intCast(data.len), @intCast(size));

        if (result_size > 0) {
            const result = try allocator.alloc(u8, @intCast(result_size));
            @memcpy(result, buffer[0..@intCast(result_size)]);
            return result;
        }
    }

    return error.DecompressionFailed;
}

pub fn getBound(self: *Lz4, input_size: usize) usize {
    _ = self;
    const bound = lz4_c.LZ4_compressBound(@intCast(input_size));
    return if (bound > 0) @intCast(bound) else input_size + input_size / 255 + 16;
}

pub fn getId(self: *Lz4) u8 {
    _ = self;
    return ALGORITHM_ID;
}

pub fn getName(self: *Lz4) []const u8 {
    _ = self;
    return NAME;
}

pub fn detectFormat(self: *Lz4, data: []const u8) bool {
    _ = self;
    // LZ4 doesn't have a reliable magic header for raw frames; avoid false positives.
    _ = data;
    return false;
}
