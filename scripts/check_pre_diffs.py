import struct

hw_data = open("hw_recon_pre.yuv", "rb").read()
dec_data = open("dec_gate.yuv", "rb").read()
samples_per_frame = 128*128 + 64*64*2
bytes_per_frame = samples_per_frame * 2

for f in range(3):
    hws = struct.unpack(f"<{samples_per_frame}H", hw_data[f*bytes_per_frame:(f+1)*bytes_per_frame])
    decs = struct.unpack(f"<{samples_per_frame}H", dec_data[f*bytes_per_frame:(f+1)*bytes_per_frame])
    diffs = [abs(a - b) for a, b in zip(hws, decs)]
    max_d = max(diffs)
    exact = sum(1 for d in diffs if d == 0)
    pct = exact * 100.0 / samples_per_frame
    print(f"PreDeblock Frame {f}: Max Diff = {max_d}, Exact = {exact}/{samples_per_frame} ({pct:.2f}%)")
    
    # Check breakdown for CTUs
    for ctu_idx in range(4):
        cx = (ctu_idx % 2) * 64
        cy = (ctu_idx // 2) * 64
        ctu_diffs = []
        for y in range(cy, cy + 64):
            for x in range(cx, cx + 64):
                ctu_diffs.append(abs(hws[y * 128 + x] - decs[y * 128 + x]))
        print(f"  CTU {ctu_idx}: Max = {max(ctu_diffs)}, Exact = {sum(1 for d in ctu_diffs if d==0)}/4096, Avg = {sum(ctu_diffs)/len(ctu_diffs):.2f}")
