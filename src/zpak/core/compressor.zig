const std = @import("std");
const algorithm = @import("../compression/algorithm.zig");
const registry_mod = @import("../compression/registry.zig");

const IAlgorithm = algorithm.IAlgorithm;
const CompressionLevel = algorithm.CompressionLevel;
pub const CompressionError = algorithm.CompressionError;
const CompressionResult = algorithm.CompressionResult;
const AlgorithmRegistry = registry_mod.AlgorithmRegistry;

const log = std.log.scoped(.compressor);

pub const Compressor = @This();

allocator: std.mem.Allocator,
registry: AlgorithmRegistry,

pub fn init(allocator: std.mem.Allocator) !Compressor {
    var registry = AlgorithmRegistry.init(allocator);
    try registry.registerDefaults();

    return Compressor{
        .allocator = allocator,
        .registry = registry,
    };
}

pub fn deinit(self: *Compressor) void {
    self.registry.deinit();
    log.debug("Deinitializing compressor", .{});
}

pub fn compress(self: *Compressor, data: []const u8) CompressionError!CompressionResult {
    return self.compressWithName(data, "LZ4", .medium);
}

pub fn compressWithId(self: *Compressor, data: []const u8, algorithm_id: u8, level: CompressionLevel) CompressionError!CompressionResult {
    const algo = self.registry.getById(algorithm_id) orelse return error.CompressionFailed;

    log.debug("Compressing {d} bytes with algorithm ID {d} using {s} level", .{ data.len, algorithm_id, @tagName(level) });

    const compressed = try algo.compress(self.allocator, data, level);

    const ratio = @as(f64, @floatFromInt(compressed.len)) / @as(f64, @floatFromInt(data.len));
    log.debug("Compressed to {d} bytes (ratio: {d:.2})", .{ compressed.len, ratio });

    return CompressionResult{
        .data = compressed,
        .original_size = data.len,
        .compressed_size = compressed.len,
        .algorithm_id = algorithm_id,
    };
}

pub fn compressWithName(self: *Compressor, data: []const u8, algorithm_name: []const u8, level: CompressionLevel) CompressionError!CompressionResult {
    const algo = self.registry.getByName(algorithm_name) orelse return error.CompressionFailed;
    return self.compressWithId(data, algo.getId(), level);
}

pub fn decompress(self: *Compressor, compressed: []const u8) CompressionError![]u8 {
    log.debug("Decompressing {d} bytes", .{compressed.len});

    const algo = self.registry.detectAlgorithm(compressed) orelse return error.DecompressionFailed;

    const result = try algo.decompress(self.allocator, compressed, null);
    log.debug("Decompressed to {d} bytes using {s}", .{ result.len, algo.getName() });

    return result;
}

pub fn decompressWithId(self: *Compressor, compressed: []const u8, algorithm_id: u8, original_size: ?usize) CompressionError![]u8 {
    const algo = self.registry.getById(algorithm_id) orelse return error.DecompressionFailed;

    log.debug("Decompressing {d} bytes with algorithm ID {d}", .{ compressed.len, algorithm_id });

    const result = try algo.decompress(self.allocator, compressed, original_size);
    log.debug("Decompressed to {d} bytes", .{result.len});

    return result;
}

pub fn decompressWithName(self: *Compressor, compressed: []const u8, algorithm_name: []const u8, original_size: ?usize) CompressionError![]u8 {
    const algo = self.registry.getByName(algorithm_name) orelse return error.DecompressionFailed;
    return self.decompressWithId(compressed, algo.getId(), original_size);
}

pub fn listAvailableAlgorithms(self: *Compressor) []IAlgorithm {
    return self.registry.listAlgorithms();
}

// Convenience methods
pub fn compressLow(self: *Compressor, data: []const u8, algorithm_name: []const u8) CompressionError!CompressionResult {
    return self.compressWithName(data, algorithm_name, .low);
}

pub fn compressMedium(self: *Compressor, data: []const u8, algorithm_name: []const u8) CompressionError!CompressionResult {
    return self.compressWithName(data, algorithm_name, .medium);
}

pub fn compressHigh(self: *Compressor, data: []const u8, algorithm_name: []const u8) CompressionError!CompressionResult {
    return self.compressWithName(data, algorithm_name, .high);
}
