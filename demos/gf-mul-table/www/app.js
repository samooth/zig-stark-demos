'use strict';

const outputEl = document.getElementById('output');
let worker = null;
let state = {
  version: null,
  proof: null,
  roots: null,
  pins: null,
  k: null,
};
let pendingTimer = 0;

function log(msg, cls = '') {
  const div = document.createElement('div');
  if (cls) div.className = cls;
  div.textContent = msg;
  outputEl.appendChild(div);
  outputEl.scrollTop = outputEl.scrollHeight;
}

function formatTime(ms) {
  if (ms < 1) return ms.toFixed(1) + ' ms';
  if (ms < 1000) return ms.toFixed(0) + ' ms';
  return (ms / 1000).toFixed(2) + ' s';
}

// --- GF(256) multiplication (Wiedemann tower, mirrors circuit.zig) ---

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

function parseValues(input) {
  const parts = input.split(',').map(s => s.trim()).filter(s => s.length > 0);
  const vals = [];
  for (const p of parts) {
    const v = parseInt(p, 10);
    if (isNaN(v) || v < 0 || v > 15) {
      return { error: 'Values must be integers 0-15. Invalid: ' + p };
    }
    vals.push(v);
  }
  if (vals.length < 2) {
    return { error: 'Need at least 2 values (n where n=2^k).' };
  }
  const n = vals.length;
  if (n & (n - 1)) {
    return { error: 'Count must be a power of 2. Got ' + n + ' values.' };
  }
  return { vals };
}

function updateTable(aVals, bVals) {
  const tbody = document.getElementById('tableBody');
  tbody.innerHTML = '';
  for (let i = 0; i < aVals.length; i++) {
    const tr = document.createElement('tr');
    const gfResult = towerMul(3, aVals[i], bVals[i]) & 0xFF;
    const intResult = (aVals[i] * bVals[i]);
    tr.innerHTML = '<td>' + aVals[i] + ' &times; ' + bVals[i] + '</td><td>' + intResult + '</td><td>' + gfResult + '</td>';
    tbody.appendChild(tr);
  }
}

document.getElementById('genBtn').addEventListener('click', () => {
  outputEl.textContent = '';
  const aParsed = parseValues(document.getElementById('aInput').value);
  const bParsed = parseValues(document.getElementById('bInput').value);
  if (aParsed.error) {
    log(aParsed.error, 'status-err');
    return;
  }
  if (bParsed.error) {
    log(bParsed.error, 'status-err');
    return;
  }
  if (aParsed.vals.length !== bParsed.vals.length) {
    log('a and b must have the same number of values.', 'status-err');
    return;
  }
  updateTable(aParsed.vals, bParsed.vals);
  log('Proving ' + aParsed.vals.length + ' multiplication triples (k=' + Math.round(Math.log2(aParsed.vals.length)) + ')...', 'status-info');
  pendingTimer = performance.now();
  worker.postMessage({ action: 'prove', a: aParsed.vals, b: bParsed.vals });
});

document.getElementById('verifyBtn').addEventListener('click', () => {
  outputEl.textContent = '';
  if (!state.proof) {
    log('No proof to verify. Generate one first.', 'status-err');
    return;
  }
  log('Verifying...', 'status-info');
  pendingTimer = performance.now();
  worker.postMessage({
    action: 'verify',
    k: state.k,
    roots: state.roots,
    pins: state.pins,
    proof: state.proof,
  });
});

document.getElementById('clearBtn').addEventListener('click', () => {
  outputEl.textContent = '';
  state = { version: state.version, proof: null, roots: null, pins: null, k: null };
});

worker = new Worker('worker.js');

worker.onmessage = function (e) {
  const msg = e.data;
  const elapsed = performance.now() - pendingTimer;
  if (msg.error) {
    log('Error: ' + msg.error, 'status-err');
    return;
  }
  if (msg.action === 'init') {
    state.version = msg.version;
    log('WASM loaded: ' + msg.version, 'status-ok');
    log('Enter a and b values (0-15, power-of-2 count) and click "Generate & Prove".', 'status-info');
    return;
  }
  if (msg.action === 'prove') {
    state.proof = msg.proof;
    state.roots = msg.roots;
    state.pins = msg.pins;
    state.k = msg.k;
    log('Proof generated in ' + formatTime(elapsed) + ': ' + msg.proof.length + ' bytes', 'status-ok');
    log('Click "Verify" to check the proof.', 'status-info');
    return;
  }
  if (msg.action === 'verify') {
    log('Verification result: ' + (msg.ok ? 'ACCEPTED' : 'REJECTED'), msg.ok ? 'status-ok' : 'status-err');
    return;
  }
};

worker.postMessage({ action: 'init' });
