const std = @import("std");

const testing = std.testing;

const borsh = @This();

/// An optional type whose enum tag is 32 bits wide.
pub fn Option(comptime T: type) type {
    return union(enum(u32)) {
        none: void,
        some: T,

        pub fn from(inner: ?T) @This() {
            if (inner) |payload| {
                return .{ .some = payload };
            }
            return .none;
        }

        pub fn into(self: @This()) ?T {
            return switch (self) {
                .some => |payload| payload,
                .none => null,
            };
        }

        pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            return switch (self) {
                .none => writer.writeAll("null"),
                .some => |payload| writer.print("{any}", .{payload}),
            };
        }
    };
}

pub fn sizeOf(data: anytype) usize {
    var stream = std.io.countingWriter(std.io.null_writer);
    borsh.write(stream.writer(), data) catch unreachable;
    return @as(usize, @intCast(stream.bytes_written));
}

pub fn readFromSlice(gpa: std.mem.Allocator, comptime T: type, slice: []const u8) !T {
    var stream = std.io.fixedBufferStream(slice);
    return borsh.read(gpa, T, stream.reader());
}

pub fn writeToSlice(slice: []u8, data: anytype) ![]u8 {
    var stream = std.io.fixedBufferStream(slice);
    try borsh.write(stream.writer(), data);
    return stream.getWritten();
}

pub inline fn writeAlloc(gpa: std.mem.Allocator, data: anytype) ![]u8 {
    const buffer = try gpa.alloc(u8, borsh.sizeOf(data));
    errdefer gpa.free(buffer);
    return try borsh.writeToSlice(buffer, data);
}

pub fn read(gpa: std.mem.Allocator, comptime T: type, reader: anytype) !T {
    switch (@typeInfo(T)) {
        .Void => return {},
        .Bool => return switch (try reader.readByte()) {
            0 => false,
            1 => true,
            else => error.BadBoolean,
        },
        .Enum => |info| {
            const tag = try borsh.read(gpa, u8, reader);
            return std.meta.intToEnum(T, @as(info.tag_type, @intCast(tag)));
        },
        .Union => |info| {
            const tag_type = info.tag_type orelse @compileError("Only tagged unions may be read.");
            const raw_tag = try borsh.read(gpa, tag_type, reader);

            inline for (info.fields) |field| {
                if (raw_tag == @field(tag_type, field.name)) {
                    // https://github.com/ziglang/zig/issues/7866
                    if (field.type == void) return @unionInit(T, field.name, {});
                    const payload = try borsh.read(gpa, field.type, reader);
                    return @unionInit(T, field.name, payload);
                }
            }

            return error.UnknownUnionTag;
        },
        .Struct => |info| {
            var data: T = undefined;
            inline for (info.fields) |field| {
                if (!field.is_comptime) {
                    @field(data, field.name) = try borsh.read(gpa, field.type, reader);
                }
            }
            return data;
        },
        .Optional => |info| {
            return switch (try reader.readByte()) {
                0 => null,
                1 => try borsh.read(gpa, info.child, reader),
                else => error.BadOptionalBoolean,
            };
        },
        .Array => |info| {
            var data: T = undefined;
            for (&data) |*element| {
                element.* = try borsh.read(gpa, info.child, reader);
            }
            return data;
        },
        .Vector => |info| {
            var data: T = undefined;
            for (&data) |*element| {
                element.* = try borsh.read(gpa, info.child, reader);
            }
            return data;
        },
        .Pointer => |info| {
            switch (info.size) {
                .One => {
                    const data = try gpa.create(info.child);
                    errdefer gpa.destroy(data);
                    data.* = try borsh.read(gpa, info.child, reader);
                    return data;
                },
                .Slice => {
                    const entries = try gpa.alloc(info.child, try borsh.read(gpa, u32, reader));
                    errdefer gpa.free(entries);
                    for (entries) |*entry| {
                        entry.* = try borsh.read(gpa, info.child, reader);
                    }
                    return entries;
                },
                else => {},
            }
        },
        .ComptimeFloat => return borsh.read(gpa, f64, reader),
        .Float => |info| {
            const data = @as(T, @bitCast(try reader.readBytesNoEof((info.bits + 7) / 8)));
            if (std.math.isNan(data)) {
                return error.FloatIsNan;
            }
            return data;
        },
        .ComptimeInt => return borsh.read(gpa, u64, reader),
        .Int => return reader.readIntLittle(T),
        else => {},
    }

    @compileError("Deserializing '" ++ @typeName(T) ++ "' is unsupported.");
}

pub fn readFree(gpa: std.mem.Allocator, value: anytype) void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .Array, .Vector => {
            for (value) |element| {
                borsh.readFree(gpa, element);
            }
        },
        .Struct => |info| {
            inline for (info.fields) |field| {
                if (!field.is_comptime) {
                    borsh.readFree(gpa, @field(value, field.name));
                }
            }
        },
        .Optional => {
            if (value) |v| {
                borsh.readFree(gpa, v);
            }
        },
        .Union => |info| {
            inline for (info.fields) |field| {
                if (value == @field(T, field.name)) {
                    return borsh.readFree(gpa, @field(value, field.name));
                }
            }
        },
        .Pointer => |info| {
            switch (info.size) {
                .One => gpa.destroy(value),
                .Slice => {
                    for (value) |item| {
                        borsh.readFree(gpa, item);
                    }
                    gpa.free(value);
                },
                else => {},
            }
        },
        else => {},
    }
}

pub fn write(writer: anytype, data: anytype) !void {
    const T = @TypeOf(data);
    switch (@typeInfo(T)) {
        .Type, .Void, .NoReturn, .Undefined, .Null, .Fn, .Opaque, .Frame, .AnyFrame => return,
        .Bool => return writer.writeByte(@intFromBool(data)),
        .Enum => return borsh.write(writer, std.math.cast(u8, @intFromEnum(data)) orelse return error.EnumTooLarge),
        .Union => |info| {
            try borsh.write(writer, std.math.cast(u8, @intFromEnum(data)) orelse return error.EnumTooLarge);
            inline for (info.fields) |field| {
                if (data == @field(T, field.name)) {
                    return borsh.write(writer, @field(data, field.name));
                }
            }
            return;
        },
        .Struct => |info| {
            var maybe_err: anyerror!void = {};
            inline for (info.fields) |field| {
                if (!field.is_comptime) {
                    if (@as(?anyerror!void, maybe_err catch null) != null) {
                        maybe_err = borsh.write(writer, @field(data, field.name));
                    }
                }
            }
            return maybe_err;
        },
        .Optional => {
            if (data) |value| {
                try writer.writeByte(1);
                try borsh.write(writer, value);
            } else {
                try writer.writeByte(0);
            }
            return;
        },
        .Array, .Vector => {
            for (data) |element| {
                try borsh.write(writer, element);
            }
            return;
        },
        .Pointer => |info| {
            switch (info.size) {
                .One => return borsh.write(writer, data.*),
                .Many => return borsh.write(writer, std.mem.span(data)),
                .Slice => {
                    try borsh.write(writer, std.math.cast(u32, data.len) orelse return error.DataTooLarge);
                    for (data) |element| {
                        try borsh.write(writer, element);
                    }
                    return;
                },
                else => {},
            }
        },
        .ComptimeFloat => return borsh.write(writer, @as(f64, data)),
        .Float => {
            if (std.math.isNan(data)) {
                return error.FloatsMayNotBeNan;
            }
            return writer.writeAll(std.mem.asBytes(&data));
        },
        .ComptimeInt => {
            if (data < 0) {
                @compileError("Signed comptime integers can not be serialized.");
            }
            return borsh.write(writer, @as(u64, data));
        },
        .Int => return writer.writeIntLittle(T, data),
        else => {},
    }

    @compileError("Serializing '" ++ @typeName(T) ++ "' is unsupported.");
}

test "borsh: serialize and deserialize" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    inline for (.{
        @as(i8, std.math.minInt(i8)),
        @as(i16, std.math.minInt(i16)),
        @as(i32, std.math.minInt(i32)),
        @as(i64, std.math.minInt(i64)),
        @as(i8, std.math.maxInt(i8)),
        @as(i16, std.math.maxInt(i16)),
        @as(i32, std.math.maxInt(i32)),
        @as(i64, std.math.maxInt(i64)),
        @as(u8, std.math.maxInt(u8)),
        @as(u16, std.math.maxInt(u16)),
        @as(u32, std.math.maxInt(u32)),
        @as(u64, std.math.maxInt(u64)),

        @as(f32, std.math.floatMin(f32)),
        @as(f64, std.math.floatMin(f64)),
        @as(f32, std.math.floatMax(f32)),
        @as(f64, std.math.floatMax(f64)),

        [_]u8{ 0, 1, 2, 3 },
    }) |expected| {
        try borsh.write(buffer.writer(), expected);
        var stream = std.io.fixedBufferStream(buffer.items);

        const actual = try borsh.read(testing.allocator, @TypeOf(expected), stream.reader());
        defer borsh.readFree(testing.allocator, actual);

        try testing.expectEqual(expected, actual);
        buffer.clearRetainingCapacity();
    }

    inline for (.{
        "hello world",
        @as([]const u8, "hello world"),
    }) |expected| {
        try borsh.write(buffer.writer(), expected);
        var stream = std.io.fixedBufferStream(buffer.items);

        const actual = try borsh.read(testing.allocator, @TypeOf(expected), stream.reader());
        defer borsh.readFree(testing.allocator, actual);

        try testing.expectEqualSlices(std.meta.Elem(@TypeOf(expected)), expected, actual);
        buffer.clearRetainingCapacity();
    }
}
