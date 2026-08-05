const std = @import("std");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const data_size: i32 = 1000000;

    const data = try allocator.alloc(i32, data_size);

    for (data, 0..) |_, i| {
        data[i] = @as(i32, @intCast(i));
    }

    for (data) |i| {
        std.debug.print("My var {}\n", .{i});
    }
}
