const std = @import("std");
const PNG = @import("zigimg").png.PNG;

pub fn main() !void {
    // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        const leaked = gpa.deinit();
        if (leaked) {
            @panic("GPA: memory leak");
        }
    }

    const png_file = try std.fs.cwd().openFile("blackleaf.png", .{});
    defer png_file.close();
    
    var png_stream = std.io.StreamSource{ .file = png_file };
    
    const img = try PNG.readImage(allocator, &png_stream);
    std.debug.print("{}", img);
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
