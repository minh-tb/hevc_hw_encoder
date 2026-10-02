"""
profile_pipeline_throughput.py
Parses ModelSim simulation log (sim_profile.log) to extract:
- Cycle counts for each CTU pipeline stage: T_MD, T_TQ, T_DB, T_CABAC, Total
- Verification of Deblock filter cycle gating (~5,511 cycles)
- Pipeline bubble stall percentages
- Maximum real-time throughput (fps) across standard resolutions at 150MHz & 200MHz
"""

import os
import re
import sys

def parse_profiler_log(log_path="sim_profile.log"):
    if not os.path.exists(log_path):
        if os.path.exists("transcript"):
            log_path = "transcript"
        else:
            print(f"Error: {log_path} and transcript not found.")
            return

    pattern = re.compile(
        r"\[PROFILER\] Frame\s+(\d+)\s+CTU\s+(\d+):\s+Total=(\d+)\s+cycles\s+\|\s+"
        r"T_MD=(\d+)\s+\|\s+T_TQ=(\d+)\s+\|\s+T_DB=(\d+)\s+\|\s+T_CABAC=(\d+)\s+\|\s+"
        r"Stall_CABAC=(\d+)\s+\|\s+Stall_Inloop=(\d+)"
    )

    records = []
    # Detect encoding (powershell redirection produces utf-16 LE)
    encoding = "utf-16"
    try:
        with open(log_path, "rb") as bf:
            bom = bf.read(2)
            if bom != b"\xff\xfe":
                encoding = "utf-8"
    except Exception:
        encoding = "utf-8"

    with open(log_path, "r", encoding=encoding, errors="ignore") as f:
        for line in f:
            m = pattern.search(line)
            if m:
                records.append({
                    "frame": int(m.group(1)),
                    "ctu": int(m.group(2)),
                    "total": int(m.group(3)),
                    "t_md": int(m.group(4)),
                    "t_tq": int(m.group(5)),
                    "t_db": int(m.group(6)),
                    "t_cabac": int(m.group(7)),
                    "stall_cabac": int(m.group(8)),
                    "stall_inloop": int(m.group(9)),
                })

    if not records:
        print("No [PROFILER] records found in log yet.")
        return

    print("====================================================================================================")
    print("                              CYCLE-ACCURATE PIPELINE PROFILING REPORT                              ")
    print("====================================================================================================")
    print(f" Total CTUs Profiled: {len(records)} across {max(r['frame'] for r in records)+1} frames")
    print("----------------------------------------------------------------------------------------------------")
    print(" Frame | CTU | Total Cyc | T_MD (cyc) | T_TQ (cyc) | T_DB (cyc) | T_CABAC (cyc) | Stall_CABAC | Stall_Inloop | Stall %")
    print("-------+-----+-----------+------------+------------+------------+---------------+-------------+--------------+--------")

    sum_total = 0
    sum_md = 0
    sum_tq = 0
    sum_db = 0
    sum_cabac = 0
    sum_stall = 0

    for r in records:
        total = r["total"]
        stalls = r["stall_cabac"] + r["stall_inloop"]
        stall_pct = (stalls * 100.0 / total) if total > 0 else 0.0
        sum_total += total
        sum_md += r["t_md"]
        sum_tq += r["t_tq"]
        sum_db += r["t_db"]
        sum_cabac += r["t_cabac"]
        sum_stall += stalls

        print(f"   {r['frame']:2d}  |  {r['ctu']:2d} |   {r['total']:7d} |    {r['t_md']:7d} |    {r['t_tq']:7d} |    {r['t_db']:7d} |       {r['t_cabac']:7d} |     {r['stall_cabac']:7d} |      {r['stall_inloop']:7d} | {stall_pct:5.1f}%")

    n = len(records)
    avg_total = sum_total / n
    avg_md = sum_md / n
    avg_tq = sum_tq / n
    avg_db = sum_db / n
    avg_cabac = sum_cabac / n
    avg_stall_pct = (sum_stall * 100.0 / sum_total) if sum_total > 0 else 0.0

    print("-------+-----+-----------+------------+------------+------------+---------------+-------------+--------------+--------")
    print(f"  AVG  |  -- |   {avg_total:7.0f} |    {avg_md:7.0f} |    {avg_tq:7.0f} |    {avg_db:7.0f} |       {avg_cabac:7.0f} |          -- |           -- | {avg_stall_pct:5.1f}%")
    print("====================================================================================================\n")

    # Bottleneck Analysis
    stages = {
        "Mode Decision (T_MD)": avg_md,
        "Transform/Quant/Recon (T_TQ)": avg_tq,
        "Deblocking Filter (T_DB)": avg_db,
        "CABAC Entropy (T_CABAC)": avg_cabac
    }
    bottleneck_stage = max(stages.items(), key=lambda x: x[1])

    print("--- 1. Pipeline Bottleneck & Gating Verification ---")
    print(f"  Critical Stage Bottleneck: {bottleneck_stage[0]} with {bottleneck_stage[1]:.0f} cycles/CTU average.")
    print(f"  Deblock Filter Verification: Observed average T_DB = {avg_db:.0f} cycles.")
    if avg_db == 0:
        print("  --> [INFO] Loop filters bypassed via DISABLE_LOOP_FILTERS (T_DB = 0 cycles).")
    elif avg_db <= 12500:
        print(f"  --> [PASS] Deblocking filter cycle gating verified intact ({avg_db:.0f} cycles/CTU <= 12,500 target)!")
    else:
        print(f"  --> [FAIL] Deblocking filter cycle gating exceeded target ({avg_db:.0f} cycles/CTU > 12,500)!")
    print(f"  Pipeline Stall Bubbles: Average stall = {avg_stall_pct:.2f}% of total processing time.")

    # Real-Time Throughput Projections
    print("\n--- 2. Real-Time Video Throughput Projections ---")
    print("  Formula: Max FPS = F_target / (N_CTU_per_frame * max(T_stage))")
    print("  Assuming pipelined stage throughput determined by bottleneck stage.\n")

    resolutions = [
        ("128x128 (Test Clip)", 4),
        ("CIF (352x288)", 24),
        ("720p HD (1280x720)", 220),
        ("1080p FHD (1920x1080)", 510)
    ]

    t_crit = max(avg_md, avg_tq, avg_db, avg_cabac, 1.0)
    t_seq = max(avg_total, 1.0)

    for f_mhz in [150.0, 200.0]:
        f_hz = f_mhz * 1e6
        print(f"  [Clock Frequency: {f_mhz:.0f} MHz]")
        print("  ---------------------------------------------------------------------------------------")
        print("   Resolution              | N_CTU | Pipelined Max FPS (Bottleneck) | Sequential Max FPS  ")
        print("  -------------------------+-------+--------------------------------+---------------------")
        for res_name, n_ctu in resolutions:
            fps_pipelined = f_hz / (n_ctu * t_crit)
            fps_seq = f_hz / (n_ctu * t_seq)
            print(f"   {res_name:<24} |  {n_ctu:4d} |           {fps_pipelined:6.1f} fps           |      {fps_seq:6.1f} fps")
        print("  ---------------------------------------------------------------------------------------\n")

if __name__ == "__main__":
    log_file = sys.argv[1] if len(sys.argv) > 1 else "sim_profile.log"
    parse_profiler_log(log_file)
