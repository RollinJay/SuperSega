'use strict';
/* Headless loader for the MasterDrive emulator.
   Runs the page's single <script> inside a vm context whose DOM is a permissive
   stub, then exposes the machine classes and helpers on the returned object.
   Used by the conformance probes and by the RTL vector generators: the machine
   model is exercised exactly as the page runs it, with no copy of its code. */
const fs = require('fs');
const vm = require('vm');

function makeStub(name) {
  // Every property read returns another stub; every call returns a stub;
  // property writes are kept so code that reads back what it set still works.
  const store = new Map();
  const fn = function () { return makeStub(name + '()'); };
  return new Proxy(fn, {
    get(t, k) {
      if (k === Symbol.toPrimitive) return () => '';
      if (k === 'toString' || k === 'valueOf') return () => '';
      if (k === Symbol.iterator) return function* () {};
      if (store.has(k)) return store.get(k);
      if (k === 'length') return 0;
      if (k === 'value') return '';
      if (k === 'checked') return false;
      if (k === 'textContent' || k === 'innerHTML') return '';
      if (k === 'then') return undefined;           // not a thenable
      return makeStub(name + '.' + String(k));
    },
    set(t, k, v) { store.set(k, v); return true; },
    apply() { return makeStub(name + '()'); },
    construct() { return makeStub('new ' + name); },
  });
}

function loadEmu(htmlPath, opts) {
  opts = opts || {};
  const html = fs.readFileSync(htmlPath, 'utf8');
  const a = html.indexOf('<script>'), b = html.lastIndexOf('</script>');
  if (a < 0 || b < 0) throw new Error('no script block');
  const code = html.slice(a + 8, b);
  const ls = new Map();
  const doc = makeStub('document');
  const ctx = {
    console: opts.quiet ? { log() {}, warn() {}, error() {} } : console,
    document: doc,
    navigator: { getGamepads: () => [], userAgent: 'node' },
    localStorage: {
      getItem: k => (ls.has(k) ? ls.get(k) : null),
      setItem: (k, v) => ls.set(k, String(v)),
      removeItem: k => ls.delete(k),
    },
    requestAnimationFrame: () => 0,
    cancelAnimationFrame: () => {},
    setTimeout: () => 0, clearTimeout: () => {},
    setInterval: () => 0, clearInterval: () => {},
    performance: { now: () => Date.now() },
    addEventListener: () => {},
    removeEventListener: () => {},
    btoa: s => Buffer.from(s, 'binary').toString('base64'),
    atob: s => Buffer.from(s, 'base64').toString('binary'),
    Image: function () { return makeStub('Image'); },
    Blob: function () { return makeStub('Blob'); },
    URL: { createObjectURL: () => '', revokeObjectURL: () => {} },
    alert: () => {}, confirm: () => false, prompt: () => null,
    TextEncoder, TextDecoder,
    Uint8Array, Uint16Array, Uint32Array, Int8Array, Int16Array, Int32Array,
    Float32Array, Float64Array, Uint8ClampedArray, ArrayBuffer, DataView,
    Math, JSON, Date, Map, Set, WeakMap, Promise, Symbol, Proxy, Reflect,
    Number, String, Boolean, Array, Object, Error, RegExp, parseInt, parseFloat,
    isNaN, isFinite,
  };
  ctx.window = ctx; ctx.self = ctx; ctx.globalThis = ctx;
  vm.createContext(ctx);
  vm.runInContext(code, ctx, { filename: 'masterdrive-emulator.js' });
  // Top-level class/const bindings live in the context's script scope; a second
  // script in the same context can see them and copy them out.
  vm.runInContext(`globalThis.__X = {
    Z80, VDP, PSG, FM, Machine, parseSegaHeader, makeKeyboard, makePointer,
    makeFpga, makeFDC, makeDebugUnit, makeSF7000, CYC,
    m: (typeof m!=='undefined')?m:null };`, ctx);
  const X = ctx.__X;
  // Run extra code in the page's scope (sees its top-level declarations).
  X.evalInPage = src => vm.runInContext(src, ctx);
  // Pull a function declared inside a block (e.g. the Debug tab's self-test)
  // out of the page source and evaluate it at page scope.
  X.extractFn = name => {
    const i = code.indexOf('function ' + name + '(');
    if (i < 0) throw new Error('no function ' + name);
    let j = code.indexOf('{', i), depth = 0, k = j;
    for (; k < code.length; k++) {
      const c = code[k];
      if (c === '{') depth++;
      else if (c === '}') { depth--; if (depth === 0) break; }
    }
    return vm.runInContext('(' + code.slice(i, k + 1) + ')', ctx);
  };
  return X;
}

function newMachine(X, mode, romBytes) {
  const m = new X.Machine();
  m.mode = mode;
  m.reset();
  if (romBytes) {
    const ab = romBytes.buffer.slice(romBytes.byteOffset, romBytes.byteOffset + romBytes.length);
    m.loadCart(ab);
    m.mode = mode;          // loadCart resets; keep the requested mode
  }
  return m;
}

module.exports = { loadEmu, newMachine };
