## zigimg

- zigimg's README says: 
  > This project assume current Zig master (0.10.0+)

  but accutually it only works with *0.11.0+*, not 0.10.0+.
    
    - Mainly due to incompatibilities of `std.buildin.Type.StructField`.

- Images of any format can be read using `Image.fromFilePath/fromFile/fromMemory`, as value of the `Image` type.

- In addition to pixel data, we can get width and height of the image from struct `Image`.

- An iterator that iterates over pixels of the image can be obtained from `Image` by `iterator` method.

## I/O in zig

- Via `io.FixedBufferStream([]u8)`, we can use `[]u8` as `io.Writer` and `io.Reader`.

```zig
var buf = [100]u8 = undefined;
var stream = std.io.FixedBufferStream([]u8){ .buffer = &buf, .pos = 0 };

stream.writer();    // convert to `io.Writer`
stream.reader();    // convert to `io.Reader`
```

- `io.StreamSource` abstracts over `File(.file)`, `FixedBuffer([]u8)(.buffer)` and `FixedBuffer([]const u8)(.const_buffer)` and offers generic I/O interface w/ seeking.

    - if it is `.const_buffer` variant, writing to it will always return error.

- `io.Writer` and `io.Reader` has useful methods for serializing to/deserializing from binary data.

    - `reader.readIntBig(u32)` reads big-endian binary data from the `reader` as `u32` value.
    - `writer.writeIntBig(u32, n)` writes `u32` value to the `writer` as big-endian binary data.
