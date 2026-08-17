const std = @import("std");
const circuit = @import("circuit");
const ser = @import("zig-stark").core.serialization;

fn now() i128 {
    var ts: std.posix.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, @intCast(ts.sec)) * std.time.ns_per_s + @as(i128, @intCast(ts.nsec));
}

fn testMul(allocator: std.mem.Allocator, a_vals: []const circuit.RangeCheck.UInt, b_vals: []const circuit.RangeCheck.UInt) !void {
    const w = try circuit.generateWitness(allocator, a_vals, b_vals);
    defer circuit.freeWitness(allocator, w);

    var c_vals = try allocator.alloc(circuit.RangeCheck.UInt, w.n);
    defer allocator.free(c_vals);
    for (0..w.n) |p| {
        c_vals[p] = @intCast(@as(u8, @truncate(circuit.towerMul(circuit.F_LEVEL, a_vals[p], b_vals[p]))));
    }

    const pins = circuit.generatePins(a_vals[0], b_vals[0], c_vals[0]);
    std.debug.print("  k={d}  n={d}  cols={d}  cons={d}  pins={d}\n", .{
        w.k, w.n, circuit.num_cols, circuit.num_cons, pins.len,
    });

    const t0 = now();
    var proof = try circuit.Stark.prove(allocator, w.k, &w.columns, &circuit.constraints, &pins, circuit.domain);
    const t1 = now();
    defer proof.deinit(allocator);

    const roots = try circuit.commitRoots(allocator, &w.columns);

    const t2 = now();
    const ok = try circuit.Stark.verify(allocator, w.k, &roots, &circuit.constraints, &pins, proof, circuit.domain);
    const t3 = now();

    const proof_ser = try ser.serialize(allocator, proof);
    defer allocator.free(proof_ser);

    std.debug.print("  prove:  {d:>10.2} ms\n", .{@as(f64, @floatFromInt(t1 - t0)) / @as(f64, std.time.ns_per_ms)});
    std.debug.print("  verify: {d:>10.2} ms\n", .{@as(f64, @floatFromInt(t3 - t2)) / @as(f64, std.time.ns_per_ms)});
    std.debug.print("  proof:  {d} B\n", .{proof_ser.len});
    std.debug.print("  verify accepted: {any}\n", .{ok});
    if (!ok) return error.VerifyFailed;

    // Round-trip serialization
    var proof2 = try ser.deserialize(allocator, proof_ser, circuit.Stark.Proof);
    defer proof2.deinit(allocator);
    const ok2 = try circuit.Stark.verify(allocator, w.k, &roots, &circuit.constraints, &pins, proof2, circuit.domain);
    std.debug.print("  ser/deser round-trip verify: {any}\n", .{ok2});
    if (!ok2) return error.RoundTripFailed;

    // Tamper test: flip one byte in the serialized proof
    var tampered = try allocator.dupe(u8, proof_ser);
    defer allocator.free(tampered);
    tampered[proof_ser.len / 2] ^= 0x01;
    tampered[proof_ser.len / 4] ^= 0x01;
    var ok_tampered: bool = undefined;
    {
        const result = ser.deserialize(allocator, tampered, circuit.Stark.Proof);
        if (result) |pt| {
            var pt_mut = pt;
            defer pt_mut.deinit(allocator);
            ok_tampered = try circuit.Stark.verify(allocator, w.k, &roots, &circuit.constraints, &pins, pt_mut, circuit.domain);
        } else |_| {
            ok_tampered = false;
        }
    }
    std.debug.print("  tampered proof rejected: {any}\n", .{!ok_tampered});
    if (ok_tampered) return error.TamperAccepted;

    // Verify first multiplication is correct
    const first_c: circuit.RangeCheck.UInt = @intCast(@as(u8, @truncate(circuit.towerMul(circuit.F_LEVEL, a_vals[0], b_vals[0]))));
    std.debug.print("  a[0]={d}  b[0]={d}  c[0]={d}  (a*b in GF(256))\n", .{ a_vals[0], b_vals[0], c_vals[0] });
    if (c_vals[0] != first_c) return error.MulMismatch;
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    const alloc = gpa.allocator();
    defer _ = gpa.deinit();

    std.debug.print("Binius GF-Multiplication-Table Demo (F=Gf256, E=Gf2_128)\n", .{});
    std.debug.print("Circuit: three 4-bit range checks + 4-bit field multiplication\n\n", .{});

    std.debug.print("Test 1: small values k=2 (n=4)\n", .{});
    const a1 = [_]circuit.RangeCheck.UInt{ 1, 3, 5, 7 };
    const b1 = [_]circuit.RangeCheck.UInt{ 2, 4, 6, 8 };
    try testMul(alloc, &a1, &b1);

    std.debug.print("\nTest 2: k=3 (n=8, mixed values)\n", .{});
    const a2 = [_]circuit.RangeCheck.UInt{ 0, 2, 3, 5, 7, 9, 11, 13 };
    const b2 = [_]circuit.RangeCheck.UInt{ 1, 3, 5, 7, 9, 11, 13, 15 };
    try testMul(alloc, &a2, &b2);

    std.debug.print("\nTest 3: k=3 (n=8, edge values)\n", .{});
    const a3 = [_]circuit.RangeCheck.UInt{ 15, 0, 1, 2, 4, 8, 3, 6 };
    const b3 = [_]circuit.RangeCheck.UInt{ 1, 15, 2, 3, 5, 7, 9, 12 };
    try testMul(alloc, &a3, &b3);

    std.debug.print("\nAll tests passed.\n", .{});
}
