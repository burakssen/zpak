const std = @import("std");

const FileUtils = @This();
const log = std.log.scoped(.file_utils);

allocator: std.mem.Allocator,

pub const FileError = error{} ||
    std.fs.Dir.OpenError ||
    std.fs.Dir.AccessError ||
    std.fs.File.OpenError ||
    std.fs.File.ReadError ||
    std.fs.File.WriteError ||
    std.fs.File.SeekError ||
    std.fs.Dir.MakeError ||
    std.mem.Allocator.Error;

pub fn init(allocator: std.mem.Allocator) FileUtils {
    return .{ .allocator = allocator };
}

pub fn deinit(_: *FileUtils) void {
    log.debug("Deinitializing file utils", .{});
}

pub fn readFile(self: *FileUtils, path: []const u8) FileError![]u8 {
    log.debug("Reading file: {s}", .{path});

    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const size = try file.getEndPos();
    const data = try self.allocator.alloc(u8, size);
    _ = try file.readAll(data);

    log.debug("Read {} bytes from {s}", .{ data.len, path });
    return data;
}

pub fn writeFile(_: *FileUtils, path: []const u8, data: []const u8) FileError!void {
    log.debug("Writing {} bytes to: {s}", .{ data.len, path });

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(data);
}

pub fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

pub fn getFileSize(path: []const u8) FileError!u64 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return try file.getEndPos();
}

pub fn createDirectory(path: []const u8) FileError!void {
    log.debug("Creating directory: {s}", .{path});
    try std.fs.cwd().makePath(path);
}

pub fn removeFile(path: []const u8) FileError!void {
    log.debug("Removing file: {s}", .{path});
    try std.fs.cwd().deleteFile(path);
}

pub fn removeDirectory(path: []const u8) FileError!void {
    log.debug("Removing directory: {s}", .{path});
    try std.fs.cwd().deleteTree(path);
}
