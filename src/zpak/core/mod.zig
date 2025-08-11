// Core namespace: shared data structures and compression interfaces
pub const Archive = @import("archive.zig");
pub const Serializer = @import("serializer.zig");
pub const Manifest = @import("manifest.zig");
pub const Compressor = @import("compressor.zig");

// Compression-related public surface
pub const Compression = @import("../compression/algorithm.zig");
pub const Registry = @import("../compression/registry.zig");
