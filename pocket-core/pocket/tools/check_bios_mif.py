#!/usr/bin/env python3
"""Check that Quartus built the BIOS ROM from the BIOS image.

usage: check_bios_mif.py <Quartus project directory> <mdr_bios.hex>

rtl/mdr_mem.v loads the BIOS ROM with $readmemh from a path relative to the
Quartus project. If Quartus cannot read the file, the ROM can come out empty
and the core shows nothing at all. Quartus writes each block RAM's contents to
db/*.mif; this finds the 8 KB one of mdr_mem and compares it, byte by byte,
with the image.
"""
import glob
import os
import re
import sys


def mif_bytes(path):
    text = open(path).read()
    depth = int(re.search(r'DEPTH\s*=\s*(\d+)', text).group(1))
    radix = re.search(r'DATA_RADIX\s*=\s*(\w+)', text).group(1).upper()
    base = {'BIN': 2, 'HEX': 16, 'UNS': 10, 'DEC': 10}[radix]
    data = [None] * depth
    body = text.split('CONTENT BEGIN', 1)[1].split('END;', 1)[0]
    for m in re.finditer(r'(\[\s*(\d+)\s*\.\.\s*(\d+)\s*\]|(\d+))\s*:\s*([0-9A-Fa-f]+)\s*;', body):
        lo, hi = (int(m.group(2)), int(m.group(3))) if m.group(2) else (int(m.group(4)),) * 2
        for a in range(lo, hi + 1):
            data[a] = int(m.group(5), base)
    return data


def main():
    proj, hexfile = sys.argv[1], sys.argv[2]
    want = [int(x, 16) for x in open(hexfile).read().split()]
    found = [p for p in glob.glob(os.path.join(proj, 'db', '*mdr_mem*.mif'))
             if re.search(r'DEPTH\s*=\s*%d\b' % len(want), open(p).read())]
    if len(found) != 1:
        sys.exit(f'BIOS ROM: expected one {len(want)}-byte mdr_mem block RAM file in {proj}/db, found {found}')
    got = mif_bytes(found[0])
    bad = sum(1 for g, w in zip(got, want) if g != w)
    if bad:
        sys.exit(f'BIOS ROM: {os.path.basename(found[0])} differs from {hexfile} in {bad} bytes')
    print(f'BIOS ROM: {os.path.basename(found[0])} holds the {len(want)}-byte image')


if __name__ == '__main__':
    main()
