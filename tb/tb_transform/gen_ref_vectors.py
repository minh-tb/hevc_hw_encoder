import math
import random

params = {
    'a': 64,
    'b': 83, 'c': 36,
    'd': 89, 'e': 75, 'f': 50, 'g': 18,
    'h': 90, 'i': 87, 'j': 80, 'k': 70, 'l': 57, 'm': 43, 'n': 25, 'o': 9,
    'p': 90, 'q': 90, 'r': 88, 's': 85, 't': 82, 'u': 78, 'v': 73, 'w': 67,
    'x': 61, 'y': 54, 'z': 46, 'A': 38, 'B': 31, 'C': 22, 'D': 13, 'E': 4
}

with open('HM/source/Lib/TLibCommon/TComRom.cpp') as f:
    lines = f.readlines()

def parse_matrix(start_line, num_rows):
    mat = []
    for line_idx in range(start_line, start_line + num_rows + 10):
        line = lines[line_idx].strip()
        if line.startswith('{'):
            content = line[line.find('{')+1 : line.find('}')]
            tokens = [tok.strip() for tok in content.split(',') if tok.strip()]
            row = []
            for tok in tokens:
                sign = 1
                if tok.startswith('-'):
                    sign = -1
                    tok = tok[1:]
                row.append(sign * params[tok])
            mat.append(row)
            if len(mat) == num_rows:
                break
    return mat

mat4 = parse_matrix(377, 4)
mat8 = parse_matrix(385, 8)
mat16 = parse_matrix(397, 16)
mat32 = parse_matrix(417, 32)

def clip_s16(val):
    if val > 32767:
        return 32767
    elif val < -32768:
        return -32768
    return val

def ashr(val, shift):
    return val >> shift

BIT_DEPTH = 10
FWD_SHIFT_OFFSET = BIT_DEPTH - 9 # 1

def fwd_dst7(src, is_second_pass):
    c0 = src[0] + src[3]
    c1 = src[1] + src[3]
    c2 = src[0] - src[1]
    c3 = 74 * src[2]
    dst = [0]*4
    dst[0] = 29 * c0 + 55 * c1 + c3
    dst[1] = 74 * (src[0] + src[1] - src[3])
    dst[2] = 29 * c2 + 55 * c0 - c3
    dst[3] = 55 * c2 - 29 * c1 + c3
    shift = 2 + FWD_SHIFT_OFFSET if not is_second_pass else 2 + 6
    rnd = 1 << (shift - 1)
    return [clip_s16(ashr(d + rnd, shift)) for d in dst]

def inv_dst7(src, is_second_pass):
    c0 = src[0] + src[2]
    c1 = src[2] + src[3]
    c2 = src[0] - src[3]
    c3 = 74 * src[1]
    dst = [0]*4
    dst[0] = 29 * c0 + 55 * c1 + c3
    dst[1] = 55 * c2 - 29 * c1 + c3
    dst[2] = 74 * (src[0] - src[2] + src[3])
    dst[3] = 55 * c0 + 29 * c2 - c3
    shift = 7 if not is_second_pass else 20 - BIT_DEPTH
    rnd = 1 << (shift - 1)
    return [clip_s16(ashr(d + rnd, shift)) for d in dst]

def mat_vec_mul(mat, vec):
    res = []
    for row in mat:
        s = sum(row[j] * vec[j] for j in range(len(vec)))
        res.append(s)
    return res

def mat_t_vec_mul(mat, vec):
    res = []
    num_cols = len(mat[0])
    for j in range(num_cols):
        s = sum(mat[i][j] * vec[i] for i in range(len(vec)))
        res.append(s)
    return res

def fwd_dct(src, N, is_second_pass):
    mat = {4: mat4, 8: mat8, 16: mat16, 32: mat32}[N]
    log2N = int(math.log2(N))
    shift = log2N + FWD_SHIFT_OFFSET if not is_second_pass else log2N + 6
    rnd = 1 << (shift - 1)
    dst = mat_vec_mul(mat, src[:N])
    return [clip_s16(ashr(d + rnd, shift)) for d in dst]

def inv_dct(src, N, is_second_pass):
    mat = {4: mat4, 8: mat8, 16: mat16, 32: mat32}[N]
    shift = 7 if not is_second_pass else 20 - BIT_DEPTH
    rnd = 1 << (shift - 1)
    dst = mat_t_vec_mul(mat, src[:N])
    return [clip_s16(ashr(d + rnd, shift)) for d in dst]

def oned(src, fwd, log2, is_dst7, is_second_pass):
    N = 1 << log2
    if is_dst7 and log2 == 2:
        res = fwd_dst7(src, is_second_pass) if fwd else inv_dst7(src, is_second_pass)
    else:
        res = fwd_dct(src, N, is_second_pass) if fwd else inv_dct(src, N, is_second_pass)
    return res + [0] * (32 - len(res))

random.seed(0)
