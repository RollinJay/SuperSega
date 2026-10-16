// Builds a test program covering timing classes and records the JS emulator's
// instruction starts and port accesses (T-state, port, direction, value) as the
// expected result.
const fs = require('fs');
const path = require('path');
// emuload.js: the emulator's headless loader (EMULOAD overrides the default, ../../../emulator/tools/emuload)
const { loadEmu } = require(process.env.EMULOAD || path.join(__dirname, '../../../emulator/tools/emuload'));
const X = loadEmu(process.argv[2], { quiet: true });
const prog = [
  0x31,0x00,0xF0,        // LD SP,$F000
  0x3E,0x12,             // LD A,$12
  0x06,0x03,             // LD B,3
  0xDD,0x21,0x00,0x80,   // LD IX,$8000
  0xFD,0x21,0x10,0x80,   // LD IY,$8010
  0xDD,0x7E,0x01,        // LD A,(IX+1)
  0xDD,0x36,0x02,0x55,   // LD (IX+2),$55
  0xDD,0x34,0x02,        // INC (IX+2)
  0xFD,0x86,0x03,        // ADD A,(IY+3)
  0xDD,0xCB,0x01,0x46,   // BIT 0,(IX+1)
  0xDD,0xCB,0x01,0x06,   // RLC (IX+1)
  0xDD,0x26,0x34,        // LD IXH,$34
  0xDB,0xBF,             // IN A,($BF)
  0xD3,0xBE,             // OUT ($BE),A
  0x0E,0x7F,             // LD C,$7F
  0xED,0x78,             // IN A,(C)
  0xED,0x79,             // OUT (C),A
  0x21,0x00,0x80,        // LD HL,$8000
  0xED,0xA3,             // OUTI
  0xED,0xA2,             // INI
  0x10,0xFE,             // DJNZ $ (B now 1 after OUTI/INI? loops until 0)
  0x06,0x02, 0xED,0xAA,  // LD B,2 ; IND
  0x06,0x03, 0xED,0xB2,  // LD B,3 ; INIR (repeats twice)
  0x06,0x02, 0xED,0xBA,  // LD B,2 ; INDR
  0x06,0x02, 0xED,0xB3,  // LD B,2 ; OTIR
  0x06,0x02, 0xED,0xBB,  // LD B,2 ; OTDR
  0xED,0xAB,             // OUTD
  0xED,0x50,             // IN D,(C)
  0xCD,0x80,0x00,        // CALL $0080
  0x18,0xFE,             // JR $
];
const sub = [0xE5, 0xE1, 0xC9];   // $0080: PUSH HL ; POP HL ; RET
const mem = new Uint8Array(0x10000);
mem.set(prog, 0); mem.set(sub, 0x80);
fs.writeFileSync('prog.hex', Array.from(mem.slice(0, 0x100)).map(b => b.toString(16).padStart(2, '0')).join('\n') + '\n');
// Every port access is logged with the emulator's T-state count at the access:
// its I/O instructions count their T-states up to the end of the access first.
const out = [];
const hex = (v, n) => v.toString(16).padStart(n, '0');
const c = new X.Z80({ rd: a => mem[a], wr: (a, v) => { mem[a] = v; },
  inp: p => { const v = (p & 0xFF) ^ 0x5A; out.push(`IO ${c.tc} ${hex(p & 0xFFFF, 4)} 0 ${hex(v, 2)}`); return v; },
  out: (p, v) => out.push(`IO ${c.tc} ${hex(p & 0xFFFF, 4)} 1 ${hex(v, 2)}`) });
c.PC = 0; c.SP = 0xF000; c.tc = 0;
for (let n = 0; n < 60; n++) { out.push(`M1 ${c.tc} ${hex(c.PC, 4)}`); c.step(); }
fs.writeFileSync('z80_js.log', out.join('\n') + '\n');
console.log('wrote', out.filter(l => l.startsWith('M1')).length, 'instructions,', out.filter(l => l.startsWith('IO')).length, 'port accesses');
