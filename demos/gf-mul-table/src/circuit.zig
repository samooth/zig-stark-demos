const std = @import("std");
const zig_stark = @import("zig-stark");
const binius = zig_stark.binius;
const Hash = zig_stark.hash.Hash;

pub const F = binius.tower.Gf256;
pub const E = binius.tower.Gf2_128;
pub const RangeCheck = binius.rangecheck.RangeCheck(F, E, 4);
pub const Stark = binius.stark.BiniusStark(F, E);
pub const PCS = binius.pcs.CommittedMlePcs(F, E);

pub const num_cols: usize = 3 * RangeCheck.num_columns;
pub const num_cons: usize = 3 * RangeCheck.num_constraints + RangeCheck.num_bits;
pub const num_pins: usize = 3;

pub const domain = "binius:gf-mul-table:v1";

pub const F_LEVEL: u8 = F.LEVEL;
pub const N_BITS: usize = RangeCheck.num_bits;

/// Comptime-only tower-field multiplication for the Wiedemann tower.
/// Computes e_i * e_j in T_level and returns the result as a raw u128.
/// This avoids runtime atomics/ensureFast and is safe in comptime blocks.
pub fn towerMul(comptime level: u8, a: u128, b: u128) u128 {
    if (level == 0) return a & b;
    const half = @as(usize, 1) << (level - 1);
    const mask: u128 = (@as(u128, 1) << half) - 1;
    const beta: u128 = if (level == 1) 1 else (@as(u128, 1) << @intCast(@as(u8, 1) << @intCast(level - 2)));
    const a0 = a & mask;
    const a1 = (a >> half) & mask;
    const b0 = b & mask;
    const b1 = (b >> half) & mask;
    const c0 = towerMul(level - 1, a0, b0);
    const c1 = towerMul(level - 1, a1, b1);
    const c2 = towerMul(level - 1, a0 ^ a1, b0 ^ b1);
    const lo = c0 ^ c1;
    const c1_beta = towerMul(level - 1, c1, beta);
    const hi = c2 ^ c0 ^ c1 ^ c1_beta;
    return lo | (hi << half);
}

/// Multiplication tensor m[i][j][k] = bit k of (e_i * e_j) in GF(256).
/// Used to express the field-multiplication constraint as degree-2 monomials
/// on the a/b/c bit columns.
const mul_tensor: [N_BITS][N_BITS][N_BITS]u1 = blk: {
    @setEvalBranchQuota(100000);
    var t: [N_BITS][N_BITS][N_BITS]u1 = undefined;
    for (0..N_BITS) |i| {
        for (0..N_BITS) |j| {
            const product = towerMul(F_LEVEL, @as(u128, 1) << @intCast(i), @as(u128, 1) << @intCast(j));
            for (0..N_BITS) |k| {
                t[i][j][k] = @intFromBool((product >> @intCast(k)) & 1 == 1);
            }
        }
    }
    break :blk t;
};

const a_offset: usize = 0;
const b_offset: usize = RangeCheck.num_columns;
const c_offset: usize = 2 * RangeCheck.num_columns;

const col_a_val = a_offset + RangeCheck.colValue();
const col_b_val = b_offset + RangeCheck.colValue();
const col_c_val = c_offset + RangeCheck.colValue();

/// Prove that for each hypercube point p: a_p ⊗ b_p = c_p in GF(16)
/// (embedded as a subfield of GF(256)), with all three values range-checked
/// to [0, 16). The multiplication tensor (precomputed from the tower field)
/// decomposes the degree-2 field product into bit-level monomials.
pub const constraints: [num_cons]Stark.Constraint = blk: {
    const mul_base = 3 * RangeCheck.num_constraints;
    var b: binius.constraints.Builder(Stark.Constraint, num_cons, 80) = .{ .mono = undefined };
    binius.constraints.shiftInto(@TypeOf(b), &b, 0, a_offset, RangeCheck.constraints);
    binius.constraints.shiftInto(@TypeOf(b), &b, RangeCheck.num_constraints, b_offset, RangeCheck.constraints);
    binius.constraints.shiftInto(@TypeOf(b), &b, 2 * RangeCheck.num_constraints, c_offset, RangeCheck.constraints);

    for (0..N_BITS) |k| {
        const t = mul_base + k;
        b.add(t, F.one(), &.{c_offset + k});
        for (0..N_BITS) |i| {
            for (0..N_BITS) |j| {
                if (mul_tensor[i][j][k] == 1) {
                    b.add(t, F.one(), &.{ a_offset + i, b_offset + j });
                }
            }
        }
    }

    const data = b.finish();
    var out: [num_cons]Stark.Constraint = undefined;
    var off: usize = 0;
    for (0..num_cons) |t| {
        out[t] = .{ .terms = data.mono[off .. off + data.cnt[t]] };
        off += data.cnt[t];
    }
    break :blk out;
};

pub const Witness = struct {
    k: usize,
    n: usize,
    columns: [num_cols][]F,
};

/// Generate bit-sliced witness columns for a batch of n = 2^k multiplications.
/// Each hypercube point p provides one triple (a_p, b_p, c_p) where
/// c_p = towerMul(a_p, b_p) in GF(256).
pub fn generateWitness(allocator: std.mem.Allocator, a: []const RangeCheck.UInt, b: []const RangeCheck.UInt) !Witness {
    const n = a.len;
    std.debug.assert(b.len == n);
    const k = std.math.log2_int(usize, n);

    const c = try allocator.alloc(RangeCheck.UInt, n);
    defer allocator.free(c);
    for (0..n) |p| {
        c[p] = @intCast(@as(u8, @truncate(towerMul(F_LEVEL, a[p], b[p]))));
    }

    const ra = try RangeCheck.generateWitness(allocator, a);
    const rb = try RangeCheck.generateWitness(allocator, b);
    const rc = try RangeCheck.generateWitness(allocator, c);

    var columns: [num_cols][]F = undefined;
    for (0..RangeCheck.num_columns) |col| {
        columns[a_offset + col] = ra[col];
        columns[b_offset + col] = rb[col];
        columns[c_offset + col] = rc[col];
    }
    return .{ .k = k, .n = n, .columns = columns };
}

pub fn freeWitness(allocator: std.mem.Allocator, w: Witness) void {
    for (w.columns) |col| allocator.free(col);
}

/// Pin the first multiplication triple (a[0], b[0], c[0]) as three public
/// boundary assertions at point 0.
pub fn generatePins(a0: RangeCheck.UInt, b0: RangeCheck.UInt, c0: RangeCheck.UInt) [num_pins]Stark.Pin {
    return .{
        .{ .col = col_a_val, .point = 0, .value = F.fromInt(a0) },
        .{ .col = col_b_val, .point = 0, .value = F.fromInt(b0) },
        .{ .col = col_c_val, .point = 0, .value = F.fromInt(c0) },
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

pub fn proveAndVerify(allocator: std.mem.Allocator, a: []const RangeCheck.UInt, b: []const RangeCheck.UInt) !void {
    const w = try generateWitness(allocator, a, b);
    defer freeWitness(allocator, w);

    const c = try allocator.alloc(RangeCheck.UInt, w.n);
    defer allocator.free(c);
    for (0..w.n) |p| {
        c[p] = @intCast(@as(u8, @truncate(towerMul(F_LEVEL, a[p], b[p]))));
    }

    const pins = generatePins(a[0], b[0], c[0]);
    const proof = try Stark.prove(allocator, w.k, &w.columns, &constraints, &pins, domain);
    defer proof.deinit(allocator);

    const roots = try commitRoots(allocator, &w.columns);
    const ok = try Stark.verify(allocator, w.k, &roots, &constraints, &pins, proof, domain);
    if (!ok) return error.VerificationFailed;

    const bytes = try zig_stark.core.serialization.serialize(allocator, proof);
    defer allocator.free(bytes);

    std.debug.print("  k={d}  n={d}  proof={d}B  verify={any}\n", .{ w.k, w.n, bytes.len, ok });
}
