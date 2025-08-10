const std = @import("std");
const Serializer = @import("serializer.zig");
const Compressor = @import("compressor.zig");
const Archive = @import("archive.zig");
const FileUtils = @import("file_utils.zig");

const Encoder = @This();
const log = std.log.scoped(.encoder);

allocator: std.mem.Allocator,
serializer: Serializer,
compressor: Compressor,
file_utils: FileUtils,
algorithm: Compressor.Algorithm,

const EncoderError = error{
    PathNotFound,
    CompressionBoundError,
    UnsupportedType,
    CompressionFailed,
    DecompressionFailed,
    InvalidArchive,
} ||
    std.mem.Allocator.Error ||
    FileUtils.FileError ||
    Archive.ArchiveError;

pub fn init(allocator: std.mem.Allocator) Encoder {
    log.debug("Initializing encoder", .{});
    return .{
        .allocator = allocator,
        .serializer = Serializer.init(allocator),
        .compressor = Compressor.init(allocator),
        .file_utils = FileUtils.init(allocator),
        .algorithm = .lz4,
    };
}

pub fn deinit(self: *Encoder) void {
    log.debug("Deinitializing encoder", .{});
    self.serializer.deinit();
    self.compressor.deinit();
    self.file_utils.deinit();
}

pub fn withAlgorithm(self: *Encoder, algorithm: Compressor.Algorithm) void {
    self.algorithm = algorithm;
}

pub fn encode(self: *Encoder, comptime T: type, data: *const T) EncoderError![]u8 {
    log.debug("Encoding object: {s}", .{@typeName(T)});

    const serialized = try self.serializer.serialize(T, data);
    defer self.allocator.free(serialized);

    return self.compressor.compressWithAlgorithm(serialized, self.algorithm, .high);
}

pub fn encodeDir(self: *Encoder, input_path: []const u8, output_path: []const u8) EncoderError!void {
    log.debug("Encoding directory: {s} -> {s}", .{ input_path, output_path });

    var archive = Archive.init(self.allocator);
    defer archive.deinit();
    archive.manifest.algorithm = self.algorithm;

    try self.collectFiles(input_path, "", &archive);
    try self.writeArchive(&archive, output_path);
}

pub fn decodeDir(self: *Encoder, archive_path: []const u8, output_dir: []const u8) EncoderError!void {
    log.debug("Decoding directory archive: {s} -> {s}", .{ archive_path, output_dir });

    const compressed_data = try self.file_utils.readFile(archive_path);
    defer self.allocator.free(compressed_data);

    const archive = try Archive.parse(self.allocator, compressed_data);
    defer archive.deinit();

    const decompressed = try self.compressor.decompress(compressed_data, archive.manifest.algorithm);
    defer self.allocator.free(decompressed);

    try archive.extractFiles(output_dir, decompressed, &self.file_utils);
}

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
        else => {}, // Skip other types
    }
}

fn walkDirectory(self: *Encoder, base_path: []const u8, rel_path: []const u8, archive: *Archive) EncoderError!void {
    const full_path = if (rel_path.len == 0)
        base_path
    else
        try std.fs.path.join(self.allocator, &.{ base_path, rel_path });
    defer if (rel_path.len > 0) self.allocator.free(full_path);

    var dir = try std.fs.cwd().openDir(full_path, .{});
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const child_path = if (rel_path.len == 0)
            entry.name
        else
            try std.fs.path.join(self.allocator, &.{ rel_path, entry.name });
        defer if (rel_path.len > 0) self.allocator.free(child_path);

        try self.collectFiles(base_path, child_path, archive);
    }
}

fn addFile(self: *Encoder, full_path: []const u8, rel_path: []const u8, archive: *Archive) EncoderError!void {
    const file_data = try self.file_utils.readFile(full_path);
    defer self.allocator.free(file_data);

    try archive.addFile(rel_path, file_data);
}

fn writeArchive(self: *Encoder, archive: *const Archive, output_path: []const u8) EncoderError!void {
    const archive_data = try archive.serialize(&self.serializer);
    defer self.allocator.free(archive_data);

    const compressed = try self.compressor.compressWithAlgorithm(archive_data, self.algorithm, .high);
    defer self.allocator.free(compressed);

    try self.file_utils.writeFile(output_path, compressed);

    log.info("Created archive with {} entries: {s}", .{ archive.manifest.entries.len, output_path });
    log.info("Size: {} -> {} bytes (ratio: {d:.2})", .{ archive_data.len, compressed.len, @as(f64, @floatFromInt(compressed.len)) / @as(f64, @floatFromInt(archive_data.len)) });
}
