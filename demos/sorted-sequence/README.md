# Binius STARK: Sorted Sequence Prover

**`demos/sorted-sequence/`**

> Proves that a sequence of 4-bit values is strictly increasing and all values are in [0, 16), using a Binius STARK over Gf256/Gf2_128 with CommittedMlePcs.

## Overview

The Sorted Sequence Prover demonstrates how to use Binius STARK to prove the sortedness property of a sequence in zero-knowledge. The circuit combines two 4-bit range checks and one 4-bit comparison, with cross-gadget value links ensuring consistency across all constraints.

## Key Features

- **Sequence Validation**: Proves strictly increasing property (`x[0] < x[1] < ... < x[n]`)
- **Range Checking**: Validates all elements are valid 4-bit values (0-15)
- **Efficient Constraint System**: Optimized using Binius gadgets
- **Zero-Knowledge**: Generates ZK-STARK proofs that can be verified without revealing sequence values
- **Browser-Compatible**: Compiled to WASM for web deployment

## Circuit Architecture

The circuit implements a sequence prover with three core components:

### 1. Two Range Checks (for x and y sequences)
- **8 boolean columns** each (bits 0-3)
- **1 value column** each (packed value)
- **9 constraints** each (8 bit consistency + 1 pack constraint)

### 2. One Comparison Gadget
- **16 boolean columns** (8 bits for x, 8 bits for y)
- **8 linear constraints** for `x < y` comparison
- **8 auxiliary variables** (eq, lt accumulators)

### 3. Cross-Gadget Links
- **16 constraints** linking range-check bits with comparison bits
- Ensures compared bits ARE the range-checked bits (no contradiction)

## Performance Characteristics
- **26 columns**: 2 × RangeCheck(4) + Compare(4) = 13 + 16 = 29 columns
- **34 constraints**: 2 × 9 (range) + 8 (compare) + 16 (links) = 42 - 8 = 34 constraints
- **2 pins**: First element at point 0, last element at point n-1
- **Proof size**: ~13–31 KB (k=2-4, n=4-16)
- **Prove time**: ~48–211 ms (native), ~10–45 s (WASM)
- **Verify time**: ~6–19 ms (native), ~1–2 s (WASM)

## Interactive Demo

The web interface allows users to:
1. Input a sequence of 4-bit values (0-15, strictly increasing)
2. Verify that the sequence is correctly sorted
3. Generate and verify STARK proofs
4. Perform tamper tests on serialized proofs

## Technical Details

### Constraint System
- **RangeCheck(4)**: Standard Binius range check gadget for 4-bit values
- **Compare(4)**: Custom comparison gadget for strict less-than
- **Cross-links**: Ensures consistency between range and comparison

### HyperCube Processing
- **n = 2^k**: Number of hypercube points (k determines sequence length)
- **Sequence length**: `n + 1` (extra element for boundary pin)
- **Example**: k=2 → n=4 → sequence length = 5 elements

### Verification Strategy
- **Prover**: Shows knowledge of valid sorted sequence without revealing values
- **Verifier**: Checks proof without needing original sequence
- **Security**: Computational soundness (computationally binding constraints)

## Building and Running

### Prerequisites
- Zig compiler >= 0.16.0
- zig-stark library (local path)

### Native Binary
```sh
zig build
./zig-out/bin/sorted_seq
```

### WASM Module
```sh
zig build wasm
demos/sorted-sequence/www/binius_wasm.wasm
```

### Web Browser
```sh
cd demos/sorted-sequence/www && npx serve .
```

### Node.js Tests
```sh
node test_wasm.js
```

## File Structure

```
demos/sorted-sequence/
├── src/
│   ├── circuit.zig      # Circuit definition with Binius gadgets
│   ├── main.zig         # Native CLI binary
│   └── wasm_capi.zig    # WASM C-ABI exports
├── www/
│   ├── index.html       # Web UI
│   ├── app.js           # Browser WASM loader
│   ├── worker.js        # Web Worker for heavy computations
│   ├── style.css        # UI styling
│   └── binius_wasm.wasm  # Compiled WASM module
└── README.md            # This file
```

## Technical Notes

1. **Test Sequences**: Must have length `n+1` where `n = 2^k` (e.g., k=2 → 5 elements, k=3 → 9 elements)
2. **Strictly Increasing**: Sequence must satisfy `x[0] < x[1] < ... < x[n]`
3. **Range Constraints**: All values must be in [0, 16) (valid 4-bit unsigned)
4. **WASM Optimization**: Uses `ReleaseSmall` to avoid `@intCast` overflow checks
5. **Boundary Pins**: First and last elements are public (for verification simplicity)

## Example Inputs/Outputs

### Valid Input
```
0, 5, 10, 13, 15
```

### Expected Results
- **Proof Generated**: 13-31 KB (depending on proof randomness)
- **Verification Time**: 6-19 ms
- **Tamper Test**: Any single-byte modification in proof causes verification to fail

### Invalid Input (Rejected)
```
0, 5, 3, 10, 15  # 5 > 3 violates strict increasing property
```

## References

- [Binius STARK Documentation](https://github.com/samooth/zig-stark)
- [Binary Tower Fields](https://github.com/samooth/zig-stark/tree/main/docs)
- [Range Check Gadget](https://github.com/samooth/zig-stark/tree/main/src/binius/gadgets/rangecheck.zig)
- [Compare Gadget](https://github.com/samooth/zig-stark/tree/main/src/binius/gadgets/compare.zig)
