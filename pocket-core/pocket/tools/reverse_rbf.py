#!/usr/bin/env python3
"""Make the Analogue Pocket bitstream: reverse the bit order of every byte of
Quartus's .rbf. usage: reverse_rbf.py ap_core.rbf bitstream.rbf_r"""
import sys
data = open(sys.argv[1], 'rb').read()
table = bytes(int(f'{b:08b}'[::-1], 2) for b in range(256))
open(sys.argv[2], 'wb').write(data.translate(table))
print(f'{len(data)} bytes -> {sys.argv[2]}')
