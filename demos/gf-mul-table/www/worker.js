'use strict';

const WASM_PATH = 'binius_wasm.wasm';

let memU8 = null;
let memU64 = null;
let exports = null;
let bumpPtr = 0;
const BUMP_START = 65536;

const N_BITS = 4;
const F_LEVEL = 3;
const NUM_COLS = 15;
const COL_A_VAL = 4;
const COL_B_VAL = 9;
const COL_C_VAL = 14;
const NUM_PINS = 3;

function zigMalloc(size) {
  const aligned = (bumpPtr + 7) & ~7;
  bumpPtr = aligned + ((size + 7) & ~7);
  return aligned;
}

function zigFree(_ptr, _size) {}

function resetBump() {
  bumpPtr = BUMP_START;
}

function readMemU8(ptr, len) {
  return new Uint8Array(memU8.buffer.slice(ptr, ptr + len));
}

function readMemString(ptr) {
  const start = ptr;
  while (memU8[ptr] !== 0) ptr++;
  return new TextDecoder().decode(memU8.subarray(start, ptr));
}

function readU64(ptr) {
  return Number(memU64.getBigUint64(ptr, true));
}

function allocAndWrite(data) {
  const len = data.length;
  const ptr = zigMalloc(len);
  memU8.set(data, ptr);
  return { ptr, len };
}

// --- Tower field multiplication (Wiedemann tower, GF(256)) ---

function towerMul(level, a, b) {
  if (level === 0) return a & b;
  const half = 1 << (level - 1);
  const mask = (1 << half) - 1;
  const beta = level === 1 ? 1 : 1 << (1 << (level - 2));
  const a0 = a & mask;
  const a1 = (a >> half) & mask;
  const b0 = b & mask;
  const b1 = (b >> half) & mask;
  const c0 = towerMul(level - 1, a0, b0);
  const c1 = towerMul(level - 1, a1, b1);
  const c2 = towerMul(level - 1, a0 ^ a1, b0 ^ b1);
  const lo = c0 ^ c1;
  const c1Beta = towerMul(level - 1, c1, beta);
  const hi = c2 ^ c0 ^ c1 ^ c1Beta;
  return lo | (hi << half);
}

function gf256Mul(a, b) {
  return towerMul(F_LEVEL, a, b) & 0xFF;
}

// --- Witness generation ---

function rangeCheckWitness(values) {
  const n = values.length;
  const cols = [];
  for (let i = 0; i < N_BITS; i++) {
    const col = new Uint8Array(n);
    for (let p = 0; p < n; p++) col[p] = (values[p] >> i) & 1;
    cols.push(col);
  }
  cols.push(new Uint8Array(values));
  return cols;
}

function generateColumns(aVals, bVals) {
  const n = aVals.length;
  const cVals = new Uint8Array(n);
  for (let i = 0; i < n; i++) {
    cVals[i] = gf256Mul(aVals[i], bVals[i]);
  }
  const aCols = rangeCheckWitness(aVals);
  const bCols = rangeCheckWitness(bVals);
  const cCols = rangeCheckWitness(cVals);
  const cols = [];
  for (let i = 0; i < 5; i++) cols.push(aCols[i]);
  for (let i = 0; i < 5; i++) cols.push(bCols[i]);
  for (let i = 0; i < 5; i++) cols.push(cCols[i]);
  return cols;
}

function generatePins(a0, b0, c0) {
  return [
    { col: COL_A_VAL, point: 0, value: a0 },
    { col: COL_B_VAL, point: 0, value: b0 },
    { col: COL_C_VAL, point: 0, value: c0 },
  ];
}

function serializeColumns(cols) {
  const n = cols[0].length;
  const total = 8 + cols.length * (8 + n);
  const buf = new Uint8Array(total);
  const dv = new DataView(buf.buffer);
  let off = 0;
  dv.setBigUint64(off, BigInt(cols.length), true); off += 8;
  for (let i = 0; i < cols.length; i++) {
    dv.setBigUint64(off, BigInt(n), true); off += 8;
    buf.set(cols[i], off); off += n;
  }
  return buf;
}

function serializePins(pins) {
  const total = 8 + pins.length * 17;
  const buf = new Uint8Array(total);
  const dv = new DataView(buf.buffer);
  let off = 0;
  dv.setBigUint64(off, BigInt(pins.length), true); off += 8;
  for (let i = 0; i < pins.length; i++) {
    dv.setBigUint64(off, BigInt(pins[i].col), true); off += 8;
    dv.setBigUint64(off, BigInt(pins[i].point), true); off += 8;
    buf[off] = pins[i].value & 0xFF; off += 1;
  }
  return buf;
}

// --- WASM operations ---

async function initWasm() {
  const resp = await fetch(WASM_PATH);
  const wasmBytes = await resp.arrayBuffer();
  const wasmModule = await WebAssembly.instantiate(wasmBytes, {
    env: {
      zig_stark_malloc: zigMalloc,
      zig_stark_free: zigFree,
    },
  });
  exports = wasmModule.instance.exports;
  memU8 = new Uint8Array(exports.memory.buffer);
  memU64 = new DataView(exports.memory.buffer);
  resetBump();
  return readMemString(exports.zs_version());
}

function doProve(aVals, bVals) {
  const n = aVals.length;
  const k = Math.round(Math.log2(n));
  const cols = generateColumns(aVals, bVals);
  const c0 = cols[COL_C_VAL][0];
  const pins = generatePins(aVals[0], bVals[0], c0);
  const colsBuf = serializeColumns(cols);
  const pinsBuf = serializePins(pins);

  const colsAlloc = allocAndWrite(colsBuf);
  const pinsAlloc = allocAndWrite(pinsBuf);
  const outPtr = zigMalloc(32);

  const ret = exports.zs_prove(
    k,
    colsAlloc.ptr,
    colsAlloc.len,
    pinsAlloc.ptr,
    pinsAlloc.len,
    outPtr,
    outPtr + 8,
    outPtr + 16,
    outPtr + 24,
  );

  if (ret !== 0) {
    return { error: 'zs_prove failed with code ' + ret };
  }

  const proofPtr = readU64(outPtr);
  const proofLen = readU64(outPtr + 8);
  const rootsPtr = readU64(outPtr + 16);
  const rootsLen = readU64(outPtr + 24);

  const proof = readMemU8(proofPtr, proofLen);
  const roots = readMemU8(rootsPtr, rootsLen);

  exports.zs_free(proofPtr, proofLen);
  exports.zs_free(rootsPtr, rootsLen);
  exports.zs_free(colsAlloc.ptr, colsAlloc.len);
  exports.zs_free(pinsAlloc.ptr, pinsAlloc.len);
  exports.zs_free(outPtr, 32);
  resetBump();

  return { proof: Array.from(proof), roots: Array.from(roots), k, pins };
}

function doVerify(k, rootsArr, pins, proofArr) {
  const rootsBuf = new Uint8Array(rootsArr);
  const pinsBuf = serializePins(pins);
  const proofBuf = new Uint8Array(proofArr);

  const rootsAlloc = allocAndWrite(rootsBuf);
  const pinsAlloc = allocAndWrite(pinsBuf);
  const proofAlloc = allocAndWrite(proofBuf);
  const outOkPtr = zigMalloc(1);

  const ret = exports.zs_verify(
    k,
    rootsAlloc.ptr,
    rootsAlloc.len,
    pinsAlloc.ptr,
    pinsAlloc.len,
    proofAlloc.ptr,
    proofAlloc.len,
    outOkPtr,
  );

  if (ret !== 0) {
    return { error: 'zs_verify failed with code ' + ret };
  }

  const ok = memU8[outOkPtr] !== 0;

  exports.zs_free(rootsAlloc.ptr, rootsAlloc.len);
  exports.zs_free(pinsAlloc.ptr, pinsAlloc.len);
  exports.zs_free(proofAlloc.ptr, proofAlloc.len);
  exports.zs_free(outOkPtr, 1);
  resetBump();

  return { ok };
}

// --- Message handling ---

self.onmessage = async function (e) {
  const msg = e.data;
  try {
    if (msg.action === 'init') {
      const version = await initWasm();
      self.postMessage({ action: 'init', version });
      return;
    }
    if (msg.action === 'prove') {
      const result = doProve(msg.a, msg.b);
      self.postMessage({ action: 'prove', ...result });
      return;
    }
    if (msg.action === 'verify') {
      const result = doVerify(msg.k, msg.roots, msg.pins, msg.proof);
      self.postMessage({ action: 'verify', ...result });
      return;
    }
  } catch (err) {
    self.postMessage({ action: msg.action, error: err.message });
  }
};
