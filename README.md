# zig-stark-demos

Demo applications built on top of [zig-stark](https://github.com/11001010/zig-stark) (commit `c119a01e`), showcasing browser-based STARK proofs with the Binius zero-check prover over binary tower fields.

## Project Layout

| Path | Description |
|------|-------------|
| `build.zig` / `build.zig.zon` | Build system (native CLI + WASM targets, zig-stark dependency, fmt check) |
| `src/circuit.zig` | Shared Binius circuit: composed RangeCheck+Compare gadget (26 columns, 34 constraints, 2 pins) |
| `src/main.zig` | Native CLI binary — prove/verify/tamper-test runner |
| `src/wasm_capi.zig` | WASM C-ABI exports (`zs_prove`, `zs_verify`, `zs_free`) |
| `demos/binius-sorted-sequence/` | Browser demo: "Sorted Sequence Prover" |
| `demos/binius-sorted-sequence/www/` | Static web assets (HTML/CSS/JS + compiled WASM) |

## Demos

### Sorted Sequence Prover

Users input a sequence of 4-bit values; the app proves that the sequence is
strictly increasing and all values are in [0, 16), using a Binius STARK over
`Gf256`/`Gf2_128` with `CommittedMlePcs`.

The circuit composes two `RangeCheck(4)` gadgets and one `Compare(4)` gadget,
with 8 cross-gadget value links ensuring both gadgets agree on their inputs.

**Circuit summary:**
- 26 columns (8 for RangeCheck + 8 for Compare + 10 for value links + 1 constant)
- 34 constraints
- 2 pins (root commitments)
- Field: `Gf256` base, `Gf2_128` extension (binary tower field)

**Proof size:** ~13–31 KB (depends on sequence length)  
**Prove time:** ~67–211 ms (native), ~1.4 s (WASM)  
**Verify time:** ~9–19 ms (native), ~72 ms (WASM)

## Building

### Native binary

```sh
zig build
./zig-out/bin/sorted_seq
```

### WASM (browser)

```sh
zig build www
```

This compiles the WASM C-ABI module to ReleaseSmall and copies it to
`demos/binius-sorted-sequence/www/binius_wasm.wasm`.

To serve the demo locally (for browser testing):

```sh
cd demos/binius-sorted-sequence/www
npx serve .   # or any static file server
```

Then open `http://localhost:3000` in a browser.

## Verification Commands

```sh
zig build              # Native binary (tests auto-run)
zig build wasm         # WASM only (to zig-out/)
zig build www          # WASM + copy to www/
zig build fmt          # Format check (zig fmt --check)
```

## Dependencies

- **zig-stark** — referenced via local path symlink `zig-stark/` → `/tmp/zig-stark`
- **Zig** — 0.16.0-dev.2535+b5bd49460
