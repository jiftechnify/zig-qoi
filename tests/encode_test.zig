const std = @import("std");

const qoi = @import("../src/qoi.zig");
const c_qoi = @import("./c_qoi_wrapper.zig");

const Image = @import("zigimg").Image;

const dirpath_test_images = "tests/images";

test "QOI encode" {
    // skip test if the test images directory does not exist.
    const dir_test_images = std.fs.cwd().openIterableDir(dirpath_test_images, .{}) catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest else return err;
    };
    var iter = dir_test_images.iterate();

    std.debug.print("\n", .{});

    var failed = false;
    while (try iter.next()) |e| {
        if (e.kind == .File and std.mem.eql(u8, std.fs.path.extension(e.name), ".png")) {
            std.debug.print("{s} ... ", .{e.name});

            var png_file = try dir_test_images.dir.openFile(e.name, .{});
            if (testEncode(&png_file)) |_| {
                std.debug.print("OK\n", .{});
            } else |err| {
                failed = true;
                std.debug.print("NG: {!}\n", .{err});
            }
        }
    }

    if (failed) {
        return error.TestFailed;
    }
}

fn testEncode(png_file: *std.fs.File) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const png_img = try readPngImage(alloc, png_file);

    var buf_c = std.ArrayList(u8).init(alloc);
    try c_qoi.encode(alloc, png_img, buf_c.writer());

    var buf_zig = std.ArrayList(u8).init(alloc);
    try qoi.encode(png_img, buf_zig.writer());

    try std.testing.expectEqualSlices(u8, buf_c.items, buf_zig.items);
}

fn readPngImage(alloc: std.mem.Allocator, png_file: *std.fs.File) !qoi.ImageData {
    var img = try Image.fromFile(alloc, png_file);

    const header = qoi.HeaderInfo{
        .width = @intCast(u32, img.width),
        .height = @intCast(u32, img.height),
        .channels = 4,
        .colorspace = qoi.Colorspace.sRGB,
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

const testcard_path = "tests/images/testcard_rgba.png";
const test_out_path = "test.qoi";

test "encodeToFile" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // skip test if the test image does not exist.
    var f = std.fs.cwd().openFile(testcard_path, .{}) catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest else return err;
    };
    const img_data = try readPngImage(alloc, &f);

    var out_f = try std.fs.cwd().createFile(test_out_path, .{});

    try qoi.encodeToFile(img_data, &out_f);

    std.fs.cwd().deleteFile(test_out_path) catch |err| {
        std.debug.print("failed to delete test output file: {!}", .{err});
    };
}

test "encodeToFileByPath" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // skip test if the test image does not exist.
    var f = std.fs.cwd().openFile(testcard_path, .{}) catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest else return err;
    };
    const img_data = try readPngImage(alloc, &f);

    _ = try qoi.encodeToFileByPath(img_data, test_out_path);

    std.fs.cwd().deleteFile(test_out_path) catch |err| {
        std.debug.print("failed to delete test output file: {!}", .{err});
    };
}
