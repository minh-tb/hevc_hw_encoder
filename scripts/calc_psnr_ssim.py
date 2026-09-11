"""
calc_psnr_ssim.py (Pure Python Standard Library)
Calculates frame-by-frame and average PSNR (Y, U, V, and weighted YUV)
between original raw YUV and decoded YUV (10-bit / 8-bit YUV420p).
"""

import math
import struct
import sys
import os

def calculate_psnr(orig_samples, dec_samples, bit_depth=10):
    if len(orig_samples) == 0:
        return 0.0
    max_val = (1 << bit_depth) - 1
    sum_sq_diff = 0.0
    for o, d in zip(orig_samples, dec_samples):
        diff = float(o - d)
        sum_sq_diff += diff * diff
    mse = sum_sq_diff / len(orig_samples)
    if mse == 0:
        return 100.0  # Identical / lossless
    psnr = 10.0 * math.log10((max_val ** 2) / mse)
    return psnr

def evaluate_yuv_sequence(orig_path, dec_path, width, height, num_frames=None, bit_depth=10):
    bytes_per_sample = 2 if bit_depth > 8 else 1
    y_size = width * height
    uv_size = (width // 2) * (height // 2)
    frame_samples = y_size + 2 * uv_size
    frame_bytes = frame_samples * bytes_per_sample

    fmt = f"<{frame_samples}H" if bit_depth > 8 else f"{frame_samples}B"

    if not os.path.exists(orig_path):
        raise FileNotFoundError(f"Original file not found: {orig_path}")
    if not os.path.exists(dec_path):
        raise FileNotFoundError(f"Decoded file not found: {dec_path}")

    orig_filesize = os.path.getsize(orig_path)
    dec_filesize = os.path.getsize(dec_path)

    total_orig_frames = orig_filesize // frame_bytes
    total_dec_frames = dec_filesize // frame_bytes
    frames_to_eval = min(total_orig_frames, total_dec_frames)

    if num_frames is not None:
        frames_to_eval = min(frames_to_eval, num_frames)

    psnr_y_list = []
    psnr_u_list = []
    psnr_v_list = []
    psnr_yuv_list = []

    with open(orig_path, "rb") as f_orig, open(dec_path, "rb") as f_dec:
        for f_idx in range(frames_to_eval):
            raw_orig = f_orig.read(frame_bytes)
            raw_dec = f_dec.read(frame_bytes)

            data_orig = struct.unpack(fmt, raw_orig)
            data_dec = struct.unpack(fmt, raw_dec)

            # Unpack Y, U, V
            orig_y = data_orig[:y_size]
            orig_u = data_orig[y_size:y_size + uv_size]
            orig_v = data_orig[y_size + uv_size:]

            dec_y = data_dec[:y_size]
            dec_u = data_dec[y_size:y_size + uv_size]
            dec_v = data_dec[y_size + uv_size:]

            py = calculate_psnr(orig_y, dec_y, bit_depth)
            pu = calculate_psnr(orig_u, dec_u, bit_depth)
            pv = calculate_psnr(orig_v, dec_v, bit_depth)
            pyuv = (6.0 * py + pu + pv) / 8.0

            psnr_y_list.append(py)
            psnr_u_list.append(pu)
            psnr_v_list.append(pv)
            psnr_yuv_list.append(pyuv)

    avg_y = sum(psnr_y_list) / len(psnr_y_list) if psnr_y_list else 0.0
    avg_u = sum(psnr_u_list) / len(psnr_u_list) if psnr_u_list else 0.0
    avg_v = sum(psnr_v_list) / len(psnr_v_list) if psnr_v_list else 0.0
    avg_yuv = sum(psnr_yuv_list) / len(psnr_yuv_list) if psnr_yuv_list else 0.0

    return {
        "frames_evaluated": frames_to_eval,
        "psnr_y_avg": avg_y,
        "psnr_u_avg": avg_u,
        "psnr_v_avg": avg_v,
        "psnr_yuv_avg": avg_yuv,
        "psnr_y_per_frame": psnr_y_list
    }

if __name__ == "__main__":
    if len(sys.argv) >= 5:
        orig = sys.argv[1]
        dec = sys.argv[2]
        w = int(sys.argv[3])
        h = int(sys.argv[4])
        res = evaluate_yuv_sequence(orig, dec, w, h)
        print(f"Evaluated {res['frames_evaluated']} frames:")
        print(f"  PSNR-Y:   {res['psnr_y_avg']:.3f} dB")
        print(f"  PSNR-U:   {res['psnr_u_avg']:.3f} dB")
        print(f"  PSNR-V:   {res['psnr_v_avg']:.3f} dB")
        print(f"  PSNR-YUV: {res['psnr_yuv_avg']:.3f} dB")
    else:
        print("Usage: python calc_psnr_ssim.py <orig.yuv> <dec.yuv> <width> <height>")
