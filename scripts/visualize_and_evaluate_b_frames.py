"""
visualize_and_evaluate_b_frames.py
Generates ground-truth orig_b_frame.yuv, decodes str_b_frame.bin with HM 18.0,
calculates PSNR/SSIM, and exports RGB BMP images and difference maps for visual inspection.
"""

import os
import sys
import struct
import math
import subprocess

WIDTH = 128
HEIGHT = 128
NUM_FRAMES = 3

def generate_ground_truth_yuv(filename="orig_b_frame.yuv"):
    """Generates the exact 3-frame 10-bit 4:2:0 YUV input stream in scanline raster order."""
    offsets = [(0, 0), (4, 2), (2, 1)] # Frame 0 (I), Frame 1 (P), Frame 2 (B)

    with open(filename, "wb") as f:
        for f_idx, (dx, dy) in enumerate(offsets):
            y_plane = []
            for y in range(HEIGHT):
                for x in range(WIDTH):
                    y_val = 300 + ((x + dx) * 400) // 128 + ((y + dy) * 200) // 128
                    y_plane.append(y_val)

            u_plane = []
            v_plane = []
            for cy in range(HEIGHT // 2):
                for cx in range(WIDTH // 2):
                    u_val = 400 + ((cx + dx // 2) * 200) // 64 + ((cy + dy // 2) * 100) // 64
                    v_val = 600 - ((cx + dx // 2) * 150) // 64 - ((cy + dy // 2) * 150) // 64
                    u_plane.append(u_val)
                    v_plane.append(v_val)

            f.write(struct.pack(f"<{len(y_plane)}H", *y_plane))
            f.write(struct.pack(f"<{len(u_plane)}H", *u_plane))
            f.write(struct.pack(f"<{len(v_plane)}H", *v_plane))

    print(f"Generated ground truth: {filename} ({os.path.getsize(filename)} bytes)")

def yuv420_to_rgb_bmp(y_plane, u_plane, v_plane, width, height, bmp_path):
    """Converts 10-bit YUV 4:2:0 planes to a 24-bit RGB BMP image."""
    # Convert 10-bit (0..1023) to normalized 8-bit (0..255)
    row_bytes = width * 3
    padding = (4 - (row_bytes % 4)) % 4
    image_size = (row_bytes + padding) * height
    file_size = 54 + image_size

    # BMP Header
    bmp_header = struct.pack(
        "<2sIHHI",
        b"BM",
        file_size,
        0, 0,
        54
    )
    # DIB Header (BITMAPINFOHEADER)
    dib_header = struct.pack(
        "<IIIHHIIIIII",
        40,
        width,
        height, # positive = bottom-up
        1,
        24,
        0,
        image_size,
        2835, 2835,
        0, 0
    )

    # Convert bottom-up
    pixel_data = bytearray()
    for row in range(height - 1, -1, -1):
        for col in range(width):
            y_val = (y_plane[row * width + col] / 1023.0) * 255.0
            u_val = (u_plane[(row // 2) * (width // 2) + (col // 2)] / 1023.0) * 255.0 - 128.0
            v_val = (v_plane[(row // 2) * (width // 2) + (col // 2)] / 1023.0) * 255.0 - 128.0

            r = int(max(0, min(255, y_val + 1.402 * v_val)))
            g = int(max(0, min(255, y_val - 0.344136 * u_val - 0.714136 * v_val)))
            b = int(max(0, min(255, y_val + 1.772 * u_val)))

            # BMP stores B, G, R
            pixel_data.extend([b, g, r])
        pixel_data.extend([0] * padding)

    with open(bmp_path, "wb") as f:
        f.write(bmp_header)
        f.write(dib_header)
        f.write(pixel_data)

def calc_psnr(orig, dec, max_val=1023.0):
    mse = sum((o - d) ** 2 for o, d in zip(orig, dec)) / len(orig)
    if mse == 0:
        return 100.0
    return 10.0 * math.log10((max_val ** 2) / mse)

def main():
    generate_ground_truth_yuv("orig_b_frame.yuv")
    
    decoder_exe = r"HM\bin\mgwmake\gcc-mingw-14.2\x86_64\release\TAppDecoder.exe"
    bitstream = "str_b_frame.bin"
    decoded_yuv = "dec_b_frame.yuv"

    if not os.path.exists(bitstream):
        print(f"Bitstream {bitstream} not found yet.")
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
        print(f"Decoded YUV {decoded_yuv} was not generated.")
        return

    # Evaluate HW Recon vs HM Decoded YUV & Orig
    frame_y_size = WIDTH * HEIGHT
    frame_c_size = (WIDTH // 2) * (HEIGHT // 2)
    samples_per_frame = frame_y_size + 2 * frame_c_size

    hw_recon_yuv = "hw_recon.yuv"
    if os.path.exists(hw_recon_yuv):
        print(f"\nEvaluating Hardware Local Reconstruction ({hw_recon_yuv})...")
        with open("orig_b_frame.yuv", "rb") as fo, open(decoded_yuv, "rb") as fd, open(hw_recon_yuv, "rb") as fh:
            for f_idx in range(NUM_FRAMES):
                raw_o = fo.read(samples_per_frame * 2)
                raw_d = fd.read(samples_per_frame * 2)
                raw_h = fh.read(samples_per_frame * 2)
                if len(raw_o) < samples_per_frame * 2 or len(raw_d) < samples_per_frame * 2 or len(raw_h) < samples_per_frame * 2:
                    break

                orig_samples = struct.unpack(f"<{samples_per_frame}H", raw_o)
                dec_samples  = struct.unpack(f"<{samples_per_frame}H", raw_d)
                hw_samples   = struct.unpack(f"<{samples_per_frame}H", raw_h)

                diff_hw_dec = [abs(h - d) for h, d in zip(hw_samples, dec_samples)]
                max_diff = max(diff_hw_dec)
                avg_diff = sum(diff_hw_dec) / len(diff_hw_dec)

                frame_type = "I-Frame (POC 0)" if f_idx == 0 else ("P-Frame (POC 1)" if f_idx == 1 else "B-Frame (POC 2)")
                print(f"\n--- Frame {f_idx}: {frame_type} HW Recon vs HM Dec Conformance ---")
                print(f"  Max Pixel Difference: {max_diff}")
                print(f"  Avg Pixel Difference: {avg_diff:.4f}")
                if max_diff == 0:
                    print(f"  Status: BIT-EXACT MATCH (100% Conformance)")
                else:
                    print(f"  Status: Discrepancy observed (Max diff = {max_diff})")

    # Evaluate PSNR & Export BMPs
    with open("orig_b_frame.yuv", "rb") as fo, open(decoded_yuv, "rb") as fd, open("hw_recon.yuv", "rb") as fh:
        for f_idx in range(NUM_FRAMES):
            raw_o = fo.read(samples_per_frame * 2)
            raw_d = fd.read(samples_per_frame * 2)
            raw_h = fh.read(samples_per_frame * 2)
            if len(raw_o) < samples_per_frame * 2 or len(raw_d) < samples_per_frame * 2 or len(raw_h) < samples_per_frame * 2:
                print(f"Incomplete frame {f_idx}")
                break

            orig_samples = struct.unpack(f"<{samples_per_frame}H", raw_o)
            dec_samples  = struct.unpack(f"<{samples_per_frame}H", raw_d)
            hw_samples   = struct.unpack(f"<{samples_per_frame}H", raw_h)

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

            frame_type = "I-Frame (POC 0)" if f_idx == 0 else ("P-Frame (POC 1)" if f_idx == 1 else "B-Frame (POC 2)")
            print(f"\n--- Frame {f_idx}: {frame_type} Quality Metrics (HM 18.0 Decoded) ---")
            print(f"  HM PSNR-Y:   {psnr_y:6.2f} dB | HW Recon PSNR-Y:   {hw_psnr_y:6.2f} dB")
            print(f"  HM PSNR-U:   {psnr_u:6.2f} dB | HW Recon PSNR-U:   {hw_psnr_u:6.2f} dB")
            print(f"  HM PSNR-V:   {psnr_v:6.2f} dB | HW Recon PSNR-V:   {hw_psnr_v:6.2f} dB")
            print(f"  HM PSNR-YUV: {psnr_yuv:6.2f} dB | HW Recon PSNR-YUV: {hw_psnr_yuv:6.2f} dB")

            # Export BMP images if requested
            if "--export-images" in sys.argv:
                yuv420_to_rgb_bmp(yo, uo, vo, WIDTH, HEIGHT, f"frame_{f_idx}_orig.bmp")
                yuv420_to_rgb_bmp(yh, uh, vh, WIDTH, HEIGHT, f"frame_{f_idx}_hw.bmp")
                yuv420_to_rgb_bmp(yd, ud, vd, WIDTH, HEIGHT, f"frame_{f_idx}_dec.bmp")
                print(f"  Exported visual BMPs: frame_{f_idx}_orig.bmp, frame_{f_idx}_hw.bmp, frame_{f_idx}_dec.bmp")

import zlib
import shutil

ARTIFACT_DIR = r"C:\Users\Admin\.gemini\antigravity\brain\5d4608a3-37aa-44aa-a86c-b0b8ca2a3146"

def bmp_to_png(bmp_path, png_path):
    """Converts 24-bit uncompressed BMP to standard PNG."""
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

def create_side_by_side_bmps():
    """Combines orig, hw, dec BMPs into a single 3-panel comparison BMP and converts to PNG."""
    for f_idx in range(NUM_FRAMES):
        paths = [f"frame_{f_idx}_orig.bmp", f"frame_{f_idx}_hw.bmp", f"frame_{f_idx}_dec.bmp"]
        if not all(os.path.exists(p) for p in paths):
            continue
        
        # Read BMP pixel data (skipping 54 byte headers)
        panels_data = []
        for p in paths:
            with open(p, "rb") as f:
                header = f.read(54)
                data = f.read()
                panels_data.append(data)
        
        # Each panel is 128x128 24bpp (row bytes = 128*3 = 384, padding = 0)
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

        out_bmp = f"frame_{f_idx}_tri_comparison.bmp"
        out_png = f"frame_{f_idx}_tri_comparison.png"
        with open(out_bmp, "wb") as f:
            f.write(bmp_header)
            f.write(dib_header)
            f.write(combined_pixels)
        
        bmp_to_png(out_bmp, out_png)
        print(f"  Generated 3-Panel Tri-Comparison: {out_png}")
        if os.path.exists(ARTIFACT_DIR):
            shutil.copy(out_png, os.path.join(ARTIFACT_DIR, out_png))

if __name__ == "__main__":
    main()
    if "--export-images" in sys.argv:
        create_side_by_side_bmps()
