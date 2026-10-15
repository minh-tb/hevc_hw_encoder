import os
import sys
import subprocess
import re

bitstream_path = 'str_b_frame.bin'
dec_output_path = 'dec_output_3frames.txt'
decoder_exe = r'HM\bin\mgwmake\gcc-mingw-14.2\x86_64\release\TAppDecoder.exe'

# Auto-invoke decoder if dec_output_3frames.txt is missing or older than bitstream
if not os.path.exists(dec_output_path) or (
    os.path.exists(bitstream_path) and os.path.getmtime(bitstream_path) > os.path.getmtime(dec_output_path)
):
    if not os.path.exists(bitstream_path):
        print(f"Error: {bitstream_path} does not exist.")
        sys.exit(1)
    print(f"Generating {dec_output_path} via {decoder_exe} -b {bitstream_path}...")
    try:
        proc = subprocess.run([decoder_exe, "-b", bitstream_path], capture_output=True, text=True, check=True)
        with open(dec_output_path, 'w', encoding='utf-8') as f:
            f.write(proc.stdout)
    except Exception as e:
        print(f"Error running decoder: {e}")
        sys.exit(1)

def parse_enc_bins(log_file):
    bins_by_poc = {0: [], 1: [], 2: []}
    poc = 0
    if not os.path.exists(log_file):
        return bins_by_poc
    with open(log_file, 'r', errors='ignore') as f:
        for line in f:
            if 'Started frame POC=0' in line: poc = 0
            elif 'Started frame POC=1' in line: poc = 1
            elif 'Started frame POC=2' in line: poc = 2
            m = re.search(r'ENC_BIN #(\d+):\s*(REG|EP|TRM)\s+bin=(\d+)\s+range=(\d+)(?:\s+pstate=(\d+)\s+valmps=(\d+)\s+ctx=(\d+))?', line)
            if m:
                bins_by_poc[poc].append({
                    'idx': int(m.group(1)),
                    'type': m.group(2),
                    'bin': int(m.group(3)),
                    'range': int(m.group(4)),
                    'pstate': int(m.group(5)) if m.group(5) is not None else None,
                    'valmps': int(m.group(6)) if m.group(6) is not None else None,
                    'ctx': int(m.group(7)) if m.group(7) is not None else None,
                })
    return bins_by_poc

enc_log_path = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith('-') else 'transcript'
enc_bins_by_poc = parse_enc_bins(enc_log_path)
total_enc = sum(len(b) for b in enc_bins_by_poc.values())

if total_enc == 0 and enc_log_path == 'transcript' and os.path.exists('transcript_3frames.log'):
    enc_log_path = 'transcript_3frames.log'
    enc_bins_by_poc = parse_enc_bins(enc_log_path)
    total_enc = sum(len(b) for b in enc_bins_by_poc.values())

if total_enc == 0:
    print(f"\n[ERROR] No ENC_BIN entries found in {enc_log_path}!")
    print(f"        Ensure that ModelSim simulation finished successfully and wrote to {enc_log_path}.")
    sys.exit(1)

dec_bins_by_poc = {0: [], 1: [], 2: []}
cur_poc = 0
try:
    with open(dec_output_path, 'r', encoding='utf-16') as f:
        dec_lines = f.readlines()
except Exception:
    with open(dec_output_path, 'r', encoding='utf-8', errors='ignore') as f:
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
            'pstate': int(m.group(5)) if m.group(5) is not None else None,
            'valmps': int(m.group(6)) if m.group(6) is not None else None,
            'ctx': int(m.group(7)) if m.group(7) is not None else None,
        })

total_mismatches = 0
total_compared = 0

print("\n=======================================================")
print(" CABAC FULL 6-FIELD CONFORMANCE VERIFICATION")
print(" (Fields: bin, type, range, pstate, valmps, ctx)")
print("=======================================================")

for poc in [0, 1, 2]:
    eb = enc_bins_by_poc[poc]
    db = dec_bins_by_poc[poc]
    print(f'\nPOC {poc}: ENC bins = {len(eb)}, DEC bins = {len(db)}')
    mismatches = 0
    compare_len = min(len(eb), len(db))
    total_compared += compare_len
    
    for i in range(compare_len):
        diffs = []
        if eb[i]['bin'] != db[i]['bin']:
            diffs.append(f'bin (enc={eb[i]["bin"]} dec={db[i]["bin"]})')
        if eb[i]['type'] != db[i]['type']:
            diffs.append(f'type (enc={eb[i]["type"]} dec={db[i]["type"]})')
        if eb[i]['range'] != db[i]['range']:
            diffs.append(f'range (enc={eb[i]["range"]} dec={db[i]["range"]})')
        if eb[i]['pstate'] != db[i]['pstate']:
            diffs.append(f'pstate (enc={eb[i]["pstate"]} dec={db[i]["pstate"]})')
        if eb[i]['valmps'] != db[i]['valmps']:
            diffs.append(f'valmps (enc={eb[i]["valmps"]} dec={db[i]["valmps"]})')
        if eb[i]['ctx'] != db[i]['ctx']:
            diffs.append(f'ctx (enc={eb[i]["ctx"]} dec={db[i]["ctx"]})')
        if diffs:
            mismatches += 1
            if mismatches <= 5:
                print(f'  Mismatch at bin #{i}: {", ".join(diffs)}')
                
    if len(eb) != len(db):
        diff_count = abs(len(eb) - len(db))
        mismatches += diff_count
        print(f'  [ERROR] Bin count mismatch: ENC has {len(eb)} bins, DEC has {len(db)} bins (diff: {diff_count})')
        
    total_mismatches += mismatches
    if mismatches == 0 and len(eb) == len(db) and len(eb) > 0:
        print(f'  >>> POC {poc}: 100.00% BIT-EXACT CONFORMANCE across all 6 fields ({len(eb)}/{len(eb)} bins matched perfectly!)')
    elif mismatches == 0:
        print(f'  >>> POC {poc}: All {compare_len} bins matched perfectly!')
    else:
        print(f'  >>> POC {poc}: {mismatches} mismatches out of {compare_len}')

print("\n=======================================================")
if total_mismatches == 0 and total_compared > 0:
    print(f"CABAC CONFORMANCE PASS: 100.00% bit-exact match across all {total_compared} bins across 3 frames!")
    sys.exit(0)
else:
    print(f"CABAC CONFORMANCE FAIL: {total_mismatches} total mismatches detected.")
    sys.exit(1)
