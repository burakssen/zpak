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
        .medium => 3, // slightly lower for better speed
        .high => 9,
    };

    if (lzma_c.lzma_easy_encoder(&stream, preset, lzma_c.LZMA_CHECK_CRC64) != lzma_c.LZMA_OK) {
        return error.CompressionFailed;
    }

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    const chunk_size: usize = 64 * 1024;
    const in_left: usize = data.len;
    const in_next: [*]const u8 = data.ptr;

    var out_avail: usize = 0;
    var out_next: [*]u8 = undefined;

    stream.next_in = in_next;
    stream.avail_in = @intCast(in_left);

    while (true) {
        if (out_avail == 0) {
            const start_len = out.items.len;
            try out.resize(start_len + chunk_size);
            out_avail = chunk_size;
            out_next = out.items.ptr + start_len;
        }

        stream.next_out = out_next;
        stream.avail_out = @intCast(out_avail);

        const ret = lzma_c.lzma_code(&stream, lzma_c.LZMA_FINISH);

        // Update out pointers based on how much was written
        const produced_now = out_avail - @as(usize, @intCast(stream.avail_out));
        out_avail -= produced_now;
        out_next += produced_now;

        switch (ret) {
            lzma_c.LZMA_OK => {
                // Need more output space; loop will allocate more
                if (stream.avail_out == 0) continue;
            },
            lzma_c.LZMA_STREAM_END => {
                // Trim to produced size and return
                const produced_total = out.items.len - out_avail;
                try out.resize(produced_total);
                return out.toOwnedSlice();
            },
            else => return error.CompressionFailed,
        }
    }
}

pub fn decompress(_: *Lzma, allocator: std.mem.Allocator, data: []const u8, original_size: ?usize) CompressionError![]u8 {
    var stream = std.mem.zeroInit(lzma_c.lzma_stream, .{});
    defer _ = lzma_c.lzma_end(&stream);

    // Limit to ~unlimited mem (UINT64_MAX) and allow multiple concatenated streams
    if (lzma_c.lzma_stream_decoder(&stream, ~@as(c_ulonglong, 0), 0) != lzma_c.LZMA_OK) {
        return error.DecompressionFailed;
    }

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    const chunk_size: usize = 64 * 1024;
    if (original_size) |hint| {
        // Pre-reserve to reduce reallocations when size is known
        try out.ensureTotalCapacity(@intCast(@max(hint, chunk_size)));
        try out.resize(0);
    }

    const in_left: usize = data.len;
    const in_next: [*]const u8 = data.ptr;

    var out_avail: usize = 0;
    var out_next: [*]u8 = undefined;

    stream.next_in = in_next;
    stream.avail_in = @intCast(in_left);

    while (true) {
        if (out_avail == 0) {
            const start_len = out.items.len;
            try out.resize(start_len + chunk_size);
            out_avail = chunk_size;
            out_next = out.items.ptr + start_len;
        }

        stream.next_out = out_next;
        stream.avail_out = @intCast(out_avail);

        const ret = lzma_c.lzma_code(&stream, lzma_c.LZMA_RUN);

        const produced_now = out_avail - @as(usize, @intCast(stream.avail_out));
        out_avail -= produced_now;
        out_next += produced_now;

        switch (ret) {
            lzma_c.LZMA_OK => {
                // Need more output space or more input; loop continues
                continue;
            },
            lzma_c.LZMA_STREAM_END => {
                const produced_total = out.items.len - out_avail;
                try out.resize(produced_total);
                return out.toOwnedSlice();
            },
            else => return error.DecompressionFailed,
        }
    }
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
