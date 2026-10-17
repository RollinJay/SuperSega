'use strict';
/* The BIOS hands over as a direct start does. For each test ROM, the machine is
   powered on with Start held for two frames (the BIOS's skip path); once the BIOS
   has launched it, every frame (picture, CPU registers, $3E/$3F) and at the end
   work RAM, VRAM and CRAM must equal those of the same ROM started directly in the
   mode its header (or .sg extension) asks for, which is how the other tools start
   games. What the BIOS clears for the game (VRAM $0000-$3FFF, the 32 colours, work
   RAM bank 0) is filled with other values at power-on first, as memory an earlier
   game left, so its own clearing is what is checked. The BIOS must also pick that
   mode itself. Each ROM runs in NTSC and in PAL.
   usage: node bios_test.js ../masterdrive-emulator.html ../../pocket-core/roms [frames] */
const fs = require('fs');
const path = require('path');
const { loadEmu, newMachine } = require('./emuload');
const X = loadEmu(process.argv[2], { quiet: true });
const dir = process.argv[3], N = +(process.argv[4] || 150);
function wantMode(file, rom) {
  if (file.endsWith('.sg')) return 'sg';
  for (const o of [0x7FF0, 0x3FF0, 0x1FF0])
    if (rom.length > o + 15 && String.fromCharCode(...rom.subarray(o, o + 8)) === 'TMR SEGA')
      return { 3: 'sms', 4: 'sms', 5: 'gg', 6: 'gg', 7: 'gg', 8: 'ss' }[rom[o + 15] >> 4] || 'sms';
  return rom.length <= 0x10000 ? 'sg' : 'sms';
}
const state = m => { const c = m.cpu;
  return [c.PC, c.SP, c.AF, c.BC, c.DE, c.HL, c.IX, c.IY, ...c.S, c.I, c.Rr, c.IFF1, c.IM, m.memCtl, m.ioCtl].join(','); };
let bad = 0, n = 0;
for (const pal of [false, true]) for (const f of fs.readdirSync(dir).filter(f => /\.(sms|sg|gg)$/.test(f)).sort()) {
  const rom = fs.readFileSync(path.join(dir, f)), mode = wantMode(f, rom);
  const A = newMachine(X, mode, rom), B = newMachine(X, mode, rom);
  A.pal = pal; B.pal = pal;
  B.platformMode = 'auto'; B.powerOn();
  B.vdp.vram.fill(0x5A, 0, 0x4000); B.vdp.cram.fill(0x15, 0, 64); B.wram.fill(0xA5, 0, 0x2000);
  let k = 0;
  for (; k < 60 && !B.boot.launch; k++) { B.btn.start = k < 2 ? 1 : 0; B.runFrame(); }
  const why = [];
  if (!B.boot.launch) why.push('no launch in 60 frames');
  for (let i = 0; i < N && !why.length; i++) {
    const fa = A.runFrame(), fb = B.runFrame();
    if (i === 0 && B.mode !== mode) { why.push(`launched as ${B.mode}, want ${mode}`); break; }
    let d = 0; for (let j = 0; j < fa.length; j++) if (fa[j] !== fb[j]) d++;
    if (d) why.push(`frame ${i}: ${d} pixels differ`);
    else if (state(A) !== state(B)) why.push(`frame ${i}: CPU or ports differ\n    direct ${state(A)}\n    BIOS   ${state(B)}`);
  }
  if (!why.length) {
    let w = 0, v = 0, c = 0;
    for (let j = 0; j < A.wram.length; j++) if (A.wram[j] !== B.wram[j]) w++;
    for (let j = 0; j < A.vdp.vram.length; j++) if (A.vdp.vram[j] !== B.vdp.vram[j]) v++;
    for (let j = 0; j < A.vdp.cram.length; j++) if (A.vdp.cram[j] !== B.vdp.cram[j]) c++;
    if (w || v || c) why.push(`${w} work RAM, ${v} VRAM and ${c} CRAM bytes differ`);
  }
  n++; if (why.length) bad++;
  console.log((why.length ? 'FAIL ' : 'PASS ') + f.padEnd(16) + ` ${pal ? 'PAL ' : 'NTSC'} ${mode.padEnd(3)} launched after ${k} frames` + (why.length ? ': ' + why.join('; ') : `, ${N} frames as a direct start`));
}
console.log(bad ? `${bad} of ${n} runs differ` : `all ${n / 2} ROMs, NTSC and PAL: the BIOS hands over as a direct start`);
process.exitCode = bad ? 1 : 0;
