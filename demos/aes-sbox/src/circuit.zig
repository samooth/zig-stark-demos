const std = @import("std");
const zig_stark = @import("zig-stark");
const binius = zig_stark.binius;
const Hash = zig_stark.hash.Hash;

pub const F = binius.tower.Gf256;
pub const E = binius.tower.Gf2_128;
pub const Stark = binius.stark.BiniusStark(F, E);
pub const PCS = binius.pcs.CommittedMlePcs(F, E);

/// Number of parallel AES S-boxes
pub const NUM_SBOXES: usize = 4;

/// Columns per S-box:
///   Input BitPack:  8 bits + value = 9
///   v_sq (x^2):     1
///   Inverse value:  1
///   Inverse BitPack: 8 bits + value = 9
///   Affine output bits: 8
///   Output value:   1
/// Total: 29 per S-box
pub const num_cols: usize = NUM_SBOXES * 29;

/// Constraints per S-box:
///   Input BitPack boolean: 8
///   Input BitPack pack:    1
///   v_sq = x^2:            1
///   v_inv * v_sq = v_in:   1
///   Inverse BitPack bool:  8
///   Inverse BitPack pack:  1
///   Affine (8 linear):     8
///   Output BitPack boolean:  8 (output bits are affine = linear(inverse bits) ⊂ GF(2))
///   Output BitPack pack:   1
/// Total: 37 per S-box
pub const num_cons: usize = NUM_SBOXES * 37;

pub const domain = "binius:aes-sbox:v1";

// Column offsets within each S-box block (stride = 29)
const INPUT_BITS: usize = 0;    // cols 0-7
const INPUT_VAL: usize = 8;     // col 8
const V_SQ: usize = 9;          // col 9
const INV_VAL: usize = 10;      // col 10
const INV_BITS: usize = 11;     // cols 11-18
const INV_VAL2: usize = 19;     // col 19
const OUT_BITS: usize = 20;     // cols 20-27
const OUT_VAL: usize = 28;      // col 28

const STRIDE: usize = 29;

fn sboxOffset(s: usize, local: usize) usize {
    return s * STRIDE + local;
}

/// AES affine matrix over GF(2) (standard AES S-box matrix).
const AFFINE_MATRIX: [8][8]u1 = blk: {
    var m: [8][8]u1 = undefined;
    const aes_rows = [8]u8{
        0b10001111, 0b11000111, 0b11100011, 0b11110001,
        0b11111000, 0b01111100, 0b00111110, 0b00011111,
    };
    for (0..8) |i| {
        for (0..8) |j| {
            m[i][j] = @intFromBool((aes_rows[i] >> j) & 1 == 1);
        }
    }
    break :blk m;
};

const AFFINE_CONSTANT: u8 = 0x63;

const C_BITS: [8]u1 = blk: {
    var c: [8]u1 = undefined;
    for (0..8) |i| c[i] = @intFromBool((AFFINE_CONSTANT >> i) & 1 == 1);
    break :blk c;
};

/// Compute AES affine transform of an inverse byte.
pub fn aesAffine(inv_byte: u8) u8 {
    var out: u8 = 0;
    for (0..8) |i| {
        var bit: u1 = C_BITS[i];
        for (0..8) |j| {
            if (AFFINE_MATRIX[i][j] == 1) {
                bit ^= @intFromBool((inv_byte >> @intCast(j)) & 1 == 1);
            }
        }
        out |= @as(u8, bit) << @intCast(i);
    }
    return out;
}

/// Full constraint system
pub const constraints: [num_cons]Stark.Constraint = blk: {
    @setEvalBranchQuota(10000);
    var b: binius.constraints.Builder(Stark.Constraint, num_cons, 4 * num_cons) = .{ .mono = undefined };
    var t: usize = 0;

    for (0..NUM_SBOXES) |s| {
        const off = s * STRIDE;

        // --- Input BitPack (9 constraints) ---
        for (0..8) |i| {
            b.add(t, F.one(), &.{off + INPUT_BITS + i});       // bit
            b.add(t, F.one(), &.{off + INPUT_BITS + i, off + INPUT_BITS + i}); // bit^2
            t += 1;
        }
        // Pack: v_in + Σ b_i * 2^i = 0
        b.add(t, F.one(), &.{off + INPUT_VAL});
        for (0..8) |i| {
            b.add(t, F.fromInt(@as(u128, 1) << @intCast(i)), &.{off + INPUT_BITS + i});
        }
        t += 1;

        // --- v_sq = v_in^2 (1 constraint) ---
        b.add(t, F.one(), &.{off + V_SQ});
        b.add(t, F.one(), &.{off + INPUT_VAL, off + INPUT_VAL});
        t += 1;

        // --- v_inv * v_sq = v_in (1 constraint) ---
        // Correct for x=0 (witness sets inv=0) and x≠0 (inv = 1/x)
        b.add(t, F.one(), &.{off + INV_VAL, off + V_SQ});
        b.add(t, F.one(), &.{off + INPUT_VAL});
        t += 1;

        // --- Inverse BitPack (9 constraints) ---
        for (0..8) |i| {
            b.add(t, F.one(), &.{off + INV_BITS + i});
            b.add(t, F.one(), &.{off + INV_BITS + i, off + INV_BITS + i});
            t += 1;
        }
        b.add(t, F.one(), &.{off + INV_VAL2});
        for (0..8) |i| {
            b.add(t, F.fromInt(@as(u128, 1) << @intCast(i)), &.{off + INV_BITS + i});
        }
        t += 1;

        // --- Affine layer: 8 linear constraints ---
        // out_bit_i + Σ_j M[i][j] * inv_bit_j + c_i = 0
        for (0..8) |i| {
            b.add(t, F.one(), &.{off + OUT_BITS + i});
            for (0..8) |j| {
                if (AFFINE_MATRIX[i][j] == 1) {
                    b.add(t, F.one(), &.{off + INV_BITS + j});
                }
            }
            if (C_BITS[i] == 1) {
                b.add(t, F.one(), &.{});  // constant
            }
            t += 1;
        }

        // --- Output BitPack (9 constraints) ---
        for (0..8) |i| {
            b.add(t, F.one(), &.{off + OUT_BITS + i});
            b.add(t, F.one(), &.{off + OUT_BITS + i, off + OUT_BITS + i});
            t += 1;
        }
        b.add(t, F.one(), &.{off + OUT_VAL});
        for (0..8) |i| {
            b.add(t, F.fromInt(@as(u128, 1) << @intCast(i)), &.{off + OUT_BITS + i});
        }
        t += 1;
    }

    const data = b.finish();
    var out: [num_cons]Stark.Constraint = undefined;
    var off: usize = 0;
    for (0..num_cons) |i| {
        out[i] = .{ .terms = data.mono[off .. off + data.cnt[i]] };
        off += data.cnt[i];
    }
    break :blk out;
};

const Witness = struct {
    k: usize,
    n: usize,
    columns: [num_cols][]F,
};

/// Generate witness for `n = 2^k` batches of `NUM_SBOXES` S-box evaluations.
/// `inputs[s][p]` = input field element for S-box `s` at hypercube point `p`.
pub fn generateWitness(allocator: std.mem.Allocator, inputs: [][]F) !Witness {
    const n = inputs[0].len;
    const k = std.math.log2_int(usize, n);

    var columns: [num_cols][]F = undefined;
    for (0..num_cols) |c| columns[c] = try allocator.alloc(F, n);

    for (0..n) |p| {
        for (0..NUM_SBOXES) |s| {
            const x = inputs[s][p];
            const x_inv = if (x.isZero()) F.zero() else x.inv();

            // Input BitPack
            for (0..8) |i| {
                columns[sboxOffset(s, INPUT_BITS + i)][p] = F.fromInt((x.value >> @intCast(i)) & 1);
            }
            columns[sboxOffset(s, INPUT_VAL)][p] = x;

            // v_sq = x^2
            columns[sboxOffset(s, V_SQ)][p] = x.mul(x);

            // Inverse
            columns[sboxOffset(s, INV_VAL)][p] = x_inv;
            for (0..8) |i| {
                columns[sboxOffset(s, INV_BITS + i)][p] = F.fromInt((x_inv.value >> @intCast(i)) & 1);
            }
            columns[sboxOffset(s, INV_VAL2)][p] = x_inv;

            // Affine output bits
            const out_byte = aesAffine(@truncate(x_inv.value));
            for (0..8) |i| {
                columns[sboxOffset(s, OUT_BITS + i)][p] = F.fromInt((out_byte >> @intCast(i)) & 1);
            }
            columns[sboxOffset(s, OUT_VAL)][p] = F.fromInt(out_byte);
        }
    }

    return .{ .k = k, .n = n, .columns = columns };
}

pub fn freeWitness(allocator: std.mem.Allocator, w: Witness) void {
    for (w.columns) |c| allocator.free(c);
}

pub fn generatePins(in0: F, out0: F) [2]Stark.Pin {
    return .{
        .{ .col = sboxOffset(0, INPUT_VAL), .point = 0, .value = in0 },
        .{ .col = sboxOffset(0, OUT_VAL), .point = 0, .value = out0 },
    };
}

pub fn commitRoots(allocator: std.mem.Allocator, columns: []const []const F) ![num_cols]Hash.Digest {
    var roots: [num_cols]Hash.Digest = undefined;
    for (0..num_cols) |c| {
        var tree = try PCS.commit(allocator, columns[c]);
        defer tree.deinit();
        roots[c] = tree.root();
    }
    return roots;
}

pub fn proveAndVerify(allocator: std.mem.Allocator, inputs: [][]F) !void {
    const w = try generateWitness(allocator, inputs);
    defer freeWitness(allocator, &w);

    const x = inputs[0][0];
    const x_inv = if (x.isZero()) F.zero() else x.inv();
    const out0 = F.fromInt(aesAffine(@truncate(x_inv.value)));

    const pins = generatePins(x, out0);
    const proof = try Stark.prove(allocator, w.k, &w.columns, &constraints, &pins, domain);
    defer proof.deinit(allocator);

    const roots = try commitRoots(allocator, &w.columns);
    const ok = try Stark.verify(allocator, w.k, &roots, &constraints, &pins, proof, domain);
    if (!ok) return error.VerificationFailed;

    const bytes = try zig_stark.core.serialization.serialize(allocator, proof);
    defer allocator.free(bytes);

    std.debug.print("  k={d}  n={d}  cols={d}  cons={d}  proof={d}B  verify={any}\n", .{
        w.k, w.n, num_cols, num_cons, bytes.len, ok,
    });
}

test "aes s-box witness satisfies constraints" {
    const alloc = std.testing.allocator;
    const k = 2;
    const n = @as(usize, 1) << k;
    var inputs: [NUM_SBOXES][]F = undefined;
    for (0..NUM_SBOXES) |s| {
        inputs[s] = try alloc.alloc(F, n);
        defer alloc.free(inputs[s]);
    }
    const test_vals = [_]u8{ 0x00, 0x01, 0x63, 0xFF };
    for (0..n) |p| {
        for (0..NUM_SBOXES) |s| {
            inputs[s][p] = F.fromInt(test_vals[p]);
        }
    }

    const w = try generateWitness(alloc, &inputs);
    defer freeWitness(alloc, &w);

    const x = inputs[0][0];
    const x_inv = if (x.isZero()) F.zero() else x.inv();
    const out0 = F.fromInt(aesAffine(@truncate(x_inv.value)));
    const pins = generatePins(x, out0);

    var proof = try Stark.prove(alloc, w.k, &w.columns, &constraints, &pins, domain);
    defer proof.deinit(alloc);

    const roots = try commitRoots(alloc, &w.columns);
    try std.testing.expect(try Stark.verify(alloc, w.k, &roots, &constraints, &pins, proof, domain));
}