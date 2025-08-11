const std = @import("std");
const algorithm = @import("algorithm.zig");
const LZ4Algorithm = @import("lz4_algorithm.zig").LZ4Algorithm;
const ZstdAlgorithm = @import("zstd_algorithm.zig").ZstdAlgorithm;

const IAlgorithm = algorithm.IAlgorithm;
const CompressionError = algorithm.CompressionError;

pub const AlgorithmRegistry = @This();

algorithms: std.ArrayList(IAlgorithm),
allocator: std.mem.Allocator,

// Static instances of algorithms
lz4_instance: LZ4Algorithm,
zstd_instance: ZstdAlgorithm,

pub fn init(allocator: std.mem.Allocator) AlgorithmRegistry {
    return .{
        .algorithms = std.ArrayList(IAlgorithm).init(allocator),
        .allocator = allocator,
        .lz4_instance = LZ4Algorithm{},
        .zstd_instance = ZstdAlgorithm{},
    };
}

pub fn deinit(self: *AlgorithmRegistry) void {
    self.algorithms.deinit();
}

pub fn registerDefaults(self: *AlgorithmRegistry) !void {
    try self.algorithms.append(IAlgorithm.init(&self.lz4_instance));
    try self.algorithms.append(IAlgorithm.init(&self.zstd_instance));
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
