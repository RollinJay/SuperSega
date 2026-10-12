// Builds a test program covering timing classes and records the JS emulator's
// T-states per instruction as the expected result.
const fs = require('fs');
const path = require('path');
// emuload.js: the emulator's headless loader (EMULOAD overrides the package location)
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
  0xCD,0x40,0x00,        // CALL $0040
  0x18,0xFE,             // JR $
];
const sub = [0xE5, 0xE1, 0xC9];   // $0040: PUSH HL ; POP HL ; RET
const mem = new Uint8Array(0x10000);
mem.set(prog, 0); mem.set(sub, 0x40);
fs.writeFileSync('prog.hex', Array.from(mem.slice(0, 0x80)).map(b => b.toString(16).padStart(2, '0')).join('\n') + '\n');
const io = [];
const c = new X.Z80({ rd: a => mem[a], wr: (a, v) => { mem[a] = v; },
  inp: p => { const v = (p & 0xFF) ^ 0x5A; io.push(['in', p & 0xFF, v]); return v; },
  out: (p, v) => io.push(['out', p & 0xFF, v]) });
c.PC = 0; c.SP = 0xF000;
let t = 0; const out = [];
for (let n = 0; n < 40; n++) { out.push(`M1 ${t} ${c.PC.toString(16).padStart(4, '0')}`); t += c.step(); }
fs.writeFileSync('z80_js.log', out.join('\n') + '\n');
console.log('wrote', out.length);
