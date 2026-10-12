'use strict';
// JS emulator instruction trace in the same record format as pocket-core/sim/ref/gstrace.cpp.
const fs = require('fs');
const { loadEmu, newMachine } = require('./emuload');
const [,, html, rom, mode, n, out] = process.argv;
const X = loadEmu(html, { quiet: true });
const m = newMachine(X, mode, fs.readFileSync(rom));
if (process.env.PAL === '1') m.pal = true;
if (process.env.PHASE) m.lineCarry = -(+process.env.PHASE);
const N = +n; const buf = Buffer.alloc(N * 12); let k = 0;
const C = m.cpu; const origStep = C.step.bind(C); const origIrq = C.irq.bind(C);
let cyc = 0;
function rec() {
  if (k >= N) return;
  const o = k * 12;
  buf.writeUInt16LE(C.PC, o); buf.writeUInt16LE(C.SP, o + 2); buf[o + 4] = C.R[7]; buf[o + 5] = C.R[6];
  buf.writeUInt32LE(cyc >>> 0, o + 6); buf.writeUInt16LE(m.vCounter(), o + 10); k++;
}
C.step = function () { rec(); const c = origStep(); cyc += c; return c; };
C.irq = function () { const c = origIrq(); cyc += c; return c; };
while (k < N) m.runFrame();
fs.writeFileSync(out, buf.subarray(0, N * 12));
console.log('traced', N);
