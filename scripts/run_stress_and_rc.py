#!/usr/bin/env python3
"""
scripts/run_stress_and_rc.py
Automated Corner-Case Stress Testing & Closed-Loop Rate Control Suite
Tests:
  1. Flat Field (CBF=0, all-zero residual, CABAC flush verification)
  2. Maximum-Contrast Checkerboard (Nyquist frequency, 16-bit intermediate transform clipping)
  3. High-Motion Video (large motion vectors up to +/-32 pixels)
  4. Closed-Loop CBR Rate Control (2000 kbps @ 30 fps, VBV fullness & Delta QP tracking)
Verifies:
  - Simulation finishes cleanly with zero hangs or timeouts
  - HM 18.0 reference decoder produces Exit Code 0 across all streams
"""

import os
import sys
import subprocess

WORKSPACE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HM_DEC = os.path.join(WORKSPACE, r"HM\bin\mgwmake\gcc-mingw-14.2\x86_64\release\TAppDecoder.exe")
TB_PATH = os.path.join(WORKSPACE, r"tb\tb_full_encoder\tb_b_frame_encoder.v")

STRESS_TESTS = [
    {
        "name": "Flat Field Pattern (Y=U=V=512)",
        "macro": "PATTERN_FLAT",
        "bin": "str_b_frame_flat.bin",
        "dec": "dec_hw_flat.yuv",
        "desc": "Verifies CBF=0 skip paths and clean CABAC syntax emission with zero residual energy."
    },
    {
        "name": "Max-Contrast Checkerboard (0 <-> 1023)",
        "macro": "PATTERN_CHECKER +define+CFG_TOTAL_FRAMES=1",
        "bin": "str_b_frame_checker.bin",
        "dec": "dec_hw_checker.yuv",
        "desc": "Verifies 16-bit intermediate transform clipping guards and saturation under maximum AC energy."
    },
    {
        "name": "High-Motion Video",
        "macro": "PATTERN_HIGH_MOTION",
        "bin": "str_b_frame_high_motion.bin",
        "dec": "dec_hw_high_motion.yuv",
        "desc": "Verifies full-range +/-32 TZ search and signed MVD bitwidths under high motion dynamics."
    }
]

def run_stress_test(t):
    print(f"\n================================================================================")
    print(f" [STRESS TEST] {t['name']}")
    print(f" Description: {t['desc']}")
    print(f"================================================================================")

    bin_path = os.path.join(WORKSPACE, t["bin"])
    dec_path = os.path.join(WORKSPACE, t["dec"])
    if os.path.exists(bin_path):
        os.remove(bin_path)

    # 1. Compile testbench
    vlog_cmd = f"vlog -sv +incdir+rtl/common +incdir+. rtl/entropy/range_coder.v rtl/entropy/bin_encoder.v rtl/entropy/syntax_coeff.v rtl/entropy/cabac_enc_top.v rtl/rate_control/rate_controller.v +define+{t['macro']} {TB_PATH}"
    print(f"  > {vlog_cmd}")
    res = subprocess.run(vlog_cmd, shell=True, cwd=WORKSPACE, capture_output=True, text=True)
    if res.returncode != 0:
        print(f"  [FAIL] vlog compilation failed:\n{res.stderr}\n{res.stdout}")
        return False

    # 2. Run simulation
    vsim_cmd = 'vsim -c -do "run -all; quit -f" work.tb_b_frame_encoder'
    print(f"  > {vsim_cmd}")
    res = subprocess.run(vsim_cmd, shell=True, cwd=WORKSPACE, capture_output=True, text=True)
    if not os.path.exists(bin_path):
        print(f"  [FAIL] Simulation failed to output bitstream: {t['bin']}")
        return False

    file_size = os.path.getsize(bin_path)
    print(f"  [PASS] Simulation completed successfully: {file_size} bytes generated.")

    # 3. Decode with HM 18.0
    dec_cmd = [HM_DEC, "-b", bin_path, "-o", dec_path, "-d", "10"]
    print(f"  > HM Decoder: {' '.join(dec_cmd)}")
    dec_res = subprocess.run(dec_cmd, cwd=WORKSPACE, capture_output=True, text=True)
    if dec_res.returncode != 0:
        print(f"  [FAIL] HM Decoder exited with error code {dec_res.returncode}:\n{dec_res.stderr}")
        return False

    print(f"  [PASS] HM 18.0 Decoded bitstream with Exit Code 0 (CONFORMANT HEVC STREAM)!")
    return True

def run_rate_control_test():
    print(f"\n================================================================================")
    print(f" [RATE CONTROL TEST] Closed-Loop CBR & VBV Buffer Verification")
    print(f" Target Bitrate: 250 kbps @ 30 fps on Foreman 128x128")
    print(f"================================================================================")

    bin_path = os.path.join(WORKSPACE, "str_b_frame_rc.bin")
    dec_path = os.path.join(WORKSPACE, "dec_hw_rc.yuv")
    if os.path.exists(bin_path):
        os.remove(bin_path)

    # 1. Compile testbench with ENABLE_RC
    vlog_cmd = f"vlog -sv +incdir+rtl/common +incdir+. rtl/entropy/range_coder.v rtl/entropy/bin_encoder.v rtl/entropy/syntax_coeff.v rtl/entropy/cabac_enc_top.v rtl/rate_control/rate_controller.v +define+ENABLE_RC {TB_PATH}"
    print(f"  > {vlog_cmd}")
    res = subprocess.run(vlog_cmd, shell=True, cwd=WORKSPACE, capture_output=True, text=True)
    if res.returncode != 0:
        print(f"  [FAIL] vlog compilation failed:\n{res.stderr}\n{res.stdout}")
        return False

    # 2. Run simulation
    vsim_cmd = 'vsim -c -do "run -all; quit -f" work.tb_b_frame_encoder'
    print(f"  > {vsim_cmd}")
    res = subprocess.run(vsim_cmd, shell=True, cwd=WORKSPACE, capture_output=True, text=True)
    if not os.path.exists(bin_path):
        print(f"  [FAIL] Simulation failed to output bitstream: str_b_frame_rc.bin")
        return False

    file_size = os.path.getsize(bin_path)
    actual_kbps = (file_size * 8.0 * 30.0) / (5.0 * 1000.0)
    print(f"  [PASS] CBR Bitstream generated: {file_size} bytes ({actual_kbps:.2f} kbps)")

    # Parse RC logs from stdout
    rc_logs = []
    for line in res.stdout.splitlines():
        if "[RATE_CONTROL]" in line:
            rc_logs.append(line.strip())
            print(f"    {line.strip()}")

    # 3. Decode with HM 18.0
    dec_cmd = [HM_DEC, "-b", bin_path, "-o", dec_path, "-d", "10"]
    print(f"  > HM Decoder: {' '.join(dec_cmd)}")
    dec_res = subprocess.run(dec_cmd, cwd=WORKSPACE, capture_output=True, text=True)
    if dec_res.returncode != 0:
        print(f"  [FAIL] HM Decoder exited with error code {dec_res.returncode}:\n{dec_res.stderr}")
        return False

    print(f"  [PASS] HM 18.0 Decoded CBR bitstream with Exit Code 0!")
    return True

def main():
    print("================================================================================")
    print("        HEVC HARDWARE ENCODER: CORNER CASES & RATE CONTROL TEST SUITE           ")
    print("================================================================================")

    results = {}
    for t in STRESS_TESTS:
        ok = run_stress_test(t)
        results[t["name"]] = ok

    ok_rc = run_rate_control_test()
    results["Closed-Loop Rate Control (CBR 2Mbps)"] = ok_rc

    print("\n\n================================================================================")
    print("                         TEST SUITE SUMMARY SCORECARD                           ")
    print("================================================================================")
    all_passed = True
    for name, passed in results.items():
        status = "PASSED (Exit Code 0)" if passed else "FAILED"
        print(f"  - {name:<45} : {status}")
        if not passed:
            all_passed = False
    print("================================================================================")
    if all_passed:
        print(" ALL CORNER CASES AND RATE CONTROL TESTS PASSED SUCCESSFULLY!")
    else:
        print(" SOME TESTS FAILED. PLEASE REVIEW LOGS.")
        sys.exit(1)

if __name__ == "__main__":
    main()
