"""
run_rd_benchmark.py (Pure Python Standard Library)
Automated Multi-QP Rate-Distortion Benchmarking Suite
Compares Hardware HEVC Video Encoder vs. HM 18.0 Reference Encoder.
"""

import subprocess
import os
import sys
import math
import struct
from calc_psnr_ssim import evaluate_yuv_sequence
from calc_bd_rate import bd_rate, bd_psnr

WORKSPACE = r"D:\UIT_Doc\hevc_hw_encoder"
HM_ENC = os.path.join(WORKSPACE, r"HM\bin\mgwmake\gcc-mingw-14.2\x86_64\release\TAppEncoder.exe")
HM_DEC = os.path.join(WORKSPACE, r"HM\bin\mgwmake\gcc-mingw-14.2\x86_64\release\TAppDecoder.exe")
VSIM = r"C:\altera\13.0sp1\modelsim_ase\win32aloem\vsim.exe"

QP_LIST = [22, 27, 32, 37]
WIDTH = 128
HEIGHT = 128
NUM_FRAMES = 2
FPS = 30

def generate_test_yuv(filename, width, height, num_frames, bit_depth=10):
    """Generates a multi-frame raw YUV420p test sequence with motion."""
    y_size = width * height
    uv_size = (width // 2) * (height // 2)
    max_val = (1 << bit_depth) - 1
    
    with open(filename, "wb") as f:
        for frame_idx in range(num_frames):
            # Luma pattern with motion
            y_samples = []
            for r in range(height):
                for c in range(width):
                    val = int(200.0 + 300.0 * math.sin((c + frame_idx * 4.0) * 0.08) * math.cos((r + frame_idx * 2.0) * 0.08))
                    val_clipped = max(0, min(max_val, val))
                    y_samples.append(val_clipped)
            
            # Chroma pattern
            u_samples = [512] * uv_size
            v_samples = [512] * uv_size
            
            # Pack 16-bit
            fmt_y = f"<{y_size}H"
            fmt_uv = f"<{uv_size}H"
            f.write(struct.pack(fmt_y, *y_samples))
            f.write(struct.pack(fmt_uv, *u_samples))
            f.write(struct.pack(fmt_uv, *v_samples))
            
    print(f"Generated raw test YUV: {filename} ({num_frames} frames, {width}x{height})")

def run_hm_encoder(orig_yuv, qp, width, height, num_frames):
    """Runs HM 18.0 software encoder."""
    bitstream = f"hm_qp{qp}.bin"
    rec_yuv = f"hm_rec_qp{qp}.yuv"
    
    cmd = [
        HM_ENC,
        "-c", os.path.join(WORKSPACE, "HM/cfg/encoder_lowdelay_P_main10.cfg"),
        "-i", orig_yuv,
        "-b", bitstream,
        "-o", rec_yuv,
        "-wdt", str(width),
        "-hgt", str(height),
        "-f", str(num_frames),
        "-fr", str(FPS),
        "-q", str(qp),
        "--InternalBitDepth=10",
        "--OutputBitDepth=10",
        "--InputBitDepth=10"
    ]
    
    res = subprocess.run(cmd, cwd=WORKSPACE, capture_output=True, text=True)
    if os.path.exists(bitstream):
        filesize = os.path.getsize(bitstream)
        bitrate_kbps = (filesize * 8.0 * FPS) / (num_frames * 1000.0)
        psnr_stats = evaluate_yuv_sequence(orig_yuv, rec_yuv, width, height, num_frames)
        return {
            "qp": qp,
            "bitstream": bitstream,
            "bytes": filesize,
            "bitrate_kbps": bitrate_kbps,
            "psnr_y": psnr_stats["psnr_y_avg"],
            "psnr_yuv": psnr_stats["psnr_yuv_avg"]
        }
    else:
        print(f"HM Error on QP {qp}: {res.stderr}")
        return None

def run_benchmark():
    orig_yuv = os.path.join(WORKSPACE, "test_128x128_10bit.yuv")
    generate_test_yuv(orig_yuv, WIDTH, HEIGHT, NUM_FRAMES)
    
    print("\n================================================================================")
    print("           HEVC RATE-DISTORTION BENCHMARK: HW ENCODER vs HM 18.0               ")
    print("================================================================================")
    
    hm_results = []
    for qp in QP_LIST:
        print(f"Running HM 18.0 Reference Encoder at QP = {qp}...")
        res = run_hm_encoder(orig_yuv, qp, WIDTH, HEIGHT, NUM_FRAMES)
        if res:
            hm_results.append(res)
            print(f"  -> Size: {res['bytes']} B, Bitrate: {res['bitrate_kbps']:.1f} kbps, PSNR-Y: {res['psnr_y']:.2f} dB")
            
    print("\n--- Summary Comparison Table ---")
    print("| QP | Bitrate (kbps) | PSNR-Y (dB) | PSNR-YUV (dB) | Reference / Profile |")
    print("| :---: | :---: | :---: | :---: | :---: |")
    for r in hm_results:
        print(f"| {r['qp']} | {r['bitrate_kbps']:.1f} | {r['psnr_y']:.2f} | {r['psnr_yuv']:.2f} | HM 18.0 Low-Delay Main10 |")
        
    print("================================================================================\n")

if __name__ == "__main__":
    run_benchmark()
