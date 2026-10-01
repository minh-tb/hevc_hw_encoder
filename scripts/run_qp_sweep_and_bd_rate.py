#!/usr/bin/env python3
"""
scripts/run_qp_sweep_and_bd_rate.py
Multi-QP Rate-Distortion (RD) Benchmarking & BD-Rate Computation Suite
Compares HEVC Hardware Encoder vs. HM 18.0 Reference Software Anchor
Across QP in {22, 27, 32, 37} on Foreman 128x128 (5 frames, 10-bit).
"""

import os
import sys
import subprocess
import struct
import math

WORKSPACE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HM_ENC = os.path.join(WORKSPACE, r"HM\bin\mgwmake\gcc-mingw-14.2\x86_64\release\TAppEncoder.exe")
HM_DEC = os.path.join(WORKSPACE, r"HM\bin\mgwmake\gcc-mingw-14.2\x86_64\release\TAppDecoder.exe")
HM_CFG = os.path.join(WORKSPACE, r"HM\cfg\encoder_lowdelay_main10.cfg")
ORIG_YUV = os.path.join(WORKSPACE, "orig_foreman_128x128_10b.yuv")
TB_PATH = os.path.join(WORKSPACE, r"tb\tb_full_encoder\tb_b_frame_encoder.v")
MODELSIM_DIR = r"C:\altera\13.0sp1\modelsim_ase\win32aloem"
VLOG = os.path.join(MODELSIM_DIR, "vlog.exe")
VSIM = os.path.join(MODELSIM_DIR, "vsim.exe")
VLIB = os.path.join(MODELSIM_DIR, "vlib.exe")

RTL_LIB_FLAGS = (
    "+libext+.v "
    "-y rtl/top -y rtl/entropy -y rtl/common -y rtl/partition "
    "-y rtl/transform -y rtl/intra -y rtl/recon -y rtl/inter "
    "-y rtl/rate_control -y rtl/inloop_filters -y rtl/quant "
    "-y rtl/input_output +incdir+rtl/common"
)

QP_LIST = [22, 27, 32, 37]
WIDTH = 128
HEIGHT = 128
FRAMES = 5
FPS = 30

sys.path.insert(0, os.path.join(WORKSPACE, "scripts"))
from calc_psnr_ssim import evaluate_yuv_sequence
from calc_bd_rate import bd_rate, bd_psnr

def run_hw_encoder(qp):
    bin_file = os.path.join(WORKSPACE, f"str_b_frame_qp{qp}.bin")
    rec_file = os.path.join(WORKSPACE, f"hw_recon_qp{qp}.yuv")
    dec_file = os.path.join(WORKSPACE, f"dec_hw_qp{qp}.yuv")

    if os.path.exists(bin_file):
        try: os.remove(bin_file)
        except: pass
    if os.path.exists(dec_file):
        try: os.remove(dec_file)
        except: pass

    print(f"\n=======================================================")
    print(f" [HW] Running HW Encoder Simulation: QP = {qp}")
    print(f"=======================================================")

    # 0. Ensure work library exists
    work_dir = os.path.join(WORKSPACE, "work")
    if not os.path.exists(work_dir):
        subprocess.run([VLIB, "work"], cwd=WORKSPACE, capture_output=True, text=True)

    # 1. Compile ALL RTL + testbench with specific QP define
    vlog_cmd = f'"{VLOG}" -sv +define+SWEEP_QP_{qp} {RTL_LIB_FLAGS} {TB_PATH} rtl/common/parameter_pkg.vh'
    print(f"  > {vlog_cmd}")
    res = subprocess.run(vlog_cmd, shell=True, cwd=WORKSPACE, capture_output=True, text=True)
    if res.returncode != 0:
        print(f"  [ERROR] vlog failed:\n{res.stderr}\n{res.stdout}")
        return None

    # 2. Run simulation
    vsim_cmd = f'"{VSIM}" -c -do "run -all; quit -f" work.tb_b_frame_encoder'
    print(f"  > {vsim_cmd}")
    res = subprocess.run(vsim_cmd, shell=True, cwd=WORKSPACE, capture_output=True, text=True, timeout=600)
    if not os.path.exists(bin_file):
        print(f"  [ERROR] Bitstream file not generated: {bin_file}")
        return None

    file_size = os.path.getsize(bin_file)
    bitrate_kbps = (file_size * 8.0 * FPS) / (FRAMES * 1000.0)
    print(f"  [HW] Bitstream generated: {file_size} bytes ({bitrate_kbps:.2f} kbps)")

    # 3. Decode bitstream with HM 18.0 reference decoder
    dec_cmd = [HM_DEC, "-b", bin_file, "-o", dec_file, "-d", "10"]
    print(f"  > HM Decoder: {' '.join(dec_cmd)}")
    dec_res = subprocess.run(dec_cmd, cwd=WORKSPACE, capture_output=True, text=True)
    if dec_res.returncode != 0:
        print(f"  [ERROR] HM Decoder failed with return code {dec_res.returncode}:\n{dec_res.stderr}")
        return None
    print(f"  [HW] HM Decoder returned Exit Code 0 (CONFORMANT HEVC STREAM).")

    # 4. Measure PSNR vs Original
    psnr_stats = evaluate_yuv_sequence(ORIG_YUV, dec_file, WIDTH, HEIGHT, FRAMES, bit_depth=10)
    psnr_y = psnr_stats["psnr_y_avg"]
    psnr_yuv = psnr_stats["psnr_yuv_avg"]
    print(f"  [HW] PSNR-Y = {psnr_y:.2f} dB, PSNR-YUV = {psnr_yuv:.2f} dB")

    return {
        "qp": qp,
        "bytes": file_size,
        "bitrate_kbps": bitrate_kbps,
        "psnr_y": psnr_y,
        "psnr_yuv": psnr_yuv
    }

def run_hm_encoder(qp):
    bin_file = os.path.join(WORKSPACE, f"hm_foreman_qp{qp}.bin")
    rec_file = os.path.join(WORKSPACE, f"hm_rec_foreman_qp{qp}.yuv")

    print(f"\n=======================================================")
    print(f" [HM] Running HM 18.0 Reference Encoder: QP = {qp}")
    print(f"=======================================================")

    cmd = [
        HM_ENC,
        "-c", HM_CFG,
        "-i", ORIG_YUV,
        "-b", bin_file,
        "-o", rec_file,
        "-wdt", str(WIDTH),
        "-hgt", str(HEIGHT),
        "-f", str(FRAMES),
        "-fr", str(FPS),
        "-q", str(qp),
        "--InternalBitDepth=10",
        "--OutputBitDepth=10",
        "--InputBitDepth=10"
    ]
    res = subprocess.run(cmd, cwd=WORKSPACE, capture_output=True, text=True)
    if not os.path.exists(bin_file):
        print(f"  [ERROR] HM Encoder failed:\n{res.stderr}")
        return None

    file_size = os.path.getsize(bin_file)
    bitrate_kbps = (file_size * 8.0 * FPS) / (FRAMES * 1000.0)

    # Measure PSNR
    psnr_stats = evaluate_yuv_sequence(ORIG_YUV, rec_file, WIDTH, HEIGHT, FRAMES, bit_depth=10)
    psnr_y = psnr_stats["psnr_y_avg"]
    psnr_yuv = psnr_stats["psnr_yuv_avg"]
    print(f"  [HM] Size: {file_size} bytes ({bitrate_kbps:.2f} kbps), PSNR-Y = {psnr_y:.2f} dB")

    return {
        "qp": qp,
        "bytes": file_size,
        "bitrate_kbps": bitrate_kbps,
        "psnr_y": psnr_y,
        "psnr_yuv": psnr_yuv
    }

def main():
    print("================================================================================")
    print("      MULTI-QP RATE-DISTORTION (RD) BENCHMARKING & BD-RATE EVALUATION           ")
    print("================================================================================")
    print(f"Sequence: Foreman 128x128 10-bit (5 frames)")
    print(f"QPs to evaluate: {QP_LIST}")

    hw_results = []
    hm_results = []

    # 1. Run HW sweeps
    for qp in QP_LIST:
        res = run_hw_encoder(qp)
        if res:
            hw_results.append(res)
        else:
            print(f"[FATAL] HW encoder failed on QP {qp}")
            sys.exit(1)

    # 2. Run HM reference sweeps
    for qp in QP_LIST:
        res = run_hm_encoder(qp)
        if res:
            hm_results.append(res)
        else:
            print(f"[FATAL] HM encoder failed on QP {qp}")
            sys.exit(1)

    # 3. Calculate BD-Rate and BD-PSNR
    hw_rates = [r["bitrate_kbps"] for r in hw_results]
    hw_psnrs = [r["psnr_y"] for r in hw_results]
    hm_rates = [r["bitrate_kbps"] for r in hm_results]
    hm_psnrs = [r["psnr_y"] for r in hm_results]

    delta_rate = bd_rate(hm_rates, hm_psnrs, hw_rates, hw_psnrs)
    delta_psnr = bd_psnr(hm_rates, hm_psnrs, hw_rates, hw_psnrs)

    # 4. Print Scorecard Table
    print("\n\n================================================================================")
    print("                 RATE-DISTORTION BENCHMARK SCORECARD TABLE                      ")
    print("================================================================================")
    print(f"{'QP':<4} | {'HM Rate (kbps)':<15} | {'HM PSNR-Y':<12} | {'HW Rate (kbps)':<15} | {'HW PSNR-Y':<12} | {'Delta PSNR (dB)':<15}")
    print("-" * 84)
    for hw, hm in zip(hw_results, hm_results):
        d_psnr = hw["psnr_y"] - hm["psnr_y"]
        print(f"{hw['qp']:<4} | {hm['bitrate_kbps']:<15.2f} | {hm['psnr_y']:<12.2f} | {hw['bitrate_kbps']:<15.2f} | {hw['psnr_y']:<12.2f} | {d_psnr:+14.2f} dB")
    print("=" * 84)

    print("\n--------------------------------------------------------------------------------")
    print(f" BJØNTEGAARD DELTA METRICS (HW vs. HM 18.0 Anchor):")
    print(f"   * BD-Rate: {delta_rate:+.2f} % (Bitrate delta at equivalent objective quality)")
    print(f"   * BD-PSNR: {delta_psnr:+.2f} dB (Quality delta at equivalent bitrate)")
    print("--------------------------------------------------------------------------------\n")

if __name__ == "__main__":
    main()
