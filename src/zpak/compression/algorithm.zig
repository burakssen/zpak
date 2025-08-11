const std = @import("std");

pub const CompressionLevel = enum {
    low,
    medium,
    high,
};

pub const CompressionError = error{
    CompressionBoundError,
    CompressionFailed,
    DecompressionFailed,
    InvalidData,
    UnknownSize,
} || std.mem.Allocator.Error;

pub const CompressionResult = struct {
    data: []u8,
    original_size: usize,
    compressed_size: usize,
    algorithm_id: u8,
};

pub const IAlgorithm = struct {
    const Self = @This();

    ptr: *anyopaque,

    compressOpaque: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, data: []const u8, level: CompressionLevel) CompressionError![]u8,
    decompressOpaque: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, data: []const u8, original_size: ?usize) CompressionError![]u8,
    getBoundOpaque: *const fn (ptr: *anyopaque, input_size: usize) usize,
    getIdOpaque: *const fn (ptr: *anyopaque) u8,
    getNameOpaque: *const fn (ptr: *anyopaque) []const u8,
    detectFormatOpaque: *const fn (ptr: *anyopaque, data: []const u8) bool,

    pub fn init(pointer: anytype) Self {
        const Ptr = @TypeOf(pointer);
        const PtrInfo = @typeInfo(Ptr);

        if (PtrInfo != .pointer) @compileError("Expected pointer");
        if (PtrInfo.pointer.size != .one) @compileError("Expected single-item pointer");

        const gen = struct {
            fn compress(ptr: *anyopaque, allocator: std.mem.Allocator, data: []const u8, level: CompressionLevel) CompressionError![]u8 {
                const self: Ptr = @ptrCast(@alignCast(ptr));
                return self.compress(allocator, data, level);
            }

            fn decompress(ptr: *anyopaque, allocator: std.mem.Allocator, data: []const u8, original_size: ?usize) CompressionError![]u8 {
                const self: Ptr = @ptrCast(@alignCast(ptr));
                return self.decompress(allocator, data, original_size);
            }

            fn get_bound(ptr: *anyopaque, input_size: usize) usize {
                const self: Ptr = @ptrCast(@alignCast(ptr));
                return self.getBound(input_size);
            }

            fn get_id(ptr: *anyopaque) u8 {
                const self: Ptr = @ptrCast(@alignCast(ptr));
                return self.getId();
            }

            fn get_name(ptr: *anyopaque) []const u8 {
                const self: Ptr = @ptrCast(@alignCast(ptr));
                return self.getName();
            }

            fn detect_format(ptr: *anyopaque, data: []const u8) bool {
                const self: Ptr = @ptrCast(@alignCast(ptr));
                return self.detectFormat(data);
            }
        };

        return .{
            .ptr = pointer,
            .compressOpaque = gen.compress,
            .decompressOpaque = gen.decompress,
            .getBoundOpaque = gen.get_bound,
            .getIdOpaque = gen.get_id,
            .getNameOpaque = gen.get_name,
            .detectFormatOpaque = gen.detect_format,
        };
    }

    pub fn compress(self: Self, allocator: std.mem.Allocator, data: []const u8, level: CompressionLevel) CompressionError![]u8 {
        return self.compressOpaque(self.ptr, allocator, data, level);
    }

    pub fn decompress(self: Self, allocator: std.mem.Allocator, data: []const u8, original_size: ?usize) CompressionError![]u8 {
        return self.decompressOpaque(self.ptr, allocator, data, original_size);
    }

    pub fn getBound(self: Self, input_size: usize) usize {
        return self.getBoundOpaque(self.ptr, input_size);
    }

    pub fn getId(self: Self) u8 {
        return self.getIdOpaque(self.ptr);
    }

    pub fn getName(self: Self) []const u8 {
        return self.getNameOpaque(self.ptr);
    }

    pub fn detectFormat(self: Self, data: []const u8) bool {
        return self.detectFormatOpaque(self.ptr, data);
    }
};
