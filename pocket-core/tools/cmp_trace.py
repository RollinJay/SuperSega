#!/usr/bin/env python3
"""Compare an instruction trace with a Gearsystem trace by cycle count.

usage: cmp_trace.py trace.bin gs_trace.bin
The first trace comes from the emulator (emulator/tools/jstrace.js) or the RTL
(sim/sys/tb_mdr -trace); the second from sim/ref/gstrace. In the text below,
"JS" means the first trace.
Gearsystem splits I/O instructions so it can sync the VDP mid-instruction, which
adds records at cycle counts that are not instruction boundaries; so every JS
record (an instruction boundary) must find a Gearsystem record at the same cycle
with the same PC and SP. Reports the first that does not."""
import struct, sys
a = open(sys.argv[1], 'rb').read(); b = open(sys.argv[2], 'rb').read()
R = lambda d, i: struct.unpack_from('<HHBBIH', d, i * 12)
na, nb = len(a) // 12, len(b) // 12
gs = {}
wrap = 0; last = 0
for i in range(nb):
    pc, sp, A, F, cyc, vc = R(b, i)
    if cyc < last: wrap += 1 << 32
    last = cyc
    gs.setdefault(cyc + wrap, (pc, sp, A, i))
wrap = 0; last = 0; checked = 0; gmax = max(gs)
for i in range(na):
    pc, sp, A, F, cyc, vc = R(a, i)
    if cyc < last: wrap += 1 << 32
    last = cyc; c = cyc + wrap
    if c > gmax: break
    g = gs.get(c)
    if g is None or g[0] != pc or g[1] != sp:
        print(f'first divergence at JS record {i}, cycle {c}: JS pc={pc:04x} sp={sp:04x} vc={vc:02x}; GS at that cycle: {g}')
        lo = max(0, i - 8)
        for j in range(lo, i + 3):
            print('  JS', j, '%04x %04x a=%02x f=%02x cyc=%d vc=%02x' % R(a, j))
        gi = g[3] if g else None
        if gi is None:
            # nearest GS record
            near = min(gs, key=lambda k: abs(k - c)); gi = gs[near][3]
        for j in range(max(0, gi - 8), gi + 3):
            print('  GS', j, '%04x %04x a=%02x f=%02x cyc=%d vc=%02x' % R(b, j))
        sys.exit(1)
    checked += 1
print(f'{checked} JS instruction boundaries all match Gearsystem (PC, SP, cycle)')
