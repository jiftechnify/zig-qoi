const std = @import("std");
const Allocator = std.mem.Allocator;

const qoi = @import("../src/qoi.zig");
const c = @cImport({
    @cDefine("QOI_IMPLEMENTATION", {});
    @cInclude("qoi.h");
});

fn headerToQoiDesc(header: qoi.QoiHeaderInfo) c.qoi_desc {
    return .{
        .width = header.width,
        .height = header.height,
        .channels = header.channels,
        .colorspace = @enumToInt(header.colorspace),
    };
}

fn rgbasToBin(alloc: Allocator, pixels: []const qoi.Rgba) !std.ArrayList(u8) {
    var buf = std.ArrayList(u8).init(alloc);
    for (pixels) |p| {
        try buf.appendSlice(&.{ p.r, p.g, p.b, p.a });
    }
    return buf;
}

pub fn encode(allocator: Allocator, header: qoi.QoiHeaderInfo, pixels: []const qoi.Rgba, writer: anytype) !void {
    const desc = headerToQoiDesc(header);

    const image_bin = try rgbasToBin(allocator, pixels);
    defer image_bin.deinit();

    var n: c_int = 0;
    const enc_bin = c.qoi_encode(image_bin.items.ptr, &desc, &n);
    if (enc_bin == null) {
        return error.CQoiEncodeError;
    }
    defer c.free(enc_bin);

    const n_usize = @intCast(usize, n);
    try writer.writeAll(@ptrCast([*]u8, enc_bin.?)[0..n_usize]);
}

pub fn write(allocator: Allocator, filename: []const u8, pixels: []const qoi.Rgba, header: qoi.QoiHeaderInfo) !void {
    const desc = headerToQoiDesc(header);

    const image_bin = try rgbasToBin(allocator, pixels);
    defer image_bin.deinit();

    const n = c.qoi_write(filename.ptr, image_bin.items.ptr, &desc);
    if (n == 0) {
        return error.CQoiEncodeError;
    }
}

fn qoiDescToHeader(desc: c.qoi_desc) qoi.QoiHeaderInfo {
    return .{
        .width = desc.width,
        .height = desc.height,
        .channels = desc.channels,
        .colorspace = @intToEnum(qoi.QoiColorspace, desc.colorspace),
    };
}

fn binToRgbas(alloc: Allocator, bin: []const u8) ![]qoi.Rgba {
    var list_px = std.ArrayList(qoi.Rgba).init(alloc);
    var i: usize = 0;
    while (i < bin.len) : (i += 4) {
        try list_px.append(.{
            .r = bin[i + 0],
            .g = bin[i + 1],
            .b = bin[i + 2],
            .a = bin[i + 3],
        });
    }
    return list_px.toOwnedSlice();
}

const QoiDecodeOutput = struct {
    header: qoi.QoiHeaderInfo,
    pixels: []qoi.Rgba,
};

/// Freeing `pixels` in the output is caller's responsbility.
pub fn read(allocator: Allocator, filename: []const u8, channels: u8) !QoiDecodeOutput {
    var desc: c.qoi_desc = undefined;

    const dec_bin = c.qoi_read(filename.ptr, &desc, channels);
    if (dec_bin == null) {
        return error.CQoiDecodeError;
    }
    defer c.free(dec_bin);

    const px_len = @intCast(usize, desc.width) * @intCast(usize, desc.height);
    const pixels = try binToRgbas(allocator, @ptrCast([*]u8, dec_bin.?)[0..(px_len * 4)]);

    return .{
        .header = qoiDescToHeader(desc),
        .pixels = pixels,
    };
}

/// Freeing `pixels` in the output is caller's responsbility.
pub fn decode(allocator: Allocator, data: []const u8, channels: u8) !QoiDecodeOutput {
    var desc: c.qoi_desc = undefined;

    const dec_bin = c.qoi_decode(data.ptr, data.len, &desc, channels);
    if (dec_bin == null) {
        return error.CQoiDecodeError;
    }
    defer c.free(dec_bin);

    const px_len = @intCast(usize, desc.width) * @intCast(usize, desc.height);
    const pixels = try binToRgbas(allocator, @ptrCast([*]u8, dec_bin.?)[0..(px_len * 4)]);

    return .{
        .header = qoiDescToHeader(desc),
        .pixels = pixels,
    };
}
