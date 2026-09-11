"""
visualize_and_evaluate_foreman.py
Evaluates str_b_frame.bin (Foreman 128x128 10-bit 3-frame sequence) decoded with HM 18.0,
calculates PSNR, checks conformance against hw_recon.yuv,
and exports side-by-side tri-comparison images (Original | HW Recon | HM Decoded).
"""

import os
import sys
import struct
import math
import subprocess
import zlib
import shutil

WIDTH = 128
HEIGHT = 128
NUM_FRAMES = 5
ARTIFACT_DIR = r"C:\Users\Admin\.gemini\antigravity\brain\5d4608a3-37aa-44aa-a86c-b0b8ca2a3146"

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

def main():
    decoder_exe = r"HM\bin\mgwmake\gcc-mingw-14.2\x86_64\release\TAppDecoder.exe"
    bitstream = "str_b_frame.bin"
    orig_yuv = "orig_foreman_128x128_10b.yuv"
    decoded_yuv = "dec_foreman.yuv"
    hw_recon_yuv = "hw_recon.yuv"

    if not os.path.exists(bitstream):
        print(f"Error: Bitstream {bitstream} not found.")
        return

    print("Running HM 18.0 Reference Decoder on str_b_frame.bin...")
    cmd = [decoder_exe, "-b", bitstream, "-o", decoded_yuv, "-d", "10"]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    print("HM Decoder Output:")
    print(proc.stdout)
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

    print(f"\nEvaluating Hardware Recon ({hw_recon_yuv}) vs HM Decoded ({decoded_yuv}) vs Ground Truth ({orig_yuv})...")
    with open(orig_yuv, "rb") as fo, open(decoded_yuv, "rb") as fd, open(hw_recon_yuv, "rb") as fh:
        for f_idx in range(NUM_FRAMES):
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

            frame_type = "I-Frame (POC 0)" if f_idx == 0 else ("P-Frame (POC 1)" if f_idx == 1 else f"B-Frame (POC {f_idx})")
            print(f"\n=======================================================")
            print(f" Frame {f_idx}: {frame_type}")
            print(f"=======================================================")
            print(f"  HM Decoded vs HW Recon: Exact {exact_hw_dec}/{samples_per_frame} ({exact_hw_dec*100/samples_per_frame:.2f}%) | Max Diff: {max_diff} | Avg Diff: {avg_diff:.4f}")
            print(f"  HM PSNR-Y:   {psnr_y:6.2f} dB | HW Recon PSNR-Y:   {hw_psnr_y:6.2f} dB")
            print(f"  HM PSNR-U:   {psnr_u:6.2f} dB | HW Recon PSNR-U:   {hw_psnr_u:6.2f} dB")
            print(f"  HM PSNR-V:   {psnr_v:6.2f} dB | HW Recon PSNR-V:   {hw_psnr_v:6.2f} dB")
            print(f"  HM PSNR-YUV: {psnr_yuv:6.2f} dB | HW Recon PSNR-YUV: {hw_psnr_yuv:6.2f} dB")

            # Per-CTU breakdown for Y
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

            # Export individual BMPs
            yuv420_to_rgb_bmp(yo, uo, vo, WIDTH, HEIGHT, f"foreman_frame_{f_idx}_orig.bmp")
            yuv420_to_rgb_bmp(yh, uh, vh, WIDTH, HEIGHT, f"foreman_frame_{f_idx}_hw.bmp")
            yuv420_to_rgb_bmp(yd, ud, vd, WIDTH, HEIGHT, f"foreman_frame_{f_idx}_dec.bmp")

    # Generate 3-panel comparison PNGs
    for f_idx in range(NUM_FRAMES):
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
    if os.path.exists(pre_filter_yuv) and os.path.exists(hw_recon_yuv):
        print("\n=======================================================")
        print(" Pre-Filter Bit-Exact Conformance (HW Recon vs HM Pre-Filter)")
        print("=======================================================")
        with open(pre_filter_yuv, "rb") as fp, open(hw_recon_yuv, "rb") as fh:
            for f_idx in range(NUM_FRAMES):
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

if __name__ == "__main__":
    main()
