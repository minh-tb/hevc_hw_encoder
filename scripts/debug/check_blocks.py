import struct

hw_data = open("hw_recon_pre.yuv", "rb").read()
dec_data = open("dec_gate.yuv", "rb").read()
samples_per_frame = 128*128 + 64*64*2
bytes_per_frame = samples_per_frame * 2

f = 1
hws = struct.unpack(f"<{samples_per_frame}H", hw_data[f*bytes_per_frame:(f+1)*bytes_per_frame])
decs = struct.unpack(f"<{samples_per_frame}H", dec_data[f*bytes_per_frame:(f+1)*bytes_per_frame])

# For CTU 2 (x=0..63, y=64..127):
# 4 32x32 blocks:
# TL: x=0..31, y=64..95
# TR: x=32..63, y=64..95
# BL: x=0..31, y=96..127
# BR: x=32..63, y=96..127
blocks_ctu2 = {
    "TL (0,64)": (0, 32, 64, 96),
    "TR (32,64)": (32, 64, 64, 96),
    "BL (0,96)": (0, 32, 96, 128),
    "BR (32,96)": (32, 64, 96, 128)
}

print("Frame 1 CTU 2 32x32 blocks:")
for name, (x0, x1, y0, y1) in blocks_ctu2.items():
    diffs = [abs(hws[y*128+x] - decs[y*128+x]) for y in range(y0, y1) for x in range(x0, x1)]
    print(f"  {name}: Max Diff = {max(diffs)}, Avg Diff = {sum(diffs)/len(diffs):.2f}, Exact = {sum(1 for d in diffs if d==0)}/1024")

blocks_ctu3 = {
    "TL (64,64)": (64, 96, 64, 96),
    "TR (96,64)": (96, 128, 64, 96),
    "BL (64,96)": (64, 96, 96, 128),
    "BR (96,96)": (96, 128, 96, 128)
}

print("\nFrame 1 CTU 3 32x32 blocks:")
for name, (x0, x1, y0, y1) in blocks_ctu3.items():
    diffs = [abs(hws[y*128+x] - decs[y*128+x]) for y in range(y0, y1) for x in range(x0, x1)]
    print(f"  {name}: Max Diff = {max(diffs)}, Avg Diff = {sum(diffs)/len(diffs):.2f}, Exact = {sum(1 for d in diffs if d==0)}/1024")
