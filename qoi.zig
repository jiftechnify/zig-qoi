pub const qoi = @import("src/qoi.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("tests/encode_test.zig");
    _ = @import("tests/decode_test.zig");
}
