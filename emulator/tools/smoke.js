'use strict';
// Smoke test: load the emulator headless, run a ROM, print a frame hash.
const fs = require('fs');
const crypto = require('crypto');
const { loadEmu, newMachine } = require('./emuload');
const [,, html, rom, mode, frames] = process.argv;
const X = loadEmu(html, { quiet: true });
const m = newMachine(X, mode || 'sms', fs.readFileSync(rom));
const n = +(frames || 300);
const t0 = Date.now();
for (let i = 0; i < n; i++) m.runFrame();
const fb = Buffer.from(m.vdp.fb.buffer.slice(0));
const h = crypto.createHash('sha1').update(fb).digest('hex').slice(0, 12);
const vh = crypto.createHash('sha1').update(Buffer.from(m.vdp.vram)).digest('hex').slice(0, 12);
console.log(JSON.stringify({ frames: n, ms: Date.now() - t0, fb: h, vram: vh,
  PC: m.cpu.PC.toString(16), regs: Array.from(m.vdp.reg.slice(0, 11)).map(v => v.toString(16)).join(' '),
  line: m.vdp.line }));
