'use strict';
// Render frames of a ROM to PNG for visual regression checks.
const fs = require('fs');
const { loadEmu, newMachine } = require('./emuload');
const { fbToPng } = require('./fbpng');
const [,, html, rom, mode, outPrefix, ...frames] = process.argv;
const X = loadEmu(html, { quiet: true });
const m = newMachine(X, mode, fs.readFileSync(rom));
const want = frames.map(Number).sort((a, b) => a - b);
let f = 0;
// optional scripted input: press Start (and button 1) periodically to get past titles
for (const target of want) {
  while (f < target) {
    const phase = f % 120;
    m.btn.start = (phase >= 60 && phase < 66) ? 1 : 0;
    m.btn.a = (phase >= 90 && phase < 96) ? 1 : 0;
    if (mode === 'sms' && m.btn.start && phase === 60) m.cpu.nmi && 0;
    m.runFrame(); f++;
  }
  fbToPng(`${outPrefix}_${target}.png`, m.vdp.fb, 256, 192, 2);
}
console.log('PC', m.cpu.PC.toString(16), 'frames', f);
