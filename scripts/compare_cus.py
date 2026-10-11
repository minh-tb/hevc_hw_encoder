import re

# Parse HM output
hm_cus = []
with open("dec_output_3frames.txt", "r", encoding="utf-8", errors="ignore") as f:
    for line in f:
        # Check for HM debug logs
        m_inter = re.search(r"\[HM_INTER_DBG\] POC=(\d+) CTU=(\d+) part=0 merge=(\d+) idx=(\d+) MV0=\((-?\d+),(-?\d+)\) ref0=(\d+)", line)
        if m_inter:
            hm_cus.append({
                "poc": int(m_inter.group(1)),
                "ctu": int(m_inter.group(2)),
                "merge": int(m_inter.group(3)),
                "merge_idx": int(m_inter.group(4)),
                "mv_x": int(m_inter.group(5)),
                "mv_y": int(m_inter.group(6)),
                "ref0": int(m_inter.group(7))
            })

print(f"Total HM inter CUs parsed: {len(hm_cus)}")
for cu in hm_cus:
    if cu["poc"] == 1:
        print(f"HM Frame 1 CTU {cu['ctu']}: merge={cu['merge']} idx={cu['merge_idx']} MV=({cu['mv_x']}, {cu['mv_y']}) ref={cu['ref0']}")

# Parse HW MODE_DECISION for Frame 1
print("\n--- HW MODE_DECISION for Frame 1 ---")
with open("transcript_run.txt", "r", errors="ignore") as f:
    for line in f:
        if "[MODE_DECISION]" in line and "POC=1" in line:
            print(line.strip())
