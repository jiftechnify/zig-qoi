const std = @import("std");

const qoi = @import("../src/qoi.zig");
const c_qoi = @import("./c_qoi_wrapper.zig");

const Image = @import("zigimg").Image;

const test_images_dir = "tests/images";

test "QOI encode" {
    const dir = std.fs.cwd().openDir(test_images_dir, .{}) catch |err| {
        if (err == error.FileNotFound) {
            return error.SkipZigTest;
        } else {
            return err;
        }
    };
    const iter_dir = try std.fs.cwd().openIterableDir(test_images_dir, .{});
    var iter = iter_dir.iterate();

    std.debug.print("\n", .{});
    var failed = false;
    while (try iter.next()) |e| {
        if (e.kind == .File and std.mem.eql(u8, std.fs.path.extension(e.name), ".png")) {
            std.debug.print("{s} ... ", .{e.name});

            var png_file = try dir.openFile(e.name, .{});
            const ok = try testEncode(&png_file);

            if (ok) {
                std.debug.print("OK\n", .{});
            } else {
                failed = true;
                std.debug.print("NG\n", .{});
            }
        }
    }

    if (failed) {
        return error.TestFailed;
    }
}

fn testEncode(png_file: *std.fs.File) !bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const png_img = try readPngImage(alloc, png_file);

    var buf_c = std.ArrayList(u8).init(alloc);
    _ = try c_qoi.encode(alloc, png_img.header, png_img.pixels, buf_c.writer());

    var buf_zig = std.ArrayList(u8).init(alloc);
    _ = try qoi.encode(png_img.header, png_img.pixels, buf_zig.writer());

    return std.mem.eql(u8, buf_c.items, buf_zig.items);
}

fn readPngImage(alloc: std.mem.Allocator, png_file: *std.fs.File) !struct { header: qoi.QoiHeaderInfo, pixels: []qoi.Rgba } {
    var img = try Image.fromFile(alloc, png_file);

    const header = qoi.QoiHeaderInfo{
        .width = @intCast(u32, img.width),
        .height = @intCast(u32, img.height),
        .channels = 4,
        .colorspace = qoi.QoiColorspace.sRGB,
    };

    var list = std.ArrayList(qoi.Rgba).init(alloc);
    var img_iter = img.iterator();
    while (img_iter.next()) |px| {
        const rgba32 = px.toRgba32();
        try list.append(.{
            .r = rgba32.r,
            .g = rgba32.g,
            .b = rgba32.b,
            .a = rgba32.a,
        });
    }

    return .{ .header = header, .pixels = try list.toOwnedSlice() };
}
