const std = @import("std");
const Manifest = @import("manifest.zig");
const ManifestEntry = Manifest.ManifestEntry;
const Serializer = @import("serializer.zig");
const FileUtils = @import("file_utils.zig");

const Archive = @This();
const log = std.log.scoped(.archive);

const MANIFEST_SIZE_BYTES = 8;

manifest: Manifest,
data: std.ArrayList(u8),
allocator: std.mem.Allocator,

pub const ArchiveError = error{
    InvalidArchive,
    ChecksumMismatch,
} ||
    std.mem.Allocator.Error ||
    std.fmt.ParseIntError ||
    Serializer.SerializerError ||
    FileUtils.FileError;

pub fn init(allocator: std.mem.Allocator) Archive {
    return .{
        .manifest = .{
            .version = Manifest.MANIFEST_VERSION,
            .entries = &.{},
            .algorithm = .lz4,
        },
        .data = std.ArrayList(u8).init(allocator),
        .allocator = allocator,
    };
}

pub fn deinit(self: *Archive) void {
    for (self.manifest.entries) |entry| {
        self.allocator.free(entry.original_path);
        self.allocator.free(entry.encoded_path);
    }
    self.allocator.free(self.manifest.entries);
    self.data.deinit();
}

pub fn addFile(self: *Archive, rel_path: []const u8, file_data: []const u8) ArchiveError!void {
    log.debug("Adding file: {s} ({} bytes)", .{ rel_path, file_data.len });

    const offset = self.data.items.len;
    try self.data.appendSlice(file_data);

    const checksum = std.hash.Crc32.hash(file_data);
    const offset_str = try std.fmt.allocPrint(self.allocator, "offset:{}", .{offset});

    const entry = ManifestEntry{
        .original_path = try self.allocator.dupe(u8, rel_path),
        .encoded_path = offset_str,
        .original_size = file_data.len,
        .encoded_size = file_data.len,
        .checksum = checksum,
    };

    const new_entries = try self.allocator.realloc(self.manifest.entries, self.manifest.entries.len + 1);
    new_entries[self.manifest.entries.len] = entry;
    self.manifest.entries = new_entries;

    log.debug("Added {s}: {} bytes at offset {}", .{ rel_path, file_data.len, offset });
}

pub fn serialize(self: *const Archive, serializer: *Serializer) ArchiveError![]u8 {
    const manifest_data = try serializer.serialize(Manifest, &self.manifest);
    defer serializer.allocator.free(manifest_data);

    // Build final archive: [manifest_size][manifest_data][archive_data]
    var final_data = std.ArrayList(u8).init(serializer.allocator);
    defer final_data.deinit();

    const manifest_size: u64 = manifest_data.len;
    try final_data.appendSlice(std.mem.asBytes(&manifest_size));
    try final_data.appendSlice(manifest_data);
    try final_data.appendSlice(self.data.items);

    return try final_data.toOwnedSlice();
}

pub fn peekManifest(allocator: std.mem.Allocator, data: []const u8) ArchiveError!Manifest {
    if (data.len < MANIFEST_SIZE_BYTES) {
        log.err("Data too small for manifest size", .{});
        return error.InvalidArchive;
    }

    // Read the manifest size (first 12 bytes)
    const manifest_size = std.mem.readInt(u64, data[0..MANIFEST_SIZE_BYTES], .little);
    if (data.len < MANIFEST_SIZE_BYTES + manifest_size) {
        log.err("Invalid manifest size: {} (data length: {})", .{ manifest_size, data.len });
        return error.InvalidArchive;
    }

    // Create a serializer to deserialize the manifest
    var serializer = Serializer.init(allocator);
    defer serializer.deinit();

    // Deserialize the manifest data
    const manifest_data = data[MANIFEST_SIZE_BYTES..][0..manifest_size];
    return try serializer.deserialize(Manifest, manifest_data);
}

pub fn parse(allocator: std.mem.Allocator, data: []const u8) ArchiveError!Archive {
    if (data.len < MANIFEST_SIZE_BYTES) {
        log.err("Data too small for manifest size", .{});
        return error.InvalidArchive;
    }

    // Read the manifest size (first 8 bytes)
    const manifest_size = std.mem.readInt(u64, data[0..MANIFEST_SIZE_BYTES], .little);
    if (data.len < MANIFEST_SIZE_BYTES + manifest_size) {
        log.err("Invalid manifest size: {} (data length: {})", .{ manifest_size, data.len });
        return error.InvalidArchive;
    }

    // Create a serializer to deserialize the manifest
    var serializer = Serializer.init(allocator);
    defer serializer.deinit();

    // Deserialize the manifest data
    const manifest_data = data[MANIFEST_SIZE_BYTES..][0..manifest_size];
    const manifest = try serializer.deserialize(Manifest, manifest_data);

    // Create the archive with the deserialized manifest
    var archive = Archive{
        .manifest = .{
            .version = manifest.version,
            .entries = manifest.entries,
            .algorithm = manifest.algorithm,
        },
        .data = std.ArrayList(u8).init(allocator),
        .allocator = allocator,
    };

    // Store the file data (everything after the manifest)
    try archive.data.appendSlice(data[MANIFEST_SIZE_BYTES + manifest_size ..]);

    log.debug("Parsed archive with {} entries", .{archive.manifest.entries.len});
    return archive;
}

pub fn extractFiles(self: *const Archive, output_dir: []const u8, archive_data: []const u8, file_utils: *FileUtils) ArchiveError!void {
    try std.fs.cwd().makePath(output_dir);

    for (self.manifest.entries) |entry| {
        const output_path = try std.fs.path.join(file_utils.allocator, &.{ output_dir, entry.original_path });
        defer file_utils.allocator.free(output_path);

        // Parse offset from encoded_path
        if (!std.mem.startsWith(u8, entry.encoded_path, "offset:")) {
            log.warn("Invalid encoded path format: {s}", .{entry.encoded_path});
            continue;
        }

        const offset = std.fmt.parseInt(usize, entry.encoded_path[7..], 10) catch |err| {
            log.warn("Failed to parse offset from {s}: {}", .{ entry.encoded_path, err });
            continue;
        };

        if (offset + entry.original_size > archive_data.len) {
            log.warn("Invalid file bounds for {s}", .{entry.original_path});
            continue;
        }

        const file_data = archive_data[offset .. offset + entry.original_size];

        // Verify checksum
        if (std.hash.Crc32.hash(file_data) != entry.checksum) {
            log.warn("Checksum mismatch for {s}", .{entry.original_path});
            return error.ChecksumMismatch;
        }

        // Create parent directories
        if (std.fs.path.dirname(output_path)) |parent| {
            try std.fs.cwd().makePath(parent);
        }

        try file_utils.writeFile(output_path, file_data);
        log.debug("Extracted: {s}", .{output_path});
    }
}
