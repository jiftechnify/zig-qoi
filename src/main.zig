const std = @import("std");
const Image = @import("zigimg").Image;

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

    // read the image file
    var img = try Image.fromFilePath(allocator, "blackleaf.png");
    defer img.deinit();

    std.debug.print("image size: {} x {}\n", .{ img.width, img.height });

    // get the iterator which iterates over pixels of the image
    // then use it to count number of pixels
    var px_iter = img.iterator();
    var px_cnt: u64 = 0;
    while (px_iter.next()) |_| {
        px_cnt += 1;
    }

    std.debug.print("#pixels: {}\n", .{px_cnt});
}
