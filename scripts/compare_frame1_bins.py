import re

# Parse ENC_BIN for Frame 1 from task-1504.log
enc_bins_f1 = []
in_frame1 = False
with open(r'C:\Users\Admin\.gemini\antigravity\brain\3c9aaba0-0abe-459a-a1b4-9c76f03d97d8\.system_generated\tasks\task-1504.log', 'r', errors='ignore') as f:
    for line in f:
        if 'Streaming Frame 1/' in line or 'Frame 1 CTU 0' in line:
            in_frame1 = True
            continue
        if 'Streaming Frame 2/' in line or 'Frame 2 CTU 0' in line:
            in_frame1 = False
        if in_frame1:
            m = re.search(r'ENC_BIN #(\d+):\s*(REG|EP|TRM)\s+bin=(\d+)\s+range=(\d+)(?:\s+pstate=(\d+)\s+valmps=(\d+)\s+ctx=(\d+))?', line)
            if m:
                enc_bins_f1.append({
                    'idx': int(m.group(1)),
                    'type': m.group(2),
                    'bin': int(m.group(3)),
                    'range': int(m.group(4)),
                    'pstate': int(m.group(5)) if m.group(5) is not None else None,
                    'valmps': int(m.group(6)) if m.group(6) is not None else None,
                    'ctx': int(m.group(7)) if m.group(7) is not None else None,
                    'raw': line.strip()
                })

# Parse DEC_BIN for Frame 1 from dec_output.txt
dec_bins_f1 = []
in_dec_f1 = False
with open('dec_output.txt', 'r', encoding='utf-16') as f:
    for line in f:
        if 'POC    0 TId:' in line:
            in_dec_f1 = True
            continue
        if in_dec_f1:
            m = re.search(r'DEC_BIN #(\d+):\s*(REG|EP|TRM)\s+bin=(\d+)\s+range=(\d+)(?:\s+pstate=(\d+)\s+valmps=(\d+)\s+ctx=(\d+))?', line)
            if m:
                dec_bins_f1.append({
                    'idx': int(m.group(1)),
                    'type': m.group(2),
                    'bin': int(m.group(3)),
                    'range': int(m.group(4)),
                    'pstate': int(m.group(5)) if m.group(5) is not None else None,
                    'valmps': int(m.group(6)) if m.group(6) is not None else None,
                    'ctx': int(m.group(7)) if m.group(7) is not None else None,
                    'raw': line.strip()
                })

print(f'Frame 1 ENC bins: {len(enc_bins_f1)}, DEC bins: {len(dec_bins_f1)}')

mismatches = 0
for i in range(min(len(enc_bins_f1), len(dec_bins_f1))):
    e = enc_bins_f1[i]
    d = dec_bins_f1[i]
    diff = []
    if e['bin'] != d['bin']:
        diff.append(f"bin: enc={e['bin']} dec={d['bin']}")
    if e['type'] != d['type']:
        diff.append(f"type: enc={e['type']} dec={d['type']}")
    if e['ctx'] != d['ctx']:
        diff.append(f"ctx: enc={e['ctx']} dec={d['ctx']}")
    if e['range'] != d['range']:
        diff.append(f"range: enc={e['range']} dec={d['range']}")
    if e['pstate'] != d['pstate']:
        diff.append(f"pstate: enc={e['pstate']} dec={d['pstate']}")
    if e['valmps'] != d['valmps']:
        diff.append(f"valmps: enc={e['valmps']} dec={d['valmps']}")
    if diff:
        print(f'Frame 1 mismatch at index {i} (ENC #{e["idx"]}, DEC #{d["idx"]}):')
        print(f'  ENC: {e["raw"]}')
        print(f'  DEC: {d["raw"]}')
        print(f'  Diff: {", ".join(diff)}')
        mismatches += 1
        if mismatches >= 10:
            break

if mismatches == 0:
    print(f'All {min(len(enc_bins_f1), len(dec_bins_f1))} bins of Frame 1 MATCHED PERFECTLY!')
