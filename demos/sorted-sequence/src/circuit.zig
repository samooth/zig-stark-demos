const std = @import("std");
const zig_stark = @import("zig-stark");
const binius = zig_stark.binius;
const Hash = zig_stark.hash.Hash;

pub const F = binius.tower.Gf256;
pub const E = binius.tower.Gf2_128;
pub const RangeCheck = binius.rangecheck.RangeCheck(F, E, 4);
pub const Compare = binius.compare.Compare(F, E, 4);
pub const Stark = binius.stark.BiniusStark(F, E);
pub const PCS = binius.pcs.CommittedMlePcs(F, E);

pub const num_cols: usize = 2 * RangeCheck.num_columns + Compare.num_columns;
pub const num_links: usize = 2 * RangeCheck.num_bits;
pub const num_cons: usize = 2 * RangeCheck.num_constraints + Compare.num_constraints + num_links;

pub const domain = "binius:sorted-seq:v1";

const col_x_value = RangeCheck.colValue();
const col_y_value = RangeCheck.num_columns + RangeCheck.colValue();

/// Two 4-bit range checks (one per element) plus a 4-bit comparison
/// (x < y), linked so the range-checked bits ARE the compared bits.
/// The statement proved is: a sequence of n+1 elements is strictly
/// increasing and every element is a valid u4.
pub const constraints: [num_cons]Stark.Constraint = blk: {
    var b: binius.constraints.Builder(Stark.Constraint, num_cons, 96) = .{ .mono = undefined };
    binius.constraints.shiftInto(@TypeOf(b), &b, 0, 0, RangeCheck.constraints);
    binius.constraints.shiftInto(@TypeOf(b), &b, RangeCheck.num_constraints, RangeCheck.num_columns, RangeCheck.constraints);
    binius.constraints.shiftInto(@TypeOf(b), &b, 2 * RangeCheck.num_constraints, 2 * RangeCheck.num_columns, Compare.constraints);
    for (0..RangeCheck.num_bits) |i| {
        const base = 2 * RangeCheck.num_constraints + Compare.num_constraints;
        b.add(base + i, F.one(), &.{i});
        b.add(base + i, F.one(), &.{2 * RangeCheck.num_columns + i});
        b.add(base + RangeCheck.num_bits + i, F.one(), &.{RangeCheck.num_columns + i});
        b.add(base + RangeCheck.num_bits + i, F.one(), &.{2 * RangeCheck.num_columns + Compare.num_bits + i});
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
    n: usize, // hypercube size = 2^k = seq.len - 1
    columns: [num_cols][]F,
};

/// Generate bit-sliced witness columns for a strictly increasing sequence.
/// `seq` has length `n + 1` where `n = 2^k` (number of hypercube points).
/// Each element must be a valid u4 in [0, 16).
pub fn generateWitness(allocator: std.mem.Allocator, seq: []const RangeCheck.UInt) !Witness {
    const seq_len = seq.len;
    const n = seq_len - 1; // hypercube size
    const k = std.math.log2_int(usize, n);
    const x = try allocator.dupe(RangeCheck.UInt, seq[0..n]);
    defer allocator.free(x);
    const y = try allocator.dupe(RangeCheck.UInt, seq[1 .. n + 1]);
    defer allocator.free(y);

    const rx = try RangeCheck.generateWitness(allocator, x);
    const ry = try RangeCheck.generateWitness(allocator, y);
    const cm = try Compare.generateWitness(allocator, x, y);

    var columns: [num_cols][]F = undefined;
    for (0..RangeCheck.num_columns) |c| columns[c] = rx[c];
    for (0..RangeCheck.num_columns) |c| columns[RangeCheck.num_columns + c] = ry[c];
    for (0..Compare.num_columns) |c| columns[2 * RangeCheck.num_columns + c] = cm[c];
    return .{ .k = k, .n = n, .columns = columns };
}

pub fn freeWitness(allocator: std.mem.Allocator, w: Witness) void {
    for (w.columns) |c| allocator.free(c);
}

/// Public boundary pins: first element pinned at point 0,
/// last element pinned at point n-1.
pub fn generatePins(n: usize, first: RangeCheck.UInt, last: RangeCheck.UInt) [2]Stark.Pin {
    return .{
        .{ .col = col_x_value, .point = 0, .value = F.fromInt(first) },
        .{ .col = col_y_value, .point = n - 1, .value = F.fromInt(last) },
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

/// Run the full prove/verify cycle for testing.
pub fn proveAndVerify(allocator: std.mem.Allocator, seq: []const RangeCheck.UInt) !void {
    const w = try generateWitness(allocator, seq);
    defer freeWitness(allocator, w);

    const pins = generatePins(w.n, seq[0], seq[w.n]);
    const proof = try Stark.prove(allocator, w.k, &w.columns, &constraints, &pins, domain);
    defer proof.deinit(allocator);

    const roots = try commitRoots(allocator, &w.columns);
    const ok = try Stark.verify(allocator, w.k, &roots, &constraints, &pins, proof, domain);
    if (!ok) return error.VerificationFailed;

    const bytes = try zig_stark.core.serialization.serialize(allocator, proof);
    defer allocator.free(bytes);

    std.debug.print("  k={d}  n={d}  proof={d}B  verify={any}\n", .{ w.k, w.n, bytes.len, ok });
}
