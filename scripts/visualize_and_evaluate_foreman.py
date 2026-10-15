"""
visualize_and_evaluate_foreman.py
Evaluates str_b_frame.bin (Foreman 128x128 10-bit sequence) decoded with HM 18.0,
calculates PSNR and SSIM, checks conformance against hw_recon.yuv,
exports side-by-side tri-comparison images and diff heatmaps,
and synchronizes visual verification artifacts.
"""

import os
import sys
import struct
import math
import subprocess
import zlib
import shutil
import base64

WIDTH = 128
HEIGHT = 128
ARTIFACT_DIR = r"C:\Users\Admin\.gemini\antigravity\brain\e27560eb-42b9-45b7-8dc4-83cab9c298bf"

def yuv420_to_rgb_bmp(y_plane, u_plane, v_plane, width, height, bmp_path):
    row_bytes = width * 3
    padding = (4 - (row_bytes % 4)) % 4
    image_size = (row_bytes + padding) * height
    file_size = 54 + image_size

    bmp_header = struct.pack("<2sIHHI", b"BM", file_size, 0, 0, 54)
    dib_header = struct.pack("<IIIHHIIIIII", 40, width, height, 1, 24, 0, image_size, 2835, 2835, 0, 0)

    pixel_data = bytearray()
    for row in range(height - 1, -1, -1):
        for col in range(width):
            y_val = (y_plane[row * width + col] / 1023.0) * 255.0
            u_val = (u_plane[(row // 2) * (width // 2) + (col // 2)] / 1023.0) * 255.0 - 128.0
            v_val = (v_plane[(row // 2) * (width // 2) + (col // 2)] / 1023.0) * 255.0 - 128.0

            r = int(max(0, min(255, y_val + 1.402 * v_val)))
            g = int(max(0, min(255, y_val - 0.344136 * u_val - 0.714136 * v_val)))
            b = int(max(0, min(255, y_val + 1.772 * u_val)))

            pixel_data.extend([b, g, r])
        pixel_data.extend([0] * padding)

    with open(bmp_path, "wb") as f:
        f.write(bmp_header)
        f.write(dib_header)
        f.write(pixel_data)

def export_diff_heatmap(yh_plane, yd_plane, width, height, bmp_path):
    row_bytes = width * 3
    padding = (4 - (row_bytes % 4)) % 4
    image_size = (row_bytes + padding) * height
    file_size = 54 + image_size

    bmp_header = struct.pack("<2sIHHI", b"BM", file_size, 0, 0, 54)
    dib_header = struct.pack("<IIIHHIIIIII", 40, width, height, 1, 24, 0, image_size, 2835, 2835, 0, 0)

    pixel_data = bytearray()
    for row in range(height - 1, -1, -1):
        for col in range(width):
            diff = abs(yh_plane[row * width + col] - yd_plane[row * width + col])
            if diff == 0:
                # Dark slate: Exact [15, 23, 42] -> BGR: [42, 23, 15]
                b, g, r = 42, 23, 15
            elif diff <= 4:
                # Sky blue: 1-4 LSB [56, 189, 248] -> BGR: [248, 189, 56]
                b, g, r = 248, 189, 56
            elif diff <= 8:
                # Emerald green: 5-8 LSB [34, 197, 94] -> BGR: [94, 197, 34]
                b, g, r = 94, 197, 34
            elif diff <= 16:
                # Yellow: 9-16 LSB [234, 179, 8] -> BGR: [8, 179, 234]
                b, g, r = 8, 179, 234
            else:
                # Red: >16 LSB [239, 68, 68] -> BGR: [68, 68, 239]
                b, g, r = 68, 68, 239
            pixel_data.extend([b, g, r])
        pixel_data.extend([0] * padding)

    with open(bmp_path, "wb") as f:
        f.write(bmp_header)
        f.write(dib_header)
        f.write(pixel_data)

def bmp_to_png(bmp_path, png_path):
    with open(bmp_path, "rb") as f:
        data = f.read()
    width, height = struct.unpack("<II", data[18:26])
    raw_pixels = data[54:]
    row_bytes = width * 3
    padding = (4 - (row_bytes % 4)) % 4
    stride = row_bytes + padding
    
    raw_lines = []
    for y in range(height - 1, -1, -1):
        line = bytearray([0])
        row_offset = y * stride
        for x in range(width):
            px_offset = row_offset + x * 3
            b = raw_pixels[px_offset]
            g = raw_pixels[px_offset + 1]
            r = raw_pixels[px_offset + 2]
            line.extend([r, g, b])
        raw_lines.append(bytes(line))
    
    compressed = zlib.compress(b"".join(raw_lines), 9)
    png = bytearray(b"\x89PNG\r\n\x1a\n")
    
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    png.extend(struct.pack(">I", len(ihdr)))
    png.extend(b"IHDR")
    png.extend(ihdr)
    png.extend(struct.pack(">I", zlib.crc32(b"IHDR" + ihdr) & 0xffffffff))
    
    png.extend(struct.pack(">I", len(compressed)))
    png.extend(b"IDAT")
    png.extend(compressed)
    png.extend(struct.pack(">I", zlib.crc32(b"IDAT" + compressed) & 0xffffffff))
    
    png.extend(struct.pack(">I", 0))
    png.extend(b"IEND")
    png.extend(struct.pack(">I", zlib.crc32(b"IEND") & 0xffffffff))
    
    with open(png_path, "wb") as f:
        f.write(png)

def calc_psnr(orig, dec, max_val=1023.0):
    mse = sum((o - d) ** 2 for o, d in zip(orig, dec)) / len(orig)
    if mse == 0:
        return 100.0
    return 10.0 * math.log10((max_val ** 2) / mse)

def calc_ssim(orig_plane, test_plane, width, height, bit_depth=10, block_size=8):
    L = (1 << bit_depth) - 1
    c1 = (0.01 * L) ** 2
    c2 = (0.03 * L) ** 2
    ssim_vals = []
    for y in range(0, height - block_size + 1, block_size):
        for x in range(0, width - block_size + 1, block_size):
            b1 = [orig_plane[(y + r) * width + (x + c)] for r in range(block_size) for c in range(block_size)]
            b2 = [test_plane[(y + r) * width + (x + c)] for r in range(block_size) for c in range(block_size)]
            n = len(b1)
            m1 = sum(b1) / n
            m2 = sum(b2) / n
            var1 = sum((v - m1)**2 for v in b1) / n
            var2 = sum((v - m2)**2 for v in b2) / n
            cov = sum((v1 - m1)*(v2 - m2) for v1, v2 in zip(b1, b2)) / n
            num = (2 * m1 * m2 + c1) * (2 * cov + c2)
            den = (m1**2 + m2**2 + c1) * (var1 + var2 + c2)
            ssim_vals.append(num / den)
    return sum(ssim_vals) / len(ssim_vals) if ssim_vals else 1.0

def png_to_base64_data_uri(png_path):
    with open(png_path, "rb") as f:
        encoded = base64.b64encode(f.read()).decode("ascii")
    return f"data:image/png;base64,{encoded}"

def main():
    decoder_exe = r"HM\bin\mgwmake\gcc-mingw-14.2\x86_64\release\TAppDecoder.exe"
    bitstream = "str_b_frame.bin"
    orig_yuv = "orig_foreman_128x128_10b.yuv"
    decoded_yuv = "dec_foreman.yuv"
    hw_recon_yuv = "hw_recon.yuv"

    if not os.path.exists(bitstream):
        print(f"Error: Bitstream {bitstream} not found.")
        return

    # Standard HEVC decoding with in-loop deblocking filter enabled
    dec_env = os.environ.copy()
    dec_env.pop("DISABLE_LOOP_FILTERS", None)
    print("Running HM 18.0 Reference Decoder on str_b_frame.bin (In-Loop Filters Enabled)...")
    cmd = [decoder_exe, "-b", bitstream, "-o", decoded_yuv, "-d", "10"]
    proc = subprocess.run(cmd, capture_output=True, text=True, env=dec_env)
    print("HM Decoder Output Summary:")
    poc_lines = [l for l in proc.stdout.splitlines() if "POC" in l or "Total Time" in l]
    for pl in poc_lines:
        print("  " + pl)
    if proc.stderr:
        print("HM Decoder Stderr:", proc.stderr)
    print(f"HM Return Code: {proc.returncode}")

    if not os.path.exists(decoded_yuv):
        print(f"Error: Decoded YUV {decoded_yuv} was not generated.")
        return

    frame_y_size = WIDTH * HEIGHT
    frame_c_size = (WIDTH // 2) * (HEIGHT // 2)
    samples_per_frame = frame_y_size + 2 * frame_c_size

    if not os.path.exists(orig_yuv):
        print(f"Error: Ground truth {orig_yuv} not found.")
        return

    num_frames = min(
        os.path.getsize(orig_yuv) // (samples_per_frame * 2),
        os.path.getsize(decoded_yuv) // (samples_per_frame * 2),
        os.path.getsize(hw_recon_yuv) // (samples_per_frame * 2)
    )

    print(f"\nEvaluating Hardware Recon ({hw_recon_yuv}) vs HM Decoded ({decoded_yuv}) vs Ground Truth ({orig_yuv})...")
    print(f"Total active frames to evaluate: {num_frames}")

    frame_summary_data = []

    with open(orig_yuv, "rb") as fo, open(decoded_yuv, "rb") as fd, open(hw_recon_yuv, "rb") as fh:
        for f_idx in range(num_frames):
            raw_o = fo.read(samples_per_frame * 2)
            raw_d = fd.read(samples_per_frame * 2)
            raw_h = fh.read(samples_per_frame * 2)
            if len(raw_o) < samples_per_frame * 2 or len(raw_d) < samples_per_frame * 2 or len(raw_h) < samples_per_frame * 2:
                print(f"Warning: Incomplete data for frame {f_idx}")
                break

            orig_samples = struct.unpack(f"<{samples_per_frame}H", raw_o)
            dec_samples  = struct.unpack(f"<{samples_per_frame}H", raw_d)
            hw_samples   = struct.unpack(f"<{samples_per_frame}H", raw_h)

            diff_hw_dec = [abs(h - d) for h, d in zip(hw_samples, dec_samples)]
            max_diff = max(diff_hw_dec)
            avg_diff = sum(diff_hw_dec) / len(diff_hw_dec)
            exact_hw_dec = diff_hw_dec.count(0)

            yo, uo, vo = orig_samples[:frame_y_size], orig_samples[frame_y_size:frame_y_size+frame_c_size], orig_samples[frame_y_size+frame_c_size:]
            yd, ud, vd = dec_samples[:frame_y_size], dec_samples[frame_y_size:frame_y_size+frame_c_size], dec_samples[frame_y_size+frame_c_size:]
            yh, uh, vh = hw_samples[:frame_y_size], hw_samples[frame_y_size:frame_y_size+frame_c_size], hw_samples[frame_y_size+frame_c_size:]

            psnr_y = calc_psnr(yo, yd)
            psnr_u = calc_psnr(uo, ud)
            psnr_v = calc_psnr(vo, vd)
            psnr_yuv = (6 * psnr_y + psnr_u + psnr_v) / 8.0

            hw_psnr_y = calc_psnr(yo, yh)
            hw_psnr_u = calc_psnr(uo, uh)
            hw_psnr_v = calc_psnr(vo, vh)
            hw_psnr_yuv = (6 * hw_psnr_y + hw_psnr_u + hw_psnr_v) / 8.0

            ssim_y = calc_ssim(yo, yd, WIDTH, HEIGHT)
            ssim_u = calc_ssim(uo, ud, WIDTH // 2, HEIGHT // 2)
            ssim_v = calc_ssim(vo, vd, WIDTH // 2, HEIGHT // 2)

            hw_ssim_y = calc_ssim(yo, yh, WIDTH, HEIGHT)
            hw_ssim_u = calc_ssim(uo, uh, WIDTH // 2, HEIGHT // 2)
            hw_ssim_v = calc_ssim(vo, vh, WIDTH // 2, HEIGHT // 2)

            frame_type = "I-Frame (POC 0)" if f_idx == 0 else ("P-Frame (POC 1)" if f_idx == 1 else f"B-Frame (POC {f_idx})")
            print(f"\n=======================================================")
            print(f" Frame {f_idx}: {frame_type}")
            print(f"=======================================================")
            print(f"  HM Decoded vs HW Recon: Exact {exact_hw_dec}/{samples_per_frame} ({exact_hw_dec*100/samples_per_frame:.2f}%) | Max Diff: {max_diff} | Avg Diff: {avg_diff:.4f}")
            print(f"  HM PSNR-Y:   {psnr_y:6.2f} dB | HW Recon PSNR-Y:   {hw_psnr_y:6.2f} dB")
            print(f"  HM PSNR-U:   {psnr_u:6.2f} dB | HW Recon PSNR-U:   {hw_psnr_u:6.2f} dB")
            print(f"  HM PSNR-V:   {psnr_v:6.2f} dB | HW Recon PSNR-V:   {hw_psnr_v:6.2f} dB")
            print(f"  HM PSNR-YUV: {psnr_yuv:6.2f} dB | HW Recon PSNR-YUV: {hw_psnr_yuv:6.2f} dB")
            print(f"  HM SSIM-Y:   {ssim_y:6.4f}    | HW Recon SSIM-Y:   {hw_ssim_y:6.4f}")
            print(f"  HM SSIM-U:   {ssim_u:6.4f}    | HW Recon SSIM-U:   {hw_ssim_u:6.4f}")
            print(f"  HM SSIM-V:   {ssim_v:6.4f}    | HW Recon SSIM-V:   {hw_ssim_v:6.4f}")

            # Per-CTU breakdown for Y
            ctu_stats = []
            for ctu_i in range(4):
                ctu_x = (ctu_i % 2) * 64
                ctu_y = (ctu_i // 2) * 64
                c_yo = [yo[(ctu_y + r) * 128 + (ctu_x + c)] for r in range(64) for c in range(64)]
                c_yd = [yd[(ctu_y + r) * 128 + (ctu_x + c)] for r in range(64) for c in range(64)]
                c_yh = [yh[(ctu_y + r) * 128 + (ctu_x + c)] for r in range(64) for c in range(64)]
                c_diff = [abs(h - d) for h, d in zip(c_yh, c_yd)]
                c_exact = c_diff.count(0)
                c_psnr_hm = calc_psnr(c_yo, c_yd)
                c_psnr_hw = calc_psnr(c_yo, c_yh)
                print(f"    CTU {ctu_i} (x={ctu_x:2d}, y={ctu_y:2d}) -> Exact: {c_exact}/4096 ({c_exact*100/4096:.1f}%) | Max Diff: {max(c_diff):2d} | Avg Diff: {sum(c_diff)/4096:.2f} | HM: {c_psnr_hm:5.2f} dB | HW: {c_psnr_hw:5.2f} dB")
                ctu_stats.append({
                    "id": ctu_i,
                    "x": ctu_x,
                    "y": ctu_y,
                    "exact": c_exact,
                    "exact_pct": f"{c_exact*100/4096:.1f}",
                    "max_diff": max(c_diff),
                    "psnr_hw": f"{c_psnr_hw:.2f}",
                    "psnr_hm": f"{c_psnr_hm:.2f}",
                    "cycles": None,
                    "t_tq": None,
                    "t_md": None,
                    "t_db": None,
                    "t_cabac": None
                })

            # Export individual BMPs & PNGs
            f_orig_bmp = f"foreman_frame_{f_idx}_orig.bmp"
            f_hw_bmp   = f"foreman_frame_{f_idx}_hw.bmp"
            f_dec_bmp  = f"foreman_frame_{f_idx}_dec.bmp"
            f_diff_bmp = f"foreman_frame_{f_idx}_diff.bmp"

            f_orig_png = f"foreman_frame_{f_idx}_orig.png"
            f_hw_png   = f"foreman_frame_{f_idx}_hw.png"
            f_dec_png  = f"foreman_frame_{f_idx}_dec.png"
            f_diff_png = f"foreman_frame_{f_idx}_diff.png"

            yuv420_to_rgb_bmp(yo, uo, vo, WIDTH, HEIGHT, f_orig_bmp)
            yuv420_to_rgb_bmp(yh, uh, vh, WIDTH, HEIGHT, f_hw_bmp)
            yuv420_to_rgb_bmp(yd, ud, vd, WIDTH, HEIGHT, f_dec_bmp)
            export_diff_heatmap(yh, yd, WIDTH, HEIGHT, f_diff_bmp)

            bmp_to_png(f_orig_bmp, f_orig_png)
            bmp_to_png(f_hw_bmp, f_hw_png)
            bmp_to_png(f_dec_bmp, f_dec_png)
            bmp_to_png(f_diff_bmp, f_diff_png)

            if os.path.exists(ARTIFACT_DIR):
                shutil.copy(f_diff_png, os.path.join(ARTIFACT_DIR, f_diff_png))

            frame_summary_data.append({
                "idx": f_idx,
                "type": frame_type,
                "slice_type": "I" if f_idx == 0 else ("P" if f_idx == 1 else "B"),
                "orig_img": png_to_base64_data_uri(f_orig_png),
                "hw_img": png_to_base64_data_uri(f_hw_png),
                "dec_img": png_to_base64_data_uri(f_dec_png),
                "diff_img": png_to_base64_data_uri(f_diff_png),
                "psnr_hw_yuv": f"{hw_psnr_yuv:.2f}",
                "psnr_dec_yuv": f"{psnr_yuv:.2f}",
                "ssim_hw_y": f"{hw_ssim_y:.4f}",
                "ssim_dec_y": f"{ssim_y:.4f}",
                "exact_pct": f"{exact_hw_dec*100/samples_per_frame:.1f}",
                "exact_count": exact_hw_dec,
                "avg_diff": f"{avg_diff:.4f}",
                "max_diff": max_diff,
                "ctu_stats": ctu_stats
            })

    # Generate 3-panel comparison PNGs
    for f_idx in range(num_frames):
        paths = [f"foreman_frame_{f_idx}_orig.bmp", f"foreman_frame_{f_idx}_hw.bmp", f"foreman_frame_{f_idx}_dec.bmp"]
        if not all(os.path.exists(p) for p in paths):
            continue
        
        panels_data = []
        for p in paths:
            with open(p, "rb") as f:
                f.read(54)
                panels_data.append(f.read())
        
        combined_w = WIDTH * 3
        combined_h = HEIGHT
        row_bytes = combined_w * 3
        padding = (4 - (row_bytes % 4)) % 4
        image_size = (row_bytes + padding) * combined_h
        file_size = 54 + image_size

        bmp_header = struct.pack("<2sIHHI", b"BM", file_size, 0, 0, 54)
        dib_header = struct.pack("<IIIHHIIIIII", 40, combined_w, combined_h, 1, 24, 0, image_size, 2835, 2835, 0, 0)

        combined_pixels = bytearray()
        for row in range(HEIGHT):
            for p_idx in range(3):
                start = row * (WIDTH * 3)
                combined_pixels.extend(panels_data[p_idx][start : start + WIDTH * 3])
            combined_pixels.extend([0] * padding)

        out_bmp = f"foreman_frame_{f_idx}_tri_comparison.bmp"
        out_png = f"foreman_frame_{f_idx}_tri_comparison.png"
        with open(out_bmp, "wb") as f:
            f.write(bmp_header)
            f.write(dib_header)
            f.write(combined_pixels)
        
        bmp_to_png(out_bmp, out_png)
        print(f"Generated side-by-side tri-comparison: {out_png}")
        if os.path.exists(ARTIFACT_DIR):
            shutil.copy(out_png, os.path.join(ARTIFACT_DIR, out_png))
            print(f"Copied {out_png} to artifact directory.")

    # Check pre-filter bit-exact match against rec_before_filter.yuv
    pre_filter_yuv = "rec_before_filter.yuv"
    target_pre_hw = "hw_recon_pre.yuv" if os.path.exists("hw_recon_pre.yuv") else hw_recon_yuv
    label_pre_hw = "HW Recon Pre-Filter" if os.path.exists("hw_recon_pre.yuv") else "HW Recon Post-Filter"
    if os.path.exists(pre_filter_yuv) and os.path.exists(target_pre_hw):
        print("\n=======================================================")
        print(f" Pre-Filter Bit-Exact Conformance ({label_pre_hw} vs HM Pre-Filter)")
        print("=======================================================")
        with open(pre_filter_yuv, "rb") as fp, open(target_pre_hw, "rb") as fh:
            for f_idx in range(num_frames):
                raw_p = fp.read(samples_per_frame * 2)
                raw_h = fh.read(samples_per_frame * 2)
                if len(raw_p) < samples_per_frame * 2 or len(raw_h) < samples_per_frame * 2:
                    break
                p_samp = struct.unpack(f"<{samples_per_frame}H", raw_p)
                h_samp = struct.unpack(f"<{samples_per_frame}H", raw_h)
                diff = [abs(h - p) for h, p in zip(h_samp, p_samp)]
                exact = diff.count(0)
                max_d = max(diff)
                avg_d = sum(diff) / len(diff)
                psnr = calc_psnr(p_samp, h_samp)
                f_type = "I-Frame" if f_idx == 0 else ("P-Frame" if f_idx == 1 else f"B-Frame (POC {f_idx})")
                print(f"  Frame {f_idx} ({f_type}): Exact {exact}/{samples_per_frame} ({exact*100/samples_per_frame:.2f}%) | Max Diff: {max_d} | Avg Diff: {avg_d:.4f} | PSNR: {psnr:.2f} dB")
                # CTU breakdown
                for ctu_i in range(4):
                    cx = (ctu_i % 2) * 64
                    cy = (ctu_i // 2) * 64
                    c_h = [h_samp[(cy + r) * 128 + (cx + c)] for r in range(64) for c in range(64)]
                    c_p = [p_samp[(cy + r) * 128 + (cx + c)] for r in range(64) for c in range(64)]
                    c_d = [abs(h - p) for h, p in zip(c_h, c_p)]
                    c_ex = c_d.count(0)
                    c_ps = calc_psnr(c_p, c_h)
                    print(f"    CTU {ctu_i}: Exact {c_ex}/4096 ({c_ex*100/4096:.1f}%) | Max Diff: {max(c_d)} | Avg Diff: {sum(c_d)/4096:.2f} | PSNR: {c_ps:.2f} dB")

    # Update visual verification HTML dashboard if present (in repo root or ARTIFACT_DIR)
    dashboard_candidates = [
        "visual_verification_dashboard.html",
        os.path.join(ARTIFACT_DIR, "visual_verification_dashboard.html")
    ]
    for dashboard_html in dashboard_candidates:
        if os.path.exists(dashboard_html) and len(frame_summary_data) > 0:
            import json
            with open(dashboard_html, "r", encoding="utf-8") as f:
                html_content = f.read()
            
            # Replace the `const frames = [...]` line
            start_tag = "const frames = "
            end_tag = ";\n"
            s_pos = html_content.find(start_tag)
            if s_pos != -1:
                e_pos = html_content.find(end_tag, s_pos)
                if e_pos != -1:
                    frames_json = json.dumps(frame_summary_data)
                    new_html = html_content[:s_pos + len(start_tag)] + frames_json + html_content[e_pos:]
                    with open(dashboard_html, "w", encoding="utf-8") as f:
                        f.write(new_html)
                    print(f"Successfully updated HTML dashboard: {dashboard_html}")

if __name__ == "__main__":
    main()
