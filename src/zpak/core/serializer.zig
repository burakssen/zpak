const std = @import("std");

const Serializer = @This();
const log = std.log.scoped(.serializer);

allocator: std.mem.Allocator,

pub const SerializerError = error{
    UnsupportedType,
    CorruptedData,
} || std.mem.Allocator.Error;

pub fn init(allocator: std.mem.Allocator) Serializer {
    return .{ .allocator = allocator };
}

pub fn deinit(_: *Serializer) void {
    log.debug("Deinitializing serializer", .{});
}

pub fn deserialize(self: *Serializer, comptime T: type, data: []const u8) SerializerError!T {
    return switch (@typeInfo(T)) {
        .int, .float, .bool => self.deserializePrimitive(T, data),
        .pointer => |ptr| self.deserializePointer(T, ptr, data),
        .@"struct" => self.deserializeStruct(T, data),
        .@"enum" => |e| self.deserializeEnum(T, e.tag_type, data),
        .optional => |opt| blk: {
            // Convention: empty field data represents null (matches serialize())
            if (data.len == 0) break :blk null;
            const child_value = try self.deserialize(opt.child, data);
            break :blk child_value; // coerces to optional T
        },
        else => error.UnsupportedType,
    };
}

fn deserializePrimitive(_: *Serializer, comptime T: type, data: []const u8) SerializerError!T {
    if (data.len != @sizeOf(T)) return error.CorruptedData;
    return std.mem.bytesToValue(T, data);
}

fn deserializePointer(self: *Serializer, comptime T: type, ptr: std.builtin.Type.Pointer, data: []const u8) SerializerError!T {
    return switch (ptr.size) {
        .slice => self.deserializeSlice(T, ptr, data),
        else => error.UnsupportedType,
    };
}

fn deserializeSlice(self: *Serializer, comptime T: type, ptr: std.builtin.Type.Pointer, data: []const u8) SerializerError!T {
    if (ptr.child == u8) {
        return try self.allocator.dupe(u8, data);
    }

    var offset: usize = 0;

    // Read the length of the slice
    if (offset + @sizeOf(usize) > data.len) return error.CorruptedData;
    const len = std.mem.readInt(usize, data[offset..][0..@sizeOf(usize)], .little);
    offset += @sizeOf(usize);

    const result = try self.allocator.alloc(ptr.child, len);
    errdefer self.allocator.free(result);

    // Read each element
    for (result) |*elem| {
        // Read the size of the element
        if (offset + @sizeOf(usize) > data.len) return error.CorruptedData;
        const elem_size = std.mem.readInt(usize, data[offset..][0..@sizeOf(usize)], .little);
        offset += @sizeOf(usize);

        // Read the element data
        if (offset + elem_size > data.len) return error.CorruptedData;
        const elem_data = data[offset..][0..elem_size];
        offset += elem_size;

        // Deserialize the element
        elem.* = try self.deserialize(ptr.child, elem_data);
    }

    return result;
}

fn deserializeStruct(self: *Serializer, comptime T: type, data: []const u8) SerializerError!T {
    var result: T = undefined;
    var offset: usize = 0;

    inline for (std.meta.fields(T)) |field| {
        // Read field size
        if (offset + @sizeOf(usize) > data.len) return error.CorruptedData;
        const field_size = std.mem.readInt(usize, data[offset..][0..@sizeOf(usize)], .little);
        offset += @sizeOf(usize);

        // Read field data
        if (offset + field_size > data.len) return error.CorruptedData;
        const field_data = data[offset..][0..field_size];
        offset += field_size;

        // Deserialize the field
        @field(result, field.name) = try self.deserialize(field.type, field_data);
    }

    return result;
}

fn deserializeEnum(self: *Serializer, comptime T: type, comptime TagT: type, data: []const u8) SerializerError!T {
    // Deserialize the enum's underlying integer tag
    const value = try self.deserializePrimitive(TagT, data);
    // Convert the integer back into the enum
    return @as(T, @enumFromInt(value));
}

pub fn serialize(self: *Serializer, comptime T: type, data: *const T) ![]u8 {
    const ti = @typeInfo(T);
    return switch (ti) {
        .int, .float, .bool => self.serializePrimitive(T, data),
        .pointer => |p| self.serializePointer(p, data),
        .@"struct" => self.serializeStruct(T, data),
        .@"enum" => |e| {
            const data_as_tag_type: *const e.tag_type = @ptrCast(data);
            return self.serializePrimitive(e.tag_type, data_as_tag_type);
        },
        .optional => |opt| {
            if (data.* == null) {
                return self.allocator.alloc(u8, 0); // Empty slice for null
            }

            return self.serialize(opt.child, &data.*.?);
        },
        .@"opaque" => {
            return self.serializeOpaque(data);
        },
        else => {
            std.log.err("Unsupported type for serialization: {s}", .{@typeName(T)});
            return error.UnsupportedType;
        },
    };
}

fn serializePrimitive(self: *Serializer, comptime T: type, data: *const T) SerializerError![]u8 {
    const bytes = try self.allocator.alloc(u8, @sizeOf(T));
    @memcpy(bytes, std.mem.asBytes(data));
    return bytes;
}

fn serializePointer(self: *Serializer, ptr: std.builtin.Type.Pointer, data: anytype) SerializerError![]u8 {
    return switch (ptr.size) {
        .slice => self.serializeSlice(ptr, data),
        else => error.UnsupportedType,
    };
}

fn serializeSlice(self: *Serializer, ptr: std.builtin.Type.Pointer, data: anytype) SerializerError![]u8 {
    if (ptr.child == u8) {
        return try self.allocator.dupe(u8, data.*);
    }

    // Handle slice of other serializable types
    const len = data.len;
    var result = std.ArrayList(u8).init(self.allocator);
    errdefer result.deinit();

    try result.appendSlice(std.mem.asBytes(&len));
    for (data.*) |elem| {
        const elem_bytes = try self.serialize(ptr.child, &elem);
        defer self.allocator.free(elem_bytes);

        const size_bytes = std.mem.asBytes(&elem_bytes.len);
        try result.appendSlice(size_bytes);
        try result.appendSlice(elem_bytes);
    }

    return try result.toOwnedSlice();
}

fn serializeStruct(self: *Serializer, comptime T: type, data: *const T) SerializerError![]u8 {
    var result = std.ArrayList(u8).init(self.allocator);
    errdefer result.deinit();

    inline for (std.meta.fields(T)) |field| {
        const field_data = try self.serialize(field.type, &@field(data, field.name));
        defer self.allocator.free(field_data);

        const size_bytes = std.mem.asBytes(&field_data.len);
        try result.appendSlice(size_bytes);
        try result.appendSlice(field_data);
    }

    return try result.toOwnedSlice();
}

fn serializeOpaque(self: *Serializer, data: *const type) SerializerError![]u8 {
    // Opaque types are serialized as a raw byte slice
    const bytes = try self.allocator.alloc(u8, @sizeOf(@TypeOf(data.*)));
    @memcpy(bytes, std.mem.asBytes(data));
    return bytes;
}
