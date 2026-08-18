//! WASM C-ABI for the Binius AES S-box demo.
//!
//! Exposes prove/verify over the canonical serialized wire format.
//! The constraint system (4 S-boxes: inversion + affine) is baked in at comptime.

const std = @import("std");
const builtin = @import("builtin");
const circuit = @import("circuit");
const zig_stark = @import("zig-stark");
const Ser = zig_stark.core.serialization;
const Hash = zig_stark.hash.Hash;

const F = circuit.F;
const E = circuit.E;
const Stark = circuit.Stark;
const num_cols = circuit.num_cols;

var debug_buf: [256]u8 = undefined;

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
    debug_buf[60] = @intCast(proof.sumcheck.rounds.len);
    debug_buf[61] = @intCast(proof.evals.len);
    debug_buf[62] = @intCast(proof_ser.len);
    const roots_ser = try Ser.serialize(alloc, roots);
    return .{ .proof = proof_ser, .roots = roots_ser };
}

/// Self-test: generate witness in Zig, prove, verify, and compare with
/// JS-style witness generation. Also test ser/deser round-trip.
pub export fn zs_self_test(k: u8) callconv(.c) c_int {
    const alloc = makeAllocator();
    const n: usize = @as(usize, 1) << @intCast(k);
    const vals = [_]u8{ 0x00, 0x01, 0x63, 0xFF };

    var inputs: [circuit.NUM_SBOXES][]F = undefined;
    for (0..circuit.NUM_SBOXES) |s| {
        inputs[s] = alloc.alloc(F, n) catch return -3;
    }

    for (0..n) |p| {
        for (0..circuit.NUM_SBOXES) |s| {
            inputs[s][p] = F.fromInt(vals[p % vals.len]);
        }
    }

    const w = circuit.generateWitness(alloc, inputs[0..]) catch { for (inputs) |col| alloc.free(col); return -3; };
    defer circuit.freeWitness(alloc, w);

    const x = inputs[0][0];
    const x_inv = if (x.isZero()) F.zero() else x.inv();
    const out0 = F.fromInt(circuit.aesAffine(@truncate(x_inv.value)));
    const pins = circuit.generatePins(x, out0);

    // Test 1: Native prove+verify
    var proof = Stark.prove(alloc, w.k, &w.columns, &circuit.constraints, &pins, circuit.domain) catch { for (inputs) |col| alloc.free(col); return -3; };
    defer proof.deinit(alloc);

    const roots = circuit.commitRoots(alloc, &w.columns) catch { for (inputs) |col| alloc.free(col); return -3; };

    const ok = Stark.verify(alloc, w.k, &roots, &circuit.constraints, &pins, proof, circuit.domain) catch { for (inputs) |col| alloc.free(col); return -3; };
    debug_buf[200] = if (ok) 1 else 0;

    // Test 2: Ser/deser round-trip (columns as slices, like JS does)
    const cols_slice: []const []const F = w.columns[0..];
    const cols_ser = Ser.serialize(alloc, cols_slice) catch { for (inputs) |col| alloc.free(col); return -3; };
    defer alloc.free(cols_ser);

    const pins_slice: []const Stark.Pin = &pins;
    const pins_ser = Ser.serialize(alloc, pins_slice) catch { for (inputs) |col| alloc.free(col); return -3; };
    defer alloc.free(pins_ser);

    const cols2 = Ser.deserialize(alloc, cols_ser, []const []const F) catch { for (inputs) |col| alloc.free(col); return -3; };
    defer { for (cols2) |c| alloc.free(c); alloc.free(cols2); }
    const pins2 = Ser.deserialize(alloc, pins_ser, []const Stark.Pin) catch { for (inputs) |col| alloc.free(col); return -3; };
    defer alloc.free(pins2);

    // Compare original columns with deserialized columns
    var col_mismatch: u32 = 0;
    for (0..num_cols) |c| {
        for (0..n) |p| {
            if (w.columns[c][p].value != cols2[c][p].value) {
                col_mismatch += 1;
                if (col_mismatch <= 5) {
                    debug_buf[50 + c] = @truncate(w.columns[c][p].value);
                    debug_buf[60 + c] = @truncate(cols2[c][p].value);
                }
            }
        }
    }
    debug_buf[202] = @intCast(col_mismatch);

    // Prove+verify with deserialized columns
    var proof2 = Stark.prove(alloc, w.k, cols2, &circuit.constraints, pins2, circuit.domain) catch { for (inputs) |col| alloc.free(col); return -3; };
    defer proof2.deinit(alloc);

    const ok2 = Stark.verify(alloc, w.k, &roots, &circuit.constraints, pins2, proof2, circuit.domain) catch false;
    debug_buf[201] = if (ok2) 1 else 0;

    // Test 3: Compare JS-style witness computation (towerMul/towerInv) with circuit
    var js_cols: [num_cols][]u8 = undefined;
    for (0..num_cols) |c| js_cols[c] = alloc.alloc(u8, n) catch { for (inputs) |col| alloc.free(col); return -3; };
    defer { for (js_cols) |c| alloc.free(c); }

    for (0..n) |p| {
        for (0..circuit.NUM_SBOXES) |s| {
            const byte = vals[p % vals.len];
            const inv: u8 = if (byte == 0) 0 else @truncate(towerInvZig(3, byte));
            const sq: u8 = @truncate(towerMulZig(3, byte, byte));
            const out_byte = circuit.aesAffine(@truncate(inv));

            for (0..8) |i| js_cols[sboxOff(s, 0 + i)][p] = @truncate((byte >> @intCast(i)) & 1);
            js_cols[sboxOff(s, 8)][p] = byte;
            js_cols[sboxOff(s, 9)][p] = sq;
            js_cols[sboxOff(s, 10)][p] = inv;
            for (0..8) |i| js_cols[sboxOff(s, 11 + i)][p] = @truncate((inv >> @intCast(i)) & 1);
            js_cols[sboxOff(s, 19)][p] = inv;
            for (0..8) |i| js_cols[sboxOff(s, 20 + i)][p] = @truncate((out_byte >> @intCast(i)) & 1);
            js_cols[sboxOff(s, 28)][p] = out_byte;
        }
    }

    var js_mismatch: u32 = 0;
    for (0..num_cols) |c| {
        for (0..n) |p| {
            if (w.columns[c][p].value != js_cols[c][p]) {
                js_mismatch += 1;
                debug_buf[70 + c] = @truncate(w.columns[c][p].value);
                debug_buf[80 + c] = js_cols[c][p];
            }
        }
    }
    debug_buf[203] = @intCast(js_mismatch);

    for (inputs) |col| alloc.free(col);
    return if (ok) 1 else 0;
}

fn sboxOff(s: usize, local: usize) usize {
    return s * STRIDE_LOCAL + local;
}

const STRIDE_LOCAL: usize = 29;

fn towerMulZig(level: u8, a: u128, b: u128) u128 {
    if (level == 0) return a & b;
    const half: u8 = @intCast(@as(u128, 1) << @intCast(level - 1));
    const mask: u128 = (@as(u128, 1) << @intCast(half)) - 1;
    const beta: u128 = if (level == 1) 1 else @as(u128, 1) << @intCast(@as(u8, 1) << @intCast(level - 2));
    const a0 = a & mask;
    const a1 = (a >> @intCast(half)) & mask;
    const b0 = b & mask;
    const b1 = (b >> @intCast(half)) & mask;
    const c0 = towerMulZig(level - 1, a0, b0);
    const c1 = towerMulZig(level - 1, a1, b1);
    const c2 = towerMulZig(level - 1, a0 ^ a1, b0 ^ b1);
    const lo = c0 ^ c1;
    const c1Beta = towerMulZig(level - 1, c1, beta);
    const hi = c2 ^ c0 ^ c1 ^ c1Beta;
    return lo | (hi << @intCast(half));
}

fn towerInvZig(level: u8, a: u128) u128 {
    if (level == 0) return if (a == 1) 1 else 0;
    const half: u8 = @intCast(@as(u128, 1) << @intCast(level - 1));
    const mask: u128 = (@as(u128, 1) << @intCast(half)) - 1;
    const beta: u128 = if (level == 1) 1 else @as(u128, 1) << @intCast(@as(u8, 1) << @intCast(level - 2));
    const a0 = a & mask;
    const a1 = (a >> @intCast(half)) & mask;
    if (a0 == 0 and a1 == 0) return 0;
    const a0_sq = towerMulZig(level - 1, a0, a0);
    const a1_sq = towerMulZig(level - 1, a1, a1);
    const a0a1 = towerMulZig(level - 1, a0, a1);
    const a0a1_beta = towerMulZig(level - 1, a0a1, beta);
    const norm = a0_sq ^ a0a1_beta ^ a1_sq;
    const inv_norm = towerInvZig(level - 1, norm);
    const a1_beta = towerMulZig(level - 1, a1, beta);
    const a0_plus_a1beta = a0 ^ a1_beta;
    const lo = towerMulZig(level - 1, a0_plus_a1beta, inv_norm);
    const hi = towerMulZig(level - 1, a1, inv_norm);
    return lo | (hi << @intCast(half));
}

pub export fn zs_version() callconv(.c) [*:0]const u8 {
    return "binius-aes-sbox 0.1.0 (Gf256/Gf2_128)";
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
    debug_buf[0] = @intCast(roots.len);
    debug_buf[1] = @intCast(k);
    defer alloc.free(roots);
    const pins = try Ser.deserialize(alloc, pins_bytes, []const Stark.Pin);
    for (pins) |p| {
        debug_buf[2 + p.col] = @intCast(p.value.value);
    }
    defer alloc.free(pins);
    var proof = try Ser.deserialize(alloc, proof_bytes, Stark.Proof);
    defer proof.deinit(alloc);
    const ok = try Stark.verify(alloc, k, roots, &circuit.constraints, pins, proof, circuit.domain);
    debug_buf[100] = if (ok) 1 else 0;
    return ok;
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

pub export fn zs_debug_ptr() callconv(.c) [*]u8 {
    return &debug_buf;
}

pub export fn zs_debug_len() callconv(.c) usize {
    return debug_buf.len;
}

// Test: proof ser/deser round-trip
// Generates a simple witness internally, proves, serializes proof, deserializes, verifies.
pub export fn zs_test_ser_basic() callconv(.c) c_int {
    const alloc = makeAllocator();
    
    const data1: []const []const u8 = &[_][]const u8{ &.{1, 2, 3}, &.{4, 5} };
    const ser1 = Ser.serialize(alloc, data1) catch return -3;
    debug_buf[100] = @intCast(ser1.len);
    debug_buf[101] = if (ser1.len == 29) 1 else 0;
    alloc.free(ser1);

    const data2: []const u8 = &[_]u8{ 0xAA, 0xBB };
    const ser2 = Ser.serialize(alloc, data2) catch return -3;
    debug_buf[102] = @intCast(ser2.len);
    debug_buf[103] = if (ser2.len == 10) 1 else 0;
    debug_buf[104] = if (ser2[8] == 0xAA and ser2[9] == 0xBB) 1 else 0;
    alloc.free(ser2);

    var hash: [32]u8 = undefined;
    for (0..32) |i| hash[i] = @intCast(i);
    const hash_slice: []const u8 = &hash;
    const ser3 = Ser.serialize(alloc, hash_slice) catch return -3;
    debug_buf[105] = @intCast(ser3.len);
    debug_buf[106] = if (ser3.len == 40) 1 else 0;
    alloc.free(ser3);

    const fval = F.fromInt(0x42);
    const ser4 = Ser.serialize(alloc, fval) catch return -3;
    debug_buf[107] = @intCast(ser4.len);
    debug_buf[108] = if (ser4.len == 1 and ser4[0] == 0x42) 1 else 0;
    alloc.free(ser4);

    // Serialize []const []const E
    var rounds_arr: [][]E = alloc.alloc([]E, 2) catch return -3;
    rounds_arr[0] = alloc.dupe(E, &[_]E{ E.fromInt(1), E.fromInt(2) }) catch return -3;
    rounds_arr[1] = alloc.dupe(E, &[_]E{ E.fromInt(3) }) catch return -3;
    const rounds_slice: []const []const E = rounds_arr;
    const ser5 = Ser.serialize(alloc, rounds_slice) catch { for (rounds_arr) |r| alloc.free(r); alloc.free(rounds_arr); return -3; };
    // Expected: 8 + (8 + 2*16) + (8 + 1*16) = 72
    debug_buf[114] = @intCast(ser5.len);
    debug_buf[115] = if (ser5.len == 72) 1 else 0;
    alloc.free(ser5);
    for (rounds_arr) |r| alloc.free(r);
    alloc.free(rounds_arr);

    return 0;
}

pub export fn zs_test_proof_serdeser(k: u8) callconv(.c) c_int {
    const alloc = makeAllocator();
    const n: usize = @as(usize, 1) << @intCast(k);
    const vals = [_]u8{ 0x00, 0x01, 0x63, 0xFF };

    var inputs: [circuit.NUM_SBOXES][]F = undefined;
    for (0..circuit.NUM_SBOXES) |s| {
        inputs[s] = alloc.alloc(F, n) catch return -3;
    }

    for (0..n) |p| {
        for (0..circuit.NUM_SBOXES) |s| {
            inputs[s][p] = F.fromInt(vals[p % vals.len]);
        }
    }

    const w = circuit.generateWitness(alloc, inputs[0..]) catch { for (inputs) |col| alloc.free(col); return -3; };
    defer circuit.freeWitness(alloc, w);

    const x = inputs[0][0];
    const x_inv = if (x.isZero()) F.zero() else x.inv();
    const out0 = F.fromInt(circuit.aesAffine(@truncate(x_inv.value)));
    const pins = circuit.generatePins(x, out0);

    const roots = circuit.commitRoots(alloc, &w.columns) catch { for (inputs) |col| alloc.free(col); return -3; };

    var proof = Stark.prove(alloc, w.k, &w.columns, &circuit.constraints, &pins, circuit.domain) catch { for (inputs) |col| alloc.free(col); return -3; };
    defer proof.deinit(alloc);

    const proof_ser = Ser.serialize(alloc, proof) catch { for (inputs) |col| alloc.free(col); return -4; };
    debug_buf[53] = @intCast(proof_ser.len);

    var proof2 = Ser.deserialize(alloc, proof_ser, Stark.Proof) catch { for (inputs) |col| alloc.free(col); return -4; };
    alloc.free(proof_ser);

    const ok = Stark.verify(alloc, w.k, &roots, &circuit.constraints, &pins, proof2, circuit.domain) catch false;
    debug_buf[54] = if (ok) 1 else 0;

    proof2.deinit(alloc);
    for (inputs) |col| alloc.free(col);
    return if (ok) 1 else 0;
}

pub export fn zs_debug_columns(
    columns_ptr: ?[*]const u8,
    columns_len: usize,
    pins_ptr: ?[*]const u8,
    pins_len: usize,
    out_roots: *[*]u8,
    out_roots_len: *usize,
) callconv(.c) c_int {
    const alloc = makeAllocator();
    const columns_bytes = sliceOf(columns_ptr, columns_len);
    const pins_bytes = sliceOf(pins_ptr, pins_len);

    const columns = Ser.deserialize(alloc, columns_bytes, []const []const F) catch return -2;
    const pins = Ser.deserialize(alloc, pins_bytes, []const Stark.Pin) catch return -2;

    // Store debug info
    debug_buf[0] = @intCast(columns.len);
    debug_buf[1] = @truncate(columns[0][0].value);
    debug_buf[2] = @truncate(columns[8][0].value);
    debug_buf[3] = @truncate(columns[9][0].value);
    debug_buf[4] = @truncate(columns[10][0].value);
    debug_buf[5] = @truncate(columns[28][0].value);

    // Check pins match column values at pinned points
    for (pins) |pin| {
        const col_val = columns[pin.col][pin.point].value;
        debug_buf[10 + pin.col] = if (col_val == pin.value.value) 1 else 0;
    }

    // Compute roots
    const roots = alloc.alloc(Hash.Digest, num_cols) catch return -3;
    for (0..num_cols) |c| {
        var tree = circuit.PCS.commit(alloc, columns[c]) catch {
            out_roots.* = undefined;
            out_roots_len.* = 0;
            return -3;
        };
        defer tree.deinit();
        roots[c] = tree.root();
    }

    const roots_ser = Ser.serialize(alloc, roots) catch return -3;
    out_roots.* = roots_ser.ptr;
    out_roots_len.* = roots_ser.len;

    // Clean up columns and pins (but not roots_ser which is returned)
    for (columns) |c| alloc.free(c);
    alloc.free(columns);
    alloc.free(pins);

    return 0;
}