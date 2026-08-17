const std = @import("std");
const circuit = @import("circuit");
const ser = @import("zig-stark").core.serialization;

fn now() i128 {
    var ts: std.posix.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, @intCast(ts.sec)) * std.time.ns_per_s + @as(i128, @intCast(ts.nsec));
}

fn testSeq(alloc: std.mem.Allocator, seq: []const circuit.RangeCheck.UInt) !void {
    const w = try circuit.generateWitness(alloc, seq);
    defer circuit.freeWitness(alloc, w);

    const pins = circuit.generatePins(w.n, seq[0], seq[w.n]);
    std.debug.print("  k={d}  n={d}  cols={d}  cons={d}  pins={d}\n", .{
        w.k, w.n, circuit.num_cols, circuit.num_cons, pins.len,
    });

    const t0 = now();
    var proof = try circuit.Stark.prove(alloc, w.k, &w.columns, &circuit.constraints, &pins, circuit.domain);
    const t1 = now();
    defer proof.deinit(alloc);

    const roots = try circuit.commitRoots(alloc, &w.columns);

    const t2 = now();
    const ok = try circuit.Stark.verify(alloc, w.k, &roots, &circuit.constraints, &pins, proof, circuit.domain);
    const t3 = now();

    const proof_ser = try ser.serialize(alloc, proof);
    defer alloc.free(proof_ser);

    std.debug.print("  prove:  {d:>10.2} ms\n", .{@as(f64, @floatFromInt(t1 - t0)) / @as(f64, std.time.ns_per_ms)});
    std.debug.print("  verify: {d:>10.2} ms\n", .{@as(f64, @floatFromInt(t3 - t2)) / @as(f64, std.time.ns_per_ms)});
    std.debug.print("  proof:  {d} B\n", .{proof_ser.len});
    std.debug.print("  verify accepted: {any}\n", .{ok});
    if (!ok) return error.VerifyFailed;

    // Round-trip serialization test
    var proof2 = try ser.deserialize(alloc, proof_ser, circuit.Stark.Proof);
    defer proof2.deinit(alloc);
    const ok2 = try circuit.Stark.verify(alloc, w.k, &roots, &circuit.constraints, &pins, proof2, circuit.domain);
    std.debug.print("  ser/deser round-trip verify: {any}\n", .{ok2});
    if (!ok2) return error.RoundTripFailed;

    // Tamper test: flip one byte in the serialized proof
    var tampered = try alloc.dupe(u8, proof_ser);
    defer alloc.free(tampered);
    tampered[proof_ser.len / 2] ^= 0x01;
    var ok_tampered: bool = undefined;
    {
        var pt = try ser.deserialize(alloc, tampered, circuit.Stark.Proof);
        defer pt.deinit(alloc);
        ok_tampered = try circuit.Stark.verify(alloc, w.k, &roots, &circuit.constraints, &pins, pt, circuit.domain);
    }
    std.debug.print("  tampered proof rejected: {any}\n", .{!ok_tampered});
    if (ok_tampered) return error.TamperAccepted;
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    const alloc = gpa.allocator();
    defer _ = gpa.deinit();

    std.debug.print("Binius Sorted-Sequence Demo (F=Gf256, E=Gf2_128)\n", .{});
    std.debug.print("Circuit: two 4-bit range checks + comparison, linked\n\n", .{});

    std.debug.print("Test 1: minimal k=2 (n=4)\n", .{});
    const seq1 = [_]circuit.RangeCheck.UInt{ 0, 5, 10, 13, 15 };
    try testSeq(alloc, &seq1);

    std.debug.print("\nTest 2: k=3 (n=8)\n", .{});
    const seq2 = [_]circuit.RangeCheck.UInt{ 0, 2, 4, 6, 8, 10, 12, 14, 15 };
    try testSeq(alloc, &seq2);

    std.debug.print("\nTest 3: k=3 (n=8, full range)\n", .{});
    const seq3 = [_]circuit.RangeCheck.UInt{ 0, 1, 3, 5, 7, 9, 11, 13, 15 };
    try testSeq(alloc, &seq3);

    std.debug.print("\nAll tests passed.\n", .{});
}
