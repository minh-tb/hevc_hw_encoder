
with open("hm_ld_str.bin", "rb") as f:
    data = f.read()

start_codes = []
for i in range(len(data)-3):
    if data[i:i+3] == b"\x00\x00\x01":
        if i > 0 and data[i-1] == 0:
            if not start_codes or start_codes[-1][0] != i-1:
                start_codes.append((i-1, 4))
        else:
            if not start_codes or start_codes[-1][0] != i:
                start_codes.append((i, 3))

headers = []
for idx, (pos, length) in enumerate(start_codes):
    next_pos = start_codes[idx+1][0] if idx+1 < len(start_codes) else len(data)
    nalu = data[pos+length:next_pos]
    if not nalu: continue
    t = (nalu[0] >> 1) & 0x3f
    if t in (32, 33, 34):
        headers.append((t, nalu.hex()))

for t, h in headers:
    name = {32: "VPS", 33: "SPS", 34: "PPS"}[t]
    print(f"{name}_HEX = \"00000001{h}\"")

