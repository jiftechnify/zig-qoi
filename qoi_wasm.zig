const std = @import("std");
const qoi = @import("src/qoi.zig");

/// Allocates a byte buffer on the wasm linear memory and returns its memory offset.
export fn allocateBuffer(len: usize) ?[*]u8 {
    log(.info, "allocateBuffer len: {}", .{ len });
    var buf = std.heap.page_allocator.alloc(u8, len) catch |err| {
        log(.err, "failed to allocate buffer: {!}", .{err});
        return null;
    };
    return buf.ptr;
}

/// Frees the byte buffer allocated on wasm linear memory.
export fn freeBuffer(ptr: [*]u8, len: usize) void {
    log(.info, "freeBuffer ptr: {*}, len: {}", .{ ptr, len });
    std.heap.page_allocator.free(ptr[0..len]);
}

const QoiHeaderInfo = extern struct {
    width: u32, // 0
    height: u32, // 4
    channels: u8, // 8
    colorspace: qoi.Colorspace, // 9
};

/// QOI-formatted image data buffer.
const QoiData = extern struct {
    buf: [*]u8, // 0
    len: usize, // 4
};

export fn encode(header: QoiHeaderInfo, img_buf: [*]const u8, img_len: u32) ?*QoiData {
    log(.info, "log from encoder!", .{});

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloactor = arena.allocator();

    const h = qoi.HeaderInfo{
        .width = header.width,
        .height = header.height,
        .channels = header.channels,
        .colorspace = header.colorspace,
    };

    var pixels = std.ArrayList(qoi.Rgba).init(alloactor);
    var i: usize = 0;
    while (i < img_len) : (i += 4) {
        const px = qoi.Rgba{
            .r = img_buf[i + 0],
            .g = img_buf[i + 1],
            .b = img_buf[i + 2],
            .a = img_buf[i + 3],
        };
        pixels.append(px) catch |err| {
            log(.err, "failed to encode: {!}", .{err});
            return null;
        };
    }

    const img_data = qoi.ImageData{
        .header = h,
        .pixels = pixels.items,
    };

    var out_buf = std.ArrayList(u8).init(std.heap.page_allocator);
    qoi.encode(img_data, out_buf.writer()) catch |err| {
        log(.err, "failed to encode: {!}", .{err});
        return null;
    };

    return &.{
        .buf = out_buf.items.ptr,
        .len = out_buf.items.len,
    };
}

/// QOI header + ImageData(array of RGBA32 pixels)
const ImageDataWithQoiHeader = extern struct {
    header: QoiHeaderInfo, // 0
    buf: [*]u8, // 12
    len: usize, // 16
};

export fn decode(buf: [*]const u8, len: usize) ?*ImageDataWithQoiHeader {
    log(.info, "log from decoder!", .{});

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fbs = std.io.fixedBufferStream(buf[0..len]);
    const res = qoi.decode(allocator, fbs.reader()) catch |err| {
        log(.err, "failed to decode: {!}", .{err});
        return null;
    };

    const h = QoiHeaderInfo{
        .width = res.header.width,
        .height = res.header.height,
        .channels = res.header.channels,
        .colorspace = res.header.colorspace,
    };
    var out_buf = std.ArrayList(u8).init(std.heap.page_allocator);
    for (res.pixels) |p| {
        out_buf.appendSlice(&.{ p.r, p.g, p.b, p.a }) catch |err| {
            log(.err, "failed to decode: {!}", .{err});
            return null;
        };
    }

    return &.{
        .header = h,
        .buf = out_buf.items.ptr,
        .len = out_buf.items.len,
    };
}

// credits: https://github.com/ousttrue/zig-opengl-wasm
/// Writes log to JS console.
extern fn console_logger(level: c_int, ptr: *const u8, size: c_int) void;

fn extern_write(level: c_int, m: []const u8) error{}!usize {
    if (m.len > 0) {
        console_logger(level, &m[0], @intCast(c_int, m.len));
    }
    return m.len;
}

fn log(
    comptime message_level: std.log.Level,
    comptime format: []const u8,
    args: anytype,
) void {
    const level = switch (message_level) {
        .err => 0,
        .warn => 1,
        .info => 2,
        .debug => 3,
    };
    const w = std.io.Writer(c_int, error{}, extern_write){
        .context = level,
    };
    w.print(format, args) catch |err| {
        const err_name = @errorName(err);
        extern_write(0, err_name) catch unreachable;
    };
    _ = extern_write(level, "\n") catch unreachable;
}
