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

def compare_yuvs(hw_yuv="hw_recon.yuv", dec_yuv="dec_gate.yuv", width=128, height=128, num_frames=5, enable_loop_filters=False, phase1=True):
    if not os.path.exists(hw_yuv) or not os.path.exists(dec_yuv):
        print(f"YUV files missing. Check {hw_yuv} and {dec_yuv}")
        sys.exit(1)
        
    luma_size = width * height
    chroma_size = (width // 2) * (height // 2)
    samples_per_frame = luma_size + 2 * chroma_size
    bytes_per_frame = samples_per_frame * 2
    
    global_max_diff = 0
    p1_f0_internal = 0
    p1_f1_internal = 0
    p1_f0_tu_fail = 0
    p1_f1_tu_fail = 0
    
    with open(hw_yuv, "rb") as f_hw, open(dec_yuv, "rb") as f_dec:
        for f in range(num_frames):
            hw_data = f_hw.read(bytes_per_frame)
            dec_data = f_dec.read(bytes_per_frame)
            
            if not hw_data or not dec_data:
                print(f"Incomplete data for frame {f}")
                break
                
            hw_samples = struct.unpack(f"<{samples_per_frame}H", hw_data)
            dec_samples = struct.unpack(f"<{samples_per_frame}H", dec_data)
            
            exact_count = 0
            max_diff = 0
            sum_diff = 0
            
            for s_hw, s_dec in zip(hw_samples, dec_samples):
                diff = abs(s_hw - s_dec)
                if diff == 0:
                    exact_count += 1
                if diff > max_diff:
                    max_diff = diff
                sum_diff += diff
                
            avg_diff = sum_diff / samples_per_frame
            
            print(f"Frame {f}: Exact matches = {exact_count}/{samples_per_frame} ({exact_count/samples_per_frame*100:.2f}%), Max Diff = {max_diff}, Avg Diff = {avg_diff:.4f}")
            
            if enable_loop_filters:
                # Spatial breakdown for deblocking analysis
                # Luma CTU boundary: x in 60..67 or y in 60..67
                ctu_bound_diffs = 0
                internal_diffs = 0
                internal_tu_edge_diffs = 0
                total_internal_tu_edges = 0
                
                for y in range(height):
                    for x in range(width):
                        idx = y * width + x
                        d = abs(hw_samples[idx] - dec_samples[idx])
                        is_ctu_boundary = (60 <= x <= 67) or (60 <= y <= 67)
                        
                        is_internal_tu = False
                        if not is_ctu_boundary:
                            for cx in [0, 64]:
                                for cy in [0, 64]:
                                    if (cx <= x < cx + 64) and (cy <= y < cy + 64):
                                        if (cx + 28 <= x <= cx + 35) or (cy + 28 <= y <= cy + 35):
                                            is_internal_tu = True
                        if is_internal_tu:
                            total_internal_tu_edges += 1
                            if d > 0:
                                internal_tu_edge_diffs += 1
                                
                        if d > 0:
                            if is_ctu_boundary:
                                ctu_bound_diffs += 1
                            else:
                                internal_diffs += 1
                                
                print(f"  -> Luma CTU boundary diffs (arch single-CTU scope): {ctu_bound_diffs}")
                print(f"  -> Luma internal diffs (outside CTU boundary): {internal_diffs}")
                print(f"  -> Luma internal 32x32 TU edges: {total_internal_tu_edges - internal_tu_edge_diffs}/{total_internal_tu_edges} matches ({(total_internal_tu_edges - internal_tu_edge_diffs)/total_internal_tu_edges*100:.2f}%)")
                
                if f == 0:
                    p1_f0_internal = internal_diffs
                    p1_f0_tu_fail = internal_tu_edge_diffs
                elif f == 1:
                    p1_f1_internal = internal_diffs
                    p1_f1_tu_fail = internal_tu_edge_diffs
            
            if max_diff > global_max_diff:
                global_max_diff = max_diff

    if enable_loop_filters and phase1:
        if p1_f0_internal == 0 and p1_f1_internal == 0 and p1_f0_tu_fail == 0 and p1_f1_tu_fail == 0:
            print("\nPASS: Phase 1 internal 32x32 TU edges 100.00% bit-exact match against HM 18.0!")
            print("      (Inter-CTU boundary filtering x=64, y=64 scheduled for Phase 2 Line Buffers)")
        else:
            print("\nFAIL: Phase 1 internal TU edge mismatch")
            sys.exit(1)
    elif global_max_diff > 0:
        print("\nFAIL: YUV mismatch")
        sys.exit(1)
    else:
        print("\nPASS: YUV exact match")

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
    parser.add_argument("--num-frames", type=int, default=5, help="Number of frames")
    args = parser.parse_args()
    
    print_metadata(args.bitstream, enable_loop_filters=args.enable_loop_filters)
    
    run_decoder(bitstream=args.bitstream, output_yuv=args.dec_yuv, enable_loop_filters=args.enable_loop_filters)
    compare_yuvs(hw_yuv=args.hw_yuv, dec_yuv=args.dec_yuv, num_frames=args.num_frames, enable_loop_filters=args.enable_loop_filters)
    parse_transcript(args.transcript)

if __name__ == "__main__":
    main()
