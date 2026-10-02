import random
import os
import sys

# Ensure tb_transform is on python path to load gen_ref_vectors
script_dir = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, script_dir)
from gen_ref_vectors import oned

random.seed(7)

def mat(N, mode):
    def v():
        if mode == 0: return random.randint(-255, 255)
        if mode == 1: return random.randint(-32768, 32767)
        if mode == 2: return random.choice([-32768, 32767])
        if mode == 3: return 32767
        if mode == 4: return -32768
        if mode == 6: return random.randint(-1023, 1023)
        if mode == 7: return random.randint(-60, 60)
        return 0

    if mode == 5:
        M = [[0]*N for _ in range(N)]
        for _ in range(random.randint(1, 4)):
            M[random.randrange(N)][random.randrange(N)] = random.randint(-6000, 6000)
        return M

    return [[v() for _ in range(N)] for _ in range(N)]

def tr2d(X, fwd, log2):
    N = 1 << log2
    if fwd:
        Y = [oned(X[j], 1, log2, 0, 0)[:N] for j in range(N)]          # Y[j][k]
        Z = [oned([Y[j][k] for j in range(N)], 1, log2, 0, 1)[:N] for k in range(N)]  # Z[k][n]
        return [[Z[k][n] for k in range(N)] for n in range(N)]    # out[n][k]
    else:
        T = [oned([X[kv][j] for kv in range(N)], 0, log2, 0, 0)[:N] for j in range(N)]  # T[j][n] (j=horiz freq idx)
        B = [oned([T[r][c] for r in range(N)], 0, log2, 0, 1)[:N] for c in range(N)]   # B[c][m]
        return B                                                  # block[row c][col m]

cnt = 0
out_path = os.path.join(script_dir, 'vec2d.hex')
with open(out_path, 'w') as f:
    for log2 in (2, 3, 4, 5):
        N = 1 << log2
        for fwd in (1, 0):
            for mode, reps in ((0, 12), (1, 8), (2, 6), (3, 1), (4, 1), (5, 8), (6, 8), (7, 6)):
                for _ in range(reps):
                    X = mat(N, mode)
                    Y = tr2d(X, fwd, log2)
                    ib = [[random.randint(-32768, 32767) for _ in range(32)] for _ in range(32)]  # garbage outside NxN
                    for r in range(N):
                        for c in range(N):
                            ib[r][c] = X[r][c]
                    ob = [[0]*32 for _ in range(32)]
                    for r in range(N):
                        for c in range(N):
                            ob[r][c] = Y[r][c]
                    f.write('%x %x\n' % (fwd, log2))
                    f.write(' '.join('%04x' % (ib[r][c] & 0xffff) for r in range(32) for c in range(32)) + '\n')
                    f.write(' '.join('%04x' % (ob[r][c] & 0xffff) for r in range(32) for c in range(32)) + '\n')
                    cnt += 1

print(f"Generated {cnt} matrices to {out_path}")