import os
import sys
import struct
import subprocess
import re
from datetime import datetime
from collections import Counter

def run_decoder(bitstream="str_b_frame.bin", output_yuv="dec_gate.yuv"):
    decoder_exe = r"HM\bin\mgwmake\gcc-mingw-14.2\x86_64\release\TAppDecoder.exe"
    
    env = os.environ.copy()
    env["DISABLE_LOOP_FILTERS"] = "1"
    
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

def compare_yuvs(hw_yuv="hw_recon.yuv", dec_yuv="dec_gate.yuv", width=128, height=128, num_frames=5):
    if not os.path.exists(hw_yuv) or not os.path.exists(dec_yuv):
        print(f"YUV files missing. Check {hw_yuv} and {dec_yuv}")
        sys.exit(1)
        
    samples_per_frame = width * height + 2 * (width // 2) * (height // 2)
    bytes_per_frame = samples_per_frame * 2
    
    global_max_diff = 0
    
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
            
            print(f"Frame {f}: Exact matches = {exact_count}/{samples_per_frame}, Max Diff = {max_diff}, Avg Diff = {avg_diff:.4f}")
            
            if max_diff > global_max_diff:
                global_max_diff = max_diff

    if global_max_diff > 0:
        print("FAIL: YUV mismatch")
        sys.exit(1)
    else:
        print("PASS: YUV exact match")

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

def print_metadata(bitstream):
    print("\n--- RUN METADATA ---")
    print(f"Date/Time: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"DISABLE_LOOP_FILTERS: {os.environ.get('DISABLE_LOOP_FILTERS', '1 (forced in script)')}")
    
    if os.path.exists(bitstream):
        print(f"Bitstream: {bitstream} ({os.path.getsize(bitstream)} bytes)")
    else:
        print(f"Bitstream: {bitstream} (FILE NOT FOUND)")

def main():
    bitstream = "str_b_frame.bin"
    
    print_metadata(bitstream)
    
    run_decoder(bitstream=bitstream, output_yuv="dec_gate.yuv")
    compare_yuvs()
    parse_transcript()

if __name__ == "__main__":
    main()
