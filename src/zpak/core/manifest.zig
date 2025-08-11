const std = @import("std");

const Manifest = @This();

pub const ManifestEntry = struct {
    original_path: []const u8,
    encoded_path: []const u8,
    original_size: u64,
    encoded_size: u64,
    checksum: u32,
};

version: u32,
entries: []ManifestEntry,
algorithm_id: ?u8,

pub const MANIFEST_VERSION = 1;
