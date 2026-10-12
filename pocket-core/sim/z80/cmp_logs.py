#!/usr/bin/env python3
"""Compare the RTL Z80 wrapper's instruction starts with the emulator's.

usage: cmp_logs.py z80_js.log z80_rtl.log

z80_js.log (gen_prog.js) holds one line per instruction: "M1 <T-state> <PC>".
z80_rtl.log (tb_z80.v) holds a line for every M1 cycle, prefix bytes included,
and one per I/O access. Each expected instruction start must appear as an RTL
M1 at the same PC and the same T-state, counted from the first instruction
(the RTL leaves reset a few T-states after the emulator's T-state 0).
"""
import sys

js = [l.split() for l in open(sys.argv[1]) if l.startswith('M1')]
rtl = [l.split() for l in open(sys.argv[2]) if l.startswith('M1')]
js = [(int(t), int(pc, 16)) for _, t, pc in js]
rtl = [(int(t), int(pc, 16)) for _, t, pc in rtl]
off = rtl[0][0] - js[0][0]
k = 0
for n, (t, pc) in enumerate(js):
    while k < len(rtl) and rtl[k][1] != pc:      # skip prefix M1s inside an instruction
        k += 1
    if k == len(rtl):
        print(f'instruction {n} at PC {pc:04x}: not found in the RTL log'); sys.exit(1)
    if rtl[k][0] - off != t:
        print(f'instruction {n} at PC {pc:04x}: emulator T-state {t}, RTL {rtl[k][0] - off}'); sys.exit(1)
    k += 1
print(f'{len(js)} instruction starts match (RTL offset {off} T-states from reset)')
