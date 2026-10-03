import struct

def analyze_diff(hw_path="hw_recon.yuv", dec_path="dec_gate.yuv", frame_idx=0):
    w, h = 128, 128
    luma_size = w * h
    chroma_size = (w // 2) * (h // 2)
    frame_bytes = (luma_size + 2 * chroma_size) * 2
    
    with open(hw_path, "rb") as f_hw, open(dec_path, "rb") as f_dec:
        f_hw.seek(frame_idx * frame_bytes)
        f_dec.seek(frame_idx * frame_bytes)
        
        hw_raw = f_hw.read(frame_bytes)
        dec_raw = f_dec.read(frame_bytes)
        
    hw_y = struct.unpack(f"<{luma_size}H", hw_raw[:luma_size*2])
    dec_y = struct.unpack(f"<{luma_size}H", dec_raw[:luma_size*2])
    
    diff_y = [abs(h - d) for h, d in zip(hw_y, dec_y)]
    
    print(f"\n=== Frame {frame_idx} Luma Analysis ===")
    num_diffs = sum(1 for d in diff_y if d > 0)
    max_d = max(diff_y)
    mean_d = sum(diff_y) / luma_size
    print(f"Total luma diffs: {num_diffs} / {luma_size} ({num_diffs/luma_size*100:.2f}%)")
    print(f"Max diff: {max_d}, Mean diff: {mean_d:.4f}")
    
    diff_on_ctu_boundary = 0
    diff_outside_ctu_boundary = 0
    diff_on_internal_tu = 0
    total_internal_tu_samples = 0
    
    for y in range(h):
        for x in range(w):
            idx = y * w + x
            d = diff_y[idx]
            is_ctu_boundary = (60 <= x <= 67) or (60 <= y <= 67)
            
            is_internal_tu_edge = False
            if not is_ctu_boundary:
                for cx in [0, 64]:
                    for cy in [0, 64]:
                        if (cx <= x < cx+64) and (cy <= y < cy+64):
                            in_vert = (cx+28 <= x <= cx+35)
                            in_horiz = (cy+28 <= y <= cy+35)
                            if in_vert or in_horiz:
                                is_internal_tu_edge = True
                                
            if is_internal_tu_edge:
                total_internal_tu_samples += 1
                if d > 0:
                    diff_on_internal_tu += 1
                    
            if d > 0:
                if is_ctu_boundary:
                    diff_on_ctu_boundary += 1
                else:
                    diff_outside_ctu_boundary += 1
                        
    if num_diffs > 0:
        print(f"Diffs on CTU boundary (x/y in [60..67]): {diff_on_ctu_boundary} / {num_diffs} ({diff_on_ctu_boundary/num_diffs*100:.2f}%)")
    print(f"Diffs outside CTU boundary: {diff_outside_ctu_boundary}")
    print(f"Diffs on internal 32x32 TU edges: {diff_on_internal_tu} / {total_internal_tu_samples} ({(total_internal_tu_samples-diff_on_internal_tu)/total_internal_tu_samples*100:.2f}% match)")
    if diff_on_internal_tu == 0:
        print(">>> 100% BIT-EXACT MATCH on all internal 32x32 TU edges! <<<")

    # Chroma Analysis (Cb and Cr)
    hw_cb = struct.unpack(f"<{chroma_size}H", hw_raw[luma_size*2:(luma_size+chroma_size)*2])
    dec_cb = struct.unpack(f"<{chroma_size}H", dec_raw[luma_size*2:(luma_size+chroma_size)*2])
    hw_cr = struct.unpack(f"<{chroma_size}H", hw_raw[(luma_size+chroma_size)*2:])
    dec_cr = struct.unpack(f"<{chroma_size}H", dec_raw[(luma_size+chroma_size)*2:])
    
    cw, ch = w // 2, h // 2
    for comp_name, (hw_c, dec_c) in [("Cb", (hw_cb, dec_cb)), ("Cr", (hw_cr, dec_cr))]:
        diff_c = [abs(h - d) for h, d in zip(hw_c, dec_c)]
        num_c = sum(1 for d in diff_c if d > 0)
        c_on_ctu = 0
        c_outside = 0
        for y in range(ch):
            for x in range(cw):
                idx = y * cw + x
                d = diff_c[idx]
                is_ctu_boundary_c = (30 <= x <= 33) or (30 <= y <= 33)
                if d > 0:
                    if is_ctu_boundary_c:
                        c_on_ctu += 1
                    else:
                        c_outside += 1
        print(f"  Chroma {comp_name}: Total diffs={num_c}/{chroma_size}, on CTU boundary={c_on_ctu}, outside CTU boundary={c_outside}")

for f in range(5):
    analyze_diff(frame_idx=f)
