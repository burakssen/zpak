const std = @import("std");
const Serializer = @import("core/serializer.zig");
const Compressor = @import("core/compressor.zig").Compressor;
const Archive = @import("core/archive.zig");
const FileUtils = @import("io/file_utils.zig");
const compression = @import("compression/algorithm.zig");

const Encoder = @This();
const log = std.log.scoped(.encoder);

allocator: std.mem.Allocator,
serializer: Serializer,
compressor: Compressor,
file_utils: FileUtils,
default_algorithm: []const u8,
default_level: compression.CompressionLevel,

const EncoderError = error{
    PathNotFound,
    CompressionBoundError,
    UnsupportedType,
    CompressionFailed,
    InvalidArchive,
    AlgorithmNotFound,
} ||
    std.mem.Allocator.Error ||
    FileUtils.FileError ||
    Archive.ArchiveError ||
    compression.CompressionError;

pub fn init(allocator: std.mem.Allocator) EncoderError!Encoder {
    log.debug("Initializing encoder", .{});
    return .{
        .allocator = allocator,
        .serializer = Serializer.init(allocator),
        .compressor = try Compressor.init(allocator),
        .file_utils = FileUtils.init(allocator),
        .default_algorithm = "LZ4",
        .default_level = .medium,
    };
}

pub fn deinit(self: *Encoder) void {
    log.debug("Deinitializing encoder", .{});
    self.serializer.deinit();
    self.compressor.deinit();
    self.file_utils.deinit();
}

pub fn setDefaultAlgorithm(self: *Encoder, algorithm_name: []const u8) void {
    self.default_algorithm = algorithm_name;
}

pub fn setDefaultLevel(self: *Encoder, level: compression.CompressionLevel) void {
    self.default_level = level;
}

pub fn encode(self: *Encoder, comptime T: type, data: *const T) EncoderError![]u8 {
    return self.encodeWithAlgorithm(T, data, self.default_algorithm, self.default_level);
}

pub fn encodeWithAlgorithm(self: *Encoder, comptime T: type, data: *const T, algorithm_name: []const u8, level: compression.CompressionLevel) EncoderError![]u8 {
    log.debug("Encoding object: {s} with {s} compression", .{ @typeName(T), algorithm_name });

    const serialized = try self.serializer.serialize(T, data);
    defer self.allocator.free(serialized);

    const result = try self.compressor.compressWithName(serialized, algorithm_name, level);
    return result.data;
}

pub fn encodeDir(self: *Encoder, input_path: []const u8, output_path: []const u8) EncoderError!void {
    return self.encodeDirWithAlgorithm(input_path, output_path, self.default_algorithm, self.default_level);
}

pub fn encodeDirWithAlgorithm(self: *Encoder, input_path: []const u8, output_path: []const u8, algorithm_name: []const u8, level: compression.CompressionLevel) EncoderError!void {
    log.debug("Encoding directory: {s} -> {s} using {s} compression", .{ input_path, output_path, algorithm_name });

    var archive = Archive.init(self.allocator);
    defer archive.deinit();

    const algo = self.compressor.registry.getByName(algorithm_name) orelse {
        log.err("Algorithm not found: {s}", .{algorithm_name});
        return error.AlgorithmNotFound;
    };

    // Set the algorithm in the archive manifest
    archive.setCompressionAlgorithm(algo);

    try self.collectFiles(input_path, "", &archive);
    try self.writeArchive(&archive, output_path, algorithm_name, level);
}

// Get compression information about the encoder
pub fn getCompressionInfo(self: *Encoder) struct {
    default_algorithm: []const u8,
    default_level: compression.CompressionLevel,
    available_algorithms: []compression.ICompressionAlgorithm,
} {
    return .{
        .default_algorithm = self.default_algorithm,
        .default_level = self.default_level,
        .available_algorithms = self.compressor.listAvailableAlgorithms(),
    };
}

// Estimate compression bound for a given data size
pub fn estimateCompressionBound(self: *Encoder, data_size: usize, algorithm_name: []const u8) EncoderError!usize {
    const algorithms = self.compressor.listAvailableAlgorithms();
    for (algorithms) |algo| {
        if (std.mem.eql(u8, algo.getName(), algorithm_name)) {
            return algo.getBound(data_size);
        }
    }
    return error.AlgorithmNotFound;
}

// Private helper methods
fn collectFiles(self: *Encoder, base_path: []const u8, rel_path: []const u8, archive: *Archive) EncoderError!void {
    const full_path = if (rel_path.len == 0)
        base_path
    else
        try std.fs.path.join(self.allocator, &.{ base_path, rel_path });
    defer if (rel_path.len > 0) self.allocator.free(full_path);

    const stat = std.fs.cwd().statFile(full_path) catch |err| switch (err) {
        error.FileNotFound => return error.PathNotFound,
        else => return err,
    };

    switch (stat.kind) {
        .file => try self.addFile(full_path, rel_path, archive),
        .directory => try self.walkDirectory(base_path, rel_path, archive),
        else => {}, // Skip other types (symlinks, etc.)
    }
}

fn walkDirectory(self: *Encoder, base_path: []const u8, rel_path: []const u8, archive: *Archive) EncoderError!void {
    const full_path = if (rel_path.len == 0)
        base_path
    else
        try std.fs.path.join(self.allocator, &.{ base_path, rel_path });
    defer if (rel_path.len > 0) self.allocator.free(full_path);

    var dir = try std.fs.cwd().openDir(full_path, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const child_path = if (rel_path.len == 0)
            try self.allocator.dupe(u8, entry.name)
        else
            try std.fs.path.join(self.allocator, &.{ rel_path, entry.name });
        defer self.allocator.free(child_path);

        try self.collectFiles(base_path, child_path, archive);
    }
}

fn addFile(self: *Encoder, full_path: []const u8, rel_path: []const u8, archive: *Archive) EncoderError!void {
    log.debug("Adding file to archive: {s}", .{rel_path});

    const file_data = try self.file_utils.readFile(full_path);
    defer self.allocator.free(file_data);

    try archive.addFile(rel_path, file_data);
}

fn writeArchive(self: *Encoder, archive: *const Archive, output_path: []const u8, algorithm_name: []const u8, level: compression.CompressionLevel) EncoderError!void {
    const archive_data = try archive.serialize(&self.serializer);
    defer self.allocator.free(archive_data);

    const compression_result = try self.compressor.compressWithName(archive_data, algorithm_name, level);
    defer self.allocator.free(compression_result.data);

    try self.file_utils.writeFile(output_path, compression_result.data);

    const ratio = @as(f64, @floatFromInt(compression_result.compressed_size)) / @as(f64, @floatFromInt(compression_result.original_size));

    log.info("Algorithm: {s}, Level: {s}", .{ algorithm_name, @tagName(level) });
    log.info("Size: {} -> {} bytes (ratio: {d:.3})", .{ compression_result.original_size, compression_result.compressed_size, ratio });
}

// Convenience methods for different compression levels
pub fn encodeLow(self: *Encoder, comptime T: type, data: *const T, algorithm_name: []const u8) EncoderError![]u8 {
    return self.encodeWithAlgorithm(T, data, algorithm_name, .low);
}

pub fn encodeMedium(self: *Encoder, comptime T: type, data: *const T, algorithm_name: []const u8) EncoderError![]u8 {
    return self.encodeWithAlgorithm(T, data, algorithm_name, .medium);
}

pub fn encodeHigh(self: *Encoder, comptime T: type, data: *const T, algorithm_name: []const u8) EncoderError![]u8 {
    return self.encodeWithAlgorithm(T, data, algorithm_name, .high);
}

pub fn encodeDirLow(self: *Encoder, input_path: []const u8, output_path: []const u8, algorithm_name: []const u8) EncoderError!void {
    return self.encodeDirWithAlgorithm(input_path, output_path, algorithm_name, .low);
}

pub fn encodeDirMedium(self: *Encoder, input_path: []const u8, output_path: []const u8, algorithm_name: []const u8) EncoderError!void {
    return self.encodeDirWithAlgorithm(input_path, output_path, algorithm_name, .medium);
}

pub fn encodeDirHigh(self: *Encoder, input_path: []const u8, output_path: []const u8, algorithm_name: []const u8) EncoderError!void {
    return self.encodeDirWithAlgorithm(input_path, output_path, algorithm_name, .high);
}
