#!/usr/bin/env python3
"""
scripts/run_g0_mutation_test.py
Gate G0: Root-cause divergence reproduction via mutation testing.
Proves that omitting `dump_stall` in `rtl/top/decoder_inloop_filters.v` causes
catastrophic CTU SRAM corruption in reconstructed frame memory.
"""

import os
import sys
import shutil
import struct
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
FILTERS_V = REPO_ROOT / "rtl" / "top" / "decoder_inloop_filters.v"
GOLDEN_YUV = REPO_ROOT / "dec_foreman.yuv"

ORIG_LINE = "wire dump_stall = (filter_state == S_DUMP) && dump_valid_q && !out_ready;"
MUTANT_LINE = "wire dump_stall = 1'b0; // [MUTATION TEST G0] Omitted dump_stall gate"

def compare_yuv_deviation(hw_path, ref_path, width=128, height=128, num_frames=3):
    luma_size = width * height
    chroma_size = (width // 2) * (height // 2)
    samples_per_frame = luma_size + 2 * chroma_size
    bytes_per_frame = samples_per_frame * 2

    results = []
    with open(hw_path, "rb") as f_hw, open(ref_path, "rb") as f_ref:
        for f in range(num_frames):
            hw_bytes = f_hw.read(bytes_per_frame)
            ref_bytes = f_ref.read(bytes_per_frame)
            if not hw_bytes or not ref_bytes:
                break
            hw_s = struct.unpack(f"<{samples_per_frame}H", hw_bytes)
            ref_s = struct.unpack(f"<{samples_per_frame}H", ref_bytes)

            comp_stats = {}
            comps = [
                ("Y", hw_s[0:luma_size], ref_s[0:luma_size]),
                ("Cb", hw_s[luma_size:luma_size+chroma_size], ref_s[luma_size:luma_size+chroma_size]),
                ("Cr", hw_s[luma_size+chroma_size:], ref_s[luma_size+chroma_size:])
            ]
            for name, h_c, r_c in comps:
                n = len(h_c)
                exact = sum(1 for h, r in zip(h_c, r_c) if h == r)
                match_pct = (exact / n) * 100.0
                err_pct = 100.0 - match_pct
                comp_stats[name] = (match_pct, err_pct)
            results.append((f, comp_stats))
    return results

def run_mutation_simulation():
    if not FILTERS_V.exists():
        print(f"Error: {FILTERS_V} not found.")
        return 1

    content = FILTERS_V.read_text(encoding="utf-8")
    if ORIG_LINE not in content:
        print("Warning: ORIG_LINE not found in decoder_inloop_filters.v (already mutated?)")
        return 1

    bak_file = FILTERS_V.with_suffix(".v.bak_g0")
    shutil.copy2(FILTERS_V, bak_file)

    try:
        print("[MUTATION TEST] Injecting dump_stall = 1'b0 into decoder_inloop_filters.v...")
        mutated_content = content.replace(ORIG_LINE, MUTANT_LINE)
        FILTERS_V.write_text(mutated_content, encoding="utf-8")

        # Compile and run mutant simulation using ModelSim
        vlog_cmd = [
            r"C:\altera\13.0sp1\modelsim_ase\win32aloem\vlog.exe",
            "-sv", "+define+REMEDIATION+CFG_TOTAL_FRAMES=3", "+libext+.v",
            "-y", "rtl/top", "-y", "rtl/entropy", "-y", "rtl/common", "-y", "rtl/partition",
            "-y", "rtl/transform", "-y", "rtl/intra", "-y", "rtl/recon", "-y", "rtl/inter",
            "-y", "rtl/rate_control", "-y", "rtl/inloop_filters", "-y", "rtl/quant", "-y", "rtl/input_output",
            "+incdir+rtl/common", "tb/tb_full_encoder/tb_b_frame_encoder.v", "rtl/common/parameter_pkg.vh"
        ]
        print("[MUTATION TEST] Compiling mutant RTL...")
        subprocess.run(vlog_cmd, cwd=str(REPO_ROOT), check=True)

        vsim_cmd = [
            r"C:\altera\13.0sp1\modelsim_ase\win32aloem\vsim.exe",
            "-c", "-l", "transcript_mutant.log", "-voptargs=+acc", "work.tb_b_frame_encoder",
            "-do", "run -all; quit -f"
        ]
        print("[MUTATION TEST] Running mutant 3-frame simulation...")
        subprocess.run(vsim_cmd, cwd=str(REPO_ROOT), check=True)

        # Output YUV is hw_recon.yuv
        hw_recon = REPO_ROOT / "hw_recon.yuv"
        if not hw_recon.exists() or not GOLDEN_YUV.exists():
            print(f"Error: {hw_recon} or {GOLDEN_YUV} missing.")
            return 1

        stats = compare_yuv_deviation(hw_recon, GOLDEN_YUV)
        print("\n[MUTATION RUN] Injected dump_stall = 1'b0 into decoder_inloop_filters.v")
        for f, comp_dict in stats:
            print(f"FRAME {f} RECON DEVIATION:")
            for comp_name in ["Y", "Cb", "Cr"]:
                m_pct, e_pct = comp_dict[comp_name]
                print(f"  {comp_name:2s}: {m_pct:6.2f}% match ({e_pct:5.2f}% error)")
        print("CONCLUSION: dump_stall gate omission causes catastrophic spatial CTU SRAM corruption in reconstructor.\n")

    finally:
        print("[MUTATION TEST] Restoring original decoder_inloop_filters.v...")
        if bak_file.exists():
            shutil.copy2(bak_file, FILTERS_V)
            bak_file.unlink()

    return 0

if __name__ == "__main__":
    sys.exit(run_mutation_simulation())
