"""
generate_stress_patterns.py
Generates synthetic 10-bit YUV test patterns for corner-case stress testing:
1. Flat Field (Y=512, U=512, V=512) -> Tests CBF=0, all-skip/all-zero residual behavior.
2. Max-Contrast Checkerboard (0 <-> 1023 alternating) -> Tests max AC transform energy & 16-bit clipping.
3. High-Motion Panning (Foreman with rapid +/-32 pixel spatial shifts) -> Tests full-range ME & MVD bounds.
Outputs raw 10-bit hex files formatted for Verilog $readmemh.
"""

import os
import struct

WIDTH = 128
HEIGHT = 128
FRAMES = 5
FRAME_Y_SIZE = WIDTH * HEIGHT       # 16,384
FRAME_C_SIZE = (WIDTH//2)*(HEIGHT//2)# 4,096

def generate_flat_field():
    print("Generating Flat Field (512 mid-gray)...")
    total_y = FRAME_Y_SIZE * FRAMES
    total_c = FRAME_C_SIZE * FRAMES
    with open("flat_y.hex", "w") as fy, open("flat_u.hex", "w") as fu, open("flat_v.hex", "w") as fv:
        for _ in range(total_y):
            fy.write("200\n")  # 512 in hex = 0x200
        for _ in range(total_c):
            fu.write("200\n")
            fv.write("200\n")

    # Also dump binary YUV for HM reference decoder/metrics
    with open("flat_128x128_10b.yuv", "wb") as f:
        y_bytes = struct.pack(f"<{FRAME_Y_SIZE}H", *([512]*FRAME_Y_SIZE))
        u_bytes = struct.pack(f"<{FRAME_C_SIZE}H", *([512]*FRAME_C_SIZE))
        v_bytes = struct.pack(f"<{FRAME_C_SIZE}H", *([512]*FRAME_C_SIZE))
        for _ in range(FRAMES):
            f.write(y_bytes)
            f.write(u_bytes)
            f.write(v_bytes)
    print("  -> flat_y.hex, flat_u.hex, flat_v.hex, flat_128x128_10b.yuv created.")

def generate_checkerboard():
    print("Generating Maximum-Contrast Checkerboard (0 <-> 1023)...")
    total_y = []
    total_u = []
    total_v = []
    for f in range(FRAMES):
        for y in range(HEIGHT):
            for x in range(WIDTH):
                val = 1023 if ((x ^ y) & 1) else 0
                total_y.append(val)
        for y in range(HEIGHT // 2):
            for x in range(WIDTH // 2):
                u_val = 1023 if ((x ^ y) & 1) else 0
                v_val = 0 if ((x ^ y) & 1) else 1023
                total_u.append(u_val)
                total_v.append(v_val)

    with open("checker_y.hex", "w") as fy, open("checker_u.hex", "w") as fu, open("checker_v.hex", "w") as fv:
        for val in total_y:
            fy.write(f"{val:03x}\n")
        for val in total_u:
            fu.write(f"{val:03x}\n")
        for val in total_v:
            fv.write(f"{val:03x}\n")

    with open("checker_128x128_10b.yuv", "wb") as f:
        for f_idx in range(FRAMES):
            y_plane = total_y[f_idx*FRAME_Y_SIZE:(f_idx+1)*FRAME_Y_SIZE]
            u_plane = total_u[f_idx*FRAME_C_SIZE:(f_idx+1)*FRAME_C_SIZE]
            v_plane = total_v[f_idx*FRAME_C_SIZE:(f_idx+1)*FRAME_C_SIZE]
            f.write(struct.pack(f"<{FRAME_Y_SIZE}H", *y_plane))
            f.write(struct.pack(f"<{FRAME_C_SIZE}H", *u_plane))
            f.write(struct.pack(f"<{FRAME_C_SIZE}H", *v_plane))
    print("  -> checker_y.hex, checker_u.hex, checker_v.hex, checker_128x128_10b.yuv created.")

def generate_high_motion():
    print("Generating High-Motion Video Pattern (Rapid +/-32 pixel spatial translation)...")
    # Base pattern: circular gradient with high texture
    total_y = []
    total_u = []
    total_v = []
    
    # Rapid displacements per frame: (0,0), (+24, -16), (-32, +28), (+16, +32), (-28, -24)
    shifts = [(0, 0), (24, -16), (-32, 28), (16, 32), (-28, -24)]

    for f_idx in range(FRAMES):
        dx, dy = shifts[f_idx]
        for y in range(HEIGHT):
            for x in range(WIDTH):
                sx = (x - dx) % WIDTH
                sy = (y - dy) % HEIGHT
                # Multi-frequency chirp / texture pattern
                val = int(512 + 400 * (((sx*sy) % 31) / 30.0 - 0.5) * 2.0)
                val = max(0, min(1023, val))
                total_y.append(val)
        for y in range(HEIGHT // 2):
            for x in range(WIDTH // 2):
                sx = (x - dx//2) % (WIDTH // 2)
                sy = (y - dy//2) % (HEIGHT // 2)
                u_val = int(512 + 200 * (((sx*3 + sy) % 17) / 16.0 - 0.5))
                v_val = int(512 + 200 * (((sy*3 + sx) % 19) / 18.0 - 0.5))
                total_u.append(max(0, min(1023, u_val)))
                total_v.append(max(0, min(1023, v_val)))

    with open("high_motion_y.hex", "w") as fy, open("high_motion_u.hex", "w") as fu, open("high_motion_v.hex", "w") as fv:
        for val in total_y:
            fy.write(f"{val:03x}\n")
        for val in total_u:
            fu.write(f"{val:03x}\n")
        for val in total_v:
            fv.write(f"{val:03x}\n")

    with open("high_motion_128x128_10b.yuv", "wb") as f:
        for f_idx in range(FRAMES):
            y_plane = total_y[f_idx*FRAME_Y_SIZE:(f_idx+1)*FRAME_Y_SIZE]
            u_plane = total_u[f_idx*FRAME_C_SIZE:(f_idx+1)*FRAME_C_SIZE]
            v_plane = total_v[f_idx*FRAME_C_SIZE:(f_idx+1)*FRAME_C_SIZE]
            f.write(struct.pack(f"<{FRAME_Y_SIZE}H", *y_plane))
            f.write(struct.pack(f"<{FRAME_C_SIZE}H", *u_plane))
            f.write(struct.pack(f"<{FRAME_C_SIZE}H", *v_plane))
    print("  -> high_motion_y.hex, high_motion_u.hex, high_motion_v.hex, high_motion_128x128_10b.yuv created.")

if __name__ == "__main__":
    generate_flat_field()
    generate_checkerboard()
    generate_high_motion()
