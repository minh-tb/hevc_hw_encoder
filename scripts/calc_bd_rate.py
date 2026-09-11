"""
calc_bd_rate.py (Pure Python Standard Library)
Calculates Bjontegaard Delta Rate (BD-Rate %) and Bjontegaard Delta PSNR (BD-PSNR dB)
using cubic curve fitting and numerical integration.
"""

import math

def polyfit3(x, y):
    """Fits y = a*x^3 + b*x^2 + c*x + d using normal equations."""
    n = len(x)
    # Build Vandermonde-like matrix powers
    s_x = [sum(xi**p for xi in x) for p in range(7)]
    s_xy = [sum((xi**p) * yi for xi, yi in zip(x, y)) for p in range(4)]
    
    # 4x4 matrix A and 4x1 vector B for [a, b, c, d]
    A = [
        [s_x[6], s_x[5], s_x[4], s_x[3]],
        [s_x[5], s_x[4], s_x[3], s_x[2]],
        [s_x[4], s_x[3], s_x[2], s_x[1]],
        [s_x[3], s_x[2], s_x[1], s_x[0]]
    ]
    B = [s_xy[3], s_xy[2], s_xy[1], s_xy[0]]
    
    # Gaussian elimination
    for i in range(4):
        max_row = i + max(range(4 - i), key=lambda r: abs(A[i + r][i]))
        A[i], A[max_row] = A[max_row], A[i]
        B[i], B[max_row] = B[max_row], B[i]
        pivot = A[i][i]
        if abs(pivot) < 1e-12:
            continue
        for j in range(i, 4):
            A[i][j] /= pivot
        B[i] /= pivot
        for r in range(4):
            if r != i:
                factor = A[r][i]
                for c in range(i, 4):
                    A[r][c] -= factor * A[i][c]
                B[r] -= factor * B[i]
    return B # [a, b, c, d]

def polyval(coeffs, x):
    a, b, c, d = coeffs
    return a * (x**3) + b * (x**2) + c * x + d

def polyint_eval(coeffs, x_min, x_max, steps=1000):
    """Numerically integrates cubic polynomial from x_min to x_max."""
    dx = (x_max - x_min) / float(steps)
    total = 0.0
    for i in range(steps):
        x_mid = x_min + (i + 0.5) * dx
        total += polyval(coeffs, x_mid) * dx
    return total

def bd_rate(rate_anchor, psnr_anchor, rate_test, psnr_test):
    l_rate_anchor = [math.log(r) for r in rate_anchor]
    l_rate_test = [math.log(r) for r in rate_test]

    min_p = max(min(psnr_anchor), min(psnr_test))
    max_p = min(max(psnr_anchor), max(psnr_test))

    if min_p >= max_p:
        return 0.0

    fit_anchor = polyfit3(psnr_anchor, l_rate_anchor)
    fit_test = polyfit3(psnr_test, l_rate_test)

    int_anchor = polyint_eval(fit_anchor, min_p, max_p)
    int_test = polyint_eval(fit_test, min_p, max_p)

    avg_diff = (int_test - int_anchor) / (max_p - min_p)
    return (math.exp(avg_diff) - 1.0) * 100.0

def bd_psnr(rate_anchor, psnr_anchor, rate_test, psnr_test):
    l_rate_anchor = [math.log(r) for r in rate_anchor]
    l_rate_test = [math.log(r) for r in rate_test]

    min_r = max(min(l_rate_anchor), min(l_rate_test))
    max_r = min(max(l_rate_anchor), max(l_rate_test))

    if min_r >= max_r:
        return 0.0

    fit_anchor = polyfit3(l_rate_anchor, psnr_anchor)
    fit_test = polyfit3(l_rate_test, psnr_test)

    int_anchor = polyint_eval(fit_anchor, min_r, max_r)
    int_test = polyint_eval(fit_test, min_r, max_r)

    avg_diff = (int_test - int_anchor) / (max_r - min_r)
    return avg_diff

if __name__ == "__main__":
    r_hm = [150.0, 300.0, 600.0, 1200.0]
    p_hm = [32.0, 35.0, 38.0, 41.0]

    r_hw = [155.0, 310.0, 615.0, 1220.0]
    p_hw = [31.9, 34.9, 37.9, 40.9]

    print(f"Sample BD-Rate: {bd_rate(r_hm, p_hm, r_hw, p_hw):+.2f} %")
    print(f"Sample BD-PSNR: {bd_psnr(r_hm, p_hm, r_hw, p_hw):+.3f} dB")


