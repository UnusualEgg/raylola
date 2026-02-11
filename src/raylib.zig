const rl = @import("raylib");
const lola = @import("lola");
const std = @import("std");

pub const lola_module = struct {
    const Value = lola.runtime.Value;
    const Env = lola.runtime.Environment;
    const TypeID = std.meta.Tag(Value);

    //pub const UserFunctionCall = *const (fn (
    //    environment: *Environment,
    //    context: AnyPointer,
    //    args: []const Value,
    //) anyerror!Value);
    fn zigToLoLa(T: type) ?TypeID {
        const info = @typeInfo(T);
        return switch (info) {
            .int, .float => .number,
            .pointer => |p| if (p.child == u8 and (p.size == .many or p.size == .slice)) .string else null,
            .void => .void,
            else => null,
        };
    }
    fn LoLaToZigValue(value: Value, T: type) T {
        const info = @typeInfo(T);
        switch (T) {
            .int, .float => value.toInteger(T),
        }
    }
};
