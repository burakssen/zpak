const std = @import("std");
const algorithm = @import("algorithm.zig");
const lz4 = @cImport(@cInclude("lz4.h"));
const lz4hc = @cImport(@cInclude("lz4hc.h"));

const CompressionLevel = algorithm.CompressionLevel;
const CompressionError = algorithm.CompressionError;

pub const LZ4Algorithm = @This();
const ALGORITHM_ID: u8 = 1;
const NAME = "LZ4";

pub fn compress(self: *LZ4Algorithm, allocator: std.mem.Allocator, data: []const u8, level: CompressionLevel) CompressionError![]u8 {
    _ = self;
    if (data.len == 0) return try allocator.alloc(u8, 0);

    const max_size = lz4.LZ4_compressBound(@intCast(data.len));
    if (max_size <= 0) return error.CompressionBoundError;

    const buffer = try allocator.alloc(u8, @intCast(max_size));
    errdefer allocator.free(buffer);

    const compressed_size = switch (level) {
        .high => lz4hc.LZ4_compress_HC(data.ptr, buffer.ptr, @intCast(data.len), @intCast(max_size), 9 // HC level
        ),
        .medium => lz4.LZ4_compress_fast(data.ptr, buffer.ptr, @intCast(data.len), @intCast(max_size), 1 // acceleration
        ),
        .low => lz4.LZ4_compress_fast(data.ptr, buffer.ptr, @intCast(data.len), @intCast(max_size), 4 // acceleration
        ),
    };

    if (compressed_size <= 0) {
        return error.CompressionFailed;
    }

    return try allocator.realloc(buffer, @intCast(compressed_size));
}

pub fn decompress(self: *LZ4Algorithm, allocator: std.mem.Allocator, data: []const u8, original_size: ?usize) CompressionError![]u8 {
    _ = self;

    if (original_size) |size| {
        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);

        const result_size = lz4.LZ4_decompress_safe(data.ptr, buffer.ptr, @intCast(data.len), @intCast(size));

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

        const result_size = lz4.LZ4_decompress_safe(data.ptr, buffer.ptr, @intCast(data.len), @intCast(size));

        if (result_size > 0) {
            const result = try allocator.alloc(u8, @intCast(result_size));
            @memcpy(result, buffer[0..@intCast(result_size)]);
            return result;
        }
    }

    return error.DecompressionFailed;
}

pub fn getBound(self: *LZ4Algorithm, input_size: usize) usize {
    _ = self;
    const bound = lz4.LZ4_compressBound(@intCast(input_size));
    return if (bound > 0) @intCast(bound) else input_size + input_size / 255 + 16;
}

pub fn getId(self: *LZ4Algorithm) u8 {
    _ = self;
    return ALGORITHM_ID;
}

pub fn getName(self: *LZ4Algorithm) []const u8 {
    _ = self;
    return NAME;
}

pub fn detectFormat(self: *LZ4Algorithm, data: []const u8) bool {
    _ = self;
    // LZ4 doesn't have a magic header, so we'll use this as a fallback
    // or implement a heuristic based on data patterns
    return data.len > 0;
}
