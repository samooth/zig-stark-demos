# zig-stark-demos

Demo applications built on top of [zig-stark](https://github.com/samooth/zig-stark) (commit `c119a01e`), showcasing browser-based STARK proofs with the Binius zero-check prover over binary tower fields.

## Project Layout

| Path | Description |
|------|-------------|
| `build.zig` / `build.zig.zon` | Build system (native CLI + WASM targets, zig-stark dependency, fmt check) |
| `demo.sh` | Convenience script for building and running demos |
| `demos/sorted-sequence/` | Sorted Sequence Prover demo (26 cols, 34 constraints, 2 pins) |
| `demos/gf-mul-table/` | GF(256) Multiplication Table demo (15 cols, 19 constraints, 3 pins) |
| `demos/aes-sbox/` | AES S-box Prover demo (116 cols, 148 constraints, 2 pins) |
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

### 3. AES S-box Prover
**`demos/aes-sbox/`**

Users input 16 values (4 per S-box × 4 points); the app proves that each input `x` maps to AES output `S(x)` (inversion + affine transform in GF(256)), using a Binius STARK over `Gf256`/`Gf2_128` with `CommittedMlePcs`.

The circuit composes 4 parallel `AES-Box(8)` gadgets (inversion + affine transform), each with two boundary pins (input value at point 0, output value at point 0) and cross-gadget linking to ensure all S-boxes use the same inversion method.

**Circuit summary:**
- 116 columns (4 × AES-Box(8) = 29 cols each)
- 148 constraints (4 × AES-Box(8) = 37 constraints each)
- 2 pins (input value of S-box 0 at point 0, output value of S-box 0 at point 0)
- Field: `Gf256` base, `Gf2_128` extension (binary tower field)
- AES S-box: `S(x) = Aff(AES.inv(x))` where `AES.inv(x)` is field inversion in GF(256) using Wiedemann tower basis

**Proof size:** ~47–59 KB (k=2, 4 points × 4 S-boxes)  
**Prove time:** ~61–303 ms (native), ~7–32 s (WASM)  
**Verify time:** ~17–31 ms (native), ~0.5–0.7 s (WASM)

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
cd demos/aes-sbox/www && npx serve .          # http://localhost:3002
```

Open in browser to interact with the demos.

## Quick Start

```sh
./demo.sh all          # Build all native binaries and run all demos + tests
./demo.sh test         # Run Node.js WASM tests
./demo.sh www          # Build all WASM + copy to www/
```

## Verification Commands

```sh
zig build              # Build all native binaries + run tests
zig build wasm         # Build WASM modules only (to zig-out/)
zig build www          # Build WASM + copy to www/
zig build fmt          # Format check (zig fmt --check)
```

Or use the helper script:

```sh
./demo.sh all          # Build and run all demos + tests
./demo.sh test         # Run Node.js WASM tests only
```

### Native binaries
```sh
zig build
./zig-out/bin/sorted_seq
./zig-out/bin/gf_mul_table
./zig-out/bin/aes_sbox
```

### Node.js WASM tests (no browser required)

```sh
node test_wasm.js
```

## Dependencies

- **zig-stark** — referenced via local path `zig-stark/` → `/tmp/zig-stark` (commit `c119a01e`)
- **Zig** — >= 0.16.0

## References

- [Binius STARK Documentation](https://github.com/samooth/zig-stark)
- [Binary Tower Fields](https://github.com/samooth/zig-stark/tree/main/docs)
- [Range Check Gadget](https://github.com/samooth/zig-stark/tree/main/src/binius/gadgets/rangecheck.zig)
- [Compare Gadget](https://github.com/samooth/zig-stark/tree/main/src/binius/gadgets/compare.zig)

## Notes

- WASM modules use **ReleaseSmall** optimization (`.optimize = .ReleaseSmall` in build.zig) to disable `@intCast` overflow checks that would panic on valid proof data for wasm32 (`usize = u32`, but serialized lengths are u64).
- Proof serialization uses **interleaved column format**: `[u64 num_cols, (u64 col_len, col_bytes), ...]`
- Test sequences must have length `n+1` where `n = 2^k` (e.g., k=2 → 5 elements, k=3 → 9 elements)
- Tamper test: flips bytes at `len/2` and `len/4` of serialized proof; verification must reject