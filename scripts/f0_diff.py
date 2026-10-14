#!/usr/bin/env python3
"""
f0_diff.py - Fast frame spatial difference and mismatch mapper.
Compares hardware reconstruction (hw_recon.yuv) against HM decoder output (dec_gate.yuv or dec_foreman.yuv).
Usage:
    python f0_diff.py [frame_idx] [hw_recon.yuv] [dec_gate.yuv]
"""

import os
import sys
import struct

W = H = 128
N = W * H * 3 // 2

def load(path):
    if not os.path.exists(path):
        raise FileNotFoundError(f"File not found: {path}")
    data = open(path, 'rb').read()
    return struct.unpack(f"<{len(data) // 2}H", data)

def main():
    f_idx = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    hw_path = sys.argv[2] if len(sys.argv) > 2 else 'hw_recon.yuv'
    dec_path = sys.argv[3] if len(sys.argv) > 3 else ('dec_gate.yuv' if os.path.exists('dec_gate.yuv') else 'dec_foreman.yuv')

    if not os.path.exists(hw_path):
        print(f"Error: {hw_path} not found.")
        return 1
    if not os.path.exists(dec_path):
        print(f"Error: {dec_path} not found.")
        return 1

    a = load(hw_path)
    b = load(dec_path)

    A = a[f_idx * N : (f_idx + 1) * N]
    B = b[f_idx * N : (f_idx + 1) * N]

    if len(A) < N or len(B) < N:
        print(f"Error: Incomplete frame {f_idx} (A has {len(A)}, B has {len(B)}, needed {N})")
        return 1

    for name, s, w in (('Y', 0, W), ('Cb', W * H, W // 2), ('Cr', W * H * 5 // 4, W // 2)):
        h = w
        cs = w // 2
        d = [[abs(A[s + y * w + x] - B[s + y * w + x]) for x in range(w)] for y in range(h)]
        flat = [v for r in d for v in r]
        ctu = []
        for cy in (0, cs):
            for cx in (0, cs):
                blk = [d[y][x] for y in range(cy, cy + cs) for x in range(cx, cx + cs)]
                ctu.append(round(sum(blk) / len(blk), 2))
        
        print('%-2s exact=%.1f%% max=%d per-CTU mean(TL,TR,BL,BR)=%s' % (
            name, 100 * flat.count(0) / len(flat), max(flat), ctu
        ))

        if name == 'Y':
            first = next(((x, y) for y in range(h) for x in range(w) if d[y][x]), None)
            if first:
                x, y = first
                print('   first Y mismatch (raster): x=%d y=%d hw=%d hm=%d' % (x, y, A[y * w + x], B[y * w + x]))
            print('   Y mismatch map, 8x8 blocks of CTU0 (1 = any diff):')
            for by in range(8):
                print('   ' + ''.join('1' if any(d[y][x] for y in range(by * 8, by * 8 + 8) for x in range(bx * 8, bx * 8 + 8)) else '.' for bx in range(8)))

    return 0

if __name__ == '__main__':
    sys.exit(main())
