import re

enc_bins = []
with open(r'C:\Users\Admin\.gemini\antigravity\brain\3c9aaba0-0abe-459a-a1b4-9c76f03d97d8\.system_generated\tasks\task-1478.log', 'r', errors='ignore') as f:
    for line in f:
        m = re.search(r'ENC_BIN #(\d+):\s*(REG|EP|TRM)\s+bin=(\d+)\s+range=(\d+)(?:\s+pstate=(\d+)\s+valmps=(\d+)\s+ctx=(\d+))?', line)
        if m:
            enc_bins.append({
                'idx': int(m.group(1)),
                'type': m.group(2),
                'bin': int(m.group(3)),
                'range': int(m.group(4)),
                'pstate': int(m.group(5)) if m.group(5) is not None else None,
                'valmps': int(m.group(6)) if m.group(6) is not None else None,
                'ctx': int(m.group(7)) if m.group(7) is not None else None,
                'raw': line.strip()
            })

dec_bins = []
try:
    with open('dec_output.txt', 'r', encoding='utf-16') as f:
        lines = f.readlines()
except Exception:
    with open('dec_output.txt', 'r', encoding='utf-8', errors='ignore') as f:
        lines = f.readlines()

for line in lines:
    m = re.search(r'DEC_BIN #(\d+):\s*(REG|EP|TRM)\s+bin=(\d+)\s+range=(\d+)(?:\s+pstate=(\d+)\s+valmps=(\d+)\s+ctx=(\d+))?', line)
    if m:
        dec_bins.append({
            'idx': int(m.group(1)),
            'type': m.group(2),
            'bin': int(m.group(3)),
            'range': int(m.group(4)),
            'pstate': int(m.group(5)) if m.group(5) is not None else None,
            'valmps': int(m.group(6)) if m.group(6) is not None else None,
            'ctx': int(m.group(7)) if m.group(7) is not None else None,
            'raw': line.strip()
        })

print(f'ENC bins: {len(enc_bins)}, DEC bins: {len(dec_bins)}')

mismatches = 0
for i in range(min(len(enc_bins), len(dec_bins))):
    e = enc_bins[i]
    d = dec_bins[i]
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
        print(f'Mismatch at bin index {i}:')
        print(f'  ENC: {e["raw"]}')
        print(f'  DEC: {d["raw"]}')
        print(f'  Diff: {", ".join(diff)}')
        mismatches += 1
        if mismatches >= 10:
            break

if mismatches == 0:
    print(f'All {min(len(enc_bins), len(dec_bins))} bins MATCHED PERFECTLY!')
