'use strict';
// Compare the JS emulator against Gearsystem (independent oracle) at the same frames.
// usage: cmp_gs.js page.html rom mode gsPrefix frames...
const fs = require('fs');
const { loadEmu, newMachine } = require('./emuload');
const { writePng } = require('./fbpng');
const [,, html, rom, mode, gsPre, ...fr] = process.argv;
const frames = fr.map(Number);
const X = loadEmu(html, { quiet: true });
const m = newMachine(X, mode, fs.readFileSync(rom));
if (process.env.PAL === '1') m.pal = true;
function readPpm(p) {
  const b = fs.readFileSync(p); let i = 0, tok = [];
  while (tok.length < 4) { let s = ''; while (b[i] <= 32) i++; while (b[i] > 32) s += String.fromCharCode(b[i++]); tok.push(s); }
  i++;
  return { w: +tok[1], h: +tok[2], d: b.subarray(i) };
}
let f = 0; const out = [];
// Gearsystem's RunToVBlank returns when the frame interrupt is raised, before the
// handler runs. Capture the JS work RAM at the same point: right after line 192.
let vbRam = null; const origScan = m.vdp.scanline.bind(m.vdp);
m.vdp.scanline = function () { const r = origScan(); if (m.vdp.line === 193) vbRam = m.wram.slice(0, 0x2000); return r; };
for (const target of frames) {
  while (f < target) {
    const phase = f % 120;
    m.btn.start = (mode === 'gg' && phase >= 60 && phase < 66) ? 1 : 0;
    m.btn.a = (phase >= 90 && phase < 96) ? 1 : 0;
    m.runFrame(); f++;
  }
  const g = readPpm(`${gsPre}_${target}.ppm`);
  // GG: Gearsystem gives 160x144; the JS frame is 256x192 with the GG window at (48,24)
  const ox = (mode === 'gg') ? 48 : 0, oy = (mode === 'gg') ? 24 : 0;
  let diff = 0, n = 0;
  for (let y = 0; y < g.h; y++) for (let x = 0; x < g.w; x++) {
    const v = m.vdp.fb[(y + oy) * 256 + x + ox] >>> 0;
    const r = v & 255, gg = (v >> 8) & 255, bb = (v >> 16) & 255;
    const o = (y * g.w + x) * 3;
    if (Math.abs(r - g.d[o]) > 8 || Math.abs(gg - g.d[o + 1]) > 8 || Math.abs(bb - g.d[o + 2]) > 8) diff++;
    n++;
  }
  const ram = fs.readFileSync(`${gsPre}_${target}.ram`);
  // JS frame `target` (1-based) ends at line 0; its VBlank capture is that frame's.
  let rd = 0; const diffs = [];
  for (let a = 0; a < 0x2000; a++) if (ram[a] !== vbRam[a]) { rd++; if (diffs.length < 12) diffs.push((0xC000 + a).toString(16) + ':' + vbRam[a].toString(16) + '/' + ram[a].toString(16)); }
  out.push({ frame: target, pixelsDiffer: diff, of: n, ramBytesDiffer: rd, firstDiffs: diffs.join(' ') });
  // side-by-side PNG: JS | GS
  writePng(`${gsPre}_cmp_${target}.png`, g.w * 2 + 8, g.h, (x, y) => {
    if (x < g.w) { const v = m.vdp.fb[(y + oy) * 256 + x + ox] >>> 0; return [v & 255, (v >> 8) & 255, (v >> 16) & 255]; }
    if (x < g.w + 8) return [255, 0, 255];
    const o = (y * g.w + (x - g.w - 8)) * 3; return [g.d[o], g.d[o + 1], g.d[o + 2]];
  }, 1);
}
console.log(JSON.stringify(out));
