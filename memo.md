- zigimg's README says: 
  > This project assume current Zig master (0.10.0+)

  but accutually it only works with *0.11.0+*, not 0.10.0+.
    
    - Mainly due to incompatibilities of `std.buildin.Type.StructField`.
