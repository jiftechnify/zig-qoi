const std = @import("std");
const zigimg = @import("zigimg");
const Rgba = @import("qoi.zig").Rgba;

/// PixelIterator which just wraps slice of `Rgba`s.
pub const RgbaSlicePixelIterator = struct {
    src: []const Rgba,
    i: usize = 0,

    const Self = @This();

    pub fn init(src: []const Rgba) Self {
        return .{ .src = src };
    }

    pub fn nextPixel(self: *Self) ?Rgba {
        if (self.i >= self.src.len) {
            return null;
        }
        const px = self.src[self.i];
        self.i += 1;
        return px;
    }
};

/// PixelIteartor which generates `Rgba`s by iterating over an 'image buffer' (a byte buffer of pixel data in the specified pixel format).
///
/// Supported pixel formats:
/// - `.rgb`: RGB24
/// - `.rgba`: RGBA32
pub const ImageBufferPixelIterator = struct {
    const PixelFormat = enum {
        rgb,
        rgba,
    };

    src: []const u8,
    i: usize = 0,
    genPixel: *const fn ([]const u8, usize) ?Rgba,

    const Self = @This();

    fn genPixelRgb(src: []const u8, i: usize) ?Rgba {
        if (i * 3 >= src.len) {
            return null;
        }
        return Rgba{
            .r = src[i * 3],
            .g = src[i * 3 + 1],
            .b = src[i * 3 + 2],
            .a = 255,
        };
    }

    fn genPixelRgba(src: []const u8, i: usize) ?Rgba {
        if (i * 4 >= src.len) {
            return null;
        }
        return Rgba{
            .r = src[i * 4],
            .g = src[i * 4 + 1],
            .b = src[i * 4 + 2],
            .a = src[i * 4 + 3],
        };
    }

    pub fn init(src: []const u8, px_fmt: Self.PixelFormat) Self {
        return switch (px_fmt) {
            .rgb => .{ .src = src, .genPixel = genPixelRgb },
            .rgba => .{ .src = src, .genPixel = genPixelRgba },
        };
    }

    pub fn nextPixel(self: *Self) ?Rgba {
        const px = self.genPixel(self.src, self.i);
        self.i += 1;
        return px;
    }
};

/// PixelIterator which wraps zigimg's `PixelStorageIterator` and generates `Rgba`s from it.
pub const ZigimgPixelIterator = struct {
    inner: zigimg.color.PixelStorageIterator,

    const Self = @This();

    pub fn init(img_iter: zigimg.color.PixelStorageIterator) Self {
        return .{ .inner = img_iter };
    }

    pub fn nextPixel(self: *Self) ?Rgba {
        const px = self.inner.next() orelse return null;
        const rgba32 = px.toRgba32();
        return Rgba{
            .r = rgba32.r,
            .g = rgba32.g,
            .b = rgba32.b,
            .a = rgba32.a,
        };
    }
};
