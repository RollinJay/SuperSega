'use strict';
// Key and gamepad bindings, checked in headless Chromium with a simulated gamepad:
// keyboard and pad input merge, the default pad mapping, Select = Pause, the Pause key
// (one NMI per press, not per auto-repeat), click-to-bind,
// Esc to cancel, persistence across a reload, reset to defaults, and an unplugged
// pad releasing its buttons. Needs Playwright with Chromium.
// usage: node controls_test.js page.html rom.sms
const path = require('path');
const { chromium } = require('playwright');
const page_url = 'file://' + path.resolve(process.argv[2]);
const rom = path.resolve(process.argv[3]);
(async () => {
  const browser = await chromium.launch();
  const ctx = await browser.newContext();
  await ctx.addInitScript(() => {
    const mk = () => ({ id: 'Test pad (STANDARD GAMEPAD)', mapping: 'standard', connected: true,
      buttons: Array.from({ length: 17 }, () => ({ pressed: false, value: 0 })), axes: [0, 0, 0, 0] });
    window.__pad = mk();
    window.__padOn = true;
    navigator.getGamepads = () => [window.__padOn ? window.__pad : null];
  });
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', e => errors.push(e.message));
  await page.goto(page_url);
  const ok = (name, cond, extra) => { console.log((cond ? 'PASS ' : 'FAIL ') + name + (extra ? '  ' + extra : '')); if (!cond) process.exitCode = 1; };
  const frames = n => page.waitForTimeout(n * 20);
  const setBtn = (i, v) => page.evaluate(([i, v]) => { window.__pad.buttons[i] = { pressed: v, value: v ? 1 : 0 }; }, [i, v]);
  await page.setInputFiles('#cart', rom);
  await page.waitForTimeout(300);
  await page.click('#run');
  await frames(10);
  ok('pad detected', (await page.textContent('#padstat')).startsWith('gamepad:'));
  // keyboard held while the pad is connected and idle
  await page.keyboard.down('z'); await frames(10);
  ok('keyboard A survives pad polling', await page.evaluate(() => m.btn.a) === 1);
  await page.keyboard.up('z'); await frames(5);
  ok('keyboard A released', await page.evaluate(() => m.btn.a) === 0);
  // default pad mapping
  await setBtn(1, true); await frames(5);
  ok('pad right face -> A', await page.evaluate(() => m.btn.a) === 1);
  await page.keyboard.down('x'); await frames(5);
  ok('pad A and key B together', await page.evaluate(() => m.btn.a === 1 && m.btn.b === 1));
  await page.keyboard.up('x'); await setBtn(1, false); await frames(5);
  ok('both released', await page.evaluate(() => m.btn.a === 0 && m.btn.b === 0));
  await setBtn(0, true); await frames(5);
  ok('pad bottom face -> B', await page.evaluate(() => m.btn.b === 1 && m.btn.a === 0));
  await setBtn(0, false); await frames(5);
  await setBtn(3, true); await frames(5);
  ok('default C includes top face', await page.evaluate(() => m.btn.c) === 1);
  await setBtn(3, false);
  await page.evaluate(() => { window.__pad.axes = [0, -1, 0, 0]; }); await frames(5);
  ok('left stick up -> Up', await page.evaluate(() => m.btn.up) === 1);
  await page.evaluate(() => { window.__pad.axes = [0, 0, 0, 0]; }); await frames(5);
  // Select = Pause (NMI on the press edge only)
  await page.evaluate(() => { window.__nmi = 0; const f = m.cpu.nmi.bind(m.cpu); m.cpu.nmi = () => { window.__nmi++; f(); }; });
  await setBtn(8, true); await frames(10); await setBtn(8, false); await frames(5);
  ok('Select raises one NMI per press', await page.evaluate(() => window.__nmi) === 1, 'nmi=' + await page.evaluate(() => window.__nmi));
  // the Pause key (Tab): one NMI per press, not one per auto-repeat
  await page.evaluate(() => { window.__nmi = 0; });
  await page.keyboard.down('Tab');
  for (let i = 0; i < 8; i++) { await frames(2); await page.keyboard.down('Tab'); }   // repeats, as a held key sends
  await page.keyboard.up('Tab'); await frames(5);
  ok('Pause key held raises one NMI', await page.evaluate(() => window.__nmi) === 1, 'nmi=' + await page.evaluate(() => window.__nmi));
  // rebind A to R1 (button 5) while running
  await page.evaluate(() => document.querySelector('button[data-padbind="a"]').click());
  await frames(3);
  ok('bind prompt shown', (await page.evaluate(() => document.querySelector('button[data-padbind="a"]').textContent)).includes('press a pad button'));
  await setBtn(5, true); await frames(5); await setBtn(5, false); await frames(5);
  ok('A rebound to R1', await page.evaluate(() => JSON.stringify(PADBIND.a)) === '[5]');
  ok('binding stored', (await page.evaluate(() => localStorage.getItem('ss_padbinds') || '')).includes('"a":[5]'));
  await setBtn(5, true); await frames(5);
  ok('R1 now presses A', await page.evaluate(() => m.btn.a) === 1);
  await setBtn(5, false); await setBtn(1, true); await frames(5);
  ok('right face no longer A', await page.evaluate(() => m.btn.a) === 0);
  await setBtn(1, false);
  // Esc cancels a pad binding
  await page.evaluate(() => document.querySelector('button[data-padbind="b"]').click());
  await page.keyboard.press('Escape'); await setBtn(6, true); await frames(5); await setBtn(6, false);
  ok('Esc cancels', await page.evaluate(() => padBindWait === null && JSON.stringify(PADBIND.b) === '[0]'));
  // keyboard rebinding still works
  await page.evaluate(() => document.querySelector('button[data-bind="c"]').click());
  await page.keyboard.press('v'); await frames(2);
  ok('key C rebound to v', await page.evaluate(() => BIND.c) === 'v');
  // persists across reload
  await page.reload(); await page.waitForTimeout(300);
  ok('pad binding persists', await page.evaluate(() => JSON.stringify(PADBIND.a)) === '[5]');
  ok('key binding persists', await page.evaluate(() => BIND.c) === 'v');
  // reset to defaults
  await page.click('#bindreset', { force: true }).catch(() => page.evaluate(() => document.getElementById('bindreset').click()));
  ok('reset restores defaults', await page.evaluate(() => JSON.stringify(PADBIND) === JSON.stringify(DEFPAD) && BIND.c === 'c'));
  ok('defaults stored', await page.evaluate(() => localStorage.getItem('ss_padbinds') === JSON.stringify(DEFPAD)));
  // pad unplugged: its buttons release
  await page.setInputFiles('#cart', rom); await page.waitForTimeout(200);
  await page.click('#run'); await setBtn(1, true); await frames(5);
  ok('pad A held before unplug', await page.evaluate(() => m.btn.a) === 1);
  await page.evaluate(() => { window.__padOn = false; }); await frames(5);
  ok('unplugged pad releases its buttons', await page.evaluate(() => m.btn.a) === 0);
  ok('no page errors', errors.length === 0, errors.join(' | '));
  await browser.close();
})().catch(e => { console.error(e); process.exit(2); });
