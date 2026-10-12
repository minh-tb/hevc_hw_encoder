import sys

def morton(x, y):
    res = 0
    for i in range(4):
        res |= ((y >> i) & 1) << (2 * i + 1)
        res |= ((x >> i) & 1) << (2 * i)
    return res

def check_bl(x, y, n, pic_y, ctu_x, frame_h=128):
    bl_y = y + n
    if pic_y + n >= frame_h: return 0
    if bl_y >= 64: return 0
    if x == 0: return 1 if ctu_x > 0 else 0
    return 1 if (morton((x - 1) >> 2, bl_y >> 2) < morton(x >> 2, y >> 2)) else 0

def check_tr(x, y, n, pic_x, ctu_x, ctu_y, frame_w=128):
    tr_x = x + n
    if pic_x + n >= frame_w: return 0
    if y == 0: return 1 if ctu_y > 0 else 0
    if tr_x >= 64: return 0
    return 1 if (morton(tr_x >> 2, (y - 1) >> 2) < morton(x >> 2, y >> 2)) else 0

total = 0
with open("tb/tb_spatial_availability/golden_vectors.txt", "w") as f:
    for ctu_y in range(2):
        for ctu_x in range(2):
            for N in [32, 16, 8, 4]:
                for y in range(0, 64, N):
                    for x in range(0, 64, N):
                        pic_x = ctu_x * 64 + x
                        pic_y = ctu_y * 64 + y
                        bl = check_bl(x, y, N, pic_y, ctu_x)
                        tr = check_tr(x, y, N, pic_x, ctu_x, ctu_y)
                        f.write(f"{ctu_x} {ctu_y} {N} {x} {y} {bl} {tr}\n")
                        total += 1

print(f"Generated {total} test vectors across all 4 CTUs (340 blocks per CTU).")
