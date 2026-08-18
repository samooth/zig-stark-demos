const std = @import("std");
const circuit = @import("circuit");
const ser = @import("zig-stark").core.serialization;
const zig_stark = @import("zig-stark");
const F = zig_stark.binius.tower.Gf256;

fn now() i128 {
    var ts: std.posix.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, @intCast(ts.sec)) * std.time.ns_per_s + @as(i128, @intCast(ts.nsec));
}

fn testSbox(allocator: std.mem.Allocator, inputs: [][]circuit.F) !void {
    const w = try circuit.generateWitness(allocator, inputs);
    defer circuit.freeWitness(allocator, w);

    const x = inputs[0][0];
    const x_inv = if (x.isZero()) circuit.F.zero() else x.inv();
    const out0 = circuit.F.fromInt(circuit.aesAffine(@truncate(x_inv.value)));

    const pins = circuit.generatePins(x, out0);
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

    std.debug.print("  prove:  {d:.2} ms\n", .{@as(f64, @floatFromInt(t1 - t0)) / @as(f64, std.time.ns_per_ms)});
    std.debug.print("  verify: {d:.2} ms\n", .{@as(f64, @floatFromInt(t3 - t2)) / @as(f64, std.time.ns_per_ms)});
    std.debug.print("  proof:  {d} B\n", .{proof_ser.len});
    std.debug.print("  verify accepted: {any}\n", .{ok});
    if (!ok) return error.VerifyFailed;

    // Round-trip serialization test
    var proof2 = try ser.deserialize(allocator, proof_ser, circuit.Stark.Proof);
    defer proof2.deinit(allocator);
    const ok2 = try circuit.Stark.verify(allocator, w.k, &roots, &circuit.constraints, &pins, proof2, circuit.domain);
    std.debug.print("  ser/deser round-trip verify: {any}\n", .{ok2});
    if (!ok2) return error.RoundTripFailed;

    // Tamper test
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

    std.debug.print("  in=0x{x:0>2}  out=0x{x:0>2}  inv=0x{x:0>2}\n", .{
        x.value, out0.value, x_inv.value,
    });
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    const alloc = gpa.allocator();
    defer _ = gpa.deinit();

    std.debug.print("Binius AES S-box Demo (F=Gf256, E=Gf2_128)\n", .{});
    std.debug.print("Circuit: {d} parallel S-boxes (inversion + affine)\n\n", .{circuit.NUM_SBOXES});

    std.debug.print("Test 1: k=2 (n=4), various inputs\n", .{});
    var inputs1: [circuit.NUM_SBOXES][]circuit.F = undefined;
    for (0..circuit.NUM_SBOXES) |s| {
        inputs1[s] = try alloc.alloc(circuit.F, 4);
    }

    const vals1 = [_]u8{ 0x00, 0x01, 0x63, 0xFF };
    for (0..4) |p| {
        for (0..circuit.NUM_SBOXES) |s| {
            inputs1[s][p] = circuit.F.fromInt(vals1[p]);
        }
    }
    try testSbox(alloc, &inputs1);
    for (inputs1) |col| alloc.free(col);

    std.debug.print("\nTest 2: k=2 (n=4), sequential bytes\n", .{});
    var inputs2: [circuit.NUM_SBOXES][]circuit.F = undefined;
    for (0..circuit.NUM_SBOXES) |s| {
        inputs2[s] = try alloc.alloc(circuit.F, 4);
    }
    const vals2 = [_]u8{ 0x02, 0x04, 0x08, 0x10 };
    for (0..4) |p| {
        for (0..circuit.NUM_SBOXES) |s| {
            inputs2[s][p] = circuit.F.fromInt(vals2[p]);
        }
    }
    try testSbox(alloc, &inputs2);
    for (inputs2) |col| alloc.free(col);

    std.debug.print("\nTest 3: k=2 (n=4), random-like\n", .{});
    var inputs3: [circuit.NUM_SBOXES][]circuit.F = undefined;
    for (0..circuit.NUM_SBOXES) |s| {
        inputs3[s] = try alloc.alloc(circuit.F, 4);
    }
    const vals3 = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
    for (0..4) |p| {
        for (0..circuit.NUM_SBOXES) |s| {
            inputs3[s][p] = circuit.F.fromInt(vals3[p]);
        }
    }
    try testSbox(alloc, &inputs3);
    for (inputs3) |col| alloc.free(col);

    std.debug.print("\nAll tests passed.\n", .{});
}

test "main runs" {
    // placeholder
}
