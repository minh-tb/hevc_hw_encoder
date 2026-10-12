import struct

hw_data = open("hw_recon_pre.yuv", "rb").read()
dec_data = open("dec_gate.yuv", "rb").read()
samples_per_frame = 128*128 + 64*64*2
bytes_per_frame = samples_per_frame * 2

f = 1
hws = struct.unpack(f"<{samples_per_frame}H", hw_data[f*bytes_per_frame:(f+1)*bytes_per_frame])
decs = struct.unpack(f"<{samples_per_frame}H", dec_data[f*bytes_per_frame:(f+1)*bytes_per_frame])

print("CTU 2 TR (x=32..63, y=64..95) First 8 rows:")
for y in range(64, 72):
    row_h = [hws[y*128 + x] for x in range(32, 40)]
    row_d = [decs[y*128 + x] for x in range(32, 40)]
    row_diff = [abs(h - d) for h, d in zip(row_h, row_d)]
    print(f"y={y}: HW={row_h[:4]} DEC={row_d[:4]} Diff={row_diff[:4]}")
