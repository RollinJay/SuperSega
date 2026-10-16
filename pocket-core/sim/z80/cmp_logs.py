#!/usr/bin/env python3
"""Compare the RTL Z80 wrapper's instruction starts with the emulator's.

usage: cmp_logs.py z80_js.log z80_rtl.log

z80_js.log (gen_prog.js) holds one line per instruction, "M1 <T-state> <PC>",
and one per port access, "IO <T-state> <port> <0 in / 1 out> <value>".
z80_rtl.log (tb_z80.v) holds a line for every M1 cycle, prefix bytes included,
and one per I/O access. Each expected instruction start must appear as an RTL
M1 at the same PC and the same T-state, counted from the first instruction
(the RTL leaves reset a few T-states after the emulator's T-state 0). The port
accesses must be the same, in order (16-bit port address, direction, value),
and each must come at the same point of its instruction: the RTL's io_sample
fires a fixed IO_LAG T-states before the point at which the emulator counts the
access (the end of its I/O cycle), for every instruction alike.
"""
import sys

IO_LAG = 2

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
jio = [l.split() for l in open(sys.argv[1]) if l.startswith('IO')]
rio = [l.split() for l in open(sys.argv[2]) if l.startswith('IO')]
if len(jio) != len(rio):
    print(f'port accesses: emulator {len(jio)}, RTL {len(rio)}'); sys.exit(1)
for n, (j, r) in enumerate(zip(jio, rio)):
    jt, rt = int(j[1]), int(r[1]) - off
    what = f'port access {n} ({j[2]} {"out" if j[3] == "1" else "in"})'
    if j[2:] != r[2:]:
        print(f'{what}: emulator {" ".join(j[2:])}, RTL {" ".join(r[2:])}'); sys.exit(1)
    if jt - rt != IO_LAG:
        print(f'{what}: emulator T {jt}, RTL T {rt} + {IO_LAG}'); sys.exit(1)
print(f'{len(js)} instruction starts and {len(jio)} port accesses match (RTL offset {off} T-states from reset)')
