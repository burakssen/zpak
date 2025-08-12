const std = @import("std");
const algorithm = @import("algorithm.zig");

const lzma_c = @cImport({
    @cInclude("lzma.h");
});

const CompressionLevel = algorithm.CompressionLevel;
const CompressionError = algorithm.CompressionError;

const Lzma = @This();

const ALGORITHM_ID: u8 = 3;
const NAME = "lzma";
const XZ_MAGIC = [_]u8{ 0xFD, '7', 'z', 'X', 'Z', 0x00 };

pub fn compress(_: *Lzma, allocator: std.mem.Allocator, data: []const u8, level: CompressionLevel) CompressionError![]u8 {
    var stream = std.mem.zeroInit(lzma_c.lzma_stream, .{});
    defer _ = lzma_c.lzma_end(&stream);

    const preset: c_uint = switch (level) {
        .low => 1,
        .medium => 5,
        .high => 9,
    };

    if (lzma_c.lzma_easy_encoder(&stream, preset, lzma_c.LZMA_CHECK_CRC64) != lzma_c.LZMA_OK) {
        return error.CompressionFailed;
    }

    // Over-allocate: compressed data <= input + overhead
    const out_buf = try allocator.alloc(u8, data.len + 1024);
    errdefer allocator.free(out_buf);

    stream.next_in = data.ptr;
    stream.avail_in = @intCast(data.len);

    stream.next_out = out_buf.ptr;
    stream.avail_out = @intCast(out_buf.len);

    const ret = lzma_c.lzma_code(&stream, lzma_c.LZMA_FINISH);
    if (ret != lzma_c.LZMA_STREAM_END) return error.CompressionFailed;

    return try allocator.realloc(out_buf, out_buf.len - stream.avail_out);
}

pub fn decompress(_: *Lzma, allocator: std.mem.Allocator, data: []const u8, original_size: ?usize) CompressionError![]u8 {
    var stream = std.mem.zeroInit(lzma_c.lzma_stream, .{});
    defer _ = lzma_c.lzma_end(&stream);

    // Limit to ~unlimited mem (UINT64_MAX) and allow multiple concatenated streams
    if (lzma_c.lzma_stream_decoder(&stream, ~@as(c_ulonglong, 0), 0) != lzma_c.LZMA_OK) {
        return error.DecompressionFailed;
    }

    const alloc_size = original_size orelse (data.len * 3); // heuristic
    const out_buf = try allocator.alloc(u8, alloc_size);
    errdefer allocator.free(out_buf);

    stream.next_in = data.ptr;
    stream.avail_in = @intCast(data.len);

    stream.next_out = out_buf.ptr;
    stream.avail_out = @intCast(out_buf.len);

    const ret = lzma_c.lzma_code(&stream, lzma_c.LZMA_FINISH);
    if (ret != lzma_c.LZMA_STREAM_END) return error.DecompressionFailed;

    return try allocator.realloc(out_buf, out_buf.len - stream.avail_out);
}

pub fn getBound(_: *Lzma, input_size: usize) usize {
    return input_size + 1024;
}

pub fn getId(self: *Lzma) u8 {
    _ = self;
    return ALGORITHM_ID;
}

pub fn getName(self: *Lzma) []const u8 {
    _ = self;
    return NAME;
}

pub fn detectFormat(_: *Lzma, data: []const u8) bool {
    return data.len >= XZ_MAGIC.len and std.mem.eql(u8, data[0..XZ_MAGIC.len], &XZ_MAGIC);
}
