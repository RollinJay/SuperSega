#!/usr/bin/env python3
"""Decode a frame of the ports.sms test ROM (mk_testrom.py) into port values.

usage: read_ports_ppm.py frame.ppm [other.ppm]

Each row of the screen holds a port number (grey cells, columns 6-13) and the
value read from it (columns 16-23), rows 3-20. A 160x144 frame is taken as the
Game Gear window (offset 48, 24). With two frames, rows that differ are marked.
"""
import sys


def read_ppm(path):
    b = open(path, 'rb').read()
    tok, i = [], 0
    while len(tok) < 4:
        while b[i] <= 32: i += 1
        s = i
        while b[i] > 32: i += 1
        tok.append(b[s:i].decode())
    i += 1
    w, h = int(tok[1]), int(tok[2])
    return w, h, b[i:]


def decode(path):
    w, h, d = read_ppm(path)
    ox, oy = (48, 24) if (w, h) == (160, 144) else (0, 0)
    def px(x, y):
        o = ((y - oy) * w + (x - ox)) * 3
        return tuple(d[o:o + 3])
    bg = px(14 * 8 + 4, 3 * 8 + 4)                      # a cell that is always blank
    rows = []
    for r in range(3, 21):
        y = r * 8 + 4
        def byte(col0):
            v = 0
            for k in range(8):
                v = (v << 1) | (px((col0 + k) * 8 + 4, y) != bg)
            return v
        rows.append((byte(6), byte(16)))
    return rows


a = decode(sys.argv[1])
b = decode(sys.argv[2]) if len(sys.argv) > 2 else None
for i, (port, val) in enumerate(a):
    line = f'${port:02X}: ${val:02X}'
    if b:
        line += f'   ${b[i][1]:02X}' + ('' if b[i] == a[i] else '   <- differs')
    print(line)
