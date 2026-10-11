import re

enc_bins_by_poc = {0: [], 1: [], 2: []}
cur_poc = 0
enc_log_path = 'transcript'
with open(enc_log_path, 'r', errors='ignore') as f:
    for line in f:
        if 'Started frame POC=0' in line: cur_poc = 0
        elif 'Started frame POC=1' in line: cur_poc = 1
        elif 'Started frame POC=2' in line: cur_poc = 2
        m = re.search(r'ENC_BIN #(\d+):\s*(REG|EP|TRM)\s+bin=(\d+)\s+range=(\d+)(?:\s+pstate=(\d+)\s+valmps=(\d+)\s+ctx=(\d+))?', line)
        if m:
            enc_bins_by_poc[cur_poc].append({
                'idx': int(m.group(1)),
                'type': m.group(2),
                'bin': int(m.group(3)),
                'range': int(m.group(4)),
                'ctx': int(m.group(7)) if m.group(7) is not None else None,
            })

dec_bins_by_poc = {0: [], 1: [], 2: []}
cur_poc = 0
try:
    with open('dec_output_3frames.txt', 'r', encoding='utf-16') as f:
        dec_lines = f.readlines()
except Exception:
    with open('dec_output_3frames.txt', 'r', encoding='utf-8', errors='ignore') as f:
        dec_lines = f.readlines()

for line in dec_lines:
        m_poc = re.search(r'POC\s+(\d+)\s+TId:', line)
        if m_poc:
            cur_poc = int(m_poc.group(1)) + 1
            continue
        m = re.search(r'DEC_BIN #(\d+):\s*(REG|EP|TRM)\s+bin=(\d+)\s+range=(\d+)(?:\s+pstate=(\d+)\s+valmps=(\d+)\s+ctx=(\d+))?', line)
        if m and cur_poc in dec_bins_by_poc:
            dec_bins_by_poc[cur_poc].append({
                'idx': int(m.group(1)),
                'type': m.group(2),
                'bin': int(m.group(3)),
                'range': int(m.group(4)),
                'ctx': int(m.group(7)) if m.group(7) is not None else None,
            })

for poc in [0, 1, 2]:
    eb = enc_bins_by_poc[poc]
    db = dec_bins_by_poc[poc]
    print(f'POC {poc}: ENC bins = {len(eb)}, DEC bins = {len(db)}')
    mismatches = 0
    compare_len = min(len(eb), len(db))
    for i in range(compare_len):
        diffs = []
        if eb[i]['bin'] != db[i]['bin']:
            diffs.append(f'bin (enc={eb[i]["bin"]} dec={db[i]["bin"]})')
        if eb[i]['type'] != db[i]['type']:
            diffs.append(f'type (enc={eb[i]["type"]} dec={db[i]["type"]})')
        if eb[i]['ctx'] != db[i]['ctx']:
            diffs.append(f'ctx (enc={eb[i]["ctx"]} dec={db[i]["ctx"]})')
        if diffs:
            mismatches += 1
            if mismatches <= 5:
                print(f'  Mismatch at bin #{i}: {", ".join(diffs)}')
    if mismatches == 0 and len(eb) == len(db) and len(eb) > 0:
        print(f'  >>> POC {poc}: 100% BIT-EXACT CONFORMANCE ({len(eb)}/{len(eb)} bins matched perfectly!)')
    elif mismatches == 0:
        print(f'  >>> POC {poc}: All {compare_len} bins matched perfectly!')
    else:
        print(f'  >>> POC {poc}: {mismatches} mismatches out of {compare_len}')
