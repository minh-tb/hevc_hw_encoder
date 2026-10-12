import struct

hw_data = open("hw_recon.yuv", "rb").read()
dec_data = open("dec_test.yuv", "rb").read()
samples_per_frame = 128*128 + 64*64*2
bytes_per_frame = samples_per_frame * 2

# Check Frame 1
f = 1
hws = struct.unpack(f"<{samples_per_frame}H", hw_data[f*bytes_per_frame:(f+1)*bytes_per_frame])
decs = struct.unpack(f"<{samples_per_frame}H", dec_data[f*bytes_per_frame:(f+1)*bytes_per_frame])

print("Frame 1 sample at (73, 127):")
idx_73_127 = 127 * 128 + 73
print(f"  HW={hws[idx_73_127]} DEC={decs[idx_73_127]} diff={abs(hws[idx_73_127] - decs[idx_73_127])}")

# Also check CTU 3 bottom-left CU: x in 64..95, y in 96..127
ctu3_bl_diffs = []
for y in range(96, 128):
    for x in range(64, 96):
        idx = y * 128 + x
        ctu3_bl_diffs.append(abs(hws[idx] - decs[idx]))

print(f"CTU 3 bottom-left CU (x=64..95, y=96..127):")
print(f"  Max Diff = {max(ctu3_bl_diffs)}, Min Diff = {min(ctu3_bl_diffs)}, Avg Diff = {sum(ctu3_bl_diffs)/len(ctu3_bl_diffs):.2f}")

# Check CTU 3 top-left CU: x in 64..95, y in 64..95
ctu3_tl_diffs = []
for y in range(64, 96):
    for x in range(64, 96):
        idx = y * 128 + x
        ctu3_tl_diffs.append(abs(hws[idx] - decs[idx]))

print(f"CTU 3 top-left CU (x=64..95, y=64..95):")
print(f"  Max Diff = {max(ctu3_tl_diffs)}, Min Diff = {min(ctu3_tl_diffs)}, Avg Diff = {sum(ctu3_tl_diffs)/len(ctu3_tl_diffs):.2f}")

# Check all 4 CTUs for Frame 1
for ctu_y in range(2):
    for ctu_x in range(2):
        ctu_idx = ctu_y * 2 + ctu_x
        ctu_diffs = []
        for y in range(ctu_y*64, (ctu_y+1)*64):
            for x in range(ctu_x*64, (ctu_x+1)*64):
                idx = y * 128 + x
                ctu_diffs.append(abs(hws[idx] - decs[idx]))
        print(f"Frame 1 CTU {ctu_idx} (x={ctu_x*64}..{(ctu_x+1)*64-1}, y={ctu_y*64}..{(ctu_y+1)*64-1}): Max Diff = {max(ctu_diffs)}, Avg Diff = {sum(ctu_diffs)/len(ctu_diffs):.2f}")
