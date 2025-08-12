const std = @import("std");
const algorithm = @import("algorithm.zig");
const Lz4 = @import("lz4.zig");
const Zstd = @import("zstd.zig");
const Lzma = @import("lzma.zig");
const Brotli = @import("brotli.zig");

const IAlgorithm = algorithm.IAlgorithm;
const CompressionError = algorithm.CompressionError;

pub const AlgorithmRegistry = @This();

algorithms: std.ArrayList(IAlgorithm),
allocator: std.mem.Allocator,

// Static instances of algorithms
lz4_instance: Lz4,
zstd_instance: Zstd,
lzma_instance: Lzma,
brotli_instance: Brotli,

pub fn init(allocator: std.mem.Allocator) AlgorithmRegistry {
    return .{
        .algorithms = std.ArrayList(IAlgorithm).init(allocator),
        .allocator = allocator,
        .lz4_instance = Lz4{},
        .zstd_instance = Zstd{},
        .lzma_instance = Lzma{},
        .brotli_instance = Brotli{},
    };
}

pub fn deinit(self: *AlgorithmRegistry) void {
    self.algorithms.deinit();
}

pub fn registerDefaults(self: *AlgorithmRegistry) !void {
    try self.algorithms.append(IAlgorithm.init(&self.lz4_instance));
    try self.algorithms.append(IAlgorithm.init(&self.zstd_instance));
    try self.algorithms.append(IAlgorithm.init(&self.lzma_instance));
    try self.algorithms.append(IAlgorithm.init(&self.brotli_instance));
}

pub fn getById(self: *AlgorithmRegistry, id: u8) ?IAlgorithm {
    for (self.algorithms.items) |algo| {
        if (algo.getId() == id) {
            return algo;
        }
    }
    return null;
}

pub fn getByName(self: *AlgorithmRegistry, name: []const u8) ?IAlgorithm {
    for (self.algorithms.items) |algo| {
        if (std.mem.eql(u8, algo.getName(), name)) {
            return algo;
        }
    }
    return null;
}

pub fn detectAlgorithm(self: *AlgorithmRegistry, data: []const u8) ?IAlgorithm {
    for (self.algorithms.items) |algo| {
        if (algo.detectFormat(data)) {
            return algo;
        }
    }
    return null;
}

pub fn listAlgorithms(self: *AlgorithmRegistry) []IAlgorithm {
    return self.algorithms.items;
}
