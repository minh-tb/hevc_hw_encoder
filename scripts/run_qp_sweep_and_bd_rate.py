#!/usr/bin/env python3
"""
scripts/run_qp_sweep_and_bd_rate.py
Multi-QP Rate-Distortion (RD) Benchmarking & BD-Rate Computation Suite
Compares HEVC Hardware Encoder vs. HM 18.0 Reference Software Anchor
Across QP in {22, 27, 32, 37} on Foreman 128x128 (3 frames: I, P, B, 10-bit).
"""

import os
import sys
import subprocess
import struct
import math
import shutil
import json

sys.path.append(os.path.dirname(os.path.abspath(__file__)))
import plot_rd_curves

WORKSPACE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HM_ENC = os.path.join(WORKSPACE, r"HM\bin\mgwmake\gcc-mingw-14.2\x86_64\release\TAppEncoder.exe")
HM_DEC = os.path.join(WORKSPACE, r"HM\bin\mgwmake\gcc-mingw-14.2\x86_64\release\TAppDecoder.exe")
HM_CFG = os.path.join(WORKSPACE, r"HM\cfg\encoder_lowdelay_main10.cfg")
ORIG_YUV = os.path.join(WORKSPACE, "orig_foreman_128x128_10b.yuv")
TB_PATH = "tb/tb_full_encoder/tb_b_frame_encoder.v"
MODELSIM_DIR = r"C:\altera\13.0sp1\modelsim_ase\win32aloem"
VLOG = os.path.join(MODELSIM_DIR, "vlog.exe")
VSIM = os.path.join(MODELSIM_DIR, "vsim.exe")
VLIB = os.path.join(MODELSIM_DIR, "vlib.exe")

QP_LIST = [22, 27, 32, 37]
WIDTH = 128
HEIGHT = 128
FRAMES = 3
FPS = 30

# Explicit list of all RTL source files to prevent ModelSim -y library caching bug
RTL_SOURCES = [
    "rtl/common/parameter_pkg.vh",
    "rtl/common/axi_read_arbiter.v",
    "rtl/common/hadamard_satd_4x4.v",
    "rtl/entropy/bin_encoder.v",
    "rtl/entropy/cabac_enc_top.v",
    "rtl/entropy/coeff_buffer.v",
    "rtl/entropy/ctx_model_store.v",
    "rtl/entropy/param_set_writer.v",
    "rtl/entropy/range_coder.v",
    "rtl/entropy/syntax_coeff.v",
    "rtl/entropy/syntax_cu.v",
    "rtl/entropy/syntax_pred.v",
    "rtl/entropy/syntax_sao.v",
    "rtl/inloop_filters/boundary_strength.v",
    "rtl/inloop_filters/db_filter_chroma.v",
    "rtl/inloop_filters/db_filter_luma.v",
    "rtl/inloop_filters/deblock_top.v",
    "rtl/inloop_filters/sao_band_offset.v",
    "rtl/inloop_filters/sao_edge_offset.v",
    "rtl/inloop_filters/sao_stats.v",
    "rtl/inloop_filters/sao_top.v",
    "rtl/input_output/nal_writer.v",
    "rtl/inter/fme_search.v",
    "rtl/inter/hpel_filter_chroma.v",
    "rtl/inter/hpel_filter_luma.v",
    "rtl/inter/inter_pred_top.v",
    "rtl/inter/mc_unit.v",
    "rtl/inter/mvp_predictor.v",
    "rtl/inter/ref_frame_buffer.v",
    "rtl/inter/sad_4x4.v",
    "rtl/inter/streaming_subpel_filter.v",
    "rtl/inter/subpel_interpolation_core.v",
    "rtl/inter/tz_search.v",
    "rtl/intra/intra_angular.v",
    "rtl/intra/intra_dc.v",
    "rtl/intra/intra_planar.v",
    "rtl/intra/intra_rmd.v",
    "rtl/intra/intra_pred_top.v",
    "rtl/intra/ref_sample_filter.v",
    "rtl/partition/ctu_partitioner.v",
    "rtl/partition/ctu_raster_scan.v",
    "rtl/partition/mode_decision.v",
    "rtl/partition/pu_cu_splitter.v",
    "rtl/partition/rate_estimator.v",
    "rtl/quant/fwd_quant.v",
    "rtl/quant/inv_quant.v",
    "rtl/rate_control/lambda_calc.v",
    "rtl/rate_control/rate_controller.v",
    "rtl/recon/frame_store.v",
    "rtl/recon/recon_unit.v",
    "rtl/recon/residual_sub.v",
    "rtl/top/address_generator.v",
    "rtl/top/decoder_inloop_filters.v",
    "rtl/top/gop_controller.v",
    "rtl/top/hevc_encoder_top.v",
    "rtl/top/slice_controller.v",
    "rtl/transform/transform_1d_core.v",
    "rtl/transform/transpose_ram_32x32.v",
    "rtl/transform/dct_top.v",
]

sys.path.insert(0, os.path.join(WORKSPACE, "scripts"))
from calc_psnr_ssim import evaluate_yuv_sequence
from calc_bd_rate import bd_rate, bd_psnr
import plot_rd_curves

def verify_bit_exact(hw_yuv, dec_yuv, width=128, height=128, frames=3):
    """Verifies sample-by-sample bit-exact match between HW reconstruction and HM decoded YUV."""
    luma_size = width * height
    chroma_size = (width // 2) * (height // 2)
    samples_per_frame = luma_size + 2 * chroma_size
    bytes_per_frame = samples_per_frame * 2

    global_max_diff = 0
    total_samples = frames * samples_per_frame
    total_exact = 0

    with open(hw_yuv, "rb") as f_hw, open(dec_yuv, "rb") as f_dec:
        for f in range(frames):
            hw_bytes = f_hw.read(bytes_per_frame)
            dec_bytes = f_dec.read(bytes_per_frame)
            if len(hw_bytes) < bytes_per_frame or len(dec_bytes) < bytes_per_frame:
                print(f"  [ERROR] Truncated YUV read for frame {f}")
                return False, -1

            hw_s = struct.unpack(f"<{samples_per_frame}H", hw_bytes)
            dec_s = struct.unpack(f"<{samples_per_frame}H", dec_bytes)

            comp_ranges = [
                ("Y ", hw_s[0:luma_size], dec_s[0:luma_size]),
                ("Cb", hw_s[luma_size:luma_size + chroma_size], dec_s[luma_size:luma_size + chroma_size]),
                ("Cr", hw_s[luma_size + chroma_size:samples_per_frame], dec_s[luma_size + chroma_size:samples_per_frame]),
            ]

            for cname, hc, dc in comp_ranges:
                diffs = [abs(h - d) for h, d in zip(hc, dc)]
                c_max = max(diffs)
                c_exact = diffs.count(0)
                total_exact += c_exact
                if c_max > global_max_diff:
                    global_max_diff = c_max
                print(f"    Frame {f} [{cname}]: Exact {c_exact}/{len(hc)} ({c_exact*100.0/len(hc):.2f}%) | Max Diff: {c_max}")

    exact_pct = total_exact * 100.0 / total_samples
    print(f"  [Bit-Exact Conformance] Total Exact: {total_exact}/{total_samples} ({exact_pct:.2f}%) | Max Diff: {global_max_diff}")
    return (global_max_diff == 0), global_max_diff

def run_hw_encoder(qp, force=False):
    bin_file = os.path.join(WORKSPACE, f"str_b_frame_qp{qp}.bin")
    rec_file = os.path.join(WORKSPACE, f"hw_recon_qp{qp}.yuv")
    dec_file = os.path.join(WORKSPACE, f"dec_hw_qp{qp}.yuv")

    default_bin = os.path.join(WORKSPACE, "str_b_frame.bin")
    default_rec = os.path.join(WORKSPACE, "hw_recon.yuv")

    # Check if already simulated and valid
    expected_rec_size = FRAMES * 24576 * 2
    already_simulated = (
        not force and
        os.path.exists(bin_file) and os.path.getsize(bin_file) > 0 and
        os.path.exists(rec_file) and os.path.getsize(rec_file) == expected_rec_size
    )

    if already_simulated:
        print(f"\n=======================================================")
        print(f" [HW] Reusing Existing Simulation Outputs: QP = {qp}")
        print(f"      Bitstream: {bin_file} ({os.path.getsize(bin_file)} bytes)")
        print(f"      Recon YUV: {rec_file} ({os.path.getsize(rec_file)} bytes)")
        print(f"=======================================================")
    else:
        # Clean up stale files before simulation
        for f in [bin_file, rec_file, dec_file, default_bin, default_rec]:
            if os.path.exists(f):
                try: os.remove(f)
                except: pass

        print(f"\n=======================================================")
        print(f" [HW] Running HW Encoder Simulation: QP = {qp}")
        print(f"=======================================================")

        # 0. Ensure work library exists
        work_lib = f"work_qp{qp}"
        work_dir = os.path.join(WORKSPACE, work_lib)
        if not os.path.exists(work_dir):
            subprocess.run([VLIB, work_lib], cwd=WORKSPACE, capture_output=True, text=True)

        # 1. Compile ALL explicit RTL sources + testbench with REMEDIATION, SWEEP_QP_{qp}, and CFG_TOTAL_FRAMES=3
        # Passing explicit RTL files completely eliminates ModelSim -y library caching issues!
        sources_str = " ".join(RTL_SOURCES)
        vlog_cmd = (
            f'"{VLOG}" -work {work_lib} -sv +define+REMEDIATION +define+SWEEP_QP_{qp} +define+CFG_TOTAL_FRAMES={FRAMES} '
            f'+incdir+rtl/common +incdir+rtl/top {sources_str} {TB_PATH}'
        )
        print(f"  > Compiling RTL + TB explicitly for QP={qp} into {work_lib}...")
        res = subprocess.run(vlog_cmd, shell=True, cwd=WORKSPACE, capture_output=True, text=True)
        if res.returncode != 0:
            print(f"  [ERROR] vlog failed for QP={qp}:\n{res.stderr}\n{res.stdout}")
            return None

        # 2. Run simulation in batch mode with optimization and onbreak handler
        log_file = os.path.join(WORKSPACE, f"vsim_qp{qp}.log").replace("\\", "/")
        do_file = f"run_sim_qp{qp}.do"
        with open(os.path.join(WORKSPACE, do_file), "w") as f_do:
            f_do.write("onbreak {quit -f}\n")
            f_do.write("run -all\n")
            f_do.write("quit -f\n")

        vsim_cmd = f'"{VSIM}" -c +nospecify -nosva -noimmedassert -l "{log_file}" -do {do_file} {work_lib}.tb_b_frame_encoder'
        print(f"  > Simulating testbench (tb_b_frame_encoder) for QP={qp} (work={work_lib})...")
        res = subprocess.run(vsim_cmd, shell=True, cwd=WORKSPACE, input="quit -f\n", text=True, timeout=10800)

        # Clean up temporary DO file
        try: os.remove(os.path.join(WORKSPACE, do_file))
        except: pass
    
    # Handle bitstream output filename
    if not os.path.exists(bin_file) and os.path.exists(default_bin):
        shutil.copyfile(default_bin, bin_file)

    if not os.path.exists(bin_file) or os.path.getsize(bin_file) == 0:
        print(f"  [ERROR] Bitstream file not generated or empty: {bin_file}")
        return None

    file_size = os.path.getsize(bin_file)
    bitrate_kbps = (file_size * 8.0 * FPS) / (FRAMES * 1000.0)
    print(f"  [HW] Bitstream generated: {file_size} bytes ({bitrate_kbps:.2f} kbps)")

    # Handle reconstruction output filename (Gotcha 2)
    if not os.path.exists(rec_file) and os.path.exists(default_rec):
        print(f"  [HW] Copying {default_rec} -> {rec_file}")
        shutil.copyfile(default_rec, rec_file)

    if not os.path.exists(rec_file) or os.path.getsize(rec_file) == 0:
        print(f"  [ERROR] Hardware reconstruction file missing or empty: {rec_file}")
        return None

    # 3. Decode bitstream with HM 18.0 reference decoder
    dec_cmd = [HM_DEC, "-b", bin_file, "-o", dec_file, "-d", "10"]
    print(f"  > HM Reference Decoder: {' '.join(dec_cmd)}")
    dec_res = subprocess.run(dec_cmd, cwd=WORKSPACE, capture_output=True, text=True)
    if dec_res.returncode != 0:
        print(f"  [ERROR] HM Decoder failed with code {dec_res.returncode}:\n{dec_res.stderr}")
        return None
    print(f"  [HW] HM Reference Decoder returned Exit Code 0 (CONFORMANT HEVC STREAM).")

    # 4. Verify bit-exact sample-by-sample match between HW recon and HM decoded YUV
    print(f"  > Verifying sample-by-sample exactness (hw_recon_qp{qp}.yuv vs. dec_hw_qp{qp}.yuv)...")
    is_bit_exact, max_diff = verify_bit_exact(rec_file, dec_file, WIDTH, HEIGHT, FRAMES)
    if not is_bit_exact:
        print(f"  [FATAL] Bit-exact verification failed for QP={qp}: max_diff={max_diff} > 0!")
        return None
    print(f"  [PASS] 100.00% Bit-Exact Match Achieved (max_diff = 0) at QP = {qp}!")

    # 5. Measure PSNR vs Original
    psnr_stats = evaluate_yuv_sequence(ORIG_YUV, dec_file, WIDTH, HEIGHT, FRAMES, bit_depth=10)
    psnr_y = psnr_stats["psnr_y_avg"]
    psnr_yuv = psnr_stats["psnr_yuv_avg"]
    print(f"  [HW] PSNR-Y = {psnr_y:.2f} dB, PSNR-YUV = {psnr_yuv:.2f} dB")

    return {
        "qp": qp,
        "bytes": file_size,
        "bitrate_kbps": bitrate_kbps,
        "psnr_y": psnr_y,
        "psnr_yuv": psnr_yuv,
        "bit_exact": is_bit_exact,
        "max_diff": max_diff
    }

def run_hm_encoder(qp, force=False):
    bin_file = os.path.join(WORKSPACE, f"hm_foreman_qp{qp}.bin")
    rec_file = os.path.join(WORKSPACE, f"hm_rec_foreman_qp{qp}.yuv")

    expected_rec_size = FRAMES * 24576 * 2
    if not force and os.path.exists(bin_file) and os.path.getsize(bin_file) > 0 and os.path.exists(rec_file) and os.path.getsize(rec_file) == expected_rec_size:
        print(f"\n=======================================================")
        print(f" [HM] Reusing Existing HM 18.0 Outputs: QP = {qp}")
        print(f"=======================================================")
        file_size = os.path.getsize(bin_file)
        bitrate_kbps = (file_size * 8.0 * FPS) / (FRAMES * 1000.0)
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

def restore_default_modelsim():
    print("\n--------------------------------------------------------------------------------")
    print(" [CLEANUP] Restoring Default QP=29 Work Library Compilation via compile.do...")
    print("--------------------------------------------------------------------------------")
    for qp in QP_LIST:
        work_dir = os.path.join(WORKSPACE, f"work_qp{qp}")
        if os.path.exists(work_dir):
            try: shutil.rmtree(work_dir)
            except: pass
    try:
        cmd = f'"{VSIM}" -c -do "do compile.do; quit -f"'
        res = subprocess.run(cmd, shell=True, cwd=WORKSPACE, capture_output=True, text=True)
        if res.returncode == 0:
            print("  [CLEANUP] Default ModelSim work library restored successfully.")
        else:
            print(f"  [WARNING] Cleanup vlog reported non-zero return code:\n{res.stderr}")
    except Exception as e:
        print(f"  [WARNING] Cleanup exception: {e}")

def main():
    import argparse
    parser = argparse.ArgumentParser(description="Multi-QP Rate-Distortion Sweeper & BD-Rate Evaluator")
    parser.add_argument("-f", "--force", action="store_true", help="Force re-running HW simulation and HM encoder")
    args = parser.parse_args()

    print("================================================================================")
    print("      MULTI-QP RATE-DISTORTION (RD) BENCHMARKING & BD-RATE EVALUATION           ")
    print("================================================================================")
    print(f"Sequence: Foreman 128x128 10-bit ({FRAMES} frames)")
    print(f"QPs to evaluate: {QP_LIST}")
    if args.force:
        print("Mode: FORCED RE-SIMULATION (ignoring cached outputs)")

    hw_results = []
    hm_results = []

    try:
        # 1. Run HW sweeps concurrently across all QPs
        import concurrent.futures
        print(f"\n[ORCHESTRATOR] Launching concurrent HW simulation workers for QPs: {QP_LIST}...")
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
            future_to_qp = {executor.submit(run_hw_encoder, qp, force=args.force): qp for qp in QP_LIST}
            res_dict = {}
            for future in concurrent.futures.as_completed(future_to_qp):
                qp = future_to_qp[future]
                res = future.result()
                if res:
                    res_dict[qp] = res
                else:
                    print(f"[FATAL] HW encoder failed on QP {qp}")
                    sys.exit(1)
            hw_results = [res_dict[qp] for qp in QP_LIST]

        # 2. Run HM reference sweeps
        for qp in QP_LIST:
            res = run_hm_encoder(qp, force=args.force)
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
        print(f"{'QP':<4} | {'HM Rate (kbps)':<15} | {'HM PSNR-Y':<12} | {'HW Rate (kbps)':<15} | {'HW PSNR-Y':<12} | {'Delta PSNR (dB)':<15} | {'Bit-Exact':<10}")
        print("-" * 97)
        for hw, hm in zip(hw_results, hm_results):
            d_psnr = hw["psnr_y"] - hm["psnr_y"]
            exact_str = "PASS (0 diff)" if hw["bit_exact"] else "FAIL"
            print(f"{hw['qp']:<4} | {hm['bitrate_kbps']:<15.2f} | {hm['psnr_y']:<12.2f} | {hw['bitrate_kbps']:<15.2f} | {hw['psnr_y']:<12.2f} | {d_psnr:+14.2f} dB | {exact_str:<10}")
        print("=" * 97)

        print("\n--------------------------------------------------------------------------------")
        print(f" BJØNTEGAARD DELTA METRICS (HW vs. HM 18.0 Anchor):")
        print(f"   * BD-Rate: {delta_rate:+.2f} % (Bitrate delta at equivalent objective quality)")
        print(f"   * BD-PSNR: {delta_psnr:+.2f} dB (Quality delta at equivalent bitrate)")
        print("--------------------------------------------------------------------------------\n")

        # 5. Export results to JSON
        sweep_data = {
            "sequence": "foreman_128x128_10b",
            "width": WIDTH,
            "height": HEIGHT,
            "frames": FRAMES,
            "fps": FPS,
            "hw_results": hw_results,
            "hm_results": hm_results,
            "bd_metrics": {
                "bd_rate_pct": round(delta_rate, 4),
                "bd_psnr_db": round(delta_psnr, 4)
            }
        }
        json_out = os.path.join(WORKSPACE, "qp_sweep_results.json")
        with open(json_out, "w", encoding="utf-8") as f:
            json.dump(sweep_data, f, indent=2)
        print(f"[SUCCESS] Exported benchmark results to: {json_out}")

        # 6. Generate Plot
        svg_out = os.path.join(WORKSPACE, "rd_curve.svg")
        plot_rd_curves.generate_svg_rd_curve(sweep_data, svg_out)

    finally:
        # 7. Restore ModelSim work library to default QP=29 compilation
        restore_default_modelsim()

if __name__ == "__main__":
    main()
