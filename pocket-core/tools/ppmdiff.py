#!/usr/bin/env python3
"""Compare two PPM frames pixel for pixel.

usage: ppmdiff.py a.ppm b.ppm [side_by_side.png] [--tol N]

Prints the number of differing pixels and their bounding box. With a third
argument, writes A | B | difference mask (x2) as a PNG for inspection.
--tol N treats channel differences up to N as equal. Gearsystem expands Game
Gear 4-bit channels through its own table (5 -> 86, not 85), so Game Gear
frames are compared with --tol 2; Master System frames match exactly.
Exit status 0 when identical, 1 when different, 2 on a size mismatch.
"""
import sys
import numpy as np
from PIL import Image


def load(p):
    im = Image.open(p).convert("RGB")
    return np.asarray(im)


def main():
    args = sys.argv[1:]
    tol = 0
    if '--tol' in args:
        i = args.index('--tol'); tol = int(args[i + 1]); del args[i:i + 2]
    sys.argv = [sys.argv[0]] + args
    a, b = load(sys.argv[1]), load(sys.argv[2])
    if a.shape != b.shape:
        print(f"size differs: {a.shape[1]}x{a.shape[0]} vs {b.shape[1]}x{b.shape[0]}")
        return 2
    d = np.any(np.abs(a.astype(int) - b.astype(int)) > tol, axis=2)
    n = int(d.sum())
    if n:
        ys, xs = np.nonzero(d)
        print(f"diff {n} px  x {xs.min()}..{xs.max()}  y {ys.min()}..{ys.max()}")
    else:
        print("diff 0 px")
    if len(sys.argv) > 3:
        h, w = d.shape
        mask = np.zeros((h, w, 3), np.uint8)
        mask[d] = (255, 0, 255)
        out = np.concatenate([a, np.full((h, 4, 3), 128, np.uint8), b,
                              np.full((h, 4, 3), 128, np.uint8), mask], axis=1)
        Image.fromarray(out).resize((out.shape[1] * 2, h * 2), Image.NEAREST).save(sys.argv[3])
    return 1 if n else 0


if __name__ == "__main__":
    sys.exit(main())
