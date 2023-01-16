const std = @import("std");
const qoi = @import("./qoi.zig");
const generic_path = @import("./utils.zig").generic_path;
const zigimg = @import("zigimg");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    if (args.len <= 1) {
        std.debug.print("usage: qoiconv <path to image file>\n", .{});
        std.os.exit(1);
    }

    try convert(allocator, args[1]);
}

fn convert(allocator: std.mem.Allocator, img_path: []const u8) !void {
    var img_file = try generic_path.openFile(img_path, .{});
    var img = try zigimg.Image.fromFile(allocator, &img_file);

    const img_name = std.fs.path.stem(img_path);
    const out_file_name = try std.fmt.allocPrint(allocator, "{s}.qoi", .{img_name});

    const header = qoi.HeaderInfo{
        .width = @intCast(u32, img.width),
        .height = @intCast(u32, img.height),
        .channels = 4,
        .colorspace = .sRGB,
    };
    const pixels = try rgbasFromZigImg(allocator, img);

    try qoi.encodeToFileByPath(.{ .header = header, .pixels = pixels }, out_file_name);
}

fn rgbasFromZigImg(allocator: std.mem.Allocator, img: zigimg.Image) ![]qoi.Rgba {
    var rgbas = std.ArrayList(qoi.Rgba).init(allocator);

    var iter = img.iterator();
    while (iter.next()) |px| {
        const rgba32 = px.toRgba32();
        try rgbas.append(.{
            .r = rgba32.r,
            .g = rgba32.g,
            .b = rgba32.b,
            .a = rgba32.a,
        });
    }

    return rgbas.toOwnedSlice();
}
