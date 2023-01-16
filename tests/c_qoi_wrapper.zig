const std = @import("std");
const Allocator = std.mem.Allocator;

const qoi = @import("../src/qoi.zig");
const c = @cImport({
    @cDefine("QOI_IMPLEMENTATION", {});
    @cInclude("qoi.h");
});

fn headerToQoiDesc(header: qoi.HeaderInfo) c.qoi_desc {
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

pub fn encode(allocator: Allocator, img_data: qoi.ImageData, writer: anytype) !void {
    const desc = headerToQoiDesc(img_data.header);

    const image_bin = try rgbasToBin(allocator, img_data.pixels);
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

fn qoiDescToHeader(desc: c.qoi_desc) qoi.HeaderInfo {
    return .{
        .width = desc.width,
        .height = desc.height,
        .channels = desc.channels,
        .colorspace = @intToEnum(qoi.Colorspace, desc.colorspace),
    };
}

fn binToRgbas(alloc: Allocator, bin: []const u8, channels: u8) ![]qoi.Rgba {
    var list_px = std.ArrayList(qoi.Rgba).init(alloc);
    var i: usize = 0;
    while (i < bin.len) : (i += channels) {
        const px = switch (channels) {
            3 => qoi.Rgba{
                .r = bin[i + 0],
                .g = bin[i + 1],
                .b = bin[i + 2],
                .a = 255,
            },
            4 => qoi.Rgba{
                .r = bin[i + 0],
                .g = bin[i + 1],
                .b = bin[i + 2],
                .a = bin[i + 3],
            },
            else => unreachable,
        };
        try list_px.append(px);
    }
    return list_px.toOwnedSlice();
}

/// Freeing `pixels` in the output is caller's responsbility.
pub fn decode(allocator: Allocator, reader: anytype, size: usize) !qoi.ImageData {
    const data = try reader.readAllAlloc(allocator, size);
    defer allocator.free(data);

    var desc: c.qoi_desc = undefined;
    const dec_bin = c.qoi_decode(data.ptr, @intCast(c_int, data.len), &desc, 0);
    if (dec_bin == null) {
        return error.CQoiDecodeError;
    }
    defer c.free(dec_bin);

    if (desc.channels != 3 and desc.channels != 4) {
        return error.CQoiDecodeError;
    }
    const bin_len = @intCast(usize, desc.width) * @intCast(usize, desc.height) * desc.channels;
    const pixels = try binToRgbas(allocator, @ptrCast([*]u8, dec_bin.?)[0..bin_len], desc.channels);

    return .{
        .header = qoiDescToHeader(desc),
        .pixels = pixels,
    };
}
