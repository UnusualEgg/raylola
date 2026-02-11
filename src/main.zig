const std = @import("std");
const lola = @import("lola");
const rl = @import("raylib.zig");

pub const ObjectPool = lola.runtime.objects.ObjectPool([_]type{
    lola.libs.runtime.LoLaDictionary,
    lola.libs.runtime.LoLaList,
});

const File = struct {
    name: [:0]const u8,
    data: []const u8,
};

fn parseArgs(allocator: std.mem.Allocator) !File {
    var args = try std.process.argsWithAllocator(allocator);
    _ = args.skip();
    const name = args.next() orelse {
        std.debug.print("expected LoLa file\n", .{});
        return error.InvalidArgs;
    };
    const data = try std.fs.cwd().readFileAlloc(allocator, name, std.math.maxInt(usize));
    errdefer allocator.free(data);

    return File{
        .name = allocator.dupeZ(u8, name),
        .data = data,
    };
}

pub fn main() !void {
    // var stdout = std.fs.File.stdout().writer(&.{});
    // const w = &stdout.interface;
    // try w.print("Hello world {any}\n", .{@typeInfo(@TypeOf(main))});
    const allocator = std.heap.smp_allocator;
    var pool = ObjectPool.init(allocator);
    defer pool.deinit();

    var diag = lola.compiler.Diagnostics.init(allocator);
    defer {
        for (diag.messages.items) |msg| {
            std.debug.print("{f}\n", msg);
        }
        diag.deinit();
    }

    const file = try parseArgs();
    defer allocator.free(file.name);
    defer allocator.free(file.data);

    const cu = try lola.compiler.compile(allocator, &diag, file.name, file.data) orelse return error.CompileError;
    defer cu.deinit();

    var env = try lola.runtime.Environment.init(allocator, &cu, pool.interface());
    defer env.deinit();

    env.installModule(lola.libs.runtime, .null_pointer);
    env.installModule(lola.libs.std, .null_pointer);
    env.installModule(rl.lola_module, .null_pointer);

    var vm = try lola.runtime.VM.init(allocator, &env);
    defer vm.deinit();

    while (true) {
        const res = try vm.execute(1024);
        pool.clearUsageCounters();
        pool.walkEnvironment(env);
        pool.walkVM(vm);
        pool.collectGarbage();
        switch (res) {
            .exhausted => {},
            .completed => break,
            .paused => {},
        }
    }
}
