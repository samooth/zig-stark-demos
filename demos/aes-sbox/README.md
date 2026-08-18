# Binius STARK: AES S-box Prover

**`demos/aes-sbox/`**

> The **AES S-box** is a critical component of the Advanced Encryption Standard (AES). It performs a non-linear transformation on 8-bit values using the inverse in GF(256) followed by an affine transformation, providing confusion and diffusion properties essential for cryptographic security.

## Overview

The AES S-box Prover demonstrates how to use Binius STARK to prove that for a set of input values, the computed outputs correctly match the AES S-box transformation in zero-knowledge.

## Key Features

- **Field Operations**: Works over the binary tower field `F = Gf256`/`E = Gf2_128`
- **Parallel Processing**: Supports 4 parallel S-box instances (configurable)
- **Zero-Knowledge**: Generates ZK-STARK proofs that can be verified without revealing inputs
- **Browser-Compatible**: Compiled to WASM for web deployment

## Circuit Architecture

The circuit implements 4 parallel AES S-boxes, each with the following structure:

### S-box Components
1. **Input Bit Packing**: 8 boolean columns + 1 packed value column
2. **Squaring**: `v_sq = x^2` constraint
3. **Field Inversion**: `v_inv × v_sq = v_in` (handles x=0 case)
4. **Inverse Bit Packing**: 8 boolean columns + 1 packed value column
5. **Affine Transformation**: 8 linear constraints for AES affine map
6. **Output Bit Packing**: 8 boolean columns + 1 packed value column

### Performance Characteristics
- **116 columns**: 4 S-boxes × 29 columns each
- **148 constraints**: 4 S-boxes × 37 constraints each
- **2 pins**: First S-box input and output values
- **Proof size**: ~47–59 KB for k=2 (4 points × 4 S-boxes)
- **Prove time**: ~61–303 ms (native), ~7–32 s (WASM)
- **Verify time**: ~17–31 ms (native), ~0.5–0.7 s (WASM)

## Interactive Demo

The web interface allows users to:
1. Input 16 values (4 per S-box × 4 points)
2. View S-box transformations in real-time
3. Generate and verify STARK proofs
4. Perform tamper tests on serialized proofs

## Technical Details

### Field Operations
- **Base Field**: `Gf256` (8-bit field)
- **Extension Field**: `Gf2_128` (128-bit extension via binary tower)
- **Multiplication**: Wiedemann tower basis recursive Karatsuba algorithm
- **Inversion**: Implemented via tower field structure

### Constraint System
- **Prover**: Binius STARK with CommittedMlePcs polynomial commitment scheme
- **Serialization**: Interleaved column format for efficient proof storage
- **Verification**: Batch verification with consistency checks

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
zig build
./zig-out/bin/aes_sbox
```

### WASM Module
```sh
zig build wasm
demos/aes-sbox/www/binius_wasm.wasm
```

### Web Browser
```sh
cd demos/aes-sbox/www && npx serve .
```

### Node.js Tests
```sh
node test_wasm.js
```

## File Structure

```
demos/aes-sbox/
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

1. **Test Sequences**: Must have length `n+1` where `n = 2^k` (e.g., k=2 → 5 elements)
2. **Field Operations**: All field arithmetic uses Wiedemann tower basis
3. **Tamper Test**: Proves that even a single-byte modification in serialized proof causes verification to fail
4. **WASM Optimization**: Uses `ReleaseSmall` to avoid `@intCast` overflow checks

## Example Input/Output

### Input Format
```
0, 1, 63, 255
```

### Expected AES S-box Outputs
| Input (hex) | Output (hex) |
|-------------|--------------|
| 0x00        | 0x63         |
| 0x01        | 0xC1         |
| 0x63        | 0xCA         |
| 0xFF        | 0xB8         |

## References

- [Binius STARK Documentation](https://github.com/samooth/zig-stark)
- [AES S-box Specification](https://en.wikipedia.org/wiki/AES_S-box)
- [Binary Tower Fields](https://github.com/samooth/zig-stark/tree/main/docs)
