const std = @import("std");
const zig_stark = @import("zig-stark");
const Ser = zig_stark.core.serialization;
const F = zig_stark.field.Gf256;

const Inner = struct {
    rounds: []const []const F,
};

const Outer = struct {
    inner: Inner,
    data: []const []const F,
};

pub export fn test_nested_ser() callconv(.c) usize {
    const alloc = makeAllocator();
    const e1: F = F.fromInt(0x42);
    const e2: F = F.fromInt(0x99);
    var a: [2]F = .{e1, e2};
    var b: [3]F = .{e2, e1, e2};
    var data_arr: [2][]const F = .{&a, &b};
    const inner: Inner = .{ .rounds = &data_arr };
    const outer: Outer = .{ .inner = inner, .data = &data_arr };
    const ser = Ser.serialize(alloc, outer) catch return 0;
    const len = ser.len;
    alloc.free(ser);
    return len;
}

var _bump: usize = 65536;
var _mem: [88000]u8 = undefined;

fn alloc_impl(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
    _ = ctx; _ = alignment; _ = ra;
    const aligned_n = (n + 7) & ~@as(usize, 7);
    if (_bump + aligned_n > @intFromPtr(&_mem) + _mem.len) return null;
    const result: [*]u8 = @ptrFromInt(_bump);
    _bump += aligned_n;
    return result;
}

fn resize_impl(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
    _ = ctx; _ = mem; _ = alignment; _ = new_len; _ = ra;
    return false;
}

fn remap_impl(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
    _ = ctx; _ = mem; _ = alignment; _ = new_len; _ = ra;
    return null;
}

fn free_impl(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, ra: usize) void {
    _ = ctx; _ = mem; _ = alignment; _ = ra;
}

fn makeAllocator() std.mem.Allocator {
    return .{
        .ptr = undefined,
        .vtable = &.{
            .alloc = alloc_impl,
            .resize = resize_impl,
            .remap = remap_impl,
            .free = free_impl,
        },
    };
}

// Need _start for wasm build
export fn _start() void {}
