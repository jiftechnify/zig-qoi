const std = @import("std");

const qoi = @import("../src/qoi.zig");
const c_qoi = @import("./c_qoi_wrapper.zig");

const expectEqual = @import("../src/utils.zig").expectEqual;

const dirpath_test_images = "tests/images";

test "QOI decode" {
    // skip test if the test images directory does not exist.
    const dir_test_images = std.fs.cwd().openIterableDir(dirpath_test_images, .{}) catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest else return err;
    };
    var iter = dir_test_images.iterate();

    std.debug.print("\n", .{});

    var failed = false;
    while (try iter.next()) |e| {
        if (e.kind == .File and std.mem.eql(u8, std.fs.path.extension(e.name), ".qoi")) {
            std.debug.print("{s} ... ", .{e.name});

            var qoi_file = try dir_test_images.dir.openFile(e.name, .{});
            if (testDecode(&qoi_file)) |_| {
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

fn testDecode(qoi_file: *std.fs.File) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var buffered = std.io.bufferedReader(qoi_file.reader());

    const res_c = try c_qoi.decode(alloc, buffered.reader(), try qoi_file.getEndPos());

    try qoi_file.seekTo(0);
    const res_zig = try qoi.decode(alloc, buffered.reader());

    try expectEqual(res_zig.header, res_c.header);
    try expectEqual(res_zig.pixels.len, res_c.pixels.len);
    var i: usize = 0;
    while (i < res_zig.pixels.len) : (i += 1) {
        try expectEqual(res_zig.pixels[i], res_c.pixels[i]);
    }
}
