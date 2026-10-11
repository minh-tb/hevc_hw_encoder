
# ITU-T H.265 Table 8-1: Luma filter coefficients
LUMA_COEFFS = [
    [0, 0, 0, 64, 0, 0, 0, 0],
    [-1, 4, -10, 58, 17, -5, 1, 0],
    [-1, 4, -11, 40, 40, -11, 4, -1],
    [0, 1, -5, 17, 58, -10, 4, -1]
]

# ITU-T H.265 Table 8-2: Chroma filter coefficients
CHROMA_COEFFS = [
    [0, 64, 0, 0],
    [-2, 58, 10, -2],
    [-4, 54, 16, -2],
    [-6, 46, 28, -4],
    [-4, 36, 36, -4],
    [-4, 28, 46, -6],
    [-2, 16, 54, -4],
    [-2, 10, 58, -2]
]

def clip_bd(val, bit_depth=10):
    max_val = (1 << bit_depth) - 1
    return max(0, min(max_val, val))

def filter_luma_sample(ref_window, frac_x, frac_y, bit_depth=10):
    """
    ref_window: 11x11 luma pixels (10-bit), sample at block corner is at (3,3)
    Output: uni_pred (10-bit), intermediate (14-bit)
    """
    ch = LUMA_COEFFS[frac_x]
    cv = LUMA_COEFFS[frac_y]
    
    if frac_x == 0 and frac_y == 0:
        val = ref_window[3, 3]
        return val, val << 4
    elif frac_y == 0:
        # H-only
        sum_h = sum(ch[k] * int(ref_window[3, 3 + k - 3]) for k in range(8))
        out_uni = clip_bd((sum_h + 32) >> 6, bit_depth)
        interm = sum_h >> 2
        return out_uni, interm
    elif frac_x == 0:
        # V-only
        sum_v = sum(cv[k] * int(ref_window[3 + k - 3, 3]) for k in range(8))
        out_uni = clip_bd((sum_v + 32) >> 6, bit_depth)
        interm = sum_v >> 2
        return out_uni, interm
    else:
        # HV two-pass
        # Step 1: H-pass on rows (3 - 3) .. (3 + 4) = 0 .. 7
        h_int = []
        for r in range(8):
            sum_h = sum(ch[k] * int(ref_window[r, 3 + k - 3]) for k in range(8))
            h_int.append(sum_h >> 2) # Plain truncation: NO offset!
        # Step 2: V-pass on h_int
        sum_v = sum(cv[k] * h_int[k] for k in range(8))
        out_uni = clip_bd((sum_v + 512) >> 10, bit_depth)
        interm = sum_v >> 6
        return out_uni, interm

def filter_chroma_sample(ref_window, frac_x, frac_y, bit_depth=10):
    """
    ref_window: 7x7 chroma pixels (10-bit), sample at block corner is at (1,1)
    Output: uni_pred (10-bit), intermediate (14-bit)
    """
    ch = CHROMA_COEFFS[frac_x]
    cv = CHROMA_COEFFS[frac_y]
    
    if frac_x == 0 and frac_y == 0:
        val = ref_window[1, 1]
        return val, val << 4
    elif frac_y == 0:
        # H-only
        sum_h = sum(ch[k] * int(ref_window[1, 1 + k - 1]) for k in range(4))
        out_uni = clip_bd((sum_h + 32) >> 6, bit_depth)
        interm = sum_h >> 2
        return out_uni, interm
    elif frac_x == 0:
        # V-only
        sum_v = sum(cv[k] * int(ref_window[1 + k - 1, 1]) for k in range(4))
        out_uni = clip_bd((sum_v + 32) >> 6, bit_depth)
        interm = sum_v >> 2
        return out_uni, interm
    else:
        # HV two-pass
        # Step 1: H-pass on rows (1 - 1) .. (1 + 2) = 0 .. 3
        h_int = []
        for r in range(4):
            sum_h = sum(ch[k] * int(ref_window[r, 1 + k - 1]) for k in range(4))
            h_int.append(sum_h >> 2) # Plain truncation
        # Step 2: V-pass on h_int
        sum_v = sum(cv[k] * h_int[k] for k in range(4))
        out_uni = clip_bd((sum_v + 512) >> 10, bit_depth)
        interm = sum_v >> 6
        return out_uni, interm

def bi_pred_average(interm_l0, interm_l1, bit_depth=10):
    """
    Clause 8.5.3.3.4.2 normative weighted average for bi-prediction:
    out_bi = ClipBD((v_L0 + v_L1 + 16) >> 5, bit_depth)
    """
    return clip_bd((interm_l0 + interm_l1 + 16) >> 5, bit_depth)

if __name__ == "__main__":
    print("Golden interpolation model ready.")
