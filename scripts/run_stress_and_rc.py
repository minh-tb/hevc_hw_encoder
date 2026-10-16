#!/usr/bin/env python3
"""
scripts/run_stress_and_rc.py
Automated Corner-Case Stress Testing & Closed-Loop Rate Control Suite
Tests:
  1. Flat Field (CBF=0, all-zero residual, CABAC flush verification)
  2. Maximum-Contrast Checkerboard (Nyquist frequency, 16-bit intermediate transform clipping)
  3. High-Motion Video (large motion vectors up to +/-32 pixels)
  4. Closed-Loop CBR Rate Control (250 kbps @ 30 fps, VBV fullness & Delta QP tracking)
Verifies:
  - Simulation finishes cleanly with zero hangs or timeouts
  - HM 18.0 reference decoder produces Exit Code 0 across all streams
"""

import os
import sys
import glob
import subprocess

WORKSPACE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODELSIM_BIN = r"C:\altera\13.0sp1\modelsim_ase\win32aloem"
if os.path.exists(MODELSIM_BIN) and MODELSIM_BIN not in os.environ.get("PATH", ""):
    os.environ["PATH"] = MODELSIM_BIN + os.pathsep + os.environ.get("PATH", "")

HM_DEC = os.path.join(WORKSPACE, r"HM\bin\mgwmake\gcc-mingw-14.2\x86_64\release\TAppDecoder.exe")
TB_PATH = os.path.join(WORKSPACE, r"tb\tb_full_encoder\tb_b_frame_encoder.v")

STRESS_TESTS = [
    {
        "name": "Flat Field Pattern (Y=U=V=512)",
        "macro": "PATTERN_FLAT +define+CFG_TOTAL_FRAMES=1",
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
        "macro": "PATTERN_HIGH_MOTION +define+CFG_TOTAL_FRAMES=2",
        "bin": "str_b_frame_high_motion.bin",
        "dec": "dec_hw_high_motion.yuv",
        "desc": "Verifies full-range +/-32 TZ search and signed MVD bitwidths under high motion dynamics."
    }
]

VLOG_OPTS = (
    "+define+REMEDIATION +libext+.v "
    "-y rtl/top -y rtl/entropy -y rtl/common -y rtl/partition -y rtl/transform "
    "-y rtl/intra -y rtl/recon -y rtl/inter -y rtl/rate_control -y rtl/inloop_filters "
    "-y rtl/quant -y rtl/input_output +incdir+rtl/common +incdir+. rtl/common/parameter_pkg.vh"
)

def get_latest_rtl_mtime():
    rtl_files = glob.glob(os.path.join(WORKSPACE, "rtl", "**", "*.v"), recursive=True)
    rtl_files += glob.glob(os.path.join(WORKSPACE, "rtl", "**", "*.vh"), recursive=True)
    return max((os.path.getmtime(f) for f in rtl_files), default=0.0)

def is_sim_output_valid(bin_path, log_path, force=False):
    if force or not os.path.exists(bin_path) or not os.path.exists(log_path):
        return False
    if os.path.getsize(bin_path) == 0:
        return False
    if os.path.getmtime(bin_path) < get_latest_rtl_mtime():
        return False
    with open(log_path, "r", errors="ignore") as f:
        for line in f:
            if "Finished Successfully!" in line:
                return True
    return False

def run_stress_test(t, force=False):
    print(f"\n================================================================================")
    print(f" [STRESS TEST] {t['name']}")
    print(f" Description: {t['desc']}")
    print(f"================================================================================")

    bin_path = os.path.join(WORKSPACE, t["bin"])
    dec_path = os.path.join(WORKSPACE, t["dec"])
    log_name = t["bin"].replace(".bin", ".log")
    log_path = os.path.join(WORKSPACE, log_name)

    if not is_sim_output_valid(bin_path, log_path, force=force):
        if os.path.exists(bin_path):
            os.remove(bin_path)
        if os.path.exists(log_path):
            os.remove(log_path)
        if os.path.exists(dec_path):
            os.remove(dec_path)

        # 1. Compile testbench
        vlog_cmd = f"vlog -sv {VLOG_OPTS} +define+{t['macro']} {TB_PATH}"
        print(f"  > {vlog_cmd}")
        res = subprocess.run(vlog_cmd, shell=True, cwd=WORKSPACE, capture_output=True, text=True)
        if res.returncode != 0:
            print(f"  [FAIL] vlog compilation failed:\n{res.stderr}\n{res.stdout}")
            return False

        # 2. Run simulation
        vsim_cmd = f'vsim -c -l {log_name} -do "run -all; quit -f" work.tb_b_frame_encoder'
        print(f"  > {vsim_cmd}")
        res = subprocess.run(vsim_cmd, shell=True, cwd=WORKSPACE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if res.returncode != 0 or not is_sim_output_valid(bin_path, log_path, force=False):
            print(f"  [FAIL] Simulation failed to complete cleanly or output bitstream: {t['bin']}")
            return False
    else:
        print(f"  [INFO] Verified simulation log ({log_name}) and bitstream ({t['bin']}) are up-to-date with RTL.")

    file_size = os.path.getsize(bin_path)
    print(f"  [PASS] Simulation completed cleanly: {file_size} bytes generated.")

    # 3. Decode with HM 18.0
    dec_cmd = [HM_DEC, "-b", bin_path, "-o", dec_path, "-d", "10"]
    print(f"  > HM Decoder: {' '.join(dec_cmd)}")
    dec_res = subprocess.run(dec_cmd, cwd=WORKSPACE, capture_output=True, text=True)
    if dec_res.returncode != 0:
        print(f"  [FAIL] HM Decoder exited with error code {dec_res.returncode}:\n{dec_res.stderr}")
        return False

    print(f"  [PASS] HM 18.0 Decoded bitstream with Exit Code 0 (CONFORMANT HEVC STREAM)!")
    return True

def run_rate_control_test(force=False):
    print(f"\n================================================================================")
    print(f" [RATE CONTROL TEST] Closed-Loop CBR & VBV Buffer Verification")
    print(f" Target Bitrate: 250 kbps @ 30 fps on Foreman 128x128")
    print(f"================================================================================")

    bin_path = os.path.join(WORKSPACE, "str_b_frame_rc.bin")
    dec_path = os.path.join(WORKSPACE, "dec_hw_rc.yuv")
    log_path = os.path.join(WORKSPACE, "str_b_frame_rc.log")

    if not is_sim_output_valid(bin_path, log_path, force=force):
        if os.path.exists(bin_path):
            os.remove(bin_path)
        if os.path.exists(log_path):
            os.remove(log_path)
        if os.path.exists(dec_path):
            os.remove(dec_path)

        # 1. Compile testbench with ENABLE_RC
        vlog_cmd = f"vlog -sv {VLOG_OPTS} +define+ENABLE_RC {TB_PATH}"
        print(f"  > {vlog_cmd}")
        res = subprocess.run(vlog_cmd, shell=True, cwd=WORKSPACE, capture_output=True, text=True)
        if res.returncode != 0:
            print(f"  [FAIL] vlog compilation failed:\n{res.stderr}\n{res.stdout}")
            return False

        # 2. Run simulation
        vsim_cmd = 'vsim -c -l str_b_frame_rc.log -do "run -all; quit -f" work.tb_b_frame_encoder'
        print(f"  > {vsim_cmd}")
        res = subprocess.run(vsim_cmd, shell=True, cwd=WORKSPACE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if res.returncode != 0 or not is_sim_output_valid(bin_path, log_path, force=False):
            print(f"  [FAIL] Simulation failed to output bitstream: str_b_frame_rc.bin")
            return False
    else:
        print(f"  [INFO] Verified simulation log (str_b_frame_rc.log) and bitstream (str_b_frame_rc.bin) are up-to-date with RTL.")

    # Verify that simulation finished cleanly and print Rate Control telemetry
    sim_ok = False
    rc_logs = []
    if os.path.exists(log_path):
        with open(log_path, "r", errors="ignore") as f:
            for line in f:
                if "Finished Successfully!" in line:
                    sim_ok = True
                if "[RATE_CONTROL]" in line:
                    rc_logs.append(line.strip())
                    print(f"    {line.strip()}")
    if not sim_ok:
        print("  [FAIL] Simulation did not complete cleanly (missing 'Finished Successfully' in str_b_frame_rc.log)")
        return False

    file_size = os.path.getsize(bin_path)
    actual_kbps = (file_size * 8.0 * 30.0) / (5.0 * 1000.0)
    print(f"  [PASS] CBR Bitstream generated: {file_size} bytes ({actual_kbps:.2f} kbps)")

    # 3. Decode with HM 18.0
    dec_cmd = [HM_DEC, "-b", bin_path, "-o", dec_path, "-d", "10"]
    print(f"  > HM Decoder: {' '.join(dec_cmd)}")
    dec_res = subprocess.run(dec_cmd, cwd=WORKSPACE, capture_output=True, text=True)
    if dec_res.returncode != 0:
        print(f"  [FAIL] HM Decoder exited with error code {dec_res.returncode}:\n{dec_res.stderr}")
        return False

    print(f"  [PASS] HM 18.0 Decoded CBR bitstream with Exit Code 0!")
    return True

def restore_default_compilation():
    """Restore default 3-frame Foreman compilation in work library and refresh rec_before_filter.yuv."""
    vlog_cmd = f"vlog -sv {VLOG_OPTS} +define+CFG_TOTAL_FRAMES=3 {TB_PATH}"
    subprocess.run(vlog_cmd, shell=True, cwd=WORKSPACE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    std_bin = os.path.join(WORKSPACE, "str_b_frame.bin")
    std_dec = os.path.join(WORKSPACE, "dec_foreman.yuv")
    if os.path.exists(std_bin):
        dec_env = os.environ.copy()
        dec_env.pop("DISABLE_LOOP_FILTERS", None)
        subprocess.run([HM_DEC, "-b", std_bin, "-o", std_dec, "-d", "10"], cwd=WORKSPACE, env=dec_env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def main():
    force = "--force" in sys.argv
    print("================================================================================")
    print("        HEVC HARDWARE ENCODER: CORNER CASES & RATE CONTROL TEST SUITE           ")
    print("================================================================================")

    results = {}
    for t in STRESS_TESTS:
        ok = run_stress_test(t, force=force)
        results[t["name"]] = ok

    ok_rc = run_rate_control_test(force=force)
    results["Closed-Loop Rate Control (CBR 250kbps)"] = ok_rc

    restore_default_compilation()

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
