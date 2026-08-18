#!/bin/bash
# Demo script for zig-stark-demos
# Usage: ./demo.sh [command]
#
# Commands:
#   build     Build all native binaries
#   wasm      Build all WASM modules
#   www       Build all WASM + copy to www/
#   test      Run Node.js WASM tests
#   sorted    Run sorted-sequence demo (native)
#   gf-mul    Run gf-mul-table demo (native)
#   aes       Run aes-sbox demo (native)
#   serve-sorted  Serve sorted-sequence on port 3000
#   serve-gf-mul    Serve gf-mul-table on port 3001
#   serve-aes       Serve aes-sbox on port 3002
#   all       Build all native binaries and run all demos + tests
#   fmt       Check code formatting
#   help      Show this help message

set -e

cd "$(dirname "$0")"

case "${1:-help}" in
  build)
    echo "Building all native binaries..."
    zig build
    echo "Done. Binaries in zig-out/bin/"
    ;;

  wasm)
    echo "Building all WASM modules..."
    zig build wasm
    echo "Done."
    ;;

  www)
    echo "Building all WASM + copying to www/..."
    zig build www
    echo "Done."
    ;;

  test)
    echo "Running Node.js WASM tests..."
    node test_wasm.js
    ;;

  sorted)
    echo "Running sorted-sequence demo..."
    zig build
    ./zig-out/bin/sorted_seq
    ;;

  gf-mul)
    echo "Running gf-mul-table demo..."
    zig build
    ./zig-out/bin/gf_mul_table
    ;;

  aes)
    echo "Running aes-sbox demo..."
    zig build
    ./zig-out/bin/aes_sbox
    ;;

  serve-sorted)
    echo "Serving sorted-sequence demo on port 3000..."
    cd demos/sorted-sequence/www && npx serve . -l 3000
    ;;

  serve-gf-mul)
    echo "Serving gf-mul-table demo on port 3001..."
    cd demos/gf-mul-table/www && npx serve . -l 3001
    ;;

  serve-aes)
    echo "Serving aes-sbox demo on port 3002..."
    cd demos/aes-sbox/www && npx serve . -l 3002
    ;;

  serve-all)
    echo "Serving all demos (ports 3000-3002) requires multiple terminals."
    echo "Use the individual serve- commands:"
    echo "  ./demo.sh serve-sorted &  # port 3000"
    echo "  ./demo.sh serve-gf-mul &  # port 3001"
    echo "  ./demo.sh serve-aes       # port 3002"
    ;;

  all)
    echo "Building all native binaries..."
    zig build
    echo ""
    echo "=== Sorted Sequence Demo ==="
    ./zig-out/bin/sorted_seq
    echo ""
    echo "=== GF(256) Multiplication Table Demo ==="
    ./zig-out/bin/gf_mul_table
    echo ""
    echo "=== AES S-box Demo ==="
    ./zig-out/bin/aes_sbox
    echo ""
    echo "=== Node.js WASM Tests ==="
    node test_wasm.js
    ;;

  fmt)
    echo "Checking code formatting..."
    zig build fmt
    ;;

  help|--help|-h)
    echo "zig-stark-demos runner script"
    echo ""
    echo "Usage: ./demo.sh [command]"
    echo ""
    echo "Commands:"
    echo "  build     Build all native binaries"
    echo "  wasm      Build all WASM modules"
    echo "  www       Build all WASM + copy to www/"
    echo "  test      Run Node.js WASM tests"
    echo "  sorted    Run sorted-sequence demo"
    echo "  gf-mul    Run gf-mul-table demo"
    echo "  aes       Run aes-sbox demo"
    echo "  serve-sorted  Serve sorted-sequence on port 3000"
    echo "  serve-gf-mul    Serve gf-mul-table on port 3001"
    echo "  serve-aes       Serve aes-sbox on port 3002"
    echo "  all       Build all native binaries and run all demos + tests"
    echo "  fmt       Check code formatting"
    echo "  help      Show this help message"
    ;;

  *)
    echo "Unknown command: $1"
    echo "Run './demo.sh help' for usage."
    exit 1
    ;;
esac
