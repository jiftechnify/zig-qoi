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

    const img = try Image.fromFile(alloc, png_file);

    const header = qoi.HeaderInfo{
        .width = @intCast(u32, img.width),
        .height = @intCast(u32, img.height),
        .channels = 4,
        .colorspace = qoi.Colorspace.sRGB,
    };

    var px_iter = qoi.ZigimgPixelIterator.init(img.iterator());
    var buf_c = std.ArrayList(u8).init(alloc);
    try c_qoi.encode(alloc, header, &px_iter, buf_c.writer());

    px_iter = qoi.ZigimgPixelIterator.init(img.iterator());
    var buf_zig = std.ArrayList(u8).init(alloc);
    try qoi.encode(header, &px_iter, buf_zig.writer());

    try std.testing.expectEqualSlices(u8, buf_c.items, buf_zig.items);
}

const testcard_path = "tests/images/testcard_rgba.png";
const test_out_path = "test.qoi";

test "encodeToFile" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // skip test if the test image does not exist.
    var src_f = std.fs.cwd().openFile(testcard_path, .{}) catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest else return err;
    };
    defer src_f.close();

    const img = try Image.fromFile(alloc, &src_f);
    const header = qoi.HeaderInfo{
        .width = @intCast(u32, img.width),
        .height = @intCast(u32, img.height),
        .channels = 4,
        .colorspace = qoi.Colorspace.sRGB,
    };
    var px_iter = qoi.ZigimgPixelIterator.init(img.iterator());

    var dst_f = try std.fs.cwd().createFile(test_out_path, .{});
    defer {
        dst_f.close();
        std.fs.cwd().deleteFile(test_out_path) catch |err| {
            std.debug.print("failed to delete test output file: {!}", .{err});
        };
    }

    try qoi.encodeToFile(header, &px_iter, &dst_f);
}

test "encodeToFileByPath" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // skip test if the test image does not exist.
    var src_f = std.fs.cwd().openFile(testcard_path, .{}) catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest else return err;
    };
    defer src_f.close();

    const img = try Image.fromFile(alloc, &src_f);
    const header = qoi.HeaderInfo{
        .width = @intCast(u32, img.width),
        .height = @intCast(u32, img.height),
        .channels = 4,
        .colorspace = qoi.Colorspace.sRGB,
    };
    var px_iter = qoi.ZigimgPixelIterator.init(img.iterator());

    _ = try qoi.encodeToFileByPath(header, &px_iter, test_out_path);
    defer {
        std.fs.cwd().deleteFile(test_out_path) catch |err| {
            std.debug.print("failed to delete test output file: {!}", .{err});
        };
    }
}
