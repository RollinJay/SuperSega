'use strict';
// SC-3000 BASIC keyboard check: boot a BASIC cartridge, type characters through
// the SK-1100 matrix and confirm they reach the screen (name table changes and
// the typed codes appear in VRAM). Also boots the SF-7000 IPL and checks that
// it polls the floppy controller.
// usage: sc_typing.js page.html romdir [outdir]
//   romdir holds the ROM files named in `carts` below and the SF-7000 IPL as
//   "SF-7000 Initial Program Loader ROM.sc" (TOSEC names; not included).
const fs = require('fs');
const { loadEmu, newMachine } = require('./emuload');
const { fbToPng } = require('./fbpng');
const path = require('path');
const [,, html, romdir, outdir] = process.argv;
if (!html || !romdir) { console.error('usage: sc_typing.js page.html romdir [outdir]'); process.exit(2); }
const X = loadEmu(html, { quiet: true });
const R = romdir + path.sep;
const carts = [
  ['l3', 'Sega SC-3000 BASIC Level 3 v1.0 (1983)(Mitec).bin', 32],
  ['l2', 'Sega SC-3000 BASIC Level 2 v1.0 (1983)(Mitec)(JP)(en-ja).bin', 16],
  ['home', 'Sega Home BASIC v1.0j (1985)(Sega)(JP).bin', 32],
];
let fails = 0;
for (const [k, f, ram] of carts) {
  const m = newMachine(X, 'sc', fs.readFileSync(R + f)); m.scRam = ram;
  for (let i = 0; i < 900; i++) m.runFrame();
  const before = m.vdp.vram.slice(0, 0x4000);
  for (const key of ['1', '2', '3', 'a']) {
    m.kb.set(key, true); for (let i = 0; i < 6; i++) m.runFrame();
    m.kb.set(key, false); for (let i = 0; i < 10; i++) m.runFrame();
  }
  const after = m.vdp.vram;
  let changed = 0; for (let i = 0; i < 0x4000; i++) if (before[i] !== after[i]) changed++;
  // look for the typed characters as consecutive ASCII codes anywhere in VRAM
  let found = -1;
  for (let i = 0; i < 0x4000 - 3; i++)
    if (after[i] === 0x31 && after[i + 1] === 0x32 && after[i + 2] === 0x33) { found = i; break; }
  if (outdir) fbToPng(`${outdir}/sc_${k}_typed.png`, m.vdp.fb, 256, 192, 1);
  const ok = changed > 0 && found >= 0;
  if (!ok) fails++;
  console.log(`${ok ? 'PASS' : 'FAIL'} ${k.padEnd(5)} VRAM bytes changed ${changed}, "123" at ${found >= 0 ? '$' + found.toString(16) : 'not found'}`);
}
// SF-7000 IPL: boots and polls the floppy controller
{
  const m = newMachine(X, 'sf', null);
  m.sf.loadIPL(new Uint8Array(fs.readFileSync(R + 'SF-7000 Initial Program Loader ROM.sc')));
  for (let i = 0; i < 300; i++) m.runFrame();
  if (outdir) fbToPng(`${outdir}/sf_ipl.png`, m.vdp.fb, 256, 192, 1);
  let lit = 0; for (let i = 0; i < 256 * 192; i++) if ((m.vdp.fb[i] & 0xFFFFFF) !== (m.vdp.fb[0] & 0xFFFFFF)) lit++;
  const ok = m.sf.fdcReads > 0;
  if (!ok) fails++;
  console.log(`${ok ? 'PASS' : 'FAIL'} sf-7000 IPL PC $${m.cpu.PC.toString(16)}, FDC reads ${m.sf.fdcReads}, ROM maps ${m.sf.romMaps}, RAM maps ${m.sf.ramMaps}, non-background pixels ${lit}`);
}
process.exit(fails ? 1 : 0);
