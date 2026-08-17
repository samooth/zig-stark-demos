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

function parseSequence(input) {
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
    return { error: 'Need at least 2 values (n+1 where n=2^k).' };
  }
  const n = vals.length - 1;
  if (n & (n - 1)) {
    return { error: 'Number of gaps must be a power of 2. Got ' + n + ' gaps (' + vals.length + ' values).' };
  }
  for (let i = 0; i < n; i++) {
    if (vals[i] >= vals[i + 1]) {
      return { error: 'Sequence must be strictly increasing. ' + vals[i] + ' >= ' + vals[i + 1] + ' at index ' + i + '.' };
    }
  }
  return { seq: vals, k: Math.round(Math.log2(n)) };
}

document.getElementById('proveBtn').addEventListener('click', () => {
  outputEl.textContent = '';
  const input = document.getElementById('seqInput').value;
  const parsed = parseSequence(input);
  if (parsed.error) {
    log(parsed.error, 'status-err');
    return;
  }
  log('Proving ' + parsed.seq.length + ' values (k=' + parsed.k + ')...', 'status-info');
  pendingTimer = performance.now();
  worker.postMessage({ action: 'prove', seq: parsed.seq });
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
    log('Enter a strictly increasing sequence (0-15) and click "Prove".', 'status-info');
    return;
  }
  if (msg.action === 'prove') {
    state.proof = msg.proof;
    state.roots = msg.roots;
    state.pins = msg.pins;
    state.k = msg.k;
    log('Proof generated in ' + formatTime(elapsed) + ': ' + msg.proof.length + ' bytes', 'status-ok');
    log('Click "Verify" to check the proof on-chain.', 'status-info');
    return;
  }
  if (msg.action === 'verify') {
    log('Verification result: ' + (msg.ok ? 'ACCEPTED' : 'REJECTED'), msg.ok ? 'status-ok' : 'status-err');
    return;
  }
};

worker.postMessage({ action: 'init' });
