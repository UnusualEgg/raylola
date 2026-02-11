const std = @import("std");

pub fn main() !void {
    var stdout = std.fs.File.stdout().writer(&.{});
    const w = &stdout.interface;
    try w.print("Hello world {any}\n", .{@typeInfo(@TypeOf(main))});
}
