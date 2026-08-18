'use strict';

const WASM_PATH = 'binius_wasm.wasm';

let memU8 = null;
let memU64 = null;
let exports = null;
let bumpPtr = 0;
const BUMP_START = 262144; // 256KB — safe for WASM memory

const NUM_SBOXES = 4;
const NUM_BITS = 8;
const NUM_COLS = NUM_SBOXES * 29; // 29 cols per sbox
const SBOX_STRIDE = 29; // columns per S-box

function colIdx(sbox, local) {
  return sbox * SBOX_STRIDE + local;
}

const COL_INPUT_VAL = colIdx(0, 8);
const COL_OUT_VAL = colIdx(0, 28);

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

function refreshMem() {
  memU8 = new Uint8Array(exports.memory.buffer);
  memU64 = new DataView(exports.memory.buffer);
}

// --- Tower field multiplication (Wiedemann tower, GF(256)) ---

function towerMul(level, a, b) {
  if (level === 0) return a & b;
  const half = 1 << (level - 1);
  const mask = (1 << half) - 1;
  const beta = level === 1 ? 1 : 1 << (1 << (level - 2));
  const a0 = a & mask, a1 = (a >> half) & mask;
  const b0 = b & mask, b1 = (b >> half) & mask;
  const c0 = towerMul(level - 1, a0, b0);
  const c1 = towerMul(level - 1, a1, b1);
  const c2 = towerMul(level - 1, a0 ^ a1, b0 ^ b1);
  const lo = c0 ^ c1;
  const c1Beta = towerMul(level - 1, c1, beta);
  const hi = c2 ^ c0 ^ c1 ^ c1Beta;
  return lo | (hi << half);
}

function towerInv(x) {
  if (x === 0) return 0;
  return towerInvRec(3, x);
}

function towerInvRec(level, a) {
  if (level === 0) {
    return a === 1 ? 1 : 0;
  }
  const half = 1 << (level - 1);
  const mask = (1 << half) - 1;
  const beta = level === 1 ? 1 : 1 << (1 << (level - 2));
  const a0 = a & mask;
  const a1 = (a >> half) & mask;
  if (a0 === 0 && a1 === 0) return 0;

  const a0_sq = towerMul(level - 1, a0, a0);
  const a1_sq = towerMul(level - 1, a1, a1);
  const a0a1 = towerMul(level - 1, a0, a1);
  const a0a1_beta = towerMul(level - 1, a0a1, beta);
  const norm = a0_sq ^ a0a1_beta ^ a1_sq;
  const inv_norm = towerInvRec(level - 1, norm);
  const a1_beta = towerMul(level - 1, a1, beta);
  const a0_plus_a1beta = a0 ^ a1_beta;
  const lo = towerMul(level - 1, a0_plus_a1beta, inv_norm);
  const hi = towerMul(level - 1, a1, inv_norm);
  return lo | (hi << half);
}

function aesSbox(byte) {
  const inv = towerInv(byte);
  const AFFINE_MATRIX = [
    [1,0,0,0,1,1,1,1],
    [1,1,0,0,0,1,1,1],
    [1,1,1,0,0,0,1,1],
    [1,1,1,1,0,0,0,1],
    [1,1,1,1,1,0,0,0],
    [0,1,1,1,1,1,0,0],
    [0,0,1,1,1,1,1,0],
    [0,0,0,1,1,1,1,1],
  ];
  const AFFINE_CONST = 0x63;
  var out = 0;
  for (let i = 0; i < 8; i++) {
    var bit = (AFFINE_CONST >> i) & 1;
    for (let j = 0; j < 8; j++) {
      if (AFFINE_MATRIX[i][j]) {
        bit ^= (inv >> j) & 1;
      }
    }
    out |= bit << i;
  }
  return { inv, out };
}

// --- Witness generation ---

function rangeCheckWitness(values) {
  // BitPack(8): 8 bit columns + 1 value column = 9 columns
  const n = values.length;
  const cols = [];
  for (let i = 0; i < 8; i++) {
    const col = new Uint8Array(n);
    for (let p = 0; p < n; p++) col[p] = (values[p] >> i) & 1;
    cols.push(col);
  }
  cols.push(new Uint8Array(values));
  return cols;
}

function generateColumns(sboxes) {
  // sboxes: [NUM_SBOXES][n] - n points
  const n = sboxes[0].length;
  const cols = [];
  
  // Columns per S-box (stride=29):
  // 0-7:    input bits
  // 8:      input value
  // 9:      v_sq (x^2)
  // 10:     inverse value
  // 11-18:  inverse bits
  // 19:     inverse value (pack)
  // 20-27:  output bits (= affine bits)
  // 28:     output value
  
  for (let s = 0; s < NUM_SBOXES; s++) {
    const vals = sboxes[s];
    const invs = [];
    const outs = [];
    for (let p = 0; p < n; p++) {
      const { inv, out } = aesSbox(vals[p]);
      invs.push(inv);
      outs.push(out);
    }
    
    // Input BitPack
    const inputCols = rangeCheckWitness(vals);
    for (let i = 0; i < 9; i++) cols.push(inputCols[i]);
    
    // v_sq col (x^2 in tower field)
    const vSqCol = new Uint8Array(n);
    for (let p = 0; p < n; p++) {
      vSqCol[p] = towerMul(3, vals[p], vals[p]);
    }
    cols.push(vSqCol);
    
    // Inverse value col
    const invValCol = new Uint8Array(n);
    for (let p = 0; p < n; p++) invValCol[p] = invs[p];
    cols.push(invValCol);
    
    // Inverse BitPack
    const invCols = rangeCheckWitness(invs);
    for (let i = 0; i < 9; i++) cols.push(invCols[i]);
    
    // Output BitPack (output bits = affine bits, which are already {0,1})
    for (let i = 0; i < 8; i++) {
      const col = new Uint8Array(n);
      for (let p = 0; p < n; p++) col[p] = (outs[p] >> i) & 1;
      cols.push(col);
    }
    // Output value pack
    cols.push(new Uint8Array(outs));
  }
  
  return cols;
}

function generatePins(sboxes) {
  // Pin input value at point 0 and output value at point 0 for S-box 0
  const firstInput = sboxes[0][0];
  const { out } = aesSbox(firstInput);
  return [
    { col: COL_INPUT_VAL, point: 0, value: firstInput },
    { col: COL_OUT_VAL, point: 0, value: out },
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
  for (const p of pins) {
    dv.setBigUint64(off, BigInt(p.col), true); off += 8;
    dv.setBigUint64(off, BigInt(p.point), true); off += 8;
    buf[off] = p.value & 0xFF; off += 1;
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
  refreshMem();
  resetBump();
  return readMemString(exports.zs_version());
}

function doProve(sboxes) {
  const k = 2;
  const cols = generateColumns(sboxes);
  const pins = generatePins(sboxes);
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

  refreshMem();
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

  refreshMem();
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
      const result = doProve(msg.sboxes);
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