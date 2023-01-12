const std = @import("std");

const utils = @import("./utils.zig");
const fitsIn = utils.fitsIn;
const addBias = utils.addBias;

const assert = std.debug.assert;

const expect = std.testing.expect;
const expectEqual = utils.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;
const test_allocator = std.testing.allocator;

const Writer = std.io.Writer;

/// Writes QOI-encoded image data to given `writer` and returns number of bytes written.
pub fn encode(header_info: QoiHeaderInfo, pixels: []const Rgba, writer: anytype) !usize {
    // TODO: return error if dimension data in header_info and length of pixel array conflict.

    var encoder = QoiEncoder{};
    return try encoder.encode(header_info, pixels, writer);
}

test "encode" {
    var buf = std.ArrayList(u8).init(test_allocator);
    defer buf.deinit();

    const header_info = QoiHeaderInfo{
        .width = 800,
        .height = 600,
        .channels = 4,
        .colorspace = .sRGB,
    };

    const written = try encode(header_info, &[_]Rgba{}, &buf.writer());

    // TODO: write actual test
    try expectEqual(22, written);
}

/// Encodes image data into QOI format.
const QoiEncoder = struct {
    px_prev: Rgba = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    seen_colors: SeenColorsTable = .{},
    run: u8 = 0,

    /// Encodes an image (in the form of a pixel array) as QOI format, returns number of bytes written to the `writer`.
    fn encode(self: *QoiEncoder, header_info: QoiHeaderInfo, pixels: []const Rgba, writer: anytype) !usize {
        try header_info.writeTo(writer);

        var written: usize = QoiHeaderInfo.len_in_bytes;

        for (pixels) |px| {
            written += try self.encodePixel(px, writer);
        }
        written += try self.finish(writer);

        return written;
    }

    /// Encodes single pixel then return number of bytes written to the `writer`.
    fn encodePixel(self: *QoiEncoder, px: Rgba, writer: anytype) !usize {
        var written: usize = 0;

        if (px.eql(self.px_prev)) {
            self.run += 1;
            if (self.run == max_run_length) {
                written += try writer.write(runChunk(max_run_length));
                self.run = 0;
            }
            return written;
        }

        // different from prev -> write chunk for previous run
        if (self.run > 0) {
            written += try writer.write(runChunk(self.run));
            self.run = 0;
        }

        const chunk = blk: {
            // match px against seen colors table
            if (self.seen_colors.matchPut(px)) |idx| {
                break :blk indexChunk(idx);
            }

            if (self.px_prev.a == px.a) {
                // calculate diff and emit diff chunk or an lmua chunk if the diff is small
                if (Rgba.rgbDiff(self.px_prev, px).tryIntoQoiChunk()) |chunk| {
                    break :blk chunk;
                }
                break :blk px.intoRgbChunk();
            }

            break :blk px.intoRgbaChunk();
        };
        written += try writer.write(chunk);

        self.px_prev = px;
        return written;
    }

    /// Writes the last run chunk (if needed) and end marker bytes, then returns number of bytes written to `writer`.
    /// Must be called after iteration over pixels have finished.
    fn finish(self: *QoiEncoder, writer: anytype) !usize {
        var written: usize = 0;

        if (self.run > 0) {
            written += try writer.write(runChunk(self.run));
            self.run = 0;
        }
        written += try writer.write(&end_marker);

        return written;
    }
};

// magic bytes "qoif"
const qoi_header_magic: [4]u8 = .{ 'q', 'o', 'i', 'f' };

pub const QoiColorspace = enum(u8) {
    sRGB = 0, // sRGB with linear alpha
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

pub const QoiHeaderInfo = struct {
    width: u32, // image width in pixels
    height: u32, // image height in pixels
    channels: u8, // number of color channels; 3 = RGB, 4 = RGBA
    colorspace: QoiColorspace,

    const Self = @This();

    /// Number of bytes when this header info is written as binary.
    const len_in_bytes = 14;

    /// Serialize this header info and write to the specified `writer`.
    pub fn writeTo(self: Self, writer: anytype) !void {
        _ = try writer.write(&qoi_header_magic);
        try writer.writeIntBig(u32, self.width);
        try writer.writeIntBig(u32, self.height);
        try writer.writeIntBig(u8, self.channels);
        try self.colorspace.writeTo(writer);
    }

    /// Read from the `reader` and deserialize into header info.
    pub fn readFrom(reader: anytype) !Self {
        // check if the first 4-bytes match the magic bytes
        const magic = try reader.readBytesNoEof(4);
        if (!std.mem.eql(u8, &magic, &qoi_header_magic)) {
            return error.InvalidQoiFormat;
        }

        return QoiHeaderInfo{
            .width = try reader.readIntBig(u32),
            .height = try reader.readIntBig(u32),
            .channels = try reader.readIntBig(u8),
            .colorspace = try QoiColorspace.readFrom(reader),
        };
    }
};

test "header info writeTo/readFrom" {
    const original_header = QoiHeaderInfo{ .width = 800, .height = 600, .channels = 3, .colorspace = QoiColorspace.linear };

    var buf: [14]u8 = undefined;
    var stream = std.io.FixedBufferStream([]u8){ .buffer = &buf, .pos = 0 };

    try original_header.writeTo(&stream.writer());

    try stream.seekTo(0);
    const read_header = try QoiHeaderInfo.readFrom(&stream.reader());

    try expectEqual(original_header, read_header);
}

test "detect invalid header magic" {
    // PNG header magic for example
    const invalid_header = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0, 0, 0 };
    var stream = std.io.FixedBufferStream([]const u8){ .buffer = &invalid_header, .pos = 0 };

    try expectError(error.InvalidQoiFormat, QoiHeaderInfo.readFrom(&stream.reader()));
}

// QOI chunk tags
// 8-bit tags
const tag_rgb = 0b11111110;
const tag_rgba = 0b11111111;
// 2-bit tags
const tag_index = 0b00_000000;
const tag_diff = 0b01_000000;
const tag_luma = 0b10_000000;
const tag_run = 0b11_000000;

// end marker
const end_marker: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 1 };

/// QOI_OP_INDEX
/// b0[7:6] ... tag `0b00`
/// b0[5:0] ... index (0..63)
fn indexChunk(idx: u8) []const u8 {
    assert(0 <= idx and idx <= 63);

    return &.{tag_index | idx};
}

test "indexChunk" {
    try expectEqualSlices(u8, &.{0b00_000000}, indexChunk(0));
    try expectEqualSlices(u8, &.{0b00_111111}, indexChunk(63));
    try expectEqualSlices(u8, &.{0b00_101010}, indexChunk(42));
}

// run-length has 6-bit width in run chunk, but 63 and 64 are illegal as they are occupied by the rgb/rgba tags.
const max_run_length = 62;

/// QOI_OP_RUN
/// b0[7:6] ... tag `0b11`
/// b0[5:0] ... run-length (1..62) with a bias of -1
fn runChunk(run: u8) []const u8 {
    assert(1 <= run and run <= max_run_length);

    return &.{tag_run | (run - 1)};
}

test "runChunk" {
    try expectEqualSlices(u8, &.{0b11_000000}, runChunk(1));
    try expectEqualSlices(u8, &.{0b11_111101}, runChunk(62));
    try expectEqualSlices(u8, &.{0b11_101001}, runChunk(42));
}

/// Pixel color in RGBA8 format.
pub const Rgba = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    /// Checks if two colors are equal.
    fn eql(self: Rgba, other: Rgba) bool {
        return self.r == other.r and self.g == other.g and self.b == other.b and self.a == other.a;
    }

    /// Calculates difference of pixel colors (`c1 - c2`). Ignores alpha channel.
    fn rgbDiff(c1: Rgba, c2: Rgba) RgbDiff {
        return .{
            .dr = @bitCast(i8, c1.r -% c2.r),
            .dg = @bitCast(i8, c1.g -% c2.g),
            .db = @bitCast(i8, c1.b -% c2.b),
        };
    }

    /// QOI_OP_RGB
    /// b0 ... tag `0b11111110`
    /// b1 ... red
    /// b2 ... blue
    /// b3 ... green
    fn intoRgbChunk(self: Rgba) []const u8 {
        return &[_]u8{ tag_rgb, self.r, self.g, self.b };
    }

    /// QOI_OP_RGBA
    /// b0 ... tag `0b11111111`
    /// b1 ... red
    /// b2 ... blue
    /// b3 ... green
    /// b4 ... alpha
    fn intoRgbaChunk(self: Rgba) []const u8 {
        return &[_]u8{ tag_rgba, self.r, self.g, self.b, self.a };
    }
};

test "Rgba.rgbDiff" {
    const tt = [_]struct { c1: Rgba, c2: Rgba, exp: RgbDiff }{
        .{
            .c1 = .{ .r = 1, .g = 2, .b = 3, .a = 255 },
            .c2 = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
            .exp = .{ .dr = 1, .dg = 2, .db = 3 },
        },
        .{
            .c1 = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
            .c2 = .{ .r = 1, .g = 2, .b = 3, .a = 255 },
            .exp = .{ .dr = -1, .dg = -2, .db = -3 },
        },
        .{
            .c1 = .{ .r = 1, .g = 2, .b = 3, .a = 255 },
            .c2 = .{ .r = 1, .g = 2, .b = 3, .a = 255 },
            .exp = .{ .dr = 0, .dg = 0, .db = 0 },
        },
        .{
            .c1 = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
            .c2 = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
            .exp = .{ .dr = -1, .dg = -1, .db = -1 },
        },
        .{
            .c1 = .{ .r = 128, .g = 128, .b = 128, .a = 255 },
            .c2 = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
            .exp = .{ .dr = -128, .dg = -128, .db = -128 },
        },
        .{
            .c1 = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
            .c2 = .{ .r = 128, .g = 128, .b = 128, .a = 255 },
            .exp = .{ .dr = -128, .dg = -128, .db = -128 },
        },
    };

    for (tt) |t| {
        try expectEqual(t.exp, Rgba.rgbDiff(t.c1, t.c2));
    }
}

test "Rgba.intoRgbChunk" {
    const tt = [_]struct { px: Rgba, exp: []const u8 }{
        .{
            .px = .{ .r = 10, .g = 20, .b = 30, .a = 255 },
            .exp = &.{ 0b11111110, 10, 20, 30 },
        },
        .{
            .px = .{ .r = 10, .g = 20, .b = 30, .a = 0 },
            .exp = &.{ 0b11111110, 10, 20, 30 },
        },
    };

    for (tt) |t| {
        try expectEqualSlices(u8, t.exp, t.px.intoRgbChunk());
    }
}

test "Rgba.intoRgbaChunk" {
    const tt = [_]struct { px: Rgba, exp: []const u8 }{
        .{
            .px = .{ .r = 10, .g = 20, .b = 30, .a = 255 },
            .exp = &.{ 0b11111111, 10, 20, 30, 255 },
        },
        .{
            .px = .{ .r = 10, .g = 20, .b = 30, .a = 0 },
            .exp = &.{ 0b11111111, 10, 20, 30, 0 },
        },
    };

    for (tt) |t| {
        try expectEqualSlices(u8, t.exp, t.px.intoRgbaChunk());
    }
}

/// Difference of pixel colors (ignoring alpha channel).
const RgbDiff = struct {
    dr: i8,
    dg: i8,
    db: i8,

    // Checks if this diff can be represented as diff chunk
    // (all channels' diffs fit in `i2` (-2..1)).
    fn canUseDiffChunk(self: RgbDiff) bool {
        return fitsIn(i2, self.dr) and fitsIn(i2, self.dg) and fitsIn(i2, self.db);
    }

    // Checks if this diff can be represented as luma chunk
    // (diff of Green fits in `i6`, plus both diff of "diff of Red and diff of Green" and diff of "diff of Blue and diff of Green" fit in 'i4').
    fn canUseLumaChunk(self: RgbDiff) bool {
        return fitsIn(i6, self.dg) and fitsIn(i4, self.dr -% self.dg) and fitsIn(i4, self.db -% self.dg);
    }

    /// Converts this diff to an appropriate QOI chunk if possible.
    /// Result will be one of a diff chunk or an luma chunk, or `null` if this diff can be converted to neither of them.
    fn tryIntoQoiChunk(self: RgbDiff) ?[]const u8 {
        if (self.canUseDiffChunk()) {
            // QOI_OP_DIFF
            // b0[7:6] ... tag 0b01
            // b0[5:4] ... diff of red (-2..1) with a bias of 2
            // b0[3:2] ... diff of blue (-2..1) with a bias of 2
            // b0[1:0] ... diff of green (-2..1) with a bias of 2
            return &.{tag_diff | addBias(self.dr, 2) << 4 | addBias(self.dg, 2) << 2 | addBias(self.db, 2)};
        }
        if (self.canUseLumaChunk()) {
            // QOI_OP_LUMA
            // b0[7:6] ... tag 0b10
            // b0[5:0] ... diff of green (-32..31) with a bias of 32
            // b1[7:4] ... diff of red minus diff of green (-8..7) with a bias of 8
            // b1[3:0] ... diff of blue minus diff of green (-8..7) with a bias of 8
            return &.{
                tag_luma | addBias(self.dg, 32),
                addBias(self.dr -% self.dg, 8) << 4 | addBias(self.db -% self.dg, 8),
            };
        }

        return null;
    }
};

test "RgbDiff.tryIntoQoiChunk" {
    const tt_non_null = [_]struct { diff: RgbDiff, exp: []const u8 }{
        // diff chunk
        .{
            .diff = .{ .dr = -2, .dg = -1, .db = 1 },
            .exp = &.{0b01_00_01_11},
        },
        .{
            .diff = .{ .dr = 0, .dg = 0, .db = 1 },
            .exp = &.{0b01_10_10_11},
        },

        // luma chunk
        .{
            .diff = .{ .dg = 10, .dr = 11, .db = 9 },
            .exp = &.{ 0b10_101010, 0b1001_0111 },
        },
        .{
            .diff = .{ .dg = 0, .dr = 7, .db = -8 },
            .exp = &.{ 0b10_100000, 0b1111_0000 },
        },
        .{
            .diff = .{ .dg = 31, .dr = 31, .db = 31 },
            .exp = &.{ 0b10_111111, 0b1000_1000 },
        },
        .{
            .diff = .{ .dg = -32, .dr = -32, .db = -32 },
            .exp = &.{ 0b10_000000, 0b1000_1000 },
        },
    };
    for (tt_non_null) |t| {
        try expectEqualSlices(u8, t.exp, t.diff.tryIntoQoiChunk().?);
    }

    const tt_null = [_]RgbDiff{
        .{ .dg = 64, .dr = 1, .db = -1 },
        .{ .dg = 32, .dr = 32, .db = 32 },
        .{ .dg = -33, .dr = -33, .db = -33 },
        .{ .dg = 0, .dr = 8, .db = 0 },
        .{ .dg = 0, .dr = -9, .db = 0 },
        .{ .dg = 0, .dr = 0, .db = 8 },
        .{ .dg = 0, .dr = 0, .db = -9 },
    };
    for (tt_null) |diff| {
        try expect(diff.tryIntoQoiChunk() == null);
    }
}

const SeenColorsTable = struct {
    array: [64]Rgba = [_]Rgba{.{ .r = 0, .g = 0, .b = 0, .a = 0 }} ** 64,

    fn pixelIndex(p: Rgba) u8 {
        return ((p.r *% 3) +% (p.g *% 5) +% (p.b *% 7) +% (p.a *% 11)) % 64;
    }

    /// If given pixel color is in this table, return the index of it.
    /// Otherwise, put given color into the table and return `null`.
    fn matchPut(self: *SeenColorsTable, new: Rgba) ?u8 {
        const idx = pixelIndex(new);

        const old = self.array[idx];
        if (new.eql(old)) {
            return idx;
        }

        self.array[idx] = new;
        return null;
    }
};

test "SeenColorsTable.matchPut" {
    var seen_colors = SeenColorsTable{};

    // put zero color value
    try expectEqual(0, seen_colors.matchPut(.{ .r = 0, .g = 0, .b = 0, .a = 0 }).?);

    // put unseen color
    const red = Rgba{ .r = 255, .g = 0, .b = 0, .a = 255 }; // index: 50
    try expect(seen_colors.matchPut(red) == null);
    // put same color again
    try expectEqual(50, seen_colors.matchPut(red).?);

    // put a color which index collides against the seen color
    const collider = Rgba{ .r = 10, .g = 2, .b = 3, .a = 255 }; // index: 50
    try expect(seen_colors.matchPut(collider) == null);
    // put same color again
    try expectEqual(50, seen_colors.matchPut(collider).?);
}
