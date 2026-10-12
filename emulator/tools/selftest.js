'use strict';
// Runs the page's own Debug-tab self-test headless and prints the report.
const { loadEmu } = require('./emuload');
const X = loadEmu(process.argv[2], { quiet: true });
const st = X.extractFn('dbgSelfTest');
const R = st();
let ok = 0;
for (const r of R) { if (r.ok) ok++; console.log((r.ok ? 'PASS ' : 'FAIL ') + r.group.padEnd(8) + r.name.padEnd(32) + r.detail); }
console.log(ok + ' of ' + R.length + ' pass');
process.exit(ok === R.length ? 0 : 1);
