import struct

hw_data = open("hw_recon_pre.yuv", "rb").read()
dec_data = open("dec_gate.yuv", "rb").read()
samples_per_frame = 128*128 + 64*64*2
bytes_per_frame = samples_per_frame * 2

f = 1
hws = struct.unpack(f"<{samples_per_frame}H", hw_data[f*bytes_per_frame:(f+1)*bytes_per_frame])
decs = struct.unpack(f"<{samples_per_frame}H", dec_data[f*bytes_per_frame:(f+1)*bytes_per_frame])

y = 94
print(f"Row y={y}: (x, HW, DEC, Diff)")
for x in range(32, 64):
    hw = hws[y*128+x]
    dec = decs[y*128+x]
    print(f"  x={x:2d}: HW={hw:4d} DEC={dec:4d} Diff={abs(hw-dec):4d}")
