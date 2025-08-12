const std = @import("std");
const algorithm = @import("algorithm.zig");

const brotli_c = @cImport({
    @cInclude("brotli/decode.h");
    @cInclude("brotli/encode.h");
});

const CompressionLevel = algorithm.CompressionLevel;
const CompressionError = algorithm.CompressionError;

const Brotli = @This();

const ALGORITHM_ID: u8 = 4;
const NAME = "brotli";

// Brotli has no magic header. We therefore do not add any custom prefix.
// However, some legacy archives may contain a custom prefix used by older versions.
const LEGACY_BROTLI_MAGIC = [_]u8{ 0xCE, 0xB2, 0xCF, 0x81 }; // legacy-only recognition

pub fn compress(_: *Brotli, allocator: std.mem.Allocator, data: []const u8, level: CompressionLevel) CompressionError![]u8 {
    const quality: c_int = switch (level) {
        .low => 3,
        .medium => 6,
        .high => 11,
    };
    const lgwin: c_int = 22; // default Brotli window size

    var max_size = brotli_c.BrotliEncoderMaxCompressedSize(data.len);
    if (max_size == 0) max_size = data.len + 1024;

    // Reserve space for compressed data only
    const out_buf = try allocator.alloc(u8, max_size);
    errdefer allocator.free(out_buf);

    // Encode into output buffer
    var encoded_size: usize = max_size;
    // BrotliEncoderCompress returns 0 on failure, non-zero on success
    if (brotli_c.BrotliEncoderCompress(quality, lgwin, brotli_c.BROTLI_MODE_GENERIC, data.len, data.ptr, &encoded_size, out_buf.ptr) == 0) {
        return error.CompressionFailed;
    }

    // Explicitly check for realloc error
    return allocator.realloc(out_buf, encoded_size) catch |err| {
        // If realloc fails, free the buffer and return the error
        allocator.free(out_buf);
        return err;
    };
}
pub fn decompress(_: *Brotli, allocator: std.mem.Allocator, data: []const u8, _: ?usize) CompressionError![]u8 {
    // Handle legacy prefix if present
    const compressed_data = blk: {
        if (data.len >= LEGACY_BROTLI_MAGIC.len and std.mem.eql(u8, data[0..LEGACY_BROTLI_MAGIC.len], &LEGACY_BROTLI_MAGIC)) {
            break :blk data[LEGACY_BROTLI_MAGIC.len..];
        }
        break :blk data;
    };

    // Use streaming API for robustness
    const state = brotli_c.BrotliDecoderCreateInstance(null, null, null) orelse return error.DecompressionFailed;
    defer brotli_c.BrotliDecoderDestroyInstance(state);

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    const chunk_size: usize = 64 * 1024;
    var in_available: usize = compressed_data.len;
    var in_next: [*c]const u8 = @ptrCast(compressed_data.ptr);

    var out_available: usize = 0;
    var out_next: [*c]u8 = undefined;

    while (true) {
        if (out_available == 0) {
            // grow output by chunk
            const start_len = out.items.len;
            try out.resize(start_len + chunk_size);
            out_available = chunk_size;
            out_next = out.items.ptr + start_len;
        }

        const result = brotli_c.BrotliDecoderDecompressStream(
            state,
            @ptrCast(&in_available),
            @ptrCast(&in_next),
            @ptrCast(&out_available),
            @ptrCast(&out_next),
            null,
        );

        if (result == brotli_c.BROTLI_DECODER_RESULT_SUCCESS) {
            // Trim to actual produced size
            const produced = out.items.len - out_available;
            try out.resize(produced);
            return out.toOwnedSlice();
        } else if (result == brotli_c.BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT) {
            // loop will allocate another chunk
            continue;
        } else if (result == brotli_c.BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT) {
            // Should not happen with full input, but allow loop to continue if more output is needed
            if (in_available == 0) {
                // If no input remains but decoder still needs input, it's an error
                return error.DecompressionFailed;
            }
        } else {
            return error.DecompressionFailed;
        }
    }
}

pub fn getBound(_: *Brotli, input_size: usize) usize {
    // Brotli provides a max bound function
    const bound = brotli_c.BrotliEncoderMaxCompressedSize(input_size);
    return if (bound == 0) input_size + 1024 else bound;
}

pub fn getId(_: *Brotli) u8 {
    return ALGORITHM_ID;
}

pub fn getName(_: *Brotli) []const u8 {
    return NAME;
}

pub fn detectFormat(_: *Brotli, data: []const u8) bool {
    // Brotli lacks a reliable magic; return false to avoid false positives.
    _ = data;
    return false;
}
