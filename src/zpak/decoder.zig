const std = @import("std");
const Serializer = @import("core/serializer.zig");
const Compressor = @import("core/compressor.zig").Compressor;
const Archive = @import("core/archive.zig");
const FileUtils = @import("io/file_utils.zig");
const Manifest = @import("core/manifest.zig");

const Decoder = @This();
const log = std.log.scoped(.decoder);

allocator: std.mem.Allocator,
serializer: Serializer,
compressor: Compressor,
file_utils: FileUtils,

const DecoderError = error{
    PathNotFound,
    InvalidArchive,
    ChecksumMismatch,
    DecompressionFailed,
    UnsupportedType,
    CorruptedData,
    UnsupportedManifestVersion,
    AlgorithmNotFound,
} ||
    std.mem.Allocator.Error ||
    FileUtils.FileError ||
    Archive.ArchiveError ||
    Compressor.CompressionError ||
    Serializer.SerializerError;

pub fn init(allocator: std.mem.Allocator) DecoderError!Decoder {
    log.debug("Initializing decoder", .{});
    return .{
        .allocator = allocator,
        .serializer = Serializer.init(allocator),
        .compressor = try Compressor.init(allocator),
        .file_utils = FileUtils.init(allocator),
    };
}

pub fn deinit(self: *Decoder) void {
    log.debug("Deinitializing decoder", .{});
    self.serializer.deinit();
    self.compressor.deinit();
    self.file_utils.deinit();
}

pub fn decodeDir(self: *Decoder, archive_path: []const u8, output_dir: []const u8) DecoderError!void {
    log.debug("Decoding directory archive: {s} -> {s}", .{ archive_path, output_dir });

    // Check if archive file exists
    const archive_exists = FileUtils.fileExists(archive_path);

    if (!archive_exists) {
        log.err("Archive file does not exist: {s}", .{archive_path});
        return error.PathNotFound;
    }

    // Read compressed archive data
    const compressed_data = try self.file_utils.readFile(archive_path);
    defer self.allocator.free(compressed_data);

    // Try to detect compression algorithm from the archive header/manifest
    const algorithm_info = try self.detectArchiveAlgorithm(compressed_data);

    // Decompress the archive
    const decompressed = try self.compressor.decompressWithName(compressed_data, algorithm_info.name, null);
    defer self.allocator.free(decompressed);

    // Parse the archive structure from the now uncompressed data
    var archive = try self.parseArchive(decompressed);
    defer archive.deinit();

    // Validate manifest version
    if (archive.manifest.version > 1) {
        log.err("Unsupported manifest version: {}", .{archive.manifest.version});
        return error.UnsupportedManifestVersion;
    }

    // Extract all files
    try self.extractArchive(&archive, decompressed, output_dir);

    log.info("Successfully extracted {} files to: {s}", .{ archive.manifest.entries.len, output_dir });
}

pub fn listArchiveContents(self: *Decoder, archive_path: []const u8) DecoderError![]const u8 {
    log.debug("Listing contents of archive: {s}", .{archive_path});

    const archive_exists = FileUtils.fileExists(archive_path);

    if (!archive_exists) {
        return error.PathNotFound;
    }

    const compressed_data = try self.file_utils.readFile(archive_path);
    defer self.allocator.free(compressed_data);

    const algorithm_info = try self.detectArchiveAlgorithm(compressed_data);

    const decompressed = try self.compressor.decompressWithName(compressed_data, algorithm_info.name, null);
    defer self.allocator.free(decompressed.data);

    var archive = try self.parseArchive(decompressed.data);
    defer archive.deinit();

    var result = std.ArrayList(u8).init(self.allocator);
    defer result.deinit();

    const writer = result.writer();
    try writer.print("Archive: {s}\n", .{archive_path});
    try writer.print("Version: {}\n", .{archive.manifest.version});
    try writer.print("Entries: {}\n\n", .{archive.manifest.entries.len});

    for (archive.manifest.entries, 0..) |entry, i| {
        try writer.print("[{}] {s}\n", .{ i + 1, entry.original_path });
        try writer.print("    Size: {} bytes\n", .{entry.original_size});
        try writer.print("    Checksum: 0x{x:0>8}\n", .{entry.checksum});
        if (i < archive.manifest.entries.len - 1) {
            try writer.print("\n", .{});
        }
    }

    return try result.toOwnedSlice();
}

pub fn extractSingleFile(self: *Decoder, archive_path: []const u8, file_path: []const u8, output_path: []const u8) DecoderError!void {
    log.debug("Extracting single file: {s} -> {s}", .{ file_path, output_path });

    const archive_exists = FileUtils.fileExists(archive_path);

    if (!archive_exists) {
        return error.PathNotFound;
    }

    const compressed_data = try self.file_utils.readFile(archive_path);
    defer self.allocator.free(compressed_data);

    const algorithm_info = try self.detectArchiveAlgorithm(compressed_data);

    const decompressed = try self.compressor.decompressWithName(compressed_data, algorithm_info.name, null);
    defer self.allocator.free(decompressed.data);

    var archive = try self.parseArchive(decompressed.data);
    defer archive.deinit();

    // Find the requested file
    for (archive.manifest.entries) |entry| {
        if (std.mem.eql(u8, entry.original_path, file_path)) {
            try self.extractSingleEntry(&entry, decompressed.data, output_path);
            log.info("Extracted: {s} -> {s}", .{ file_path, output_path });
            return;
        }
    }

    log.warn("File not found in archive: {s}", .{file_path});
    return error.PathNotFound;
}

pub fn verifyArchive(self: *Decoder, archive_path: []const u8) DecoderError!bool {
    log.debug("Verifying archive integrity: {s}", .{archive_path});

    const archive_exists = FileUtils.fileExists(archive_path);

    if (!archive_exists) {
        log.err("Archive file does not exist: {s}", .{archive_path});
        return error.PathNotFound;
    }

    const compressed_data = try self.file_utils.readFile(archive_path);
    defer self.allocator.free(compressed_data);

    const algorithm_info = self.detectArchiveAlgorithm(compressed_data) catch |err| {
        log.warn("Failed to detect compression algorithm: {}", .{err});
        return false;
    };

    const decompressed = self.compressor.decompressWithName(compressed_data, algorithm_info.name, algorithm_info.level) catch |err| {
        log.warn("Failed to decompress archive: {}", .{err});
        return false;
    };
    defer self.allocator.free(decompressed.data);

    var archive = self.parseArchive(decompressed.data) catch |err| {
        log.warn("Failed to parse archive: {}", .{err});
        return false;
    };
    defer archive.deinit();

    // Verify all file checksums
    const MANIFEST_SIZE_BYTES = 8;
    const manifest_size = std.mem.readInt(u64, decompressed.data[0..MANIFEST_SIZE_BYTES][0..8], .little);
    const data_start = MANIFEST_SIZE_BYTES + manifest_size;

    for (archive.manifest.entries) |entry| {
        if (!std.mem.startsWith(u8, entry.encoded_path, "offset:")) {
            log.warn("Invalid encoded path format: {s}", .{entry.encoded_path});
            return false;
        }

        const offset = std.fmt.parseInt(usize, entry.encoded_path[7..], 10) catch {
            log.warn("Failed to parse offset from {s}", .{entry.encoded_path});
            return false;
        };

        const actual_offset = data_start + offset;
        if (actual_offset + entry.original_size > decompressed.data.len) {
            log.warn("Invalid file bounds for {s}", .{entry.original_path});
            return false;
        }

        const file_data = decompressed.data[actual_offset .. actual_offset + entry.original_size];
        if (std.hash.Crc32.hash(file_data) != entry.checksum) {
            log.warn("Checksum mismatch for {s}", .{entry.original_path});
            return false;
        }
    }

    log.info("Archive verification successful: {s}", .{archive_path});
    return true;
}

// Private helper methods
fn detectArchiveAlgorithm(self: *Decoder, compressed_data: []const u8) DecoderError!struct { name: []const u8, level: @import("compression/algorithm.zig").CompressionLevel } {
    // This is a simplified version - you might want to store algorithm info in archive header
    // For now, try to detect based on data patterns or use a default

    // Try common algorithms in order of preference
    const algorithms = self.compressor.listAvailableAlgorithms();

    for (algorithms) |algo| {
        // Try to decompress with each algorithm to see if it works
        if (self.compressor.decompressWithName(compressed_data, algo.getName(), compressed_data.len)) |result| {
            self.allocator.free(result);
            return .{ .name = algo.getName(), .level = .medium };
        } else |_| {
            // Continue to next algorithm
        }
    }

    // Default fallback
    return .{ .name = "LZ4", .level = .medium };
}

fn deserialize(self: *Decoder, comptime T: type, data: []const u8) DecoderError!T {
    return switch (@typeInfo(T)) {
        .int, .float => self.deserializePrimitive(T, data),
        .pointer => |ptr| self.deserializePointer(T, ptr, data),
        .@"struct" => self.deserializeStruct(T, data),
        else => error.UnsupportedType,
    };
}

fn deserializePrimitive(self: *Decoder, comptime T: type, data: []const u8) DecoderError!T {
    _ = self;
    if (data.len != @sizeOf(T)) return error.CorruptedData;
    return @as(*const T, @ptrCast(@alignCast(data.ptr))).*;
}

fn deserializePointer(self: *Decoder, comptime T: type, ptr: std.builtin.Type.Pointer, data: []const u8) DecoderError!T {
    return switch (ptr.size) {
        .slice => self.deserializeSlice(T, ptr, data),
        else => error.UnsupportedType,
    };
}

fn deserializeSlice(self: *Decoder, comptime T: type, ptr: std.builtin.Type.Pointer, data: []const u8) DecoderError!T {
    if (ptr.child == u8) {
        return try self.allocator.dupe(u8, data);
    }

    // Handle slice of other deserializable types
    if (data.len < @sizeOf(usize)) return error.CorruptedData;

    const len = @as(*const usize, @ptrCast(@alignCast(data.ptr))).*;
    var offset: usize = @sizeOf(usize);

    const result = try self.allocator.alloc(ptr.child, len);
    errdefer self.allocator.free(result);

    for (result) |*elem| {
        if (offset + @sizeOf(usize) > data.len) return error.CorruptedData;

        const elem_size = @as(*const usize, @ptrCast(@alignCast(data.ptr + offset))).*;
        offset += @sizeOf(usize);

        if (offset + elem_size > data.len) return error.CorruptedData;

        elem.* = try self.deserialize(ptr.child, data[offset .. offset + elem_size]);
        offset += elem_size;
    }

    return result;
}

fn deserializeStruct(self: *Decoder, comptime T: type, data: []const u8) DecoderError!T {
    var result: T = undefined;
    var offset: usize = 0;

    inline for (std.meta.fields(T)) |field| {
        if (offset + @sizeOf(usize) > data.len) return error.CorruptedData;

        const field_size = @as(*const usize, @ptrCast(@alignCast(data.ptr + offset))).*;
        offset += @sizeOf(usize);

        if (offset + field_size > data.len) return error.CorruptedData;

        @field(result, field.name) = try self.deserialize(field.type, data[offset .. offset + field_size]);
        offset += field_size;
    }

    return result;
}

fn extractArchive(self: *Decoder, archive: *const Archive, archive_data: []const u8, output_dir: []const u8) DecoderError!void {
    // Create output directory
    FileUtils.createDirectory(output_dir) catch |err| {
        log.err("Failed to create output directory '{s}': {}", .{ output_dir, err });
        return err;
    };

    log.debug("Extracting {} entries to: {s}", .{ archive.manifest.entries.len, output_dir });

    for (archive.manifest.entries, 0..) |entry, i| {
        log.debug("Extracting {}/{}: {s}", .{ i + 1, archive.manifest.entries.len, entry.original_path });

        const output_path = std.fs.path.join(self.allocator, &.{ output_dir, entry.original_path }) catch |err| {
            log.err("Failed to construct output path for '{s}': {}", .{ entry.original_path, err });
            return err;
        };
        defer self.allocator.free(output_path);

        self.extractSingleEntry(&entry, archive_data, output_path) catch |err| {
            log.err("Failed to extract '{s}': {}", .{ entry.original_path, err });
            return err;
        };

        log.debug("Successfully extracted: {s}", .{output_path});
    }
}

fn extractSingleEntry(self: *Decoder, entry: *const Manifest.ManifestEntry, archive_data: []const u8, output_path: []const u8) DecoderError!void {
    // Parse offset from encoded_path
    if (!std.mem.startsWith(u8, entry.encoded_path, "offset:")) {
        log.err("Invalid encoded path format: {s} (expected 'offset:...')", .{entry.encoded_path});
        return error.CorruptedData;
    }

    const offset_str = entry.encoded_path[7..];
    const offset = std.fmt.parseInt(usize, offset_str, 10) catch |err| {
        log.err("Failed to parse offset from '{s}': {}", .{ offset_str, err });
        return error.CorruptedData;
    };

    // Calculate data start (after manifest)
    const MANIFEST_SIZE_BYTES = 8;
    if (archive_data.len < MANIFEST_SIZE_BYTES) {
        log.err("Archive data too small for header", .{});
        return error.CorruptedData;
    }

    const manifest_size = std.mem.readInt(u64, archive_data[0..MANIFEST_SIZE_BYTES][0..8], .little);
    const data_start = MANIFEST_SIZE_BYTES + manifest_size;
    const actual_offset = data_start + offset;

    log.debug("Extracting {s}: offset={}, data_start={}, actual_offset={}, size={}", .{ entry.original_path, offset, data_start, actual_offset, entry.original_size });

    // Validate bounds
    if (actual_offset >= archive_data.len) {
        log.err("File offset out of bounds for {s}: {} >= {}", .{ entry.original_path, actual_offset, archive_data.len });
        return error.CorruptedData;
    }

    if (actual_offset + entry.original_size > archive_data.len) {
        log.err("File extends beyond archive for {s}: end={}, archive_size={}", .{ entry.original_path, actual_offset + entry.original_size, archive_data.len });
        return error.CorruptedData;
    }

    const file_data = archive_data[actual_offset .. actual_offset + entry.original_size];

    // Verify checksum
    const computed_checksum = std.hash.Crc32.hash(file_data);
    if (computed_checksum != entry.checksum) {
        log.err("Checksum mismatch for {s}: expected 0x{x:0>8}, got 0x{x:0>8}", .{ entry.original_path, entry.checksum, computed_checksum });
        return error.ChecksumMismatch;
    }

    // Create parent directories if needed
    if (std.fs.path.dirname(output_path)) |parent| {
        FileUtils.createDirectory(parent) catch |err| {
            log.err("Failed to create parent directory '{s}': {}", .{ parent, err });
            return err;
        };
    }

    // Write the file
    self.file_utils.writeFile(output_path, file_data) catch |err| {
        log.err("Failed to write file '{s}': {}", .{ output_path, err });
        return err;
    };
}

// Parse archive from decompressed data
fn parseArchive(self: *Decoder, data: []const u8) DecoderError!Archive {
    log.debug("Parsing archive data ({} bytes)", .{data.len});

    // Delegate to Archive.parse which should have the proper implementation
    const archive = try Archive.parse(self.allocator, data);

    // Verify the manifest has entries
    if (archive.manifest.entries.len == 0) {
        log.warn("Archive has no entries", .{});
    } else {
        log.debug("Archive contains {} entries", .{archive.manifest.entries.len});
    }

    return archive;
}
