# Binius STARK: GF(256) Multiplication Table Prover

**`demos/gf-mul-table/`**

> Proves that for a batch of inputs, c = a × b in GF(256) (Wiedemann tower field) with all three values range-checked to [0, 16), using a Binius STARK over Gf256/Gf2_128 with CommittedMlePcs.

## Overview

The GF(256) Multiplication Table Prover demonstrates how to use Binius STARK to prove multiplication relationships in the finite field GF(256) over the binary tower field structure, with all values range-checked to 4-bit values (0-15).

## Key Features

- **Field Operations**: Works over the binary tower field `F = Gf256`/`E = Gf2_128`
- **Range Checks**: Built-in 4-bit range checking for all values
- **Tower Field Multiplication**: Uses Wiedemann tower basis recursive Karatsuba algorithm
- **Zero-Knowledge**: Generates ZK-STARK proofs that can be verified without revealing inputs
- **Browser-Compatible**: Compiled to WASM for web deployment

## Circuit Architecture

The circuit implements three 4-bit range checks (for a, b, c) plus a degree-2 field multiplication constraint expressed via a precomputed tower-field multiplication tensor.

### Performance Characteristics
- **15 columns**: 3 × RangeCheck(4) = 5 columns each
- **19 constraints**: 3 × range-check + 4 multiplication constraints
- **3 pins**: First multiplication triple (a[0], b[0], c[0]) at point 0
- **Proof size**: ~7–18 KB for batch sizes 4-8 (k=2-3)
- **Prove time**: ~48–172 ms (native), ~1–4 s (WASM)
- **Verify time**: ~6–13 ms (native), ~45–55 ms (WASM)

## Interactive Demo

The web interface allows users to:
1. Input a and b values (comma-separated, power-of-2 count)
2. View multiplication results in the 8×8 GF(256) table
3. Generate and verify STARK proofs
4. Perform tamper tests on serialized proofs

## Technical Details

### Field Operations
- **Base Field**: `Gf256` (8-bit field, level 3 in tower)
- **Extension Field**: `Gf2_128` (128-bit extension via binary tower)
- **Tower Structure**: Wiedemann tower basis with base field `Gf256`
- **Multiplication Algorithm**: Recursive Karatsuba implementation in towerMul

### Constraint System
- **Range Check**: 4-bit binary decomposition with consistency constraints
- **Field Multiplication**: Expressed as degree-2 monomials using precomputed tensor
- **Batch Processing**: Handles n = 2^k multiplications simultaneously
- **Public Inputs**: Three boundary pins (a[0], b[0], c[0]) at point 0

### Precomputed Tensor
The multiplication tensor `mul_tensor[i][j][k] = bit k of (e_i × e_j)` in GF(256):
- **Size**: 16 × 16 × 16 boolean array
- **Computation**: Comptime-only using towerMul for all combinations
- **Usage**: Decomposes the nonlinear multiplication constraint into linear bits

### Security Properties
- **Completeness**: Valid proofs always verify
- **Soundness**: Invalid proofs cannot verify (computational soundness)
- **Zero-Knowledge**: Proof reveals no information about secret inputs

## Building and Running

### Prerequisites
- Zig compiler >= 0.16.0
- zig-stark library (local path)

### Native Binary
```sh
zig build demo-gf-mul-table
./zig-out/bin/gf_mul_table
```

### WASM Module
```sh
zig build wasm
demos/gf-mul-table/www/binius_wasm.wasm
```

### Web Browser
```sh
cd demos/gf-mul-table/www && npx serve .
```

### Node.js Tests
```sh
node test_wasm.js
```

## File Structure

```
demos/gf-mul-table/
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

1. **Test Sequences**: Must have length `n = 2^k` (e.g., k=2 → 4 elements, k=3 → 8 elements)
2. **Field Arithmetic**: All field arithmetic uses Wiedemann tower basis
3. **Precomputation**: Multiplication tensor is computed comptime for efficiency
4. **WASM Optimization**: Uses `ReleaseSmall` to avoid `@intCast` overflow checks
5. **Range Check**: Values must be in range [0, 16) (4-bit unsigned)

## Example Input/Output

### Input Format
```
3, 5, 7, 9  # k=2, n=4 multiplications
```

### Expected GF(256) Multiplication Table
| a \ b | 3  | 5  | 7  | 9  |
|-------|----|----|----|----|
| 3     | 15 | 19 | 21 | 27 |
| 5     | 19 | 9  | 11 | 17 |
| 7     | 21 | 11 | 14 | 20 |
| 9     | 27 | 17 | 20 | 27 |

### Verification
The proof validates that each (a, b) pair produces the correct product c in GF(256), and all values are within the 4-bit range [0, 15].

## References

- [Binius STARK Documentation](https://github.com/samooth/zig-stark)
- [Binary Tower Fields](https://github.com/samooth/zig-stark/tree/main/docs)
- [Wiedemann Tower Field Structure](https://arxiv.org/abs/2008.05692)
