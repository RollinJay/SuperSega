'use strict';
// Run a ROM on the emulator's machine model and write frames as PPM, at the
// height the VDP is set to (192/224/240) or the 160x144 Game Gear window.
// Uses the same scripted input as the Gearsystem runner and the RTL harness.
// usage: js_dump.js page.html rom mode outprefix frames...   (PAL=1 for 50 Hz;
//        AEL=sprlimit,ovf,stereo,autofire,vramboost,turbo=2 switches enhancement-layer boosts on)
const fs = require('fs');
const { loadEmu, newMachine } = require('./emuload');
const [,, html, rom, mode, pre, ...fr] = process.argv;
const frames = fr.map(Number);
const X = loadEmu(html, { quiet: true });
const m = newMachine(X, mode, fs.readFileSync(rom));
if (process.env.PAL === '1') m.pal = true;
for (const kv of (process.env.AEL || '').split(',').filter(Boolean)) {
  const [k, v] = kv.split('='); m.ael[k] = v === undefined ? true : parseFloat(v);
}
if (m.ael.stereo) m.psg.pstereo = m.mode !== 'ss';
let f = 0;
for (const target of frames) {
  while (f < target) {
    const phase = f % 120;
    m.btn.start = (mode === 'gg' && phase >= 60 && phase < 66) ? 1 : 0;
    m.btn.a = (phase >= 90 && phase < 96) ? 1 : 0;
    m.runFrame(); f++;
  }
  const gg = mode === 'gg';
  const w = gg ? 160 : 256, h = gg ? 144 : m.vdp.height();
  const ox = gg ? 48 : 0, oy = gg ? 24 : 0;
  const buf = Buffer.alloc(w * h * 3);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const v = m.vdp.fb[(y + oy) * 256 + x + ox] >>> 0;
    const o = (y * w + x) * 3;
    buf[o] = v & 255; buf[o + 1] = (v >> 8) & 255; buf[o + 2] = (v >> 16) & 255;
  }
  fs.writeFileSync(`${pre}_${target}.ppm`, Buffer.concat([Buffer.from(`P6\n${w} ${h}\n255\n`), buf]));
}
console.log('frames', f);
