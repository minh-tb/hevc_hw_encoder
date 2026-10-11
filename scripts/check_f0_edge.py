import struct

hw_data = open("hw_recon.yuv", "rb").read()
dec_data = open("dec_test.yuv", "rb").read()
samples_per_frame = 128*128 + 64*64*2
bytes_per_frame = samples_per_frame * 2

# Frame 0
f = 0
hws0 = struct.unpack(f"<{samples_per_frame}H", hw_data[f*bytes_per_frame:(f+1)*bytes_per_frame])
decs0 = struct.unpack(f"<{samples_per_frame}H", dec_data[f*bytes_per_frame:(f+1)*bytes_per_frame])

print("Frame 0 bottom edge samples y=127, x=45..63:")
for x in range(45, 64):
    print(f"x={x}: HW={hws0[127*128+x]} DEC={decs0[127*128+x]} diff={abs(hws0[127*128+x]-decs0[127*128+x])}")
