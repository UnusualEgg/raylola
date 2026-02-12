const rl = @import("raylib");
const lola = @import("lola");
const std = @import("std");

const Value = lola.runtime.Value;
const Env = lola.runtime.Environment;
const TypeID = std.meta.Tag(Value);
const Ctx = lola.runtime.Context;

const root = @import("root");
const GlobalObjectPool = if (@import("builtin").is_test)
    // we need to do a workaround here for testing purposes
    lola.runtime.objects.ObjectPool([_]type{
        lola.libs.runtime.LoLaList,
        lola.libs.runtime.LoLaDictionary,
    })
else if (@hasDecl(root, "ObjectPool"))
    root.ObjectPool
else
    @compileError("Please define and use a global ObjectPool type to use the raylib classes.");

pub const lola_module = struct {

    //pub const UserFunctionCall = *const (fn (
    //    environment: *Environment,
    //    context: AnyPointer,
    //    args: []const Value,
    //) anyerror!Value);
    fn canTranslateZigToLoLa(T: type) bool {
        const info = @typeInfo(T);
        return switch (info) {
            .int, .float => true,
            .pointer => |p| if (p.child == u8 and p.is_const and ((p.size == .many and p.sentinel() != null) or p.size == .slice)) true else false,
            .void => true,
            .bool => true,
            else => false,
        };
    }
    fn zigToLoLaValue(allocator: std.mem.Allocator, zig_value: anytype) anyerror!Value {
        const T = @TypeOf(zig_value);
        const info = @typeInfo(T);
        switch (info) {
            .int, .float => return Value.initInteger(T, zig_value),
            .pointer => |p| {
                if (p.child == u8 and p.is_const) {
                    switch (p.size) {
                        .many => {
                            if (p.sentinel() == null) unreachable;
                            return Value.initString(allocator, std.mem.span(zig_value));
                        },
                        .slice => {
                            return Value.initString(allocator, zig_value);
                        },
                        else => unreachable,
                    }
                } else unreachable;
            },
            .bool => return Value.initBoolean(zig_value),
            .void => return .void,
            else => unreachable,
        }
    }
    //null = not possible to translate
    fn CanTranslateLoLaToZigValue(T: type) bool {
        const info = @typeInfo(T);
        switch (info) {
            .int, .float => {
                return true;
            },
            .pointer => |p| if (p.child == u8 and ((p.size == .many and p.sentinel() != null) or p.size == .slice)) return true else return false,
            else => return false,
        }
    }
    fn LoLaToZigValue(allocator: std.mem.Allocator, value: Value, T: type) anyerror!T {
        const info = @typeInfo(T);
        switch (info) {
            .int, .float => {
                return value.toInteger(T);
            },
            .pointer => |p| {
                if (p.child == u8 and ((p.size == .many and p.sentinel() != null) or p.size == .slice)) {
                    if (p.sentinel()) |sentinel| {
                        const s = try value.toString();
                        const buf = try allocator.allocSentinel(u8, s.len, sentinel);
                        @memcpy(buf, s);
                        return buf;
                    } else {
                        return value.toString();
                    }
                } else unreachable;
            },
            else => unreachable,
        }
    }
    fn generateLoLaFn(function: anytype) (fn (
        environment: *Env,
        context: Ctx,
        args: []const Value,
    ) anyerror!Value) {
        const T = @TypeOf(function);
        if (@typeInfo(T) != .@"fn") @compileError("only functions supported");
        const info = @typeInfo(T).@"fn";
        const params = info.params;
        if (info.return_type) |RetType| {
            if (!canTranslateZigToLoLa(RetType)) @compileError("unable to translate return type");
        }
        comptime {
            for (params) |param| {
                if (param.type) |ParamT| {
                    if (!CanTranslateLoLaToZigValue(ParamT))
                        @compileError(std.fmt.comptimePrint("type {s} not compatible with LoLa", .{@typeName(ParamT)}));
                }
            }
            // @compileLog("generating func of type ", T);
        }

        return struct {
            const FnPtr = &function;
            // const name = func_name;
            fn func(env: *Env, ctx: Ctx, args: []const Value) anyerror!Value {
                _ = &env;
                _ = &ctx;
                if (args.len != params.len) return error.InvalidArgs;

                const StructField = std.builtin.Type.StructField;
                const TupleT = comptime blk: {
                    var fields_buf: [params.len]StructField = undefined;
                    for (params, 0..) |param, i| {
                        const ParamT = param.type orelse @compileError("param must have type");
                        const field_name = std.fmt.comptimePrint("{d}", .{i});
                        fields_buf[i] = StructField{
                            .name = field_name,
                            .type = ParamT,
                            .default_value_ptr = null,
                            .is_comptime = false,
                            .alignment = @alignOf(ParamT),
                        };
                    }
                    const TupleType = @Type(std.builtin.Type{ .@"struct" = .{
                        .is_tuple = true,
                        .layout = .auto,
                        .decls = &.{},
                        .fields = &fields_buf,
                    } });
                    break :blk TupleType;
                };
                var tuple: TupleT = undefined;
                inline for (params, 0..) |param, i| {
                    const ParamT = param.type.?;
                    const field_name = std.fmt.comptimePrint("{d}", .{i});
                    const v = try LoLaToZigValue(env.allocator, args[i], ParamT);
                    @field(tuple, field_name) = v;
                }
                // std.debug.print("calling func {s} of type {s}\n", .{ func_name, std.fmt.comptimePrint("{any}", .{@typeInfo(T)}) });
                // std.debug.print("with {any}\n", .{tuple});
                const ret = @call(.auto, FnPtr, tuple);
                //free allocated stirngs
                inline for (tuple) |t| {
                    const TupT = @TypeOf(t);
                    switch (@typeInfo(TupT)) {
                        .pointer => |p| {
                            if (p.sentinel() != null) {
                                env.allocator.free(t);
                            }
                        },
                        else => {},
                    }
                }
                return zigToLoLaValue(env.allocator, ret);
            }
        }.func;
    }
    pub const InitWindow = generateLoLaFn(rl.initWindow);
    pub const CloseWindow = generateLoLaFn(rl.closeWindow);
    pub const WindowShouldClose = generateLoLaFn(rl.windowShouldClose);
    pub const BeginDrawing = generateLoLaFn(rl.beginDrawing);
    pub const EndDrawing = generateLoLaFn(rl.endDrawing);

    pub fn ClearBackground(env: *Env, ctx: Ctx, args: []const Value) anyerror!Value {
        _ = &ctx;
        _ = &env;
        if (args.len != 4) return error.InvalidArgs;
        const color = rl.Color{
            .r = try args[0].toInteger(u8),
            .g = try args[1].toInteger(u8),
            .b = try args[2].toInteger(u8),
            .a = try args[3].toInteger(u8),
        };
        rl.clearBackground(color);
        return .void;
    }
    fn flagsFromArray(arr: lola.runtime.value.Array) !rl.ConfigFlags {
        var flags: u32 = 0;
        // const flag_vals = std.builtin.Type.StructField
        for (arr.contents) |val| {
            const flag_name = try val.toString();

            inline for (std.meta.fieldNames(rl.ConfigFlags), 0..) |field_name, i| {
                if (std.mem.eql(u8, flag_name, field_name)) {
                    //we can do this because they're bit flags
                    flags |= 1 << i;
                    break;
                }
            } else {
                return error.InvalidArgs;
            }
        }
        return @bitCast(flags);
    }
    pub fn SetWindowState(env: *Env, ctx: Ctx, args: []const Value) anyerror!Value {
        _ = &ctx;
        _ = &env;
        if (args.len != 1) return error.InvalidArgs;
        const arr = try args[0].toArray();
        const flags = try flagsFromArray(arr);
        rl.setWindowState(flags);
        return .void;
    }
    pub fn SetConfigFlags(env: *Env, ctx: Ctx, args: []const Value) anyerror!Value {
        _ = &ctx;
        _ = &env;
        if (args.len != 1) return error.InvalidArgs;
        const arr = try args[0].toArray();
        const flags = try flagsFromArray(arr);
        rl.setConfigFlags(flags);
        return .void;
    }
    pub fn DrawRectangle(env: *Env, ctx: Ctx, args: []const Value) anyerror!Value {
        _ = &ctx;
        _ = &env;
        if (args.len != 8) return error.InvalidArgs;
        const x = try args[0].toInteger(i32);
        const y = try args[1].toInteger(i32);
        const w = try args[2].toInteger(i32);
        const h = try args[3].toInteger(i32);
        const color = rl.Color{
            .r = try args[4].toInteger(u8),
            .g = try args[5].toInteger(u8),
            .b = try args[6].toInteger(u8),
            .a = try args[7].toInteger(u8),
        };
        rl.drawRectangle(x, y, w, h, color);
        return .void;
    }
    pub fn SetTargetFPS(env: *Env, ctx: Ctx, args: []const Value) anyerror!Value {
        _ = &ctx;
        _ = &env;
        if (args.len != 1) return error.InvalidArgs;
        const fps = try args[0].toInteger(i32);
        rl.setTargetFPS(fps);
        return .void;
    }
    pub fn IsKey1Pressed(env: *Env, ctx: Ctx, args: []const Value) anyerror!Value {
        _ = &ctx;
        _ = &env;
        if (args.len != 0) return error.InvalidArgs;
        return Value.initBoolean(rl.isKeyPressed(.one));
    }
    pub fn IsKey2Pressed(env: *Env, ctx: Ctx, args: []const Value) anyerror!Value {
        _ = &ctx;
        _ = &env;
        if (args.len != 0) return error.InvalidArgs;
        return Value.initBoolean(rl.isKeyPressed(.two));
    }
    pub fn GetRenderWidth(env: *Env, ctx: Ctx, args: []const Value) anyerror!Value {
        _ = &ctx;
        _ = &env;
        if (args.len != 0) return error.InvalidArgs;
        return Value.initInteger(i32, rl.getRenderWidth());
    }
    pub fn GetRenderHeight(env: *Env, ctx: Ctx, args: []const Value) anyerror!Value {
        _ = &ctx;
        _ = &env;
        if (args.len != 0) return error.InvalidArgs;
        return Value.initInteger(i32, rl.getRenderHeight());
    }

    // pub fn CreateColor(env: *Env, ctx: Ctx, args: []const Value) anyerror!Value {
    //     _ = &ctx;
    //     if (args.len != 4) return error.InvalidArgs;
    //     const color = try env.allocator.create(Objects.Color);
    //     errdefer env.allocator.destroy(color);
    //     color.* = .{
    //         .allocator = env.allocator,
    //         .data = ,
    //     };
    //     return lola.runtime.value.Value.initObject(
    //         try env.objectPool.castTo(GlobalObjectPool).createObject(color),
    //     );
    // }
    // pub const UserFunctionCall = *const (fn (
    //     environment: *Env,
    //     context: Ctx,
    //     args: []const Value,
    // ) anyerror!Value);
};
