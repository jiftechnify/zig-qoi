const std = @import("std");
const assert = std.debug.assert;

const Image = @import("zigimg").Image;
const qoi = @import("./qoi.zig");
const c_qoi = @import("./c_qoi_wrapper.zig");

pub fn main() !void {
    // initialize an allocator for Image buffer
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        const leaked = gpa.deinit();
        if (leaked) {
            @panic("GPA: memory leak");
        }
    }

    const sample_pixels = [_]qoi.Rgba{.{ .r = 0x2e, .g = 0xb6, .b = 0xaa, .a = 0xff }} ** (32 * 32);
    const sample_header = qoi.QoiHeaderInfo{
        .width = 32,
        .height = 32,
        .channels = 4,
        .colorspace = qoi.QoiColorspace.sRGB,
    };

    // sample: QOI file read/write with C impl
    const c_sample_filename = "c_qoi_write_sample.qoi";
    _ = try c_qoi.write(allocator, c_sample_filename, &sample_pixels, sample_header);
    const out = try c_qoi.read(allocator, c_sample_filename, 4);

    defer allocator.free(out.pixels);

    assert(std.meta.eql(sample_header, out.header));
    assert(sample_pixels.len == out.pixels.len);
    var i: usize = 0;
    while (i < sample_pixels.len) : (i += 1) {
        assert(std.meta.eql(sample_pixels[i], out.pixels[i]));
    }

    // sample: QOI file write with Zig impl
    const zig_sample_filename = "zig_qoi_write_sample.qoi";
    const out_file = try std.fs.cwd().createFile(zig_sample_filename, .{ .truncate = true });
    defer out_file.close();

    var ss = std.io.StreamSource{ .file = out_file };
    const n = try qoi.encode(sample_header, &sample_pixels, ss.writer());
    std.debug.print("zig impl: {} bytes written\n", .{n});

    // sample: convert PNG to QOI with C impl
    // read the image file
    var png_img = try Image.fromFilePath(allocator, "blackleaf.png");
    defer png_img.deinit();

    // build QOI header from image metadata
    const h = qoi.QoiHeaderInfo{
        .width = @intCast(u32, png_img.width),
        .height = @intCast(u32, png_img.height),
        .channels = 4,
        .colorspace = qoi.QoiColorspace.sRGB,
    };

    // adjust pixels data type
    var png_pixels = std.ArrayList(qoi.Rgba).init(allocator);
    defer png_pixels.deinit();

    var png_iter = png_img.iterator();
    while (png_iter.next()) |px| {
        const rgba32 = px.toRgba32();
        try png_pixels.append(.{
            .r = rgba32.r,
            .g = rgba32.g,
            .b = rgba32.b,
            .a = rgba32.a,
        });
    }

    // encode to QOI format and write to file by C impl
    _ = try c_qoi.write(allocator, "c_blackleaf.qoi", png_pixels.items, h);

    // encode to QOI format and write to file by Zig impl
    const zig_bl_out_file = try std.fs.cwd().createFile("zig_blackleaf.qoi", .{ .truncate = true });
    defer zig_bl_out_file.close();

    var ss2 = std.io.StreamSource{ .file = zig_bl_out_file };
    _ = try qoi.encode(h, png_pixels.items, ss2.writer());
}
