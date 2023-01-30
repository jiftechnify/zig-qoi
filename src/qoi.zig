const std = @import("std");
const io = std.io;
const File = std.fs.File;
const Allocator = std.mem.Allocator;

pub usingnamespace @import("./pixel_iter.zig");

const utils = @import("./utils.zig");
const fitsIn = utils.fitsIn;
const addBias = utils.addBias;
const subBias = utils.subBias;
const generic_path = utils.generic_path;

const assert = std.debug.assert;

const expect = std.testing.expect;
const expectEqual = utils.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;
const test_allocator = std.testing.allocator;

/// Writes QOI-encoded image data to given `writer`.
///
/// `px_iter` must be an 'iterator of pixels', which has a method named `nextPixel` whose return type is `?Rgba`,
/// every call to it returns a next pixel (`Rgba`) in an image and `null` if it reached the end of image data.
/// Use `qoi.XxxPixelIterator.init()` series constructors to get 'iterator of pixels' from an image data in various forms.
pub fn encode(header: HeaderInfo, px_iter: anytype, writer: anytype) !void {
    var encoder = Encoder{};
    try encoder.encode(header, px_iter, writer);
}

/// Writes QOI-encoded image data to given file.
///
/// `px_iter` must be an 'iterator of pixels', which has a method named `nextPixel` whose return type is `?Rgba`,
/// every call to it returns a next pixel (`Rgba`) in an image and `null` if it reached the end of image data.
/// Use `qoi.XxxPixelIterator.init()` series constructors to get 'iterator of pixels' from an image data in various forms.
pub fn encodeToFile(header: HeaderInfo, px_iter: anytype, dst_file: *File) !void {
    var buffered = io.bufferedWriter(dst_file.writer());
    try encode(header, px_iter, buffered.writer());
    try buffered.flush();
}

/// Writes QOI-encoded image data to the file created at `dst_path`.
///
/// `px_iter` must be an 'iterator of pixels', which has a method named `nextPixel` whose return type is `?Rgba`,
/// every call to it returns a next pixel (`Rgba`) in an image and `null` if it reached the end of image data.
/// Use `qoi.XxxPixelIterator.init()` series constructors to get 'iterator of pixels' from an image data in various forms.
pub fn encodeToFileByPath(header: HeaderInfo, px_iter: anytype, dst_path: []const u8) !void {
    var f = try generic_path.createFile(dst_path, .{});
    try encodeToFile(header, px_iter, &f);
}

/// Encodes image data into QOI format.
const Encoder = struct {
    px_prev: Rgba = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    seen_colors: SeenColorsTable = .{},
    run: u8 = 0,

    /// Encodes an image (in the form of a pixel array) to writer in QOI format.
    ///
    /// `px_iter` must be a value of 'iterator of pixels', which has a method named `nextPixel` whose return type is `?Rgba`.
    fn encode(self: *Encoder, header: HeaderInfo, px_iter: anytype, writer: anytype) !void {
        try header.writeTo(writer);

        while (px_iter.nextPixel()) |px| {
            try self.encodePixel(px, writer);
        }
        try self.finish(writer);
    }

    /// Encodes single pixel then return number of bytes written to the `writer`.
    fn encodePixel(self: *Encoder, px: Rgba, writer: anytype) !void {
        if (Rgba.eql(px, self.px_prev)) {
            self.run += 1;
            if (self.run == max_run_length) {
                try writer.writeAll(runChunk(max_run_length));
                self.run = 0;
            }
            return;
        }

        // different from prev -> write chunk for previous run
        if (self.run > 0) {
            try writer.writeAll(runChunk(self.run));
            self.run = 0;
        }

        defer self.px_prev = px;

        // match px against seen colors table
        if (self.seen_colors.matchPut(px)) |idx| {
            try writer.writeAll(indexChunk(idx));
            return;
        }

        // TODO: To workaround problems with using slices returned from functions in wasm32 build, writing chunks 'directly'.
        // Consider to restore original code when these problems are fixed in the future.

        if (self.px_prev.a == px.a) {
            // calculate diff and emit diff chunk or an lmua chunk if the diff is small
            const diff = Rgba.rgbDiff(px, self.px_prev);
            if (diff.canUseDiffChunk()) {
                // QOI_OP_DIFF
                try writer.writeAll(&.{tag_diff | addBias(diff.dr, 2) << 4 | addBias(diff.dg, 2) << 2 | addBias(diff.db, 2)});
                return;
            }
            if (diff.canUseLumaChunk()) {
                // QOI_OP_LUMA
                try writer.writeAll(&.{
                    tag_luma | addBias(diff.dg, 32),
                    addBias(diff.dr -% diff.dg, 8) << 4 | addBias(diff.db -% diff.dg, 8),
                });
                return;
            }
            // QOI_OP_RGB
            try writer.writeAll(&.{ tag_rgb, px.r, px.g, px.b });
            return;
        }
        // QOI_OP_RGBA
        try writer.writeAll(&.{ tag_rgba, px.r, px.g, px.b, px.a });
    }

    /// Writes the last run chunk (if needed) and end marker bytes.
    /// Must be called after iteration over pixels have finished.
    fn finish(self: *Encoder, writer: anytype) !void {
        if (self.run > 0) {
            try writer.writeAll(runChunk(self.run));
            self.run = 0;
        }
        try writer.writeAll(&end_marker);
    }
};

/// QOI header info + decoded image in the form of iterator of pixels in RGBA32 format.
pub fn DecodeResult(comptime Reader: type) type {
    return struct {
        header: HeaderInfo,
        px_iter: DecodingPixelIterator(Reader),
    };
}

/// Decodes QOI-encoded image data from given `reader`.
pub fn decode(reader: anytype) !DecodeResult(@TypeOf(reader)) {
    const header = try HeaderInfo.readFrom(reader);
    const px_iter = decodingPixelIterator(reader);

    return .{ .header = header, .px_iter = px_iter };
}

const BufFileReader = std.io.BufferedReader(4096, std.fs.File.Reader).Reader;

/// Decodes QOI-encoded image data from given file.
pub fn decodeFromFile(src_file: File) !DecodeResult(BufFileReader) {
    var buffered = io.bufferedReader(src_file.reader());
    return try decode(buffered.reader());
}

/// Decodes QOI-encoded image data from the file at `src_path`.
pub fn decodeFromFileByPath(src_path: []const u8) !DecodeResult(BufFileReader) {
    const f = try generic_path.openFile(src_path, .{});
    return try decodeFromFile(f);
}

fn decodingPixelIterator(reader: anytype) DecodingPixelIterator(@TypeOf(reader)) {
    return .{ .reader = reader };
}

fn DecodingPixelIterator(comptime Reader: type) type {
    return struct {
        reader: Reader,

        px_prev: Rgba = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        seen_colors: SeenColorsTable = .{},

        remaining_run: u8 = 0,

        last_idx_0_px: ?Rgba = null,
        pending_byte: ?u8 = null,

        finished: bool = false,

        const Self = @This();

        pub fn nextPixel(self: *Self) !?Rgba {
            if (self.finished) return null;

            if (self.remaining_run > 0) {
                self.remaining_run -= 1;
                return self.px_prev;
            }

            const b = if (self.pending_byte) |pb| blk: {
                self.pending_byte = null;
                break :blk pb;
            } else try self.reader.readByte();

            if (self.last_idx_0_px) |px| {
                if (b == 0) {
                    // previous byte was first byte of end marker!
                    self.finished = true;

                    // so far, 2 consecutive zero bytes detecetd; match next 6 bytes against end marker pattern
                    const end = try self.reader.readBytesNoEof(6);
                    if (!std.mem.eql(u8, &end, &.{ 0, 0, 0, 0, 0, 1 })) {
                        return error.InvalidQoiFormat;
                    }
                    return null;
                }

                // previous byte was QOI_OP_INDEX(0)
                self.pending_byte = b;
                self.px_prev = px;
                self.last_idx_0_px = null;
                return px;
            }

            const px_and_run: ?struct { px: Rgba, run: u8 } = blk: {
                switch (b) {
                    tag_rgb => {
                        const rgb = try self.reader.readBytesNoEof(3);
                        break :blk .{ .px = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2], .a = self.px_prev.a }, .run = 1 };
                    },
                    tag_rgba => {
                        const rgba = try self.reader.readBytesNoEof(4);
                        break :blk .{ .px = .{ .r = rgba[0], .g = rgba[1], .b = rgba[2], .a = rgba[3] }, .run = 1 };
                    },
                    else => {},
                }
                // 8-bit tags didn't match; check 2-bit tags
                const tag2 = b & 0b11_000000;
                switch (tag2) {
                    tag_index => {
                        if (b == 0) { // maybe first byte of end marker; defer appending pixel
                            self.last_idx_0_px = self.seen_colors.get(0);
                            break :blk null;
                        }
                        break :blk .{ .px = self.seen_colors.get(b), .run = 1 };
                    },
                    tag_diff => {
                        const diff = RgbDiff.fromDiffChunk(b);
                        break :blk .{ .px = self.px_prev.applyRgbDiff(diff), .run = 1 };
                    },
                    tag_luma => {
                        const b1 = try self.reader.readByte();
                        const diff = RgbDiff.fromLumaChunk(b, b1);
                        break :blk .{ .px = self.px_prev.applyRgbDiff(diff), .run = 1 };
                    },
                    tag_run => {
                        const run = (b & 0b00_111111) + 1;
                        break :blk .{ .px = self.px_prev, .run = run };
                    },
                    else => unreachable,
                }
            };

            if (px_and_run) |pxr| {
                self.px_prev = pxr.px;
                if (pxr.run > 1) {
                    self.remaining_run = pxr.run - 1;
                }
                _ = self.seen_colors.matchPut(pxr.px);

                return pxr.px;
            }
            // if b == 0
            return self.nextPixel();
        }
    };
}

// magic bytes "qoif"
const qoi_header_magic: [4]u8 = .{ 'q', 'o', 'i', 'f' };

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

/// Information embeded in the QOI header.
pub const HeaderInfo = struct {
    width: u32,
    height: u32,
    channels: u8, // number of color channels; 3 = RGB, 4 = RGBA
    colorspace: Colorspace,

    const Self = @This();

    /// Number of bytes when this header info is written as binary.
    const len_in_bytes = 14;

    /// Serialize this header info and write to the specified `writer`.
    pub fn writeTo(self: Self, writer: anytype) !void {
        try writer.writeAll(&qoi_header_magic);
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

        return HeaderInfo{
            .width = try reader.readIntBig(u32),
            .height = try reader.readIntBig(u32),
            .channels = try reader.readIntBig(u8),
            .colorspace = try Colorspace.readFrom(reader),
        };
    }

    test "header info writeTo/readFrom" {
        const original_header = HeaderInfo{ .width = 800, .height = 600, .channels = 3, .colorspace = Colorspace.linear };

        var buf: [14]u8 = undefined;
        var stream = std.io.FixedBufferStream([]u8){ .buffer = &buf, .pos = 0 };

        try original_header.writeTo(&stream.writer());

        try stream.seekTo(0);
        const read_header = try HeaderInfo.readFrom(&stream.reader());

        try expectEqual(original_header, read_header);
    }

    test "detect invalid header magic" {
        // PNG header magic for example
        const invalid_header = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0, 0, 0 };
        var stream = std.io.FixedBufferStream([]const u8){ .buffer = &invalid_header, .pos = 0 };

        try expectError(error.InvalidQoiFormat, HeaderInfo.readFrom(&stream.reader()));
    }
};

/// Colorspace specifier for the QOI header.
pub const Colorspace = enum(u8) {
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

/// Pixel color in RGBA32 format (each pixel has 4 channels: R, G, B, and A, each channel is 8-bit depth).
pub const Rgba = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    /// Checks if colors of pixels are equal.
    fn eql(p1: Rgba, p2: Rgba) bool {
        return p1.r == p2.r and p1.g == p2.g and p1.b == p2.b and p1.a == p2.a;
    }

    /// Calculates difference of pixel colors (`p1 - p2`). Ignores alpha channel.
    fn rgbDiff(p1: Rgba, p2: Rgba) RgbDiff {
        return .{
            .dr = @bitCast(i8, p1.r -% p2.r),
            .dg = @bitCast(i8, p1.g -% p2.g),
            .db = @bitCast(i8, p1.b -% p2.b),
        };
    }

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

    /// QOI_OP_RGB
    /// b0 ... tag `0b11111110`
    /// b1 ... red
    /// b2 ... blue
    /// b3 ... green
    fn intoRgbChunk(self: Rgba) []const u8 {
        return &[_]u8{ tag_rgb, self.r, self.g, self.b };
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

    /// QOI_OP_RGBA
    /// b0 ... tag `0b11111111`
    /// b1 ... red
    /// b2 ... blue
    /// b3 ... green
    /// b4 ... alpha
    fn intoRgbaChunk(self: Rgba) []const u8 {
        return &[_]u8{ tag_rgba, self.r, self.g, self.b, self.a };
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

    fn applyRgbDiff(self: Rgba, diff: RgbDiff) Rgba {
        return .{
            .r = self.r +% @bitCast(u8, diff.dr),
            .g = self.g +% @bitCast(u8, diff.dg),
            .b = self.b +% @bitCast(u8, diff.db),
            .a = self.a,
        };
    }
};

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

    fn fromDiffChunk(b: u8) RgbDiff {
        return .{
            .dr = subBias((b >> 4) & 0b11, 2),
            .dg = subBias((b >> 2) & 0b11, 2),
            .db = subBias(b & 0b11, 2),
        };
    }

    fn fromLumaChunk(b0: u8, b1: u8) RgbDiff {
        const dg = subBias((b0 & 0b111111), 32);
        return .{
            .dr = dg +% subBias((b1 >> 4) & 0b1111, 8),
            .dg = dg,
            .db = dg +% subBias(b1 & 0b1111, 8),
        };
    }
};

const SeenColorsTable = struct {
    array: [64]Rgba = [_]Rgba{.{ .r = 0, .g = 0, .b = 0, .a = 0 }} ** 64,

    fn pixelIndex(p: Rgba) u8 {
        return ((p.r *% 3) +% (p.g *% 5) +% (p.b *% 7) +% (p.a *% 11)) % 64;
    }

    fn get(self: *const SeenColorsTable, idx: u8) Rgba {
        assert(0 <= idx and idx < 64);

        return self.array[idx];
    }

    /// If given pixel color is in this table, return the index of it.
    /// Otherwise, put given color into the table and return `null`.
    fn matchPut(self: *SeenColorsTable, new: Rgba) ?u8 {
        const idx = pixelIndex(new);

        const old = self.array[idx];
        if (Rgba.eql(new, old)) {
            return idx;
        }

        self.array[idx] = new;
        return null;
    }

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
};
