# zig-stark-demos

Demo applications built on top of [zig-stark](https://github.com/11001010/zig-stark) (commit `c119a01e`), showcasing browser-based STARK proofs with the Binius zero-check prover over binary tower fields.

## Project Layout

| Path | Description |
|------|-------------|
| `build.zig` / `build.zig.zon` | Build system (native CLI + WASM targets, zig-stark dependency, fmt check) |
| `demos/sorted-sequence/` | Sorted Sequence Prover demo (26 cols, 34 constraints, 2 pins) |
| `demos/gf-mul-table/` | GF(256) Multiplication Table demo (15 cols, 19 constraints, 3 pins) |
| `demos/*/src/circuit.zig` | Circuit definition with Binius gadgets |
| `demos/*/src/main.zig` | Native CLI binary — prove/verify/tamper-test runner |
| `demos/*/src/wasm_capi.zig` | WASM C-ABI exports (`zs_prove`, `zs_verify`, `zs_free`) |
| `demos/*/www/` | Static web assets (HTML/CSS/JS + compiled WASM) |
| `test_wasm.js` | Node.js WASM test script |

## Demos

### 1. Sorted Sequence Prover
**`demos/sorted-sequence/`**

Users input a sequence of 4-bit values; the app proves that the sequence is strictly increasing and all values are in [0, 16), using a Binius STARK over `Gf256`/`Gf2_128` with `CommittedMlePcs`.

The circuit composes two `RangeCheck(4)` gadgets and one `Compare(4)` gadget, with cross-gadget value links ensuring both gadgets agree on their inputs.

**Circuit summary:**
- 26 columns (2 × RangeCheck(4) + Compare(4))
- 34 constraints
- 2 pins (first element at point 0, last element at point n-1)
- Field: `Gf256` base, `Gf2_128` extension (binary tower field)

**Proof size:** ~13–31 KB (depends on sequence length)  
**Prove time:** ~48–211 ms (native), ~10–45 s (WASM)  
**Verify time:** ~6–19 ms (native), ~1–2 s (WASM)

### 2. GF(256) Multiplication Table Prover
**`demos/gf-mul-table/`**

Users input pairs of 4-bit values `(a, b)`; the app proves that `c = a × b` in GF(256) for each pair, with all three values range-checked to [0, 16), using a Binius STARK over `Gf256`/`Gf2_128` with `CommittedMlePcs`.

The circuit composes three `RangeCheck(4)` gadgets (for a, b, c) plus a degree-2 field multiplication constraint expressed via a precomputed tower-field multiplication tensor.

**Circuit summary:**
- 15 columns (3 × RangeCheck(4) = 5 cols each)
- 19 constraints (3 × range-check + 4 multiplication constraints)
- 3 pins (a[0], b[0], c[0] at point 0)
- Field: `Gf256` base, `Gf2_128` extension (binary tower field)
- Multiplication via Wiedemann tower: `towerMul(level, a, b)` recursive Karatsuba

**Proof size:** ~7–18 KB (depends on batch size)  
**Prove time:** ~48–172 ms (native), ~1–4 s (WASM)  
**Verify time:** ~6–13 ms (native), ~45–55 ms (WASM)

## Building

### Native binaries (both demos)

```sh
zig build
./zig-out/bin/sorted_seq
./zig-out/bin/gf_mul_table
```

### WASM (both demos, ReleaseSmall to avoid @intCast panics on wasm32)

```sh
zig build wasm          # Compiles to zig-out/
zig build www           # Compiles + copies to demos/*/www/
```

This compiles the WASM C-ABI modules with `ReleaseSmall` optimization (required to avoid `@intCast(u64→u32)` panics on valid proof data for wasm32 `usize`) and copies to `demos/*/www/binius_wasm.wasm`.

### Browser demos

```sh
cd demos/sorted-sequence/www && npx serve .   # http://localhost:3000
cd demos/gf-mul-table/www && npx serve .      # http://localhost:3001
```

Open in browser to interact with the demos.

## Verification Commands

```sh
zig build              # Build all native binaries + run tests
zig build wasm         # Build WASM modules only (to zig-out/)
zig build www          # Build WASM + copy to www/
zig build fmt          # Format check (zig fmt --check)
```

### Node.js WASM tests (no browser required)

```sh
node test_wasm.js
```

This loads both WASM modules via WebAssembly.instantiate, generates witnesses in JavaScript, calls `zs_prove`/`zs_verify`, and runs prove/verify/tamper tests for both demos.

## Dependencies

- **zig-stark** — referenced via local path `zig-stark/` → `/tmp/zig-stark` (commit `c119a01e`)
- **Zig** — 0.16.0-dev.2535+b5bd49460 (or compatible)

## Notes

- WASM modules use **ReleaseSmall** optimization (`.optimize = .ReleaseSmall` in build.zig) to disable `@intCast` overflow checks that would panic on valid proof data for wasm32 (`usize = u32`, but serialized lengths are u64).
- Proof serialization uses **interleaved column format**: `[u64 num_cols, (u64 col_len, col_bytes), ...]`
- Test sequences must have length `n+1` where `n = 2^k` (e.g., k=2 → 5 elements, k=3 → 9 elements)
- Tamper test: flips bytes at `len/2` and `len/4` of serialized proof; verification must reject