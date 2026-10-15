import os
import sys
import struct
import subprocess
import re
from datetime import datetime
from collections import Counter

def run_decoder(bitstream="str_b_frame.bin", output_yuv="dec_gate.yuv", enable_loop_filters=False):
    decoder_exe = r"HM\bin\mgwmake\gcc-mingw-14.2\x86_64\release\TAppDecoder.exe"
    
    env = os.environ.copy()
    if not enable_loop_filters:
        env["DISABLE_LOOP_FILTERS"] = "1"
    elif "DISABLE_LOOP_FILTERS" in env:
        del env["DISABLE_LOOP_FILTERS"]
    
    cmd = [
        decoder_exe,
        "-b", bitstream,
        "-o", output_yuv,
        "-d", "10"
    ]
    
    print(f"Running Decoder: {' '.join(cmd)}")
    try:
        subprocess.run(cmd, env=env, check=True)
    except subprocess.CalledProcessError as e:
        print(f"Error running decoder: {e}")
        sys.exit(1)
    except FileNotFoundError:
        print(f"Decoder executable not found at {decoder_exe}")
        sys.exit(1)

def compare_yuvs(hw_yuv="hw_recon.yuv", dec_yuv="dec_gate.yuv", width=128, height=128, num_frames=3, enable_loop_filters=False, phase1=False):
    if not os.path.exists(hw_yuv) or not os.path.exists(dec_yuv):
        print(f"YUV files missing. Check {hw_yuv} and {dec_yuv}")
        sys.exit(1)
        
    luma_size = width * height
    chroma_size = (width // 2) * (height // 2)
    samples_per_frame = luma_size + 2 * chroma_size
    bytes_per_frame = samples_per_frame * 2
    
    global_max_diff = 0
    frames_checked = 0
    
    with open(hw_yuv, "rb") as f_hw, open(dec_yuv, "rb") as f_dec:
        for f in range(num_frames):
            hw_data = f_hw.read(bytes_per_frame)
            dec_data = f_dec.read(bytes_per_frame)
            
            if not hw_data or not dec_data:
                if f == 0:
                    print(f"Error: No data available for frame {f}")
                    sys.exit(1)
                print(f"Reached EOF after {f} frames.")
                break
                
            hw_samples = struct.unpack(f"<{samples_per_frame}H", hw_data)
            dec_samples = struct.unpack(f"<{samples_per_frame}H", dec_data)
            frames_checked += 1
            
            # Component breakdown: Y, Cb, Cr
            comp_ranges = [
                ("Y ", hw_samples[0:luma_size], dec_samples[0:luma_size]),
                ("Cb", hw_samples[luma_size:luma_size + chroma_size], dec_samples[luma_size:luma_size + chroma_size]),
                ("Cr", hw_samples[luma_size + chroma_size:samples_per_frame], dec_samples[luma_size + chroma_size:samples_per_frame]),
            ]
            
            f_max_diff = 0
            f_exact_count = 0
            f_sum_diff = 0
            
            print(f"\n--- Frame {f} ---")
            for comp_name, h_comp, d_comp in comp_ranges:
                c_len = len(h_comp)
                c_diff = [abs(h - d) for h, d in zip(h_comp, d_comp)]
                c_exact = c_diff.count(0)
                c_max = max(c_diff)
                c_avg = sum(c_diff) / c_len
                f_exact_count += c_exact
                f_sum_diff += sum(c_diff)
                if c_max > f_max_diff:
                    f_max_diff = c_max
                print(f"  [{comp_name}] Exact: {c_exact}/{c_len} ({c_exact*100/c_len:.2f}%) | Max Diff: {c_max:3d} | Avg Diff: {c_avg:.4f}")
                
            f_avg_diff = f_sum_diff / samples_per_frame
            print(f"  [Total] Exact: {f_exact_count}/{samples_per_frame} ({f_exact_count*100/samples_per_frame:.2f}%) | Max Diff: {f_max_diff:3d} | Avg Diff: {f_avg_diff:.4f}")
            
            if f_max_diff > global_max_diff:
                global_max_diff = f_max_diff

    print("\n=======================================================")
    print(" REGRESSION GATE VERIFICATION SUMMARY")
    print("=======================================================")
    print(f"Frames verified: {frames_checked}")
    print(f"Loop filters enabled: {enable_loop_filters}")
    print(f"Global Max Sample Difference: {global_max_diff}")
    
    if global_max_diff > 0:
        print(f"\nFAIL: Bit-exact conformance failure (global_max_diff = {global_max_diff} > 0)")
        sys.exit(1)
    else:
        print(f"\nPASS: Full {frames_checked}-frame 100.00% bit-exact match against HM 18.0 across all components Y, Cb, Cr (global_max_diff = 0)!")

def parse_transcript(transcript_file="transcript"):
    if not os.path.exists(transcript_file):
        print(f"Transcript file {transcript_file} not found. Skipping parsing.")
        return
        
    cu_sizes = Counter()
    best_modes = Counter()
    splits = Counter()
    
    tu_sizes_luma = Counter()
    tu_sizes_chroma = Counter()
    
    intra_modes = Counter()
    
    # Regexes
    # [MODE_DECISION] ... SIZE=... BEST=... SPLIT=...
    re_mode = re.compile(r"\[MODE_DECISION\].*SIZE=(\d+).*BEST=(\w+).*SPLIT=(\d+)")
    # pu_cu_splitter.*tu_size_log2
    re_tu = re.compile(r"pu_cu_splitter.*tu_size_log2\s*[:=]\s*(\d+).*tu_comp\s*[:=]\s*(\d+)")
    # CABAC_ENC_TOP.*cu_intra_mode
    re_intra = re.compile(r"CABAC_ENC_TOP.*cu_intra_mode\s*[:=]\s*(\d+)")
    
    dst_vii_invoked = False
    
    with open(transcript_file, "r") as f:
        for line in f:
            m_mode = re_mode.search(line)
            if m_mode:
                size, best, split = m_mode.groups()
                cu_sizes[size] += 1
                best_modes[best] += 1
                splits[split] += 1
                
            m_tu = re_tu.search(line)
            if m_tu:
                tu_size, tu_comp = m_tu.groups()
                if tu_comp == "0":
                    tu_sizes_luma[tu_size] += 1
                    if tu_size == "2":
                        dst_vii_invoked = True
                else:
                    tu_sizes_chroma[tu_size] += 1
                    
            m_intra = re_intra.search(line)
            if m_intra:
                intra_modes[m_intra.group(1)] += 1
                
    # Summaries
    print("\n--- SIMULATION SUMMARY ---")
    print("CU Size Histogram:")
    for k, v in sorted(cu_sizes.items()): print(f"  Size {k}: {v}")
    
    print("\nTU Size Histogram:")
    print("  Luma:")
    for k, v in sorted(tu_sizes_luma.items()): print(f"    log2(Size) {k}: {v}")
    print("  Chroma:")
    for k, v in sorted(tu_sizes_chroma.items()): print(f"    log2(Size) {k}: {v}")
    
    print("\nIntra Mode Histogram:")
    for k, v in sorted(intra_modes.items()): print(f"  Mode {k}: {v}")
    
    print("\nSplit Decisions:")
    for k, v in sorted(splits.items()): print(f"  SPLIT={k}: {v}")
    
    print("\nMode Type Histogram:")
    for k, v in sorted(best_modes.items()): print(f"  {k}: {v}")
    
    # Warnings
    print("\n--- WARNINGS ---")
    warnings = 0
    if len(splits) == 0 or (len(splits) == 1 and "0" in splits):
        print("WARNING: No CU splits occurred (all SPLIT=0)")
        warnings += 1
        
    all_tu_sizes = set(tu_sizes_luma.keys()) | set(tu_sizes_chroma.keys())
    if len(all_tu_sizes) <= 1:
        print("WARNING: Only one TU size appears")
        warnings += 1
        
    if not dst_vii_invoked:
        print("WARNING: DST-VII was never invoked (no tu_size_log2=2 with tu_comp=0)")
        warnings += 1
        
    if len(intra_modes) < 3:
        print("WARNING: Fewer than 3 distinct intra modes appeared")
        warnings += 1
        
    if warnings == 0:
        print("No warnings.")

def print_metadata(bitstream, enable_loop_filters=False):
    print("\n--- RUN METADATA ---")
    print(f"Date/Time: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"DISABLE_LOOP_FILTERS: {'0 (loop filters enabled)' if enable_loop_filters else '1 (forced in script)'}")
    
    if os.path.exists(bitstream):
        print(f"Bitstream: {bitstream} ({os.path.getsize(bitstream)} bytes)")
    else:
        print(f"Bitstream: {bitstream} (FILE NOT FOUND)")

def main():
    import argparse
    parser = argparse.ArgumentParser(description="HEVC Regression Gate")
    parser.add_argument("--enable-loop-filters", action="store_true", help="Enable in-loop filters in HM decoder (omit DISABLE_LOOP_FILTERS)")
    parser.add_argument("--bitstream", default="str_b_frame.bin", help="Input bitstream")
    parser.add_argument("--hw-yuv", default="hw_recon.yuv", help="Hardware reconstructed YUV")
    parser.add_argument("--dec-yuv", default="dec_gate.yuv", help="Decoder reconstructed YUV")
    parser.add_argument("--transcript", default="transcript", help="Simulation transcript")
    parser.add_argument("--phase1", action="store_true", help="Deprecated (unmasked full verification is now standard)")
    parser.add_argument("--num-frames", type=int, default=3, help="Number of frames (default: 3)")
    args = parser.parse_args()
    
    print_metadata(args.bitstream, enable_loop_filters=args.enable_loop_filters)
    
    run_decoder(bitstream=args.bitstream, output_yuv=args.dec_yuv, enable_loop_filters=args.enable_loop_filters)
    compare_yuvs(hw_yuv=args.hw_yuv, dec_yuv=args.dec_yuv, num_frames=args.num_frames, enable_loop_filters=args.enable_loop_filters, phase1=args.phase1)
    parse_transcript(args.transcript)

if __name__ == "__main__":
    main()
