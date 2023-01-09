const std = @import("std");

pub const testing = struct {
    // workaround for an issue of `expectEqual`.
    //
    // When a comptime-known value is passed as `expected`, the compiler complains that
    // `actual` value must be comptime-known, although `actual` value is generally runtime-known.
    // So we are forced to cast `expected` to a type of runtime-known value, which is cumbersome.
    //
    // To resolve this issue, we can define wrapper of `expectEqual` which casts `expected` to the type of `actual` automatically.
    //
    // cf. https://github.com/ziglang/zig/issues/4437#issuecomment-683309291
    pub fn expectEqual(expected: anytype, actual: anytype) !void {
        try std.testing.expectEqual(@as(@TypeOf(actual), expected), actual);
    }
};

const expectEqual = testing.expectEqual;

/// Checks if given `i8` value fits in the range of type `T`.
///
/// `T` must be a signed integer type.
pub fn fitsIn(comptime T: type, n: i8) bool {
    switch (@typeInfo(T)) {
        .Int => |i| {
            switch (i.signedness) {
                .signed => {
                    if (i.bits > 8) {
                        @compileError("T's number of bits should be less than or equal to 8");
                    }
                    return std.math.minInt(T) <= n and n <= std.math.maxInt(T);
                },
                .unsigned => @compileError("T should be signed integer type"),
            }
        },
        else => @compileError("T should be signed integer type"),
    }
}

test "fitsIn" {
    try expectEqual(false, fitsIn(i2, -3));
    try expectEqual(true, fitsIn(i2, -2));
    try expectEqual(true, fitsIn(i2, -1));
    try expectEqual(true, fitsIn(i2, 0));
    try expectEqual(true, fitsIn(i2, 1));
    try expectEqual(false, fitsIn(i2, 2));

    try expectEqual(true, fitsIn(i4, 7));
    try expectEqual(true, fitsIn(i4, -8));
    try expectEqual(false, fitsIn(i4, 8));

    try expectEqual(true, fitsIn(i6, 31));
    try expectEqual(true, fitsIn(i6, -32));
    try expectEqual(false, fitsIn(i6, 32));
}

/// Add `bias` to `n` and convert it to `u8` by bit-preserving cast.
pub fn addBias(n: i8, bias: i8) u8 {
    return @bitCast(u8, n +% bias);
}

test "addBias" {
    try expectEqual(0, addBias(-2, 2));
    try expectEqual(1, addBias(-1, 2));
    try expectEqual(2, addBias(0, 2));
    try expectEqual(3, addBias(1, 2));

    try expectEqual(0, addBias(-8, 8));
    try expectEqual(8, addBias(0, 8));
    try expectEqual(15, addBias(7, 8));

    try expectEqual(0, addBias(-32, 32));
    try expectEqual(32, addBias(0, 32));
    try expectEqual(63, addBias(31, 32));
}
