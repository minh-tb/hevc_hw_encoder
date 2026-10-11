import struct

hw_data = open("hw_recon_pre.yuv", "rb").read()
dec_data = open("dec_gate.yuv", "rb").read()
samples_per_frame = 128*128 + 64*64*2
bytes_per_frame = samples_per_frame * 2

f = 1
hws = struct.unpack(f"<{samples_per_frame}H", hw_data[f*bytes_per_frame:(f+1)*bytes_per_frame])
decs = struct.unpack(f"<{samples_per_frame}H", dec_data[f*bytes_per_frame:(f+1)*bytes_per_frame])

# Search in CTU 2 TR (x=32..63, y=64..95)
top_diffs = []
for y in range(64, 96):
    for x in range(32, 64):
        d = abs(hws[y*128+x] - decs[y*128+x])
        top_diffs.append((d, x, y, hws[y*128+x], decs[y*128+x]))

top_diffs.sort(reverse=True)
print("Top 10 diffs in CTU 2 TR:")
for d, x, y, hw, dec in top_diffs[:10]:
    print(f"  ({x}, {y}): Diff={d}, HW={hw}, DEC={dec}")
