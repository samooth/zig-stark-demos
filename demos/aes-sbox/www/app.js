'use strict';

const outputEl = document.getElementById('output');
const sboxBody = document.getElementById('sboxBody');
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

function parseInputs(input) {
  const parts = input.split(',').map(s => s.trim()).filter(s => s.length > 0);
  const vals = [];
  for (const p of parts) {
    const v = parseInt(p, 10);
    if (isNaN(v) || v < 0 || v > 255) {
      return { error: 'Values must be integers 0-255. Invalid: ' + p };
    }
    vals.push(v);
  }
  if (vals.length !== 16) {
    return { error: 'Need exactly 16 values (4 S-boxes × 4 points). Got ' + vals.length + '.' };
  }
  // Group into 4 S-boxes × 4 points
  const sboxes = [];
  for (let s = 0; s < 4; s++) {
    const sb = [];
    for (let p = 0; p < 4; p++) {
      sb.push(vals[s * 4 + p]);
    }
    sboxes.push(sb);
  }
  return { sboxes };
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

function towerInv(x) {
  // Compute inverse in tower field GF(256) = level 3
  if (x === 0) return 0;
  // Use extended Euclidean or pow(x, 254)
  // For demo, we can use a precomputed table or the circuit's approach
  // Since we're in JS, let's compute via the tower field structure
  // Actually, we need the inverse in the tower basis, not polynomial basis
  // The circuit uses tower.inv() which is in the Wiedemann tower basis
  // For the browser, we need the same computation
  // Let's implement the recursive inverse
  return towerInvRec(3, x);
}

function towerInvRec(level, a) {
  if (level === 0) {
    return a === 1 ? 1 : 0; // In GF(2), 1⁻¹ = 1, 0⁻¹ = 0 (handled by caller)
  }
  const half = 1 << (level - 1);
  const mask = (1 << half) - 1;
  const beta = level === 1 ? 1 : 1 << (1 << (level - 2));
  const a0 = a & mask;
  const a1 = (a >> half) & mask;
  if (a0 === 0 && a1 === 0) return 0;
  
  // Compute norm: N = a0² + a0*a1*β + a1² in subfield
  const a0_sq = towerMul(level - 1, a0, a0);
  const a1_sq = towerMul(level - 1, a1, a1);
  const a0a1 = towerMul(level - 1, a0, a1);
  const a0a1_beta = towerMul(level - 1, a0a1, beta);
  const norm = a0_sq ^ a0a1_beta ^ a1_sq;
  
  // inv_norm in subfield
  const inv_norm = towerInvRec(level - 1, norm);
  
  // lo = (a0 + a1*β) * inv_norm
  const a1_beta = towerMul(level - 1, a1, beta);
  const a0_plus_a1beta = a0 ^ a1_beta;
  const lo = towerMul(level - 1, a0_plus_a1beta, inv_norm);
  
  // hi = a1 * inv_norm
  const hi = towerMul(level - 1, a1, inv_norm);
  
  return lo | (hi << half);
}

function aesSbox(byte) {
  const inv = towerInv(byte);
  // Affine transform (AES matrix + 0x63)
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

function updateSboxTable(sboxes) {
  sboxBody.innerHTML = '';
  for (let s = 0; s < 4; s++) {
    for (let p = 0; p < 4; p++) {
      const tr = document.createElement('tr');
      const byte = sboxes[s][p];
      const { inv, out } = aesSbox(byte);
      const isFirst = p === 0;
      tr.innerHTML = '<td>' + (isFirst ? 'S-box ' + s : '') + '</td><td>0x' + byte.toString(16).padStart(2, '0') + '</td><td>0x' + inv.toString(16).padStart(2, '0') + '</td><td>0x' + out.toString(16).padStart(2, '0') + '</td>';
      sboxBody.appendChild(tr);
    }
  }
}

document.getElementById('proveBtn').addEventListener('click', () => {
  outputEl.textContent = '';
  const input = document.getElementById('inputSbox').value;
  const parsed = parseInputs(input);
  if (parsed.error) {
    log(parsed.error, 'status-err');
    return;
  }
  updateSboxTable(parsed.sboxes);
  log('Proving 4 S-boxes × 4 points (k=2)...', 'status-info');
  pendingTimer = performance.now();
  worker.postMessage({ action: 'prove', sboxes: parsed.sboxes });
});

document.getElementById('verifyBtn').addEventListener('click', () => {
  outputEl.textContent = '';
  if (!state.proof) {
    log('No proof to verify. Click "Prove" first.', 'status-err');
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
  sboxBody.innerHTML = '';
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
    log('Enter 16 input bytes (4 per S-box × 4 points) and click "Prove".', 'status-info');
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