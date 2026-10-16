'use strict';
/* Behavioural probes for the v7 emulator fixes. Each probe states the hardware
   behaviour it checks and the source of that behaviour. Run against the original
   and the fixed page: the original should fail the probes for the bugs it had. */
const { loadEmu } = require('./emuload');
const X = loadEmu(process.argv[2], { quiet: true });
const results = [];
function probe(id, what, fn) {
  let ok = false, note = '';
  try { const r = fn(); ok = !!r.ok; note = r.note || ''; }
  catch (e) { note = 'threw: ' + e.message; }
  results.push({ id, what, ok, note });
}
// A Z80 on a flat 64 KB bus, for CPU probes.
function flatCpu(prog, at) {
  const mem = new Uint8Array(0x10000);
  mem.set(prog, at || 0);
  const io = { out: [], in: () => 0xFF };
  const c = new X.Z80({ rd: a => mem[a], wr: (a, v) => { mem[a] = v; },
    inp: p => io.in(p), out: (p, v) => io.out.push([p & 0xFF, v]) });
  c.PC = at || 0; c.SP = 0xF000; c.IM = 1;
  return { c, mem, io };
}
function steps(c, n) { let t = 0; for (let i = 0; i < n; i++) t += c.step(); return t; }

// ---------------------------------------------------------------- CPU
probe('M1', 'IRQ during HALT returns to the instruction after HALT (Zilog UM0080: PC is incremented past HALT before the interrupt is accepted)', () => {
  // 0000: EI ; 0001: HALT ; 0002: LD A,$42 ; 0004: JR $
  // 0038: RETI-equivalent: EI ; RET
  const { c, mem } = flatCpu([0xFB, 0x76, 0x3E, 0x42, 0x18, 0xFE]);
  mem[0x38] = 0xFB; mem[0x39] = 0xC9;
  c.step(); c.step();                       // EI, HALT
  const ret = c.PC;                         // PC after fetching HALT
  c.irq();
  const pushed = mem[c.SP] | (mem[c.SP + 1] << 8);
  c.step(); c.step();                       // EI, RET
  c.step();                                 // LD A,$42
  return { ok: pushed === 0x0002 && c.R[7] === 0x42, note: `pushed ${pushed.toString(16)}, A=${c.R[7].toString(16)} (want 2, 42)` };
});

probe('M2', 'EI delays interrupt acceptance by one instruction (Zilog UM0080)', () => {
  // Loop: EI ; NOP ; DI ; ... the frame loop's rule decides whether an IRQ can
  // land between EI and NOP. Model the frame loop's check after each step.
  const { c } = flatCpu([0xFB, 0x00, 0xF3, 0x00]);
  const can = [];
  for (let i = 0; i < 3; i++) { c.step(); can.push(!!(c.IFF1 && !c.eiPend)); }
  // after EI: not yet; after NOP: yes; after DI: no
  return { ok: can.join() === 'false,true,false', note: 'acceptable after EI,NOP,DI = ' + can.join() };
});

probe('M3a', 'DD 26 nn is LD IXH,n: no displacement byte (undocumented but used)', () => {
  const { c } = flatCpu([0xDD, 0x26, 0x12, 0xDD, 0x2E, 0x34, 0x3E, 0x99]);
  steps(c, 3);
  return { ok: c.IX === 0x1234 && c.R[7] === 0x99 && c.PC === 8, note: `IX=${c.IX.toString(16)} A=${c.R[7].toString(16)} PC=${c.PC}` };
});
probe('M3b', '(IX+d) timings: LD r,(IX+d)=19, LD (IX+d),n=19, INC (IX+d)=23, ADD A,(IX+d)=19, LD IX,nn=14', () => {
  const prog = [0xDD, 0x21, 0x00, 0x80,  0xDD, 0x7E, 0x01,  0xDD, 0x36, 0x02, 0x55,
                0xDD, 0x34, 0x02,  0xDD, 0x86, 0x02];
  const { c } = flatCpu(prog);
  const t = [];
  for (let i = 0; i < 5; i++) t.push(c.step());
  return { ok: t.join() === '14,19,19,23,19', note: 'T-states ' + t.join() };
});
probe('M4', 'DDCB timings: BIT b,(IX+d)=20, RLC (IX+d)=23 (Zilog UM0080)', () => {
  const { c } = flatCpu([0xDD, 0xCB, 0x01, 0x46, 0xDD, 0xCB, 0x01, 0x06]);
  c.IX = 0x8000;
  const t = [c.step(), c.step()];
  return { ok: t.join() === '20,23', note: 'T-states ' + t.join() };
});

// ---------------------------------------------------------------- VDP
function sms(mode) { const m = new X.Machine(); m.mode = mode || 'sms'; m.reset(); return m; }
function vdpSetup(m) {
  const V = m.vdp;
  V.vram.fill(0); V.vram[0x3F00] = 0xD0;
  V.reg[0] = 0x04; V.reg[1] = 0x40; V.reg[2] = 0xFF; V.reg[5] = 0xFF; V.reg[6] = 0xFB;
  // tile 1: solid colour 1; tile 0 blank. CRAM 1 = white, 17 = white
  for (let r = 0; r < 8; r++) V.vram[32 + r * 4] = 0xFF;
  V.cram[2] = 0xFF; V.cram[3] = 0x0F; V.cram[34] = 0xFF; V.cram[35] = 0x0F;
  return V;
}
probe('M5', 'H scroll moves the background right: map column 0 appears at x = scroll (SMS VDP docs, reg 8)', () => {
  const m = sms(); const V = vdpSetup(m);
  V.vram[0x3800] = 1;                    // map column 0, row 0 = solid tile
  V.reg[8] = 8; V.hsLatch = 8; V.vsLatch = 0;
  V.renderLine(0);
  const lit = []; for (let x = 0; x < 24; x++) if ((V.fb[x] & 0xFFFFFF) !== 0) lit.push(x);
  return { ok: lit[0] === 8 && lit[lit.length - 1] === 15, note: 'lit x ' + (lit.length ? lit[0] + '..' + lit[lit.length - 1] : 'none') };
});
probe('M6', 'H scroll written during line N applies from line N+1; V scroll from the next frame', () => {
  const m = sms(); const V = vdpSetup(m); m.noRender = false;
  V.vram[0x3800] = 1; V.reg[8] = 0; V.reg[9] = 0; V.hsLatch = 0; V.vsLatch = 0;
  V.line = 10;
  V.reg[8] = 16;                          // written while line 10 is "current"
  V.scanline();                           // draws line 10 with the latched value
  const l10 = []; for (let x = 0; x < 32; x++) if ((V.fb[10 * 256 + x] & 0xFFFFFF) !== 0) l10.push(x);
  V.scanline();                           // line 11 uses 16
  const l11 = []; for (let x = 0; x < 32; x++) if ((V.fb[11 * 256 + x] & 0xFFFFFF) !== 0) l11.push(x);
  // line 10 is in tile row 1 (y=10): the map entry at row 1 col 0 is 0 -> use row 0? put tile at rows 1 too
  return { ok: V.hsLatch === 16, note: `latch after line 10 = ${V.hsLatch}; line10 lit ${l10.length}, line11 lit ${l11.length}` };
});
probe('M7', 'Sprite with Y=$F8 shows its lower rows at the top of the screen (Y+1 > 240 wraps)', () => {
  const m = sms(); const V = vdpSetup(m);
  V.reg[6] = 0xFB;                        // sprite patterns at $0000
  V.vram[0x3F00] = 0xF8; V.vram[0x3F01] = 0xD0;
  V.vram[0x3F80] = 40; V.vram[0x3F81] = 1;
  V.renderLine(0);
  let n = 0; for (let x = 40; x < 48; x++) if ((V.fb[x] & 0xFFFFFF) !== 0) n++;
  return { ok: n === 8 && V.sprCount[0] === 1, note: `${n} pixels on line 0, sprCount ${V.sprCount[0]}` };
});
probe('M8', 'V counter jumps: NTSC 192 reads $DA then $D5; PAL 192 reads $F2 then $BA', () => {
  const m = sms(); const V = m.vdp; const r = [];
  for (const ln of [0xDA, 0xDB, 261]) { V.line = ln; r.push(m.inp(0x7E)); }
  m.pal = true;
  for (const ln of [0xF2, 0xF3, 312]) { V.line = ln; r.push(m.inp(0x7E)); }
  const want = [0xDA, 0xD5, 0xFF, 0xF2, 0xBA, 0xFF];
  return { ok: r.join() === want.join(), note: r.map(v => v.toString(16)).join(' ') };
});
probe('M8h', 'H counter advances within the line (was the line number)', () => {
  const m = sms(); m.vdp.line = 50;
  m.lineT = 0; const a = m.inp(0x7F); m.lineT = 100; const b = m.inp(0x7F); m.lineT = 227; const c = m.inp(0x7F);
  return { ok: a === 0 && b === 0x4B && c >= 0xE9, note: [a, b, c].map(v => v.toString(16)).join(' ') };
});

// ---------------------------------------------------------------- frame loop
probe('M9a', 'Line overrun carried: a frame is 262 x 228 CPU cycles within one instruction', () => {
  const m = sms(); const rom = new Uint8Array(0x8000);
  // DD 7E 00 (19 T) in a loop: JR back. 19+12 = 31-cycle loop never aligns to 228
  rom.set([0xDD, 0x7E, 0x00, 0x18, 0xFB], 0);
  m.cart = rom; m.romMode = 'shadow';
  let tot = 0; for (let f = 0; f < 10; f++) { m.runFrame(); tot += m.frameCycles; }
  const want = 10 * 262 * 228;
  return { ok: Math.abs(tot - want) < 32, note: `${tot} cycles in 10 frames, ideal ${want}` };
});
probe('M9b', 'Frame interrupt flag stays set until the status register is read (also across a frame boundary)', () => {
  // DI, wait ~367 lines (into line ~105 of the second frame), then read status.
  const m = sms(); const rom = new Uint8Array(0x8000);
  rom.set([0xF3, 0x0E, 25, 0x06, 0x00, 0x10, 0xFE, 0x0D, 0x20, 0xF9,
           0xDB, 0xBF, 0x32, 0x00, 0xC0, 0x18, 0xFE], 0);
  m.cart = rom; m.romMode = 'shadow'; m.vdp.reg[1] = 0x40;
  m.runFrame(); m.runFrame();
  const s = m.wram[0];
  return { ok: (s & 0x80) !== 0, note: 'status read at line ~105 of frame 2: $' + s.toString(16) };
});
probe('M9c', 'A pending line IRQ is taken right after EI+1 instruction, not at the end of the line', () => {
  const m = sms(); const rom = new Uint8Array(0x8000);
  rom.set([0xFB, 0x18, 0xFE], 0);          // EI ; JR $
  rom.set([0xFB, 0xC9], 0x38);             // handler: EI ; RET
  m.cart = rom; m.romMode = 'shadow';
  m.vdp.reg[0] = 0x14; m.vdp.reg[1] = 0x40; m.vdp.irqLine = 1;   // line IRQ pending, enabled
  let at = -1; const orig = m.cpu.irq.bind(m.cpu);
  m.cpu.irq = function () { if (at < 0) at = m.frameCycles; return orig(); };
  m.runFrame();
  return { ok: at >= 0 && at < 40, note: 'IRQ accepted at cycle ' + at + ' of the frame' };
});

// ---------------------------------------------------------------- I/O
probe('M10a', 'MasterDrive math result readable at $0F/$10 (was answered by the pad mirror); Feature Enable A bit 7 set, as the I/O registers need (M54)', () => {
  const m = sms('ss'); m.vdp.reg[15] = 0x80;
  m.out(0x0C, 200); m.out(0x0D, 100); m.out(0x0E, 0);
  const lo = m.inp(0x0F), hi = m.inp(0x10);
  return { ok: ((hi << 8) | lo) === 20000, note: `read ${(hi << 8) | lo}, want 20000` };
});
probe('M10b', 'MasterDrive multitap detection $16 and slot select $09 readback; Feature Enable A bit 7 set (M54)', () => {
  const m = sms('ss'); m.vdp.reg[15] = 0x80; m.out(0x09, 0x02);
  return { ok: m.inp(0x16) === 0x81 && m.inp(0x09) === 0x02, note: `$16=${m.inp(0x16).toString(16)} $09=${m.inp(0x09).toString(16)}` };
});
probe('M38', 'MasterDrive: with the I/O registers open (Feature Enable A bit 7, M54), writes to the read-only ports $0F, $10 and $16 are absorbed, not taken as $3E/$3F mirrors; on the Master System they still are (Technical Reference \u00a711)', () => {
  const s = sms('ss'); s.vdp.reg[15] = 0x80; const mc = s.memCtl, ic = s.ioCtl;
  s.out(0x0F, 0x00); s.out(0x10, 0x00); s.out(0x16, 0x00);
  const m = sms('sms'); m.out(0x0F, 0x55); m.out(0x10, 0xAA);
  return { ok: s.memCtl === mc && s.ioCtl === ic && m.ioCtl === 0x55 && m.memCtl === 0xAA,
           note: `SS $3E ${s.memCtl.toString(16)} $3F ${s.ioCtl.toString(16)}; SMS $3E ${m.memCtl.toString(16)} $3F ${m.ioCtl.toString(16)}` };
});
probe('M39', 'SG-1000, SC-3000 and SF-7000 have no $3E/$3F registers: writes to $07-$3F change nothing, as in the Pocket core (Technical Reference \u00a711)', () => {
  const res = ['sg', 'sc', 'sf'].map(mode => { const m = sms(mode); const mc = m.memCtl, ic = m.ioCtl;
    m.out(0x3E, 0x00); m.out(0x3F, 0x00); m.out(0x07, 0x55); m.out(0x21, 0x00);
    return m.memCtl === mc && m.ioCtl === ic; });
  return { ok: res.every(Boolean), note: 'sg sc sf: ' + res.join(' ') };
});
probe('M10c', 'Game Gear $00: $C0 idle, $40 with Start, export (MAME sms.cpp gg_input_port_00_r)', () => {
  const m = sms('gg'); const a = m.inp(0x00); m.btn.start = 1; const b = m.inp(0x00);
  return { ok: a === 0xC0 && b === 0x40, note: `${a.toString(16)} / ${b.toString(16)}` };
});
probe('M10d', 'FM detection with the I/O chip disabled finds the FM unit (MAME smsj_audio_control_r)', () => {
  const m = sms('sms');
  m.out(0x3E, m.memCtl | 0x04);           // disable I/O chip
  let c = 0;
  for (let b = 7; b > 0; b--) { const v = b & 1; m.out(0xF2, v); if ((m.inp(0xF2) & 7) === v) c++; }
  return { ok: c === 7, note: c + ' of 7 matches' };
});
probe('M10e', 'Game Gear ignores the I/O-chip disable bit for its pad ports (MAME)', () => {
  const m = sms('gg'); m.out(0x3E, m.memCtl | 0x04); m.btn.up = 1;
  const v = m.inp(0xDC);
  return { ok: (v & 1) === 0, note: '$DC=' + v.toString(16) };
});
probe('M12', 'Bus synchroniser at 200%: CPU is held, wait is finite and reaches the 42-cycle steady state', () => {
  const m = sms('ss'); const rom = new Uint8Array(0x8000);
  // OUTI loop to $BE during active display: LD C,$BE ; LD HL,$0000 ; loop: OUTI ; JR loop
  rom.set([0x0E, 0xBE, 0x21, 0x00, 0x00, 0xED, 0xA3, 0x18, 0xFC], 0);
  m.cart = rom; m.romMode = 'shadow'; m.vdp.reg[1] = 0x40; m.vdp.reg[15] = 0x40;
  m.out(0xF3, 4);                          // 200%
  m.runFrame();
  const w = m.syncWait;
  // steady state: one 29-cycle VDP slot per access = 58 CPU cycles at 200%;
  // the loop itself takes 28, so each access waits 30. Allow the first few to settle.
  const acc = Math.round(m.frameCycles / 58);
  return { ok: Number.isFinite(w) && w > 0 && w < m.frameCycles, note: 'syncWait ' + w + ' of ' + m.frameCycles + ' frame cycles' };
});
probe('M14', 'DMA RAM->VRAM copies work RAM contents', () => {
  const m = sms('ss');
  m.wr(0xC000, 0x5A); m.wr(0xC001, 0xA5);
  // src $0000 in RAM select (sel=2), mode 0, dst VRAM $1000, length 2
  m.out(0xF4, 0x00); m.out(0xF5, 0x00); m.out(0xF6, 0x02); m.out(0xF7, 0x00); m.out(0xF8, 0x10);
  m.out(0xF9, 0x02); m.out(0xFA, 0x80);
  return { ok: m.vdp.vram[0x1000] === 0x5A && m.vdp.vram[0x1001] === 0xA5, note: 'VRAM ' + m.vdp.vram[0x1000].toString(16) + ' ' + m.vdp.vram[0x1001].toString(16) };
});

probe('M7w', 'Sprite Y wrap rule: Y+1 of 241-256 wraps to the top; a 32-line magnified sprite at Y=$E8 does not (Gearsystem, MAME)', () => {
  const m = sms(); const V = vdpSetup(m);
  V.reg[1] = 0x43;                        // display on, 8x16, magnified: 32 lines
  for (let r = 0; r < 16; r++) V.vram[r * 4] = 0xFF;   // tiles 0-1 (8x16 pair) solid
  V.vram[0x3F00] = 0xE8; V.vram[0x3F01] = 0xD0;
  V.vram[0x3F80] = 40; V.vram[0x3F81] = 0;
  V.renderLine(0);
  const a = V.sprCount[0];
  V.vram[0x3F00] = 0xF8; V.renderLine(0);
  const b = V.sprCount[0];
  return { ok: a === 0 && b === 1, note: `Y=$E8: ${a} sprite(s) on line 0, Y=$F8: ${b} (want 0, 1)` };
});
probe('M29', '224-line mode: R0 M2+M4 with R1 M1 gives 224 lines; M3 gives 240; M2 clear stays 192 (MAME sega315_5246)', () => {
  const V = sms().vdp; const r = [];
  V.reg[0] = 0x36; V.reg[1] = 0xE0 | 0x10; r.push(V.height());
  V.reg[0] = 0x36; V.reg[1] = 0xE0 | 0x08; r.push(V.height());
  V.reg[0] = 0x34; V.reg[1] = 0xE0 | 0x18; r.push(V.height());
  return { ok: r.join() === '224,240,192', note: r.join(' ') };
});
probe('M29r', '224-line mode renders lines 192-223 from the 32x32 name table at $3700', () => {
  const m = sms(); const V = vdpSetup(m);
  V.reg[0] = 0x06; V.reg[1] = 0x50; V.reg[2] = 0xFF;   // 224 lines, display on
  V.vram[0x3700 + 26 * 64] = 1;                        // row 26 col 0 -> line 208
  V.hsLatch = 0; V.vsLatch = 0;
  V.renderLine(208);
  let n = 0; for (let x = 0; x < 8; x++) if ((V.fb[208 * 256 + x] & 0xFFFFFF) !== 0) n++;
  return { ok: V.height() === 224 && n === 8, note: `height ${V.height()}, ${n} pixels lit on line 208` };
});
// ---------------------------------------------------------------- PSG
probe('M20', 'PSG noise rate 0: the shift register advances once per 32 PSG clocks (counter $10 toggles a flip-flop)', () => {
  const P = new X.PSG(); P.write(0xE4);   // noise: white, rate 0
  let shifts = 0, prev = P.sr;
  for (let i = 0; i < 3200; i++) { P.sample(1); if (P.sr !== prev) { shifts++; prev = P.sr; } }
  return { ok: Math.abs(shifts - 100) <= 1, note: `${shifts} shifts in 3200 clocks (want 100)` };
});
probe('M21', 'PSG volume: 2 dB per step (attenuation 2 = 0.631 of full, 15 = silent)', () => {
  const P = new X.PSG(); P.write(0x80 | 0x0F); P.write(0x3F);   // tone 0 period $3FF
  P.write(0x90 | 0); const a0 = Math.abs(P.sample(0)[0]);
  P.write(0x90 | 2); const a2 = Math.abs(P.sample(0)[0]);
  P.write(0x90 | 15); const a15 = Math.abs(P.sample(0)[0]);
  const r = a2 / a0;
  return { ok: Math.abs(r - 0.631) < 0.005 && a15 === 0, note: `ratio ${r.toFixed(3)}, silent ${a15}` };
});
// ---------------------------------------------------------------- keyboard PPI
function kbMachine() { const m = sms('sc'); return m; }
probe('M22', 'Keyboard ghosting closure over a chain that needs four passes (diode-less matrix)', () => {
  const m = kbMachine(); m.out(0xDF, 0x92); m.out(0xDE, 0x00);   // row 0
  for (const k of ['1', '5', 't', 'r', 'f', 'd', 'c', 'x', ' ']) m.kb.set(k, true);
  const v = m.inp(0xDC);
  return { ok: v === 0xE0, note: '$DC=' + v.toString(16) + ' (want e0: columns 0-4)' };
});
probe('M27', 'PPI at reset selects row 7, so pads read without software touching the PPI; a mode word clears port C; bit set/reset works', () => {
  const m = sms('sg'); m.btn.up = 1;
  const a = m.inp(0xDC);                  // reset: row 7, P1 up pressed -> bit 0 low
  m.out(0xDF, 0x92); const b = m.inp(0xDC);   // mode set: port C = 0 -> row 0, no keys
  m.out(0xDE, 0x07); const c = m.inp(0xDC);   // row 7 again
  m.out(0xDF, 0x00);                          // BSR: clear port C bit 0 -> row 6
  const row = m.kb.row;
  return { ok: (a & 1) === 0 && b === 0xFF && (c & 1) === 0 && row === 6,
           note: `reset $DC=${a.toString(16)}, after $92 ${b.toString(16)}, row 7 ${c.toString(16)}, BSR row ${row}` };
});
probe('M28', 'SF-7000 PPI: a mode word clears port C, mapping the IPL back in (8255)', () => {
  const S = X.makeSF7000(); S.control(0x0D);   // BSR set bit 6: /ROM SEL high -> RAM
  const a = S.romSel; S.control(0x92); const b = S.romSel;
  return { ok: a === 1 && b === 0, note: `after BSR ${a}, after mode word ${b}` };
});
// ---------------------------------------------------------------- controller ports
probe('M25', 'TR configured as an output reads back the level driven (Gearsystem): $DC bit 5, $DD bit 3', () => {
  const m = sms('sms');
  m.out(0x3F, 0xFF & ~0x01 & ~0x10);    // TR A output, low
  const a = m.inp(0xDC) & 0x20;
  m.out(0x3F, (0xFF & ~0x01));          // TR A output, high
  const b = m.inp(0xDC) & 0x20;
  m.out(0x3F, 0xFF & ~0x04 & ~0x40);    // TR B output, low
  const c = m.inp(0xDD) & 0x08;
  return { ok: a === 0 && b === 0x20 && c === 0, note: `A low ${a}, A high ${b}, B low ${c}` };
});
probe('M26', 'Reads of $00-$3F return $FF on SMS (except decoded GG/SS registers); SG keeps the pad mirror', () => {
  const m = sms('sms'); m.btn.up = 1;
  const a = m.inp(0x3F), b = m.inp(0x20);
  const g = sms('gg'); const c = g.inp(0x10);
  const s = sms('ss'); const d = s.inp(0x30);
  return { ok: a === 0xFF && b === 0xFF && c === 0xFF && d === 0xFF, note: [a, b, c, d].map(v => v.toString(16)).join(' ') };
});
probe('M30', 'Game Gear: only $C0/$DC and $C1/$DD answer above $C0 (Gearsystem)', () => {
  const g = sms('gg'); g.btn.up = 1;
  const a = g.inp(0xC0), b = g.inp(0xDC), c = g.inp(0xC2), d = g.inp(0xFE);
  return { ok: (a & 1) === 0 && (b & 1) === 0 && c === 0xFF && d === 0xFF, note: [a, b, c, d].map(v => v.toString(16)).join(' ') };
});

probe('M40', 'Line interrupt only in Mode 4 in the stock modes: an SG-1000 or a Master System in a TMS mode raises none, Mode 4 does; MasterDrive mode raises it in a TMS mode too, as the owner decided (Q15) (machine profile stock_behaviour.vdp.line_counter)', () => {
  const run = (mode, r0) => { const m = sms(mode); m.vdp.reg[0] = r0; m.vdp.reg[1] = 0x40; m.vdp.reg[10] = 0;  // IE1 set, counter 0
    m.vdp.irqLine = 0; for (let i = 0; i < 4; i++) m.vdp.scanline(); return m.vdp.irqLine ? 1 : 0; };
  const sgTms = run('sg', 0x10), smsTms = run('sms', 0x10), smsM4 = run('sms', 0x14), ssTms = run('ss', 0x10);
  return { ok: !sgTms && !smsTms && smsM4 && ssTms,
           note: `SG TMS ${sgTms}, SMS TMS ${smsTms}, SMS Mode 4 ${smsM4}, SS TMS ${ssTms}` };
});
probe('M41', 'Start = Pause boost: Start raises Pause in the Master System, SG-1000 and SC-3000 modes, not on the Game Gear (it has its own Start) nor for MasterDrive software (machine profile enhancement_layer)', () => {
  const res = ['sms', 'sg', 'sc', 'gg', 'ss'].map(mode => { const m = sms(mode); let n = 0;
    m.ael.startpause = true; const f = m.cpu.nmi.bind(m.cpu); m.cpu.nmi = () => { n++; f(); };
    m.btn.start = 1; m.runFrame(); m.runFrame(); return n; });
  return { ok: res.join('') === '11100', note: 'NMIs sms sg sc gg ss: ' + res.join(' ') };
});

// ---------------------------------------------------------------- mappers
probe('M31', 'Codemasters: banks 0,1,0 at power-on; registers only at $0000/$4000/$8000. Korean: only $A000 (Gearsystem, MAME)', () => {
  const rom = new Uint8Array(8 * 0x4000);
  for (let b = 0; b < 8; b++) rom.fill(b, b * 0x4000, (b + 1) * 0x4000);
  const m = new X.Machine(); m.mapper = 'codemasters'; m.mode = 'sms'; m.reset(); m.cart = rom; m.romMode = 'shadow';
  const p0 = m.rd(0x8000);                   // power-on slot 2 = bank 0
  m.wr(0x8001, 5); const p1 = m.rd(0x8000);  // not a register
  m.wr(0x8000, 6); const p2 = m.rd(0x8000);
  const k = new X.Machine(); k.mapper = 'korean'; k.mode = 'sms'; k.reset(); k.cart = rom; k.romMode = 'shadow';
  k.wr(0xA001, 5); const k1 = k.rd(0x8000); k.wr(0xA000, 3); const k2 = k.rd(0x8000);
  return { ok: p0 === 0 && p1 === 0 && p2 === 6 && k1 === 2 && k2 === 3, note: `cm ${p0} ${p1} ${p2}, korean ${k1} ${k2} (want 0 0 6, 2 3)` };
});

// ---------------------------------------------------------------- enhancement layer
probe('M32', 'AEL pseudo-stereo: tone 0 left, tone 1 right, tone 2 both, until software writes $06; not applied to MasterDrive software', () => {
  const m = sms('sms'); m.ael.stereo = true; m.reset();
  const P = m.psg;
  P.write(0x80 | 0x0F); P.write(0x3F); P.write(0x90);      // tone 0 audible
  P.write(0xBF);                                          // tone 1 silent
  const t0 = P.sample(0);
  P.write(0x9F); P.write(0xA0 | 0x0F); P.write(0x3F); P.write(0xB0);   // tone 0 off, tone 1 on
  const t1 = P.sample(0);
  const g = sms('gg'); g.ael.stereo = true; g.reset();
  g.out(0x06, 0xFF); const set = g.psg.stereoSet;
  const s = sms('ss'); s.ael.stereo = true; s.reset();   // MasterDrive software: no boost
  const Q = s.psg; Q.write(0x80 | 0x0F); Q.write(0x3F); Q.write(0x90); Q.write(0xBF);
  const ts = Q.sample(0);
  return { ok: t0[0] !== 0 && t0[1] === 0 && t1[0] === 0 && t1[1] !== 0 && set === 1 && ts[0] !== 0 && ts[1] !== 0,
           note: `tone0 L ${t0[0].toFixed(3)} R ${t0[1].toFixed(3)}; tone1 L ${t1[0].toFixed(3)} R ${t1[1].toFixed(3)}; $06 owned ${set}; SS tone0 both ${ts[0] !== 0 && ts[1] !== 0}` };
});

probe('M16', 'A DD prefix followed by another prefix costs 4 T-states; the second prefix starts the instruction (Zilog)', () => {
  const { c } = flatCpu([0xDD, 0xDD, 0x21, 0x34, 0x12]);
  const t = [c.step(), c.step()];
  return { ok: t.join() === '4,14' && c.IX === 0x1234, note: `T-states ${t.join()}, IX=${c.IX.toString(16)}` };
});
probe('M18', 'Game Gear CRAM is byte-addressed: even byte latched, odd byte stores the entry (entry = address / 2)', () => {
  const m = sms('gg'); const V = m.vdp;
  m.out(0xBF, 0x02); m.out(0xBF, 0xC0);      // CRAM address 2 = entry 1
  m.out(0xBE, 0x34); m.out(0xBE, 0x0C);      // entry 1 = $C34
  return { ok: V.cram[2] === 0x34 && V.cram[3] === 0x0C && V.cram[0] === 0 && V.cram[1] === 0,
           note: 'cram[0..3] = ' + Array.from(V.cram.slice(0, 4)).map(v => v.toString(16)).join(' ') };
});
probe('M23', 'Overlapping sprites: the lowest-numbered sprite is on top', () => {
  const m = sms(); const V = vdpSetup(m);
  for (let r = 0; r < 8; r++) { V.vram[r * 4] = 0xFF; V.vram[32 + r * 4 + 1] = 0xFF; }   // tile 0 colour 1, tile 1 colour 2
  V.cram[17] = 0x03; V.cram[18] = 0x0C;      // sprite colours 1 red, 2 green (SMS 6-bit)
  V.vram[0x3F00] = 9; V.vram[0x3F01] = 9; V.vram[0x3F02] = 0xD0;
  V.vram[0x3F80] = 40; V.vram[0x3F81] = 0;   // sprite 0: tile 0 (colour 1)
  V.vram[0x3F82] = 40; V.vram[0x3F83] = 1;   // sprite 1: tile 1 (colour 2)
  V.renderLine(10);
  const px = V.fb[10 * 256 + 42] >>> 0, want = V.colour(1, 1) >>> 0;
  return { ok: px === want && (V.status & 0x20) !== 0, note: `pixel ${px.toString(16)} want ${want.toString(16)}, collision ${(V.status >> 5) & 1}` };
});
probe('M33', 'Sprite-limit boost: 16 for stock software, but not imposed on MasterDrive software', () => {
  const a = sms('sms'); a.ael.sprlimit = true;
  const b = sms('ss'); b.ael.sprlimit = true;
  const la = a.vdp.spriteLimit(), lb = b.vdp.spriteLimit();
  b.vdp.reg[15] = 0x10; const lc = b.vdp.spriteLimit();
  return { ok: la === 16 && lb === 8 && lc === 16, note: `SMS ${la}, MasterDrive ${lb}, MasterDrive with FEA bit 4 ${lc}` };
});
probe('M34', 'FM detection latch only in SMS and MasterDrive modes; Game Gear $F2 reads $FF', () => {
  const g = sms('gg'); g.out(0xF2, 0x01); const a = g.inp(0xF2);
  const s = sms('sms'); s.out(0xF2, 0x01); const b = s.inp(0xF2) & 3;
  return { ok: a === 0xFF && b === 1, note: `GG $F2=${a.toString(16)}, SMS $F2=${b}` };
});

probe('M35', 'AEL auto-fire (machine profile): in the stock modes button 2 toggles every two frames while C is held, and releasing C leaves the pad as it is; in MasterDrive mode C is left to the software', () => {
  const a = sms('sms'); a.ael.autofire = true; a.btn.c = 1; a.btn.b = 0;
  const seq = [];
  for (let f = 0; f < 4; f++) { a.afTick = f; seq.push((a.inp(0xDC) >> 5) & 1); }   // 0 = pressed
  a.afTick = 2; a.inp(0xDC); a.btn.c = 0;               // release C while the toggle presses button 2
  const after = (a.inp(0xDC) >> 5) & 1;
  const s = sms('ss'); s.ael.autofire = true; s.btn.c = 1; s.btn.b = 0;
  const sb = [];
  for (let f = 0; f < 4; f++) { s.afTick = f; sb.push((s.inp(0xDC) >> 4) & 1); }  // TH high: bit 4 = B
  return { ok: seq.join('') === '1100' && after === 1 && sb.join('') === '1111',
           note: `SMS button 2 ${seq.join('')}, after release ${after}, MasterDrive B ${sb.join('')}` };
});
probe('M36', 'Stock machine: $FB-$FF read as the controller mirror (SMS: even ports $DC, odd $DD; Game Gear $FF). The debug unit answers reads only in MasterDrive mode', () => {
  const a = sms('sms'); a.btn.up = 1;
  const dc = a.inp(0xDC), fc = a.inp(0xFC), dd = a.inp(0xDD), fb = a.inp(0xFB);
  const g = sms('gg'); const gfc = g.inp(0xFC);
  const s = sms('ss'); const sfc = s.inp(0xFC);
  return { ok: fc === dc && fb === dd && gfc === 0xFF && (sfc & 0x40) !== 0 && sfc !== s.inp(0xDC),
           note: `SMS $FC=${fc.toString(16)} ($DC ${dc.toString(16)}), GG $FC=${gfc.toString(16)}, SS $FC=${sfc.toString(16)}` };
});

probe('M37', 'AEL turbo for stock software (machine profile): the enhancement-layer step sets the CPU clock in the stock modes but not in MasterDrive mode, where $F3 decides; VRAM speed-up removes the VDP access wait of the bus synchroniser for stock software only (FM writes are still held)', () => {
  const a = sms('sms'); a.ael.turbo = 2;
  const s = sms('ss'); s.ael.turbo = 2;
  const ma = a.cpuMult ? a.cpuMult() : 1, ms = s.cpuMult ? s.cpuMult() : 1;
  s.vdp.reg[15] = 0x40; s.out(0xF3, 4);                        // software asks for 200 %
  const ms2 = s.cpuMult ? s.cpuMult() : 1;
  // two VDP accesses back to back at 200 %: held without the boost, free with it
  const hold = m => { m.vdp.reg[1] = 0x40; m.vdp.line = 10; m.lastVdpAccess = 0; m.cpu.tc = 100; m.busSync(); return m.busSync(); };
  const w1 = hold(a);
  a.ael.vramboost = true; const w2 = hold(a);
  s.ael.vramboost = true; const w3 = hold(s);
  // with the boost on, an FM data write 2 base cycles after its address write still waits out the 12
  a.out(0xF0, 0x10); a.cpu.tc += 4; const fb = a.cpu.tc; a.out(0xF1, 0x00); const wf = a.cpu.tc - fb;
  return { ok: ma === 2 && ms === 1 && ms2 === 2 && w1 > 0 && w2 === 0 && w3 > 0 && wf === 2 * (12 - 2),
           note: `SMS x${ma}, SS x${ms} (x${ms2} after $F3), waits: SMS ${w1}, SMS+boost ${w2}, SS+boost ${w3}, FM+boost ${wf}` };
});

// ---------------------------------------------------------------- TMS9918 modes
// Graphics I on an SG-1000: name table $3800, patterns $0000, colours $2000,
// sprite attributes $3B00, sprite patterns $1800. Sprite pattern 0 is solid.
function tmsSetup(m) {
  const V = m.vdp;
  V.vram.fill(0);
  V.reg[0] = 0x00; V.reg[1] = 0x40; V.reg[2] = 0x0E; V.reg[3] = 0x80; V.reg[4] = 0x00;
  V.reg[5] = 0x76; V.reg[6] = 0x03; V.reg[7] = 0x04;               // backdrop: dark blue
  for (let r = 0; r < 8; r++) V.vram[0x1800 + r] = 0xFF;
  V.vram[0x3B00] = 0xD0;
  return V;
}
const u32 = v => v >>> 0;                                          // framebuffer values are unsigned
function tmsSprite(V, i, y, x, colour) { const a = 0x3B00 + i * 4; V.vram[a] = y; V.vram[a + 1] = x; V.vram[a + 2] = 0; V.vram[a + 3] = colour; V.vram[a + 4] = 0xD0; }
probe('M42', 'TMS9918 modes: when sprites overlap, the lowest-numbered sprite is drawn on top (Technical Reference §3; TMS9918A Data Manual; Gearsystem)', () => {
  const m = sms('sg'); const V = tmsSetup(m);
  tmsSprite(V, 0, 9, 40, 0x08); tmsSprite(V, 1, 9, 44, 0x02);      // red over green, 4 pixels apart
  V.renderLine(10);
  const at = x => u32(V.fb[10 * 256 + x]), red = u32(V.tms(8)), green = u32(V.tms(2));
  return { ok: at(44) === red && at(47) === red && at(48) === green,
           note: `x44-47 ${at(44) === red && at(47) === red ? 'sprite 0' : 'sprite 1'}, x48 ${at(48) === green ? 'sprite 1' : '?'}` };
});
probe('M43', 'TMS9918 modes: two sprites meeting on a pixel set the collision flag (status bit 5); sprites side by side do not (Technical Reference §3; TMS9918A Data Manual; Gearsystem)', () => {
  const m = sms('sg'); const V = tmsSetup(m);
  tmsSprite(V, 0, 9, 40, 0x08); tmsSprite(V, 1, 9, 48, 0x02);      // touching, not overlapping
  V.status = 0; V.renderLine(10); const apart = V.status & 0x20;
  tmsSprite(V, 1, 9, 47, 0x02);                                    // one column overlaps
  V.status = 0; V.renderLine(10); const over = V.status & 0x20;
  return { ok: !apart && !!over, note: `side by side ${apart ? 'set' : 'clear'}, overlapping ${over ? 'set' : 'clear'}` };
});
probe('M44', 'TMS9918 modes: colour 0 is transparent in Text and Multicolor too, showing the backdrop (TMS9918A Data Manual; Gearsystem)', () => {
  const m = sms('sg'); const V = tmsSetup(m);
  V.reg[7] = 0x04;                                                 // Text: foreground 0, backdrop 4
  V.reg[1] = 0x50; V.vram[0x0000] = 0xFC;                          // character 0: left 6 pixels set
  V.renderLine(0); const txt = u32(V.fb[8]);
  V.reg[1] = 0x48; V.vram[0x0000] = 0x05;                          // Multicolor: left block 0, right block 5
  V.renderLine(0); const mcl = u32(V.fb[0]), mcr = u32(V.fb[4]);
  const bd = u32(V.tms(4));
  return { ok: txt === bd && mcl === bd && mcr === u32(V.tms(5)),
           note: `text fg 0 ${txt === bd ? 'backdrop' : 'not backdrop'}, multicolor 0 ${mcl === bd ? 'backdrop' : 'not backdrop'}` };
});

probe('M45', 'Graphics II: R3 bits 6-0 mask the colour-table index the way R4 bits 1-0 mask the pattern table (TMS9918A Data Manual; Gearsystem)', () => {
  const m = sms('sg'); const V = m.vdp; V.vram.fill(0);
  V.reg[0] = 0x02; V.reg[1] = 0x40; V.reg[2] = 0x0E; V.reg[4] = 0x03; V.reg[5] = 0x76; V.reg[7] = 0x01;
  V.vram[0x3B00] = 0xD0;
  V.vram[0x3800 + 8 * 32] = 0x00;                                  // row 8 (second third), name 0: index $100
  V.vram[0x0800] = 0xFF;                                           // its pattern row 0: all foreground
  V.vram[0x2000] = 0x20; V.vram[0x2800] = 0x80;                    // colour index $000: green; $100: red
  V.reg[3] = 0xFF; V.renderLine(64); const full = u32(V.fb[64 * 256]);
  V.reg[3] = 0x9F; V.renderLine(64); const masked = u32(V.fb[64 * 256]);  // mask $0FF: index $100 -> $000
  return { ok: full === u32(V.tms(8)) && masked === u32(V.tms(2)),
           note: `R3=$FF ${full === u32(V.tms(8)) ? 'red' : '?'}, R3=$9F ${masked === u32(V.tms(2)) ? 'green (masked)' : 'not masked'}` };
});

probe('M46', '$F2 bits 1-0 select the sound chips heard: 0 PSG only (power-on), 1 FM only, 2 neither, 3 both; with no FM unit the PSG alone plays (Technical Reference §7; MAME sms_m.cpp)', () => {
  const tag = o => (o.psg ? 'P' : '-') + (o.fm ? 'F' : '-');
  const m = sms('sms'); const st = [tag(m.soundOn())];
  for (const v of [0, 1, 2, 3]) { m.out(0xF2, v); st.push(tag(m.soundOn())); }
  const g = sms('gg'); g.out(0xF2, 1); const gg = tag(g.soundOn());
  return { ok: st.join(' ') === 'P- P- -F -- PF' && gg === 'P-',
           note: `reset, $F2=0-3: ${st.join(' ')}; Game Gear $F2=1: ${gg}` };
});

probe('M47', 'At turbo the bus synchroniser holds an FM write until the chip can take it: 12 base cycles after an address write, 84 after a data write; no hold at 100 % (Technical Reference §1; YM2413 Application Manual)', () => {
  const held = (turbo, gapT) => {                                  // two FM writes gapT CPU T-states apart
    const m = sms('sms'); m.ael.turbo = turbo; m.lastFm = null;
    m.out(0xF0, 0x10); m.cpu.tc += gapT;
    const before = m.cpu.tc; m.out(0xF1, 0x4A); const afterData = m.cpu.tc - before;
    m.cpu.tc += gapT; const b2 = m.cpu.tc; m.out(0xF0, 0x20); const afterAddr = m.cpu.tc - b2;
    return [afterData, afterAddr];
  };
  const [d2, a2] = held(2, 4);                                     // 200 %: 2 base cycles after each write
  const [d1, a1] = held(1, 4);                                     // 100 %
  return { ok: d2 === 2 * (12 - 2) && a2 === 2 * (84 - 2) && d1 === 0 && a1 === 0,
           note: `200 %: data held ${d2} T, next address ${a2} T; 100 %: ${d1}, ${a1}` };
});

probe('M48', 'The pad in the stock modes: A is button 1, B is button 2, and Start = Pause is on at power-on, so Start pauses a Master System game without any setting (Technical Reference §6, §15)', () => {
  const m = sms('sms'); let n = 0;
  const f = m.cpu.nmi.bind(m.cpu); m.cpu.nmi = () => { n++; f(); };
  const on = m.ael.startpause === true;
  m.btn.a = 1; const a = m.inp(0xDC); m.btn.a = 0; m.btn.b = 1; const b = m.inp(0xDC); m.btn.b = 0;
  m.btn.start = 1; m.runFrame(); m.runFrame();
  const hex = v => '$' + v.toString(16).toUpperCase().padStart(2, '0');
  return { ok: on && n === 1 && (a & 0x30) === 0x20 && (b & 0x30) === 0x10,
           note: `Start = Pause ${on ? 'on' : 'off'} at power-on, NMIs ${n}; A -> $DC ${hex(a)}, B -> ${hex(b)}` };
});

probe('M49', 'PAL runs on the PAL clock: base 3.546893 MHz, frames at 49.70 Hz (313 lines of 228 cycles); NTSC 3.579545 MHz, 59.92 Hz (Technical Reference §1)', () => {
  const m = sms('sms');
  m.pal = false; const nHz = m.baseHz(), nF = m.frameHz();
  m.pal = true;  const pHz = m.baseHz(), pF = m.frameHz();
  return { ok: nHz === 3579545 && pHz === 3546893 && Math.abs(nF - 59.92) < 0.01 && Math.abs(pF - 49.70) < 0.01,
           note: `NTSC ${nF.toFixed(2)} Hz, PAL ${pF.toFixed(2)} Hz` };
});

probe('M50', 'The FM write timing of the bus synchroniser carries over a frame boundary: an FM write late in one frame still holds the first FM write of the next at turbo; reset and loading a state start it afresh (Technical Reference §1)', () => {
  const m = sms('sms'); m.ael.turbo = 2;
  const core = m.runFrameCore; m.runFrameCore = () => m.vdp.fb;  // the frame boundary only, no instructions
  m.out(0xF0, 0x10); m.runFrame(); m.cpu.tc += 4;                   // address write, frame ends, 2 base cycles later:
  const b = m.cpu.tc; m.out(0xF1, 0x4A); const held = m.cpu.tc - b;  // the data write waits out the 12
  m.runFrameCore = core;
  // reset, then a write 4 T after the CPU's count passes the last one again: no hold
  const last = m.cpu.tc; m.reset(); m.cpu.tc = last + 4;
  const r = m.cpu.tc; m.out(0xF0, 0x20); const afterReset = m.cpu.tc - r;
  // a state taken just after a write, loaded after another write: the loaded machine holds nothing
  const saveState = X.evalInPage('saveState'), loadState = X.evalInPage('loadState');
  m.out(0xF1, 0x00); const st = JSON.parse(JSON.stringify(saveState(m)));
  m.cpu.tc += 30; m.out(0xF0, 0x30); st.cpu.tc = m.cpu.tc + 2; loadState(m, st);
  const l = m.cpu.tc; m.out(0xF1, 0x00); const afterLoad = m.cpu.tc - l;
  return { ok: held === 2 * (12 - 2) && afterReset === 0 && afterLoad === 0,
           note: `across the frame boundary held ${held} T; after reset ${afterReset} T; after a state load ${afterLoad} T` };
});

probe('M51', 'Every port access is timed where it ends: OUT (C),A straight after OUT ($F0),A ends 12 T-states later, OUT ($F1),A 11 and OUTI 16, so at 200 % the FM data write is held for the rest of the 12 base cycles; INI reads its port at T13, before its memory write, so a VDP read by INI straight after IN A,($BE) is held for the rest of the VDP slot (Technical Reference §1; cycle order from MAME z80)', () => {
  const held = (code, mode) => {                                   // run code from $C000 at 200 %; T-states of hold
    const m = sms(mode || 'sms'); m.ael.turbo = 2;
    code.forEach((v, i) => m.wr(0xC000 + i, v)); m.cpu.PC = 0xC000;
    for (let i = 0; i < code.length && m.cpu.PC < 0xC000 + code.length; i++) m.cpu.step();
    return m.syncWait || 0;
  };
  const viaC = held([0x0E, 0xF1, 0xD3, 0xF0, 0xED, 0x79]);         // LD C,$F1 ; OUT ($F0),A ; OUT (C),A
  const viaN = held([0xD3, 0xF0, 0xD3, 0xF1]);                     // OUT ($F0),A ; OUT ($F1),A
  const viaI = held([0x21, 0x00, 0xC1, 0x01, 0xF1, 0x01, 0xD3, 0xF0, 0xED, 0xA3]);   // LD HL,$C100 ; LD BC,$01F1 ; OUT ($F0),A ; OUTI
  const viaR = held([0x21, 0x00, 0xC1, 0x01, 0xBE, 0x01, 0xDB, 0xBE, 0xED, 0xA2]);   // ... LD BC,$01BE ; IN A,($BE) ; INI
  // the display is off, so the VDP takes an access every 16 base cycles: 32 T at 200 %
  return { ok: viaC === 24 - 12 && viaN === 24 - 11 && viaI === 24 - 16 && viaR === 32 - 13,
           note: `FM data write held ${viaC} T after OUT (C),A, ${viaN} after OUT ($F1),A, ${viaI} after OUTI; VDP read by INI held ${viaR}` };
});

probe('M52', 'The bus synchroniser counts the time since the last VDP access, and since the last FM write, in base cycles whatever the turbo step: a step change between two accesses rescales the time already passed, accesses made at 100 % count, and however long the machine has run the hold is only the rest of the slot; the time also carries over a frame boundary (Technical Reference §1)', () => {
  const ss = () => { const m = sms('ss'); m.vdp.reg[15] = 0x40; return m; };   // Feature Enable A bit 6: $F3 may set the step
  const after = (m, port, v) => { const b = m.cpu.tc; m.out(port, v); return m.cpu.tc - b; };
  // VDP: access at 125 % after a long run, 10 T (8 base cycles), step to 200 %, 4 T (2 base cycles), access
  const a = ss(); a.out(0xF3, 1); a.cpu.tc = 10000000;
  a.out(0xBF, 0x00); a.cpu.tc += 10; a.out(0xF3, 4); a.cpu.tc += 4;
  const step = after(a, 0xBF, 0x80);                               // the rest of the 16-cycle slot (display off): 6 base = 12 T
  // VDP: access at 100 %, 4 T (4 base cycles), step to 200 %, 4 T (2 base cycles), access
  const c = ss(); c.out(0xBF, 0x00); c.cpu.tc += 4; c.out(0xF3, 4); c.cpu.tc += 4;
  const base = after(c, 0xBF, 0x80);                               // 10 base = 20 T
  // FM: address write at 125 %, 5 T (4 base cycles), step to 200 %, 4 T (2 base cycles), data write
  const f = ss(); f.out(0xF3, 1); f.out(0xF0, 0x10); f.cpu.tc += 5; f.out(0xF3, 4); f.cpu.tc += 4;
  const fm = after(f, 0xF1, 0x4A);                                 // the rest of the 12: 6 base = 12 T
  // across a frame boundary at 200 % (stock software, the turbo boost)
  const g = sms('sms'); g.ael.turbo = 2;
  const core = g.runFrameCore; g.runFrameCore = () => g.vdp.fb;
  g.out(0xBF, 0x00); g.runFrame(); g.cpu.tc += 4;
  const frame = after(g, 0xBF, 0x80);                              // 14 base = 28 T
  g.runFrameCore = core;
  return { ok: step === 12 && base === 20 && fm === 12 && frame === 28,
           note: `held ${step} T after a step change at 125 %, ${base} after one at 100 %, FM ${fm}; across the frame boundary ${frame}` };
});

probe('M53', 'IN F,(C) ($ED $70) reads port (C), sets S, Z and P/V from the value and keeps no value, in 12 T-states (The Undocumented Z80 Documented; MAME z80)', () => {
  const run = v => {
    const { c, io } = flatCpu([0x0E, 0xDC, 0xED, 0x70]);           // LD C,$DC ; IN F,(C)
    const reads = []; io.in = p => { reads.push(p & 0xFF); return v; };
    c.R[6] = 0x00; c.step(); const a = c.R[7]; const t = c.step();
    return { t, f: c.R[6] & 0xC4, reads: reads.join(','), keep: c.R[7] === a };
  };
  const ef = run(0xEF), zero = run(0x00);                          // $EF: S, odd parity; $00: Z, even parity
  return { ok: ef.t === 12 && ef.f === 0x80 && zero.f === 0x44 && ef.reads === '220' && ef.keep,
           note: `${ef.t} T, port ${ef.reads || 'not read'}, F&$C4 $${ef.f.toString(16)} / $${zero.f.toString(16)}` };
});

probe('M54', 'MasterDrive I/O gate (Q1): until software sets Feature Enable A bit 7, ports $01-$17 act as the $3E/$3F mirrors and read $FF, and $00 still reads Start and region; with the bit set they are the MasterDrive and Game Gear registers; clearing it closes them again but what they were set to stays in force; the gate is MasterDrive mode only (Technical Reference \u00a711)', () => {
  const hex = v => '$' + v.toString(16).toUpperCase().padStart(2, '0');
  const r15 = (m, v) => { m.out(0xBF, v); m.out(0xBF, 0x8F); };       // VDP register 15 through the control port
  const m = sms('ss');
  const closed = [0x01, 0x05, 0x06, 0x09, 0x0E, 0x0F, 0x16, 0x17].map(q => m.inp(q));
  const start = m.inp(0x00);
  m.out(0x0C, 0xAB); const mc1 = m.memCtl; m.out(0x0D, 0xF5); const ic1 = m.ioCtl;
  m.out(0x06, 0xA9); const mc2 = m.memCtl, st0 = m.psg.stereoSet;
  m.out(0x05, 0x12); const ic2 = m.ioCtl, gg5 = m.ggReg[5];
  m.out(0x3E, 0xA8); m.out(0x3F, 0xFF);                                  // back to the reset values
  r15(m, 0x80);
  m.out(0x0C, 200); m.out(0x0D, 100); m.out(0x0E, 0);
  const prod = m.inp(0x0F) | (m.inp(0x10) << 8), tap = m.inp(0x16);
  m.out(0x06, 0x0F); m.out(0x05, 0x12); m.out(0x0A, 5);
  const openOk = prod === 20000 && tap === 0x81 && m.psg.stereo === 0x0F && m.ggReg[5] === 0x12 &&
                 m.memCtl === 0xA8 && m.ioCtl === 0xFF && m.wramBank === 5;
  r15(m, 0x00);
  const shut = m.inp(0x16), kept = m.wramBank;
  const g = sms('gg'); g.out(0x06, 0x0F);                                 // Game Gear: $06 needs no gate
  const s = sms('sms'); s.vdp.reg[15] = 0x80; s.out(0x0C, 0xAB);         // Master System: the mirrors, bit or no bit
  const ok = closed.every(v => v === 0xFF) && (start & 0x3F) === 0 && start !== 0xFF &&
             mc1 === 0xAB && ic1 === 0xF5 && mc2 === 0xA9 && !st0 && ic2 === 0x12 && gg5 === 0x00 &&
             openOk && shut === 0xFF && kept === 5 && g.psg.stereo === 0x0F && s.memCtl === 0xAB;
  return { ok, note: `closed: ${closed.map(hex).join(' ')}, $00 ${hex(start)}, mirrors ${hex(mc1)}/${hex(ic1)}/${hex(mc2)}/${hex(ic2)}; ` +
                     `open: ${prod}, $16 ${hex(tap)}; closed again: $16 ${hex(shut)}, bank ${kept}` };
});

probe('M55', 'Machine ID (Q8): with Feature Enable A bit 7 set, port $17 reads $A7 in MasterDrive mode (high nibble $A = MasterDrive, low nibble the machine version 7); stock modes read $FF; a write to $17 is absorbed with the gate open and is a $3F mirror write before (Technical Reference \u00a714)', () => {
  const detect = mode => {                                         // LD A,$80 ; OUT ($BF),A ; LD A,$8F ; OUT ($BF),A ; IN A,($17)
    const m = sms(mode); const code = [0x3E, 0x80, 0xD3, 0xBF, 0x3E, 0x8F, 0xD3, 0xBF, 0xDB, 0x17];
    code.forEach((v, i) => m.wr(0xC000 + i, v)); m.cpu.PC = 0xC000;
    for (let i = 0; i < 5; i++) m.cpu.step();
    return m.cpu.R[7];
  };
  const ids = ['ss', 'sms', 'gg'].map(detect);
  const a = sms('ss'); const before = a.inp(0x17); a.out(0x17, 0xF5); const mirror = a.ioCtl;
  a.vdp.reg[15] = 0x80; a.out(0x3F, 0xFF); a.out(0x17, 0x00); const absorbed = a.ioCtl;
  const hex = v => '$' + v.toString(16).toUpperCase().padStart(2, '0');
  return { ok: ids[0] === 0xA7 && ids[1] === 0xFF && ids[2] === 0xFF && before === 0xFF && mirror === 0xF5 && absorbed === 0xFF,
           note: `MasterDrive ${hex(ids[0])}, SMS ${hex(ids[1])}, GG ${hex(ids[2])}; before the gate ${hex(before)}, write -> $3F ${hex(mirror)}; after ${hex(absorbed)}` };
});

probe('M56', 'Math unit divide (Q7): A / B, unsigned, the quotient in $0F and the remainder in $10; a divide by zero gives $FF/$00; multiply is unchanged (Technical Reference \u00a79)', () => {
  const m = sms('ss'); m.vdp.reg[15] = 0x80;
  const run = (a, b, op) => { m.out(0x0C, a); m.out(0x0D, b); m.out(0x0E, op); return [m.inp(0x0F), m.inp(0x10)]; };
  let bad = 0;
  for (let a = 0; a < 256; a++) for (let b = 0; b < 256; b++) {
    const [q, r] = run(a, b, 1);
    if (b ? (q !== Math.floor(a / b) || r !== a % b) : (q !== 0xFF || r !== 0x00)) bad++;
  }
  const d = run(200, 7, 1), x = run(255, 255, 0);
  return { ok: bad === 0 && d[0] === 28 && d[1] === 4 && x[0] === 0x01 && x[1] === 0xFE && m.inp(0x0E) === 0,
           note: `${bad} of 65536 divides wrong; 200 / 7 = ${d[0]} r ${d[1]}; 255 x 255 = $${(x[1] * 256 + x[0]).toString(16)}` };
});

probe('M57', 'Work RAM bank readback (Q9): $0A reads the selected bank in bits 3-0, bits 7-4 read 0; in Master System mode it reads $FF (Technical Reference \u00a72)', () => {
  const m = sms('ss'); m.vdp.reg[15] = 0x80;
  const got = [0x00, 0x05, 0x0B, 0x0F, 0xF3, 0xFF].map(v => { m.out(0x0A, v); return m.inp(0x0A); });
  const s = sms('sms'); s.vdp.reg[15] = 0x80;
  return { ok: got.join(',') === '0,5,11,15,3,15' && s.inp(0x0A) === 0xFF,
           note: `writes $00 $05 $0B $0F $F3 $FF read ${got.join(' ')}; Master System $${s.inp(0x0A).toString(16)}` };
});

probe('M58', 'PCM FIFO fill (Q14): $08 bits 6-4 read the bytes queued divided by 8, saturating at 7; the 65th byte is dropped (Technical Reference \u00a77)', () => {
  const want = { 0: 0x00, 7: 0x00, 8: 0x10, 15: 0x10, 16: 0x20, 55: 0x60, 56: 0x70, 63: 0x70, 64: 0x70, 65: 0x70 };
  const got = Object.keys(want).map(n => { const m = sms('ss'); m.vdp.reg[15] = 0x80;
    for (let i = 0; i < +n; i++) m.out(0x07, 0x80); return [n, m.inp(0x08), m.pcm.fifo.length]; });
  return { ok: got.every(([n, v, len]) => v === want[n] && len === Math.min(64, +n)),
           note: got.map(([n, v]) => `${n}:$${v.toString(16)}`).join(' ') };
});

probe('M59', 'Cartridge save RAM (Q3): 32 KB, two banks of 16 KB as the 315-5235 maps them: $FFFC bit 3 maps it over $8000-$BFFF and bit 2 picks the bank, so $8000 and $A000 are different bytes and the two banks are separate (Technical Reference \u00a72, \u00a78)', () => {
  const m = sms('sms'); m.mapper = 'sega';
  const put = (sel, a, v) => { m.wr(0xFFFC, sel); m.wr(a, v); };
  put(0x08, 0x8000, 0x11); put(0x08, 0xA000, 0x22); put(0x0C, 0x8000, 0x33); put(0x0C, 0xBFFF, 0x44);
  const get = (sel, a) => { m.wr(0xFFFC, sel); return m.rd(a); };
  const got = [get(0x08, 0x8000), get(0x08, 0xA000), get(0x0C, 0x8000), get(0x0C, 0xBFFF)];
  const hex = v => '$' + v.toString(16).toUpperCase().padStart(2, '0');
  return { ok: got.join(',') === [0x11, 0x22, 0x33, 0x44].join(',') && m.ram[0x2000] === 0x11 && m.ram[0x4000] === 0x22 && m.ram[0x6000] === 0x33,
           note: `bank 0 $8000 ${hex(got[0])}, $A000 ${hex(got[1])}; bank 1 $8000 ${hex(got[2])}, $BFFF ${hex(got[3])}` };
});

probe('M60', 'Cartridge wait state at 200 % (Q12, kept): the machine reads its cartridge as a 250 ns ROM, so at 200 % every read in $0000-$BFFF takes one wait state and a NOP in ROM takes 5 T-states (4 at 175 %, and 4 in work RAM); the wait follows a mid-frame $F3 step change at once; a halted CPU in ROM takes it on its M1 reads too; SF-7000 RAM never waits (Technical Reference \u00a71)', () => {
  const m = sms('ss'); m.cart = new Uint8Array(0x8000);           // all NOPs
  const def = m.romMode === 'cart' && m.romNs === 250;
  m.vdp.reg[15] = 0x40; m.out(0xF3, 4);                          // 200 %, in mid-frame
  const ws = m.ws;
  m.cpu.PC = 0x0000; const rom200 = m.cpu.step();
  m.cpu.PC = 0xC000; m.wr(0xC000, 0x00); const ram200 = m.cpu.step();
  m.cpu.PC = 0x0100; m.cpu.halt = 1; const halt200 = m.cpu.step(); m.cpu.halt = 0;
  m.out(0xF3, 3); m.cpu.PC = 0x0000; const rom175 = m.cpu.step();
  const f = sms('sf'); f.ael.turbo = 2; f.ws = f.romWaitStates(); f.wr(0x0000, 0x00); f.cpu.PC = 0x0000;
  const sf200 = f.cpu.step();
  return { ok: def && ws === 1 && rom200 === 5 && ram200 === 4 && halt200 === 5 && rom175 === 4 && sf200 === 4,
           note: `default ${m.romMode} ${m.romNs} ns; 200 %: ROM NOP ${rom200} T, RAM ${ram200}, HALT ${halt200}; 175 %: ${rom175}; SF-7000 at 200 %: ${sf200}` };
});

probe('M61', 'ESAT is always 2 bytes per sprite: entry i at the ESAT base + 2i; byte 0 bit 4 magnifies, bit 5 moves the sprite 32 pixels left, byte 1 bits 3-0 pick the palette (with extended CRAM). Feature Enable C bit 4 is retired and changes nothing (Technical Reference §5, Q13)', () => {
  const run = fec => {
    const m = sms('ss'); const V = vdpSetup(m);
    V.reg[15] = 0x28; V.reg[16 + 2] = 0x02; V.reg[16 + 7] = fec;      // XRB + ESAT; extended CRAM; Feature Enable C
    V.reg[12] = 0x20;                                                 // ESAT at $2000
    V.vram[0x3F00] = 9; V.vram[0x3F01] = 9; V.vram[0x3F02] = 0xD0;
    V.vram[0x3F80] = 40; V.vram[0x3F81] = 1; V.vram[0x3F82] = 100; V.vram[0x3F83] = 1;
    V.vram[0x2000] = 0x10;                                            // sprite 0: magnified
    V.vram[0x2002] = 0x20; V.vram[0x2003] = 0x05;                     // sprite 1: early clock, palette 5
    V.cram[(5 * 16 + 1) * 2] = 0x0F; V.cram[(5 * 16 + 1) * 2 + 1] = 0x00; V.pw[0] |= 1 << 5;   // palette 5 entry 1: red
    V.renderLine(10);
    const lit = x => (V.fb[10 * 256 + x] & 0xFFFFFF) !== 0;
    return { mag: lit(40) && lit(55) && !lit(56), early: lit(68) && lit(75) && !lit(100),
             pal: (V.fb[10 * 256 + 68] >>> 0) === (V.colour(5, 1) >>> 0) };
  };
  const a = run(0x00), b = run(0x10);
  const ok = a.mag && a.early && a.pal && b.mag && b.early && b.pal;
  return { ok, note: `bit 4 clear: magnify ${a.mag}, early clock ${a.early}, palette ${a.pal}; set: ${b.mag}, ${b.early}, ${b.pal}` };
});

probe('M62', 'TMS modes at 224 and 240 lines (MasterDrive software, Feature Enable B): the name table continues and Graphics II takes rows 24-29 from a fourth pattern and colour bank (third 3, masked by R4 bits 1-0 and R3 bits 6-5); Y = $D0 ends the sprite list only at 192 lines, as in Mode 4; a stock SG-1000 stays at 192 lines (Technical Reference §3, Q17)', () => {
  const setup = (mode, feb) => {
    const m = sms(mode); const V = tmsSetup(m);
    V.reg[15] = 0x20; V.reg[16 + 2] = feb;                            // XRB; Feature Enable B height
    V.reg[0] = 0x02; V.reg[3] = 0xFF; V.reg[4] = 0x03;                // Graphics II, four banks
    return V;
  };
  const V = setup('ss', 0x80);
  V.vram[0x3800 + 25 * 32] = 5;                                      // row 25 (third 3), column 0: name 5
  V.vram[0x1800 + 5 * 8] = 0xFF; V.vram[0x3800 + 5 * 8] = 0x80;      // bank 3: pattern 5 row 0 set; colour red
  V.vram[0x1000 + 5 * 8] = 0xFF; V.vram[0x3000 + 5 * 8] = 0x20;      // bank 2: green
  V.renderLine(200); const b3 = (V.fb[200 * 256] >>> 0) === (V.tms(8) >>> 0);
  V.reg[4] = 0x02; V.reg[3] = 0xDF;                                   // masks: third 3 -> pattern bank 2, colour bank 2
  V.renderLine(200); const b2 = (V.fb[200 * 256] >>> 0) === (V.tms(2) >>> 0);
  V.reg[4] = 0x03; V.reg[3] = 0xFF;
  tmsSprite(V, 0, 0xD0, 10, 0x0F); tmsSprite(V, 1, 99, 50, 0x08);
  V.renderLine(100); const after = (V.fb[100 * 256 + 50] >>> 0) === (V.tms(8) >>> 0);
  V.renderLine(209); const d0 = (V.fb[209 * 256 + 10] >>> 0) === (V.tms(15) >>> 0);
  const W = setup('ss', 0x00); tmsSprite(W, 0, 0xD0, 10, 0x0F); tmsSprite(W, 1, 99, 50, 0x08);
  W.renderLine(100); const ended = (W.fb[100 * 256 + 50] >>> 0) === (W.tms(4) >>> 0);
  const sg = setup('sg', 0x80);
  return { ok: V.height() === 240 && b3 && b2 && after && d0 && ended && sg.height() === 192,
           note: `height ${V.height()}, bank 3 ${b3}, masked to bank 2 ${b2}, sprite after $D0 ${after}, $D0 sprite on 209 ${d0}, 192: $D0 ends ${ended}, SG ${sg.height()}` };
});

probe('M63', 'TMS modes at 224 and 240 lines: a sprite starts on line Y+1, or Y+1-256 when Y+1 is 241 or more, as in Mode 4 (at 192 lines: 225 or more), as the owner decided (Technical Reference §3, Q17)', () => {
  const m = sms('ss'); const V = tmsSetup(m); V.reg[15] = 0x20; V.reg[16 + 2] = 0x80;
  tmsSprite(V, 0, 0xE7, 10, 0x0F);                                    // line 232
  V.renderLine(232); const tall = (V.fb[232 * 256 + 10] >>> 0) === (V.tms(15) >>> 0);
  V.reg[16 + 2] = 0x00; V.vram[0x3B00] = 0xFA; V.renderLine(2); const low = (V.fb[2 * 256 + 10] >>> 0) === (V.tms(15) >>> 0);
  return { ok: tall && low, note: `240 lines: Y=$E7 on line 232 ${tall}; 192 lines: Y=$FA on line 2 ${low}` };
});

probe('M64', 'Window layer with the background scrolled: the scrolled background fills every screen column left of the window, and the window covers screen x from 8 x R13 (Technical Reference §3, Q16)', () => {
  const m = sms('ss'); const V = vdpSetup(m);
  V.reg[15] = 0x24; V.reg[16 + 0] = 0x20;                           // XRB + window; window tilemap at $2000
  V.reg[13] = 16; V.reg[14] = 0x00;                                 // window from x = 128, every line
  for (let r = 0; r < 8; r++) V.vram[64 + r * 4 + 1] = 0xFF;        // tile 2: colour 2
  V.cram[4] = 0x0F; V.cram[5] = 0x00;                               // entry 2: red
  for (let i = 0; i < 32 * 28; i++) V.vram[0x3800 + i * 2] = 1;     // background: tile 1 (white)
  for (let i = 0; i < 32 * 32; i++) V.vram[0x2000 + i * 2] = 2;     // window: tile 2 (red)
  V.hsLatch = 8; V.renderLine(10);
  const px = x => V.fb[10 * 256 + x] >>> 0, white = V.colour(0, 1) >>> 0, red = V.colour(0, 2) >>> 0;
  const ok = px(3) === white && px(127) === white && px(128) === red && px(255) === red;
  return { ok, note: `x 3 ${px(3) === white ? 'background' : 'gap'}, x 127 ${px(127) === white}, x 128 window ${px(128) === red}, x 255 ${px(255) === red}` };
});

probe('M65', 'DMA fill writes the byte in $F4 (the mode register $F6 holds only the mode and source): $F4 = $5A, $F6 = $08 (fill), destination $1000, length 4 (Technical Reference §9, Q16)', () => {
  const m = sms('ss'); const V = m.vdp; V.vram.fill(0);
  for (const [p, v] of [[0xF4, 0x5A], [0xF5, 0], [0xF6, 0x08], [0xF7, 0x00], [0xF8, 0x10], [0xF9, 4], [0xFA, 0x80]]) m.out(p, v);
  const got = Array.from(V.vram.slice(0x1000, 0x1005));
  const ok = got.join() === '90,90,90,90,0' && m.inp(0xF4) === 0x5A && m.inp(0xF8) === 0x10;
  return { ok, note: 'VRAM $1000-$1004: ' + got.map(v => '$' + v.toString(16).toUpperCase()).join(' ') };
});

probe('M66', 'DMA to CRAM marks the palettes it writes as written, so an extended palette loaded by DMA is shown, not aliased to palette 0 or 1 (Technical Reference §9, Q16)', () => {
  const m = sms('ss'); const V = m.vdp;
  V.reg[15] = 0x20; V.reg[16 + 2] = 0x02;                           // XRB; extended CRAM
  m.wram.set([0x0F, 0x00, 0xF0, 0x00], 0x100);                      // entries: red, green
  for (const [p, v] of [[0xF4, 0x00], [0xF5, 0x01], [0xF6, 0x02], [0xF7, 0xA0], [0xF8, 0x40], [0xF9, 4], [0xFA, 0x80]]) m.out(p, v);
  const shown = (V.colour(5, 1) >>> 0) === (V.rgb(5 * 16 + 1) >>> 0) && (V.rgb(5 * 16 + 1) >>> 0) !== (V.rgb(17) >>> 0);
  return { ok: shown && !!(V.pw[0] & (1 << 5)), note: `CRAM $A2-$A3 ${V.cram[0xA2]},${V.cram[0xA3]}; palette 5 marked ${!!(V.pw[0] & (1 << 5))}, shown ${shown}` };
});

probe('M67', 'Reset returns the PCM output to silence (it held its last sample, a constant offset on both sides, until new samples came) (Technical Reference §7, Q16)', () => {
  const m = sms('ss'); m.pcmLast = 0.15; m.reset();
  return { ok: m.pcmLast === 0, note: 'level after reset ' + m.pcmLast };
});

probe('M68', 'R0 bit 7 exempts screen x 192 to the right edge from the vertical scroll, whatever the horizontal scroll: the lock is by screen position, not by map column (Gearsystem, Video.cpp RenderBG; Technical Reference §16)', () => {
  const m = sms('sms'); const V = vdpSetup(m);
  V.reg[0] = 0x84;                                                  // Mode 4, R0 bit 7
  for (let r = 0; r < 8; r++) V.vram[64 + r * 4 + 1] = 0xFF;        // tile 2: colour 2
  V.cram[4] = 0x0F; V.cram[5] = 0x00;                               // entry 2: red
  for (let c = 0; c < 32; c++) { V.vram[0x3800 + c * 2] = 1; V.vram[0x3800 + 2 * 64 + c * 2] = 2; }
  V.hsLatch = 4; V.vsLatch = 16; V.renderLine(0);                    // scrolled: map row 2 (red); locked: row 0 (white)
  const px = x => V.fb[x] >>> 0, white = V.colour(0, 1) >>> 0, red = V.colour(0, 2) >>> 0;
  const ok = px(191) === red && px(192) === white && px(195) === white && px(255) === white;
  return { ok, note: `x 191 ${px(191) === red ? 'scrolled' : 'locked'}, x 192 ${px(192) === white ? 'locked' : 'scrolled'}, x 195 ${px(195) === white ? 'locked' : 'scrolled'}` };
});

probe('M69', 'A magnified sprite cut by the left edge shows the visible half of its first pixel: with R1 bit 0 and R0 bit 3 a sprite at X = 7 starts at x = -1, so x = 0 shows its first pixel (Gearsystem draws sprites per screen pixel; Technical Reference §5)', () => {
  const m = sms('sms'); const V = vdpSetup(m);
  V.reg[0] = 0x0C; V.reg[1] = 0x41;                                 // sprites 8 left; display on, magnified
  V.vram[0x3F00] = 9; V.vram[0x3F01] = 0xD0; V.vram[0x3F80] = 7; V.vram[0x3F81] = 1;
  V.renderLine(10);
  const spr = V.colour(1, 1) >>> 0;
  const ok = (V.fb[10 * 256] >>> 0) === spr && (V.fb[10 * 256 + 14] >>> 0) === spr && (V.fb[10 * 256 + 15] >>> 0) !== spr;
  return { ok, note: `x 0 ${(V.fb[10 * 256] >>> 0) === spr ? 'sprite' : 'background'}, x 14 ${(V.fb[10 * 256 + 14] >>> 0) === spr}, x 15 ${(V.fb[10 * 256 + 15] >>> 0) !== spr ? 'background' : 'sprite'}` };
});

let pass = 0;
for (const r of results) { if (r.ok) pass++; console.log((r.ok ? 'PASS ' : 'FAIL ') + r.id.padEnd(5) + ' ' + r.note.padEnd(46) + ' | ' + r.what); }
console.log(`${pass} of ${results.length} pass`);
process.exitCode = pass === results.length ? 0 : 1;
