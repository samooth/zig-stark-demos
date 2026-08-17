'use strict';

const WASM_PATH = 'binius_wasm.wasm';

let memU8 = null;
let memU64 = null;
let exports = null;
let bumpPtr = 0;
const BUMP_START = 65536;

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

// --- Witness generation: RangeCheck (m=4) ---

function rangeCheckWitness(values) {
  const n = values.length;
  const cols = [];
  for (let i = 0; i < 4; i++) {
    const col = new Uint8Array(n);
    for (let p = 0; p < n; p++) col[p] = (values[p] >> i) & 1;
    cols.push(col);
  }
  cols.push(new Uint8Array(values));
  return cols;
}

// --- Witness generation: Compare (m=4) ---

function compareWitness(x, y) {
  const n = x.length;
  const cols = [];
  for (let i = 0; i < 16; i++) cols.push(new Uint8Array(n));
  for (let p = 0; p < n; p++) {
    let eqAcc = 1;
    let ltAcc = 0;
    for (let i = 3; i >= 0; i--) {
      const ai = (x[p] >> i) & 1;
      const bi = (y[p] >> i) & 1;
      cols[i][p] = ai;
      cols[4 + i][p] = bi;
      const atLow = ai === 0 && bi === 1 ? 1 : 0;
      ltAcc ^= atLow & eqAcc;
      eqAcc &= 1 ^ (ai ^ bi);
      cols[8 + i][p] = eqAcc;
      cols[12 + i][p] = ltAcc;
    }
  }
  return cols;
}

const NUM_COLS = 26;
const COL_X_VAL = 4;
const COL_Y_VAL = 9;

function generateColumns(seq) {
  const n = seq.length - 1;
  const x = seq.slice(0, n);
  const y = seq.slice(1, n + 1);
  const xCols = rangeCheckWitness(x);
  const yCols = rangeCheckWitness(y);
  const cmpCols = compareWitness(x, y);
  const cols = [];
  for (let i = 0; i < 5; i++) cols.push(xCols[i]);
  for (let i = 0; i < 5; i++) cols.push(yCols[i]);
  for (let i = 0; i < 16; i++) cols.push(cmpCols[i]);
  return cols;
}

function generatePins(n, seq) {
  return [
    { col: COL_X_VAL, point: 0, value: seq[0] },
    { col: COL_Y_VAL, point: n - 1, value: seq[n] },
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

function doProve(seq) {
  const n = seq.length - 1;
  const k = Math.round(Math.log2(n));
  const cols = generateColumns(seq);
  const pins = generatePins(n, seq);
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
      const result = doProve(msg.seq);
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
