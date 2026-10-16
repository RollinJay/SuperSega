'use strict';
// ROM identity and stored-data migration, headless (the emulator's application
// code, not the machine model). Each ROM's settings, battery image, snapshot and
// save routing are stored under a CRC-32 of the whole ROM; the key used before
// hashed every 17th byte, so ROMs differing only between those bytes shared it.
// Checks: the two keys of the test ROMs; what was stored under the old key is
// copied to the new one once (a marker stops Forget from being undone, and is
// written only if every copy reached storage); two ROMs that shared an old key
// each get their own copy; the save card's game ID does not change; save states
// carry both ids and load with either or neither.
// usage: node romid_test.js page.html romdir
const fs = require('fs');
const path = require('path');
const { loadEmu } = require('./emuload');
const X = loadEmu(process.argv[2], { quiet: true });
const romdir = process.argv[3];
const E = n => X.evalInPage(n);
const store = E('store'), LS = E('localStorage');
const romLoaded = E('romLoaded'), gameId = E('gameId'), cfgSave = E('cfgSave'), saveState = E('saveState'), loadState = E('loadState');
const romHash = E('romHash'), romHashSampled = E('romHashSampled');
let bad = 0;
const ok = (name, cond, extra) => { console.log((cond ? 'PASS ' : 'FAIL ') + name + (extra ? '  ' + extra : '')); if (!cond) bad++; };
const rom = f => new Uint8Array(fs.readFileSync(path.join(romdir, f)));
const load = f => { const m = new X.Machine(); m.mode = 'sms'; m.reset(); const d = rom(f);
  m.loadCart(d.buffer.slice(d.byteOffset, d.byteOffset + d.length)); return [m, romLoaded(m)]; };
// the save card's game ID as every existing card holds it: from the old key
const oldGid = id => { let h = 0x811c9dc5; for (let i = 0; i < id.length; i++) { h ^= id.charCodeAt(i); h = (h * 0x01000193) >>> 0; } return h >>> 0; };

const a = rom('vdp224.sms'), b = rom('vdp192.sms');
ok('new keys differ', romHash(a) !== romHash(b), romHash(a) + ' ' + romHash(b));
ok('old keys collide (why they are replaced)', romHashSampled(a) === romHashSampled(b), romHashSampled(a));
const OLD = romHashSampled(a), NEW_A = romHash(a), NEW_B = romHash(b);

// stored under the old key
store.set('cfg_' + OLD, JSON.stringify({ ael: { sprlimit: true }, mode: 'sms', pal: false }));
store.set('cartsram_' + OLD, 'QUJD');
store.set('route_' + OLD, 'both');
let [m, r] = load('vdp224.sms');
ok('first load copies 3 items', r.moved === 3, 'moved ' + r.moved);
ok('settings restored from the copy', m.ael.sprlimit === true);
ok('copies under the new key', store.get('cfg_' + NEW_A) === store.get('cfg_' + OLD) && store.get('cartsram_' + NEW_A) === 'QUJD'
   && store.get('route_' + NEW_A) === 'both');
ok('marker written', store.get('romid_' + NEW_A) === OLD);
ok('old keys kept', store.get('cfg_' + OLD) !== null && store.get('cartsram_' + OLD) === 'QUJD');
store.del('cfg_' + NEW_A);                                     // Forget
[m, r] = load('vdp224.sms');
ok('Forget is not undone by the old key', r.moved === 0 && m.ael.sprlimit === false, 'moved ' + r.moved);
let mb; [mb, r] = load('vdp192.sms');
ok('the other ROM gets its own copy', r.moved === 3 && store.get('cfg_' + NEW_B) !== null);
mb.ael.sprlimit = false; mb.ael.stereo = true; cfgSave(mb);
ok("saving one ROM's settings leaves the other's", store.get('cfg_' + NEW_A) === null && JSON.parse(store.get('cfg_' + NEW_B)).ael.stereo === true);

// a copy that does not reach storage writes no marker
const SAVE = romHashSampled(rom('save.sms'));
store.set('cfg_' + SAVE, JSON.stringify({ ael: {}, mode: 'sms', pal: false }));
const real = LS.setItem; LS.setItem = () => { throw new Error('quota'); };
load('save.sms');
LS.setItem = real;
ok('no marker when a copy fails', store.get('romid_' + romHash(rom('save.sms'))) === null);

// the save card and save states
ok("the card's game ID is unchanged", gameId(m) === oldGid(OLD) && gameId(mb) === oldGid(OLD), '0x' + gameId(m).toString(16));
const st = saveState(m);
ok('a state carries both ids', st.v === 1 && st.id === NEW_A && st.idSampled === OLD);
let loaded = true;
try { const s1 = JSON.parse(JSON.stringify(st)); s1.id = OLD; loadState(m, s1);
      const s2 = JSON.parse(JSON.stringify(st)); delete s2.id; delete s2.idSampled; loadState(m, s2); } catch (e) { loaded = false; }
ok('a state loads with the old id or none', loaded);
console.log(bad ? `${bad} failed` : 'all passed');
process.exitCode = bad ? 1 : 0;
