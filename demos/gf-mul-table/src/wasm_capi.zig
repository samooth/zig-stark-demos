//! WASM C-ABI for the Binius GF-multiplication-table demo.
//!
//! Exposes prove/verify over the canonical serialized wire format
//! (see zig-stark docs/wire.md). The constraint system (three 4-bit range
//! checks + 4-bit field multiplication via tower tensor) is baked in at
//! comptime; only the witness columns and boundary pins vary per invocation.
//!
//! Wire format (little-endian):
//!   - k:           u8  (hypercube dimension, n = 2^k)
//!   - columns:     u64 len, then per-column: u64 len + F elements (1 byte each for Gf256)
//!   - pins:        u64 len, then per-pin: u64 col, u64 point, 1 byte value
//!   - roots:       u64 len, then per-root: 32 bytes
//!   - proof:       serialized Stark.Proof

const std = @import("std");
const builtin = @import("builtin");
const circuit = @import("circuit");
const zig_stark = @import("zig-stark");
const Ser = zig_stark.core.serialization;
const Hash = zig_stark.hash.Hash;

const F = circuit.F;
const Stark = circuit.Stark;
const num_cols = circuit.num_cols;

const Error = error{ InvalidInput, OutOfMemory, Protocol };

fn errCode(err: anyerror) c_int {
    return switch (err) {
        error.OutOfMemory => -3,
        error.InvalidInput, error.TrailingBytes, error.UnexpectedEnd => -2,
        error.Protocol => -4,
        else => -1,
    };
}

// ---------------------------------------------------------------------------
// Host memory management: on wasm the host imports zig_stark_malloc/free.
// The JS side provides a monotonic bump over the module's linear memory.
// ---------------------------------------------------------------------------

extern fn zig_stark_malloc(size: usize) ?[*]u8;
extern fn zig_stark_free(ptr: [*]u8, size: usize) void;

const Header = struct { orig: usize, size: usize };

fn importedMalloc(size: usize) ?[*]u8 {
    if (comptime builtin.cpu.arch == .wasm32) return zig_stark_malloc(size);
    @panic("wasm_capi is wasm32-only");
}

fn importedFree(ptr: [*]u8, size: usize) void {
    if (comptime builtin.cpu.arch == .wasm32) {
        zig_stark_free(ptr, size);
        return;
    }
    @panic("wasm_capi is wasm32-only");
}

fn importedAllocImpl(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
    _ = ctx;
    _ = ra;
    const min_bytes = @max(alignment.toByteUnits(), @alignOf(Header));
    const pad = min_bytes - 1;
    const total = @sizeOf(Header) + pad + n;
    const base = importedMalloc(total) orelse return null;
    const base_addr: usize = @intFromPtr(base);
    const payload_addr = std.mem.alignForward(usize, base_addr + @sizeOf(Header), min_bytes);
    const header_ptr: *Header = @ptrFromInt(payload_addr - @sizeOf(Header));
    header_ptr.* = .{ .orig = base_addr, .size = total };
    return @ptrFromInt(payload_addr);
}

fn importedFreeImpl(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
    _ = ctx;
    _ = alignment;
    _ = ra;
    const addr: usize = @intFromPtr(memory.ptr);
    const header_ptr: *Header = @ptrFromInt(addr - @sizeOf(Header));
    const h = header_ptr.*;
    importedFree(@ptrFromInt(h.orig), h.size);
}

fn makeAllocator() std.mem.Allocator {
    return .{
        .ptr = @constCast(@as(*anyopaque, @ptrFromInt(@alignOf(usize)))),
        .vtable = &.{
            .alloc = importedAllocImpl,
            .resize = resizeImpl,
            .remap = remapImpl,
            .free = importedFreeImpl,
        },
    };
}

fn resizeImpl(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
    _ = ctx;
    _ = memory;
    _ = alignment;
    _ = new_len;
    _ = ra;
    return false;
}

fn remapImpl(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
    _ = ctx;
    _ = memory;
    _ = alignment;
    _ = new_len;
    _ = ra;
    return null;
}

fn sliceOf(ptr: ?[*]const u8, len: usize) []const u8 {
    return if (ptr) |p| p[0..len] else &[_]u8{};
}

// ---------------------------------------------------------------------------
// Prove
// ---------------------------------------------------------------------------

fn prove(
    alloc: std.mem.Allocator,
    k: usize,
    columns_bytes: []const u8,
    pins_bytes: []const u8,
) !struct { proof: []u8, roots: []u8 } {
    const columns = try Ser.deserialize(alloc, columns_bytes, []const []const F);
    defer {
        for (columns) |c| alloc.free(c);
        alloc.free(columns);
    }
    const pins = try Ser.deserialize(alloc, pins_bytes, []const Stark.Pin);
    defer alloc.free(pins);

    var proof = try Stark.prove(alloc, k, columns, &circuit.constraints, pins, circuit.domain);
    defer proof.deinit(alloc);

    const roots = try alloc.alloc(Hash.Digest, num_cols);
    defer alloc.free(roots);
    for (0..num_cols) |c| {
        var tree = try circuit.PCS.commit(alloc, columns[c]);
        defer tree.deinit();
        roots[c] = tree.root();
    }

    const proof_ser = try Ser.serialize(alloc, proof);
    const roots_ser = try Ser.serialize(alloc, roots);
    return .{ .proof = proof_ser, .roots = roots_ser };
}

pub export fn zs_version() callconv(.c) [*:0]const u8 {
    return "binius-gf-mul-table 0.1.0 (Gf256/Gf2_128)";
}

pub export fn zs_prove(
    k: u8,
    columns_ptr: ?[*]const u8,
    columns_len: usize,
    pins_ptr: ?[*]const u8,
    pins_len: usize,
    out_proof: *[*]u8,
    out_proof_len: *usize,
    out_roots: *[*]u8,
    out_roots_len: *usize,
) callconv(.c) c_int {
    const alloc = makeAllocator();
    const columns_bytes = sliceOf(columns_ptr, columns_len);
    const pins_bytes = sliceOf(pins_ptr, pins_len);

    const result = prove(alloc, k, columns_bytes, pins_bytes) catch |err| return errCode(err);
    out_proof.* = result.proof.ptr;
    out_proof_len.* = result.proof.len;
    out_roots.* = result.roots.ptr;
    out_roots_len.* = result.roots.len;
    return 0;
}

// ---------------------------------------------------------------------------
// Verify
// ---------------------------------------------------------------------------

fn verify(
    alloc: std.mem.Allocator,
    k: usize,
    roots_bytes: []const u8,
    pins_bytes: []const u8,
    proof_bytes: []const u8,
) !bool {
    const roots = try Ser.deserialize(alloc, roots_bytes, []const Hash.Digest);
    defer alloc.free(roots);
    const pins = try Ser.deserialize(alloc, pins_bytes, []const Stark.Pin);
    defer alloc.free(pins);
    var proof = try Ser.deserialize(alloc, proof_bytes, Stark.Proof);
    defer proof.deinit(alloc);
    return try Stark.verify(alloc, k, roots, &circuit.constraints, pins, proof, circuit.domain);
}

pub export fn zs_verify(
    k: u8,
    roots_ptr: ?[*]const u8,
    roots_len: usize,
    pins_ptr: ?[*]const u8,
    pins_len: usize,
    proof_ptr: ?[*]const u8,
    proof_len: usize,
    out_ok: *bool,
) callconv(.c) c_int {
    const alloc = makeAllocator();
    const roots_bytes = sliceOf(roots_ptr, roots_len);
    const pins_bytes = sliceOf(pins_ptr, pins_len);
    const proof_bytes = sliceOf(proof_ptr, proof_len);

    const ok = verify(alloc, k, roots_bytes, pins_bytes, proof_bytes) catch |err| return errCode(err);
    out_ok.* = ok;
    return 0;
}

// ---------------------------------------------------------------------------
// Free
// ---------------------------------------------------------------------------

pub export fn zs_free(ptr: ?[*]u8, len: usize) callconv(.c) void {
    if (ptr) |p| makeAllocator().free(p[0..len]);
}
