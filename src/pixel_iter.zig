const std = @import("std");
const zigimg = @import("zigimg");
const Rgba = @import("qoi.zig").Rgba;

pub const IdentityPixelIterator = struct {
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

pub const BinaryPixelIterator = struct {
    const Mode = enum {
        rgb,
        rgba,
    };

    src: []const u8,
    i: usize = 0,
    genPixel: *const fn ([]const u8, usize) ?Rgba,

    const Self = @This();

    pub fn init(src: []const u8, mode: Self.Mode) Self {
        return switch (mode) {
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
