#!/usr/bin/env python3
"""
scripts/run_sao_rc_validation.py
End-to-End Simulation & Verification Runner:
Rate Control (cfg_rc_enable = 1) + SAO (cfg_sao_enable = 1) across 3 frames (I, P, B).
"""

import os
import sys
import subprocess
import struct
import shutil

WORKSPACE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODELSIM_DIR = r"C:\altera\13.0sp1\modelsim_ase\win32aloem"
VLOG = os.path.join(MODELSIM_DIR, "vlog.exe")
VSIM = os.path.join(MODELSIM_DIR, "vsim.exe")
HM_DEC = os.path.join(WORKSPACE, r"HM\bin\mgwmake\gcc-mingw-14.2\x86_64\release\TAppDecoder.exe")
TB_PATH = "tb/tb_full_encoder/tb_b_frame_encoder.v"

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
    "rtl/inter/mc_window_fetch.v",
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

def main():
    print("================================================================================")
    print(" HEVC HARDWARE ENCODER: RATE CONTROL + SAO 3-FRAME INTEGRATION RUNNER")
    print(" Modes: Rate Control (CBR 250 kbps) + SAO Band Offset (Pointwise Bit-Exact)")
    print(" Sequence: Foreman 128x128 10-bit (3 frames: I, P, B)")
    print("================================================================================")

    # Clean old artifacts
    files_to_clean = [
        "str_b_frame.bin", "hw_recon.yuv", "hw_recon_pre.yuv", "dec_foreman.yuv",
        "str_b_frame_rc.bin", "hw_recon_rc.yuv", "dec_hw_rc.yuv"
    ]
    for fn in files_to_clean:
        p = os.path.join(WORKSPACE, fn)
        if os.path.exists(p):
            try: os.remove(p)
            except: pass

    # 1. Compile RTL + Testbench
    print("\n[Step 1/5] Compiling RTL and TB into work with REMEDIATION + ENABLE_RC + CFG_SAO_ENABLE...")
    sources_str = " ".join(RTL_SOURCES)
    vlog_cmd = (
        f'"{VLOG}" -work work -sv +define+REMEDIATION +define+ENABLE_RC +define+CFG_SAO_ENABLE +define+CFG_TOTAL_FRAMES=3 '
        f'+incdir+rtl/common +incdir+rtl/top +incdir+rtl/entropy +incdir+rtl/inloop_filters '
        f'{sources_str} {TB_PATH}'
    )
    res = subprocess.run(vlog_cmd, shell=True, cwd=WORKSPACE, capture_output=True, text=True)
    if res.returncode != 0:
        print(f"[FAIL] vlog compilation failed:\n{res.stderr}\n{res.stdout}")
        sys.exit(1)
    print("  [PASS] vlog compiled successfully.")

    # 2. Run ModelSim Simulation
    print("\n[Step 2/5] Running ModelSim simulation (tb_b_frame_encoder)...")
    log_file = os.path.join(WORKSPACE, "transcript_3frames.log").replace("\\", "/")
    vsim_cmd = f'"{VSIM}" -c +nospecify -nosva -noimmedassert -l "{log_file}" -do "run -all; quit -f" work.tb_b_frame_encoder'
    res = subprocess.run(vsim_cmd, shell=True, cwd=WORKSPACE, capture_output=True, text=True)
    if res.returncode != 0:
        print(f"[FAIL] vsim simulation failed with code {res.returncode}")
        sys.exit(1)

    bin_path = os.path.join(WORKSPACE, "str_b_frame.bin")
    rec_path = os.path.join(WORKSPACE, "hw_recon.yuv")
    if not os.path.exists(bin_path) or os.path.getsize(bin_path) == 0:
        print(f"[FAIL] Bitstream {bin_path} not generated or empty!")
        sys.exit(1)
    if not os.path.exists(rec_path) or os.path.getsize(rec_path) == 0:
        print(f"[FAIL] Recon YUV {rec_path} not generated or empty!")
        sys.exit(1)

    bin_size = os.path.getsize(bin_path)
    rec_size = os.path.getsize(rec_path)
    print(f"  [PASS] Simulation completed successfully!")
    print(f"         Bitstream generated: {bin_size} bytes ({bin_path})")
    print(f"         Hardware Recon YUV:  {rec_size} bytes ({rec_path})")

    # Copy to RC filenames
    shutil.copy(bin_path, os.path.join(WORKSPACE, "str_b_frame_rc.bin"))
    shutil.copy(rec_path, os.path.join(WORKSPACE, "hw_recon_rc.yuv"))

    # 3. Decode with HM 18.0
    print("\n[Step 3/5] Decoding bitstream with HM 18.0 Reference Decoder (TAppDecoder)...")
    dec_path = os.path.join(WORKSPACE, "dec_foreman.yuv")
    dec_cmd = [HM_DEC, "-b", bin_path, "-o", dec_path, "-d", "10"]
    dec_res = subprocess.run(dec_cmd, cwd=WORKSPACE, capture_output=True, text=True)
    if dec_res.returncode != 0:
        print(f"[FAIL] HM Decoder exited with error code {dec_res.returncode}:\n{dec_res.stderr}\n{dec_res.stdout}")
        sys.exit(1)

    print("HM 18.0 Decoder Output:")
    for line in dec_res.stdout.splitlines():
        if "POC" in line or "Total Time" in line or "bytes" in line:
            print(f"  {line.strip()}")
    print("  [PASS] HM 18.0 decoded stream with EXIT CODE 0 (zero syntax errors)!")

    shutil.copy(dec_path, os.path.join(WORKSPACE, "dec_hw_rc.yuv"))

    # 4. Verify Bit-Exactness
    print("\n[Step 4/5] Verifying 100% Bit-Exact Reconstruction (HW Recon vs. HM Decoded)...")
    width = 128
    height = 128
    frames = 3
    luma_size = width * height
    chroma_size = (width // 2) * (height // 2)
    samples_per_frame = luma_size + 2 * chroma_size
    bytes_per_frame = samples_per_frame * 2
    total_samples = frames * samples_per_frame

    global_max_diff = 0
    total_exact = 0

    with open(rec_path, "rb") as f_hw, open(dec_path, "rb") as f_dec:
        for f in range(frames):
            hw_bytes = f_hw.read(bytes_per_frame)
            dec_bytes = f_dec.read(bytes_per_frame)
            if len(hw_bytes) < bytes_per_frame or len(dec_bytes) < bytes_per_frame:
                print(f"  [FAIL] Incomplete frame data for frame {f}")
                sys.exit(1)

            hw_s = struct.unpack(f"<{samples_per_frame}H", hw_bytes)
            dec_s = struct.unpack(f"<{samples_per_frame}H", dec_bytes)

            comp_ranges = [
                ("Y ", hw_s[0:luma_size], dec_s[0:luma_size]),
                ("Cb", hw_s[luma_size:luma_size + chroma_size], dec_s[luma_size:luma_size + chroma_size]),
                ("Cr", hw_s[luma_size + chroma_size:samples_per_frame], dec_s[luma_size + chroma_size:samples_per_frame]),
            ]

            frame_type = "I-Frame" if f == 0 else ("P-Frame" if f == 1 else "B-Frame")
            print(f"\n  Frame {f} ({frame_type}, POC {f}):")
            for cname, hc, dc in comp_ranges:
                diffs = [abs(h - d) for h, d in zip(hc, dc)]
                c_max = max(diffs)
                c_exact = diffs.count(0)
                total_exact += c_exact
                if c_max > global_max_diff:
                    global_max_diff = c_max
                print(f"    Component [{cname}]: Exact {c_exact}/{len(hc)} ({c_exact*100.0/len(hc):.2f}%) | Max Diff: {c_max}")

    exact_pct = (total_exact * 100.0) / total_samples
    print(f"\n================================================================================")
    print(f" BIT-EXACT CONFORMANCE SUMMARY:")
    print(f"   Total Samples Tested:   {total_samples} (across 3 frames, 10-bit YUV 4:2:0)")
    print(f"   Exact Matching Samples: {total_exact} ({exact_pct:.2f}%)")
    print(f"   Global Maximum Diff:    {global_max_diff}")
    print(f"================================================================================")

    if global_max_diff == 0:
        print(">>> SUCCESS: 100.00% BIT-EXACT CONFORMANCE ACHIEVED (max_diff == 0)! <<<")
    else:
        print(f">>> FAILURE: Deviation detected! max_diff = {global_max_diff} <<<")
        sys.exit(1)

    # 5. Visual Artifacts
    print("\n[Step 5/5] Generating Visual Verification Artifacts and Dashboard...")
    subprocess.run([sys.executable, "scripts/visualize_and_evaluate_foreman.py"], cwd=WORKSPACE, check=True)
    subprocess.run([sys.executable, "scripts/build_visual_verification_app.py"], cwd=WORKSPACE, check=True)
    print("\n[ALL TASKS COMPLETED SUCCESSFULLY]")

if __name__ == "__main__":
    main()
