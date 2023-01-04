const std = @import("std");
const expect = std.testing.expect;
const assert = std.debug.assert;
const mem_eql = std.mem.eql;
const meta_eql = std.meta.eql;

// magic bytes "qoif"
const qoi_header_magic: [4]u8 = .{'q', 'o', 'i', 'f'};

const QoiColorspace = enum(u8) {
    sRGB = 0,   // sRGB with linear alpha
    linear = 1, // all channels linear

    const Self = @This();

    fn writeTo(self: Self, writer: anytype) !void {
        try writer.writeIntBig(u8, @enumToInt(self));
    }

    fn readFrom(reader: anytype) !Self {
        const n = try reader.readIntBig(u8);
        return switch (n) {
            0 => .sRGB,
            1 => .linear,
            else => error.InvalidQoiColorspace,
        };
    }
};

const QoiHeader = struct {
    width: u32,   // image width in pixels
    height: u32,  // image height in pixels
    channels: u8, // number of color channels; 3 = RGB, 4 = RGBA
    colorspace: QoiColorspace,

    const Self = @This();

    // serialize this QOI header and write to the specified `writer`.
    pub fn writeTo(self: Self, writer: anytype) !void {
        _ = try writer.write(&qoi_header_magic);
        try writer.writeIntBig(u32, self.width);
        try writer.writeIntBig(u32, self.height);
        try writer.writeIntBig(u8, self.channels);
        try self.colorspace.writeTo(writer);
    }

    // read from the `reader` and deserialize a QOI Header.
    pub fn readFrom(reader: anytype) !Self {
        // check if the first 4-bytes match the magic bytes
        const magic = try reader.readBytesNoEof(4);
        assert(mem_eql(u8, &magic, &qoi_header_magic));

        return QoiHeader{
            .width = try reader.readIntBig(u32),
            .height = try reader.readIntBig(u32),
            .channels = try reader.readIntBig(u8),
            .colorspace = try QoiColorspace.readFrom(reader),
        };
    }
};

test "writeTo/Readfrom" {
    const originalHeader = QoiHeader{
        .width = 800,
        .height = 600,
        .channels = 3,
        .colorspace = QoiColorspace.linear
    };

    var buf: [14]u8 = undefined;
    var stream = std.io.FixedBufferStream([]u8){ .buffer = &buf, .pos = 0 };

    try originalHeader.writeTo(&stream.writer());

    try stream.seekTo(0);
    const readHeader = try QoiHeader.readFrom(&stream.reader());

    try expect(meta_eql(originalHeader, readHeader));
}
