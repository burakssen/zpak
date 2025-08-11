const std = @import("std");
const zpak = @import("zpak");

test "Encoder init/deinit and default compression info" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var enc = try zpak.Encoder.init(allocator);
    defer enc.deinit();

    const info = enc.getCompressionInfo();
    try std.testing.expect(info.default_algorithm.len > 0);
    try std.testing.expect(info.available_algorithms.len > 0);
}
