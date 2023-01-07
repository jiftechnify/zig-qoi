const std = @import("std");

const expect = std.testing.expect;

// workaround for an issue of `expectEqual`.
//
// When a comptime-known value is passed as `expected`, the compiler complains that
// `actual` value must be comptime-known, although `actual` value is generally runtime-known.
// So we are forced to cast `expected` to a type of runtime-known value, which is cumbersome.
//
// To resolve this issue, we can define wrapper of `expectEqual` which casts `expected` to the type of `actual` automatically.
//
// cf. https://github.com/ziglang/zig/issues/4437#issuecomment-683309291
fn expectEqual(expected: anytype, actual: anytype) !void {
    try std.testing.expectEqual(@as(@TypeOf(actual), expected), actual);
}

const expectEqualSlices = std.testing.expectEqualSlices;

const assert = std.debug.assert;
const mem_eql = std.mem.eql;
const meta_eql = std.meta.eql;
const test_allocator = std.testing.allocator;

// magic bytes "qoif"
const qoi_header_magic: [4]u8 = .{ 'q', 'o', 'i', 'f' };

const QoiColorspace = enum(u8) {
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

const QoiHeaderInfo = struct {
    width: u32, // image width in pixels
    height: u32, // image height in pixels
    channels: u8, // number of color channels; 3 = RGB, 4 = RGBA
    colorspace: QoiColorspace,

    const Self = @This();

    /// serialize this header info and write to the specified `writer`.
    pub fn writeTo(self: Self, writer: anytype) !void {
        _ = try writer.write(&qoi_header_magic);
        try writer.writeIntBig(u32, self.width);
        try writer.writeIntBig(u32, self.height);
        try writer.writeIntBig(u8, self.channels);
        try self.colorspace.writeTo(writer);
    }

    /// read from the `reader` and deserialize into header info.
    pub fn readFrom(reader: anytype) !Self {
        // check if the first 4-bytes match the magic bytes
        const magic = try reader.readBytesNoEof(4);
        assert(mem_eql(u8, &magic, &qoi_header_magic));

        return QoiHeaderInfo{
            .width = try reader.readIntBig(u32),
            .height = try reader.readIntBig(u32),
            .channels = try reader.readIntBig(u8),
            .colorspace = try QoiColorspace.readFrom(reader),
        };
    }
};

test "header info writeTo/Readfrom" {
    const originalHeader = QoiHeaderInfo{ .width = 800, .height = 600, .channels = 3, .colorspace = QoiColorspace.linear };

    var buf: [14]u8 = undefined;
    var stream = std.io.FixedBufferStream([]u8){ .buffer = &buf, .pos = 0 };

    try originalHeader.writeTo(&stream.writer());

    try stream.seekTo(0);
    const readHeader = try QoiHeaderInfo.readFrom(&stream.reader());

    try expectEqual(originalHeader, readHeader);
}

// QOI chunk tags
const tag_rgb = 0b11111110;
const tag_rgba = 0b11111111;
const tag_index = 0b00;
const tag_diff = 0b01;
const tag_luma = 0b10;
const tag_run = 0b11;

// end marker
const end_marker: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 1 };

/// QOI_OP_INDEX
/// b0[7:6] ... tag `0b00`
/// b0[5:0] ... index (0..63)
fn indexChunk(idx: u8) []const u8 {
    assert(0 <= idx and idx <= 63);

    var b0: u8 = 0;
    b0 |= tag_index << 6;
    b0 |= idx;

    return &.{b0};
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
/// b0[5:0] ... run-length (1..62)
fn runChunk(run: u8) []const u8 {
    assert(1 <= run and run <= max_run_length);

    var b0: u8 = 0;
    b0 |= tag_run << 6;
    b0 |= run - 1; // run-length is stored with a bias of -1

    return &.{b0};
}

test "runChunk" {
    try expectEqualSlices(u8, &.{0b11_000000}, runChunk(1));
    try expectEqualSlices(u8, &.{0b11_111101}, runChunk(62));
    try expectEqualSlices(u8, &.{0b11_101001}, runChunk(42));
}

/// Pixel color in RGBA8 format.
const Rgba = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    /// returns whether two colors are equal.
    fn eql(self: Rgba, other: Rgba) bool {
        return self.r == other.r and self.g == other.g and self.b == other.b and self.a == other.a;
    }

    /// calculates difference of pixel colors (`c1 - c2`).
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
    fn toRgbChunk(self: Rgba) []const u8 {
        return &[_]u8{ tag_rgb, self.r, self.g, self.b };
    }

    /// QOI_OP_RGBA
    /// b0 ... tag `0b11111111`
    /// b1 ... red
    /// b2 ... blue
    /// b3 ... green
    /// b4 ... alpha
    fn toRgbaChunk(self: Rgba) []const u8 {
        return &[_]u8{ tag_rgba, self.r, self.g, self.b, self.a };
    }
};

test "Rgba.rgbDiff" {
    const tt = [_]struct { c1: Rgba, c2: Rgba, exp: RgbDiff }{
        .{ .c1 = .{ .r = 1, .g = 2, .b = 3, .a = 255 }, .c2 = .{ .r = 0, .g = 0, .b = 0, .a = 255 }, .exp = .{ .dr = 1, .dg = 2, .db = 3 } },
        .{ .c1 = .{ .r = 0, .g = 0, .b = 0, .a = 255 }, .c2 = .{ .r = 1, .g = 2, .b = 3, .a = 255 }, .exp = .{ .dr = -1, .dg = -2, .db = -3 } },
        .{ .c1 = .{ .r = 1, .g = 2, .b = 3, .a = 255 }, .c2 = .{ .r = 1, .g = 2, .b = 3, .a = 255 }, .exp = .{ .dr = 0, .dg = 0, .db = 0 } },
        .{ .c1 = .{ .r = 255, .g = 255, .b = 255, .a = 255 }, .c2 = .{ .r = 0, .g = 0, .b = 0, .a = 255 }, .exp = .{ .dr = -1, .dg = -1, .db = -1 } },
        .{ .c1 = .{ .r = 128, .g = 128, .b = 128, .a = 255 }, .c2 = .{ .r = 0, .g = 0, .b = 0, .a = 255 }, .exp = .{ .dr = -128, .dg = -128, .db = -128 } },
        .{ .c1 = .{ .r = 0, .g = 0, .b = 0, .a = 255 }, .c2 = .{ .r = 128, .g = 128, .b = 128, .a = 255 }, .exp = .{ .dr = -128, .dg = -128, .db = -128 } },
    };

    for (tt) |t| {
        try expectEqual(t.exp, Rgba.rgbDiff(t.c1, t.c2));
    }
}

test "Rgba.toRgbChunk" {
    const tt = [_]struct { px: Rgba, exp: []const u8 }{
        .{ .px = .{ .r = 10, .g = 20, .b = 30, .a = 255 }, .exp = &.{ 0b11111110, 10, 20, 30 } },
        .{ .px = .{ .r = 10, .g = 20, .b = 30, .a = 0 }, .exp = &.{ 0b11111110, 10, 20, 30 } },
    };

    for (tt) |t| {
        try expectEqualSlices(u8, t.exp, t.px.toRgbChunk());
    }
}

test "Rgba.toRgbaChunk" {
    const tt = [_]struct { px: Rgba, exp: []const u8 }{
        .{ .px = .{ .r = 10, .g = 20, .b = 30, .a = 255 }, .exp = &.{ 0b11111111, 10, 20, 30, 255 } },
        .{ .px = .{ .r = 10, .g = 20, .b = 30, .a = 0 }, .exp = &.{ 0b11111111, 10, 20, 30, 0 } },
    };

    for (tt) |t| {
        try expectEqualSlices(u8, t.exp, t.px.toRgbaChunk());
    }
}

/// Difference of pixel colors (ignoring alpha channel).
const RgbDiff = struct {
    dr: i8,
    dg: i8,
    db: i8,

    // checks if this diff can be represented as diff chunk
    // (all channels' diffs fit in `i2` (-2..1)).
    fn canUseDiffChunk(self: RgbDiff) bool {
        return fitsIn(i2, self.dr) and fitsIn(i2, self.dg) and fitsIn(i2, self.db);
    }

    // checks if this diff can be represented as luma chunk
    // (diff of Green fits in `i6`, plus both diff of "diff of Red and diff of Green" and diff of "diff of Blue and diff of Green" fit in 'i4').
    fn canUseLumaChunk(self: RgbDiff) bool {
        return fitsIn(i6, self.dg) and fitsIn(i4, self.dr -% self.dg) and fitsIn(i4, self.db -% self.dg);
    }

    /// converts this diff to an appropriate QOI chunk if possible.
    /// result will be one of a diff chunk or an luma chunk, or `null` if this diff can be converted to neither of them.
    fn asQoiChunk(self: RgbDiff) ?[]const u8 {
        if (self.canUseDiffChunk()) {
            // QOI_OP_DIFF
            // b0[7:6] ... tag 0b01
            // b0[5:4] ... diff of red (-2..1)
            // b0[3:2] ... diff of blue (-2..1)
            // b0[1:0] ... diff of green (-2..1)
            var b0: u8 = 0;
            b0 |= tag_diff << 6;
            b0 |= addBias(self.dr, 2) << 4; // diffs are stored with a bias of 2
            b0 |= addBias(self.dg, 2) << 2;
            b0 |= addBias(self.db, 2);

            return &.{b0};
        }
        if (self.canUseLumaChunk()) {
            // QOI_OP_LUMAencodes image data into QOI format and
            // b0[7:6] ... tag 0b10
            // b0[5:0] ... diff of green (-32..31)
            // b1[7:4] ... diff of red minus diff of green (-8..7)
            // b1[3:0] ... diff of blue minus diff of green (-8..7)
            var b0: u8 = 0;
            b0 |= tag_luma << 6;
            b0 |= addBias(self.dg, 32); // diff of green is stored with a bias of 32

            var b1: u8 = 0;
            b1 |= addBias(self.dr -% self.dg, 8) << 4; // diffs of diffs are stored with a bias of 8
            b1 |= addBias(self.db -% self.dg, 8);

            return &.{ b0, b1 };
        }

        return null;
    }
};

test "RgbDiff.asQoiChunk" {
    const tt_non_null = [_]struct { diff: RgbDiff, exp: []const u8 }{
        // diff chunk
        .{ .diff = .{ .dr = -2, .dg = -1, .db = 1 }, .exp = &.{0b01_00_01_11} },
        .{ .diff = .{ .dr = 0, .dg = 0, .db = 1 }, .exp = &.{0b01_10_10_11} },

        // luma chunk
        .{ .diff = .{ .dg = 10, .dr = 11, .db = 9 }, .exp = &.{ 0b10_101010, 0b1001_0111 } },
        .{ .diff = .{ .dg = 0, .dr = 7, .db = -8 }, .exp = &.{ 0b10_100000, 0b1111_0000 } },
        .{ .diff = .{ .dg = 31, .dr = 31, .db = 31 }, .exp = &.{ 0b10_111111, 0b1000_1000 } },
        .{ .diff = .{ .dg = -32, .dr = -32, .db = -32 }, .exp = &.{ 0b10_000000, 0b1000_1000 } },
    };
    for (tt_non_null) |t| {
        try expectEqualSlices(u8, t.exp, t.diff.asQoiChunk().?);
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
        try expect(diff.asQoiChunk() == null);
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

/// encodes image data into QOI format.
const QoiEncoder = struct {
    px_prev: Rgba = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    seen_colors: SeenColorsTable = .{},
    run: u8 = 0,

    fn encode(self: *QoiEncoder, header_info: QoiHeaderInfo, pixels: []const Rgba, writer: anytype) !void {
        try header_info.writeTo(writer);

        for (pixels) |px| {
            try self.encodePixel(px, writer);
        }
        try self.finish(writer);
    }

    /// encodes single pixel.
    fn encodePixel(self: *QoiEncoder, px: Rgba, writer: anytype) !void {
        if (px.eql(self.px_prev)) {
            self.run += 1;
            if (self.run == max_run_length) {
                _ = try writer.write(runChunk(max_run_length));
                self.run = 0;
            }
            return;
        }

        // different from prev -> write chunk for previous run
        if (self.run > 0) {
            _ = try writer.write(runChunk(self.run));
            self.run = 0;
        }

        const chunk = blk: {
            // match px against seen colors table
            if (self.seen_colors.matchPut(px)) |idx| {
                break :blk indexChunk(idx);
            }

            if (self.px_prev.a == px.a) {
                // calculate diff and emit diff chunk or an lmua chunk if the diff is small
                if (Rgba.rgbDiff(self.px_prev, px).asQoiChunk()) |chunk| {
                    break :blk chunk;
                }
                break :blk px.toRgbChunk();
            }

            break :blk px.toRgbaChunk();
        };
        _ = try writer.write(chunk);

        self.px_prev = px;
    }

    /// writes the last run chunk (if needed) and end marker bytes.
    /// must be called after iteration of pixels have finished.
    fn finish(self: *QoiEncoder, writer: anytype) !void {
        if (self.run > 0) {
            _ = try writer.write(runChunk(self.run));
            self.run = 0;
        }
        _ = try writer.write(&end_marker);
    }
};

/// writes QOI-encoded image data to given writer.
pub fn encode(header_info: QoiHeaderInfo, pixels: []const Rgba, writer: anytype) !void {
    var encoder = QoiEncoder{};
    try encoder.encode(header_info, pixels, writer);
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

    try encode(header_info, &[_]Rgba{}, &buf.writer());

    // TODO: write actual test
    try expect(1 == 1);
}

/// checks if given `i8` value fits in the range of type `T`.
///
/// `T` must be a signed integer type.
fn fitsIn(comptime T: type, n: i8) bool {
    switch (@typeInfo(T)) {
        .Int => |i| {
            switch (i.signedness) {
                .signed => return std.math.minInt(T) <= n and n <= std.math.maxInt(T),
                .unsigned => @compileError("T should be signed integer type"),
            }
        },
        else => @compileError("T should be signed integer type"),
    }
}

test "fitsIn" {
    try expectEqual(false, fitsIn(i2, -3));
    try expectEqual(true, fitsIn(i2, -2));
    try expectEqual(true, fitsIn(i2, -1));
    try expectEqual(true, fitsIn(i2, 0));
    try expectEqual(true, fitsIn(i2, 1));
    try expectEqual(false, fitsIn(i2, 2));

    try expectEqual(true, fitsIn(i4, 7));
    try expectEqual(true, fitsIn(i4, -8));
    try expectEqual(false, fitsIn(i4, 8));

    try expectEqual(true, fitsIn(i6, 31));
    try expectEqual(true, fitsIn(i6, -32));
    try expectEqual(false, fitsIn(i6, 32));
}

/// add `bias` to `n` and convert it to `u8` by bit-preserving cast.
fn addBias(n: i8, bias: i8) u8 {
    return @bitCast(u8, n +% bias);
}

test "addBias" {
    try expectEqual(0, addBias(-2, 2));
    try expectEqual(1, addBias(-1, 2));
    try expectEqual(2, addBias(0, 2));
    try expectEqual(3, addBias(1, 2));

    try expectEqual(0, addBias(-8, 8));
    try expectEqual(8, addBias(0, 8));
    try expectEqual(15, addBias(7, 8));

    try expectEqual(0, addBias(-32, 32));
    try expectEqual(32, addBias(0, 32));
    try expectEqual(63, addBias(31, 32));
}
