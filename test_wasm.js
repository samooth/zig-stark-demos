'use strict';
const fs = require('fs');
const path = require('path');
const root = path.resolve('.');

const BUMP_START = 262144; // 256KB — past static data, below output region
const OUTPUT_OFFSET = 65536; // Fixed output parameter region

async function testWasm(demoName, wasmPath, demoType) {
  console.log('\n=== ' + demoName + ' ===');
  const wasmSource = fs.readFileSync(wasmPath);

  let bumpPtr = BUMP_START;

  function zigMalloc(size) {
    const aligned = (bumpPtr + 7) & ~7;
    bumpPtr = aligned + ((size + 7) & ~7);
    return aligned;
  }

  function zigFree(_ptr, _size) {}

  const wasmModule = await WebAssembly.instantiate(wasmSource, {
    env: {
      zig_stark_malloc: zigMalloc,
      zig_stark_free: zigFree,
    },
  });
  const { memory, zs_prove, zs_verify, zs_free, zs_version } = wasmModule.instance.exports;

  function refreshMem() {
    memU8 = new Uint8Array(memory.buffer);
    dv = new DataView(memory.buffer);
  }

  let memU8 = new Uint8Array(memory.buffer);
  let dv = new DataView(memory.buffer);

  function resetBump() { bumpPtr = BUMP_START; refreshMem(); }

  function allocAndWrite(data) {
    const a = (bumpPtr + 7) & ~7;
    bumpPtr = a + ((data.length + 7) & ~7);
    memU8.set(data, a);
    return { ptr: a, len: data.length };
  }

  function readU64(ptr) { return Number(dv.getBigUint64(ptr, true)); }
  function readBytes(ptr, len) { return Buffer.from(memU8.slice(ptr, ptr + len)); }

  function readMemString(ptr) {
    let s = '';
    let i = ptr;
    while (memU8[i] !== 0) s += String.fromCharCode(memU8[i++]);
    return s;
  }

  const version = readMemString(zs_version());
  console.log('Version:', version);
  console.log('Memory size:', memory.buffer.byteLength, 'bytes');

  // --- Witness generators ---

  function rcWitness(values) {
    const cols = [];
    for (let i = 0; i < 4; i++) {
      const col = new Uint8Array(values.length);
      for (let p = 0; p < values.length; p++) col[p] = (values[p] >> i) & 1;
      cols.push(col);
    }
    cols.push(new Uint8Array(values));
    return cols;
  }

  function cmpWitness(x, y) {
    const n = x.length;
    const cols = [];
    for (let i = 0; i < 16; i++) cols.push(new Uint8Array(n));
    for (let p = 0; p < n; p++) {
      let eqAcc = 1, ltAcc = 0;
      for (let i = 3; i >= 0; i--) {
        const ai = (x[p] >> i) & 1;
        const bi = (y[p] >> i) & 1;
        cols[i][p] = ai; cols[4 + i][p] = bi;
        const atLow = ai === 0 && bi === 1 ? 1 : 0;
        ltAcc ^= atLow & eqAcc;
        eqAcc &= 1 ^ (ai ^ bi);
        cols[8 + i][p] = eqAcc;
        cols[12 + i][p] = ltAcc;
      }
    }
    return cols;
  }

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

  // --- Serialization ---

  function serializeColumns(cols) {
    const n = cols[0].length;
    const total = 8 + cols.length * (8 + n);
    const buf = new Uint8Array(total);
    const d = new DataView(buf.buffer);
    let off = 0;
    d.setBigUint64(off, BigInt(cols.length), true); off += 8;
    for (let i = 0; i < cols.length; i++) {
      d.setBigUint64(off, BigInt(n), true); off += 8;
      buf.set(cols[i], off); off += n;
    }
    return buf;
  }

  function serializePins(pins) {
    const total = 8 + pins.length * 17;
    const buf = new Uint8Array(total);
    const d = new DataView(buf.buffer);
    let off = 0;
    d.setBigUint64(off, BigInt(pins.length), true); off += 8;
    for (const p of pins) {
      d.setBigUint64(off, BigInt(p.col), true); off += 8;
      d.setBigUint64(off, BigInt(p.point), true); off += 8;
      buf[off] = p.value & 0xFF; off += 1;
    }
    return buf;
  }

  let allPass = true;

  if (demoType === 'sorted-seq') {
    const tests = [
      { seq: [0, 5, 10, 13, 15] },
      { seq: [0, 2, 4, 6, 8, 10, 12, 14, 15] },
      { seq: [0, 1, 3, 5, 7, 9, 11, 13, 15] },
    ];

    for (const test of tests) {
      const seq = test.seq;
      const n = seq.length - 1;
      const k = Math.round(Math.log2(n));
      const x = seq.slice(0, n);
      const y = seq.slice(1, n + 1);
      const cols = [...rcWitness(x), ...rcWitness(y), ...cmpWitness(x, y)];
      const pins = [
        { col: 4, point: 0, value: seq[0] },
        { col: 9, point: n - 1, value: seq[n] },
      ];

      const colsBuf = serializeColumns(cols);
      const pinsBuf = serializePins(pins);

      resetBump();
      const ca = allocAndWrite(colsBuf);
      const pa = allocAndWrite(pinsBuf);

      // Output params at fixed location
      const outPtr = OUTPUT_OFFSET;

      const t0 = Date.now();
      const ret = zs_prove(k, ca.ptr, ca.len, pa.ptr, pa.len, outPtr, outPtr + 8, outPtr + 16, outPtr + 24);
      refreshMem();
      const t1 = Date.now();

      if (ret !== 0) {
        console.log('Test seq=' + JSON.stringify(seq) + ': PROVE FAILED ret=' + ret);
        allPass = false;
        continue;
      }

      const proofPtr = readU64(outPtr);
      const proofLen = readU64(outPtr + 8);
      const rootsPtr = readU64(outPtr + 16);
      const rootsLen = readU64(outPtr + 24);

      const proof = readBytes(proofPtr, proofLen);
      const roots = readBytes(rootsPtr, rootsLen);

      zs_free(proofPtr, proofLen);
      zs_free(rootsPtr, rootsLen);

      // Verify
      resetBump();
      const ra = allocAndWrite(roots);
      const pa2 = allocAndWrite(pinsBuf);
      const pra = allocAndWrite(proof);
      const okPtr = OUTPUT_OFFSET + 32;

      const ret2 = zs_verify(k, ra.ptr, ra.len, pa2.ptr, pa2.len, pra.ptr, pra.len, okPtr);
      refreshMem();
      const ok = ret2 === 0 && memU8[okPtr] !== 0;
      const t2 = Date.now();

      // Tamper test
      const tampered = Buffer.from(proof);
      tampered[Math.floor(tampered.length / 2)] ^= 0x01;
      tampered[Math.floor(tampered.length / 4)] ^= 0x01;

      resetBump();
      const ra2 = allocAndWrite(roots);
      const pa2b = allocAndWrite(pinsBuf);
      const pra2 = allocAndWrite(tampered);
      const okPtr2 = OUTPUT_OFFSET + 32;

      const retTampered = zs_verify(k, ra2.ptr, ra2.len, pa2b.ptr, pa2b.len, pra2.ptr, pra2.len, okPtr2);
      refreshMem();
      const okTamperedVal = retTampered === 0 && memU8[okPtr2] !== 0;
      const t3 = Date.now();

      console.log('Test seq=' + JSON.stringify(seq) + ' (k=' + k + '):');
      console.log('  prove: ' + (t1 - t0) + 'ms, ' + proofLen + 'B');
      console.log('  verify: ' + (t2 - t1) + 'ms, ok=' + ok);
      console.log('  tampered: ok=' + okTamperedVal + ' (ret=' + retTampered + ')');
      const pass = ok && !okTamperedVal;
      if (!pass) allPass = false;
      console.log(pass ? '  PASS' : '  FAIL');
    }

  } else if (demoType === 'gf-mul-table') {
    const tests = [
      { a: [3, 5, 7, 9], b: [2, 4, 6, 8] },
      { a: [0, 2, 3, 5, 7, 9, 11, 13], b: [1, 3, 5, 7, 9, 11, 13, 15] },
      { a: [15, 0, 1, 2, 4, 8, 3, 6], b: [1, 15, 2, 3, 5, 7, 9, 12] },
    ];

    for (const test of tests) {
      const aVals = test.a;
      const bVals = test.b;
      const n = aVals.length;
      const k = Math.round(Math.log2(n));
      const cVals = aVals.map((a, i) => towerMul(3, a, bVals[i]) & 0xFF);

      const cols = [...rcWitness(aVals), ...rcWitness(bVals), ...rcWitness(cVals)];
      const pins = [
        { col: 4, point: 0, value: aVals[0] },
        { col: 9, point: 0, value: bVals[0] },
        { col: 14, point: 0, value: cVals[0] },
      ];

      const colsBuf = serializeColumns(cols);
      const pinsBuf = serializePins(pins);

      resetBump();
      const ca = allocAndWrite(colsBuf);
      const pa = allocAndWrite(pinsBuf);
      const outPtr = OUTPUT_OFFSET;

      const t0 = Date.now();
      const ret = zs_prove(k, ca.ptr, ca.len, pa.ptr, pa.len, outPtr, outPtr + 8, outPtr + 16, outPtr + 24);
      refreshMem();
      const t1 = Date.now();

      if (ret !== 0) {
        console.log('Test a=' + JSON.stringify(aVals) + ': PROVE FAILED ret=' + ret);
        allPass = false;
        continue;
      }

      const proofPtr = readU64(outPtr);
      const proofLen = readU64(outPtr + 8);
      const rootsPtr = readU64(outPtr + 16);
      const rootsLen = readU64(outPtr + 24);

      console.log('  DEBUG: proofPtr=' + proofPtr + ' proofLen=' + proofLen + ' rootsPtr=' + rootsPtr + ' rootsLen=' + rootsLen);
      const proof = readBytes(proofPtr, proofLen);
      const proofHex = Buffer.from(proof).toString('hex');
      console.log('  DEBUG: proof full hex: ' + proofHex);
      fs.writeFileSync('/tmp/gfmul_proof.bin', proof);
      const roots = readBytes(rootsPtr, rootsLen);
      console.log('  DEBUG: roots first 32 bytes: ' + Buffer.from(roots.slice(0, 32)).toString('hex'));

      zs_free(proofPtr, proofLen);
      zs_free(rootsPtr, rootsLen);

      // Verify
      resetBump();
      const ra = allocAndWrite(roots);
      const pa2 = allocAndWrite(pinsBuf);
      const pra = allocAndWrite(proof);
      console.log('  DEBUG: verify proof at ' + pra.ptr + ' len ' + pra.len + ' roots at ' + ra.ptr + ' len ' + ra.len);
      const okPtr = OUTPUT_OFFSET + 32;

      const ret2 = zs_verify(k, ra.ptr, ra.len, pa2.ptr, pa2.len, pra.ptr, pra.len, okPtr);
      refreshMem();
      const ok = ret2 === 0 && memU8[okPtr] !== 0;
      const t2 = Date.now();

      // Round-trip verify
      const okRT = ok;

      // Tamper test
      const tampered = Buffer.from(proof);
      tampered[Math.floor(tampered.length / 2)] ^= 0x01;
      tampered[Math.floor(tampered.length / 4)] ^= 0x01;

      resetBump();
      const ra2 = allocAndWrite(roots);
      const pa2b = allocAndWrite(pinsBuf);
      const pra2 = allocAndWrite(tampered);
      const okPtr2 = OUTPUT_OFFSET + 32;

      const retTampered = zs_verify(k, ra2.ptr, ra2.len, pa2b.ptr, pa2b.len, pra2.ptr, pra2.len, okPtr2);
      refreshMem();
      const okTamperedVal = retTampered === 0 && memU8[okPtr2] !== 0;
      const t3 = Date.now();

      console.log('Test a=' + JSON.stringify(aVals) + ' (k=' + k + '):');
      console.log('  c = ' + cVals.map((v, i) => aVals[i] + '*' + bVals[i] + '=' + v).join(', '));
      console.log('  prove: ' + (t1 - t0) + 'ms, ' + proofLen + 'B');
      console.log('  verify: ' + (t2 - t1) + 'ms, ok=' + ok);
      console.log('  tampered: ok=' + okTamperedVal + ' (ret=' + retTampered + ')');
      const pass = ok && !okTamperedVal;
      if (!pass) allPass = false;
      console.log(pass ? '  PASS' : '  FAIL');
    }
  }

  return allPass;
}

(async () => {
  let allPass = true;

  allPass &= await testWasm(
    'Sorted Sequence',
    path.join(root, 'demos/sorted-sequence/www/binius_wasm.wasm'),
    'sorted-seq'
  );

  allPass &= await testWasm(
    'GF Mul Table',
    path.join(root, 'demos/gf-mul-table/www/binius_wasm.wasm'),
    'gf-mul-table'
  );

  console.log('\n=== OVERALL: ' + (allPass ? 'ALL PASS' : 'SOME FAILED') + ' ===');
  process.exit(allPass ? 0 : 1);
})();
