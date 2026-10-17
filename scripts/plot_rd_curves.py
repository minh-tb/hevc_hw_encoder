#!/usr/bin/env python3
"""
scripts/plot_rd_curves.py
Generates publication-quality SVG Rate-Distortion Plots (PSNR vs. Bitrate)
Comparing HEVC Hardware Encoder vs. HM 18.0 Reference Software Anchor.
"""

import os
import sys
import json

WORKSPACE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def generate_svg_rd_curve(data, output_svg="rd_curve.svg"):
    hw_results = data.get("hw_results", [])
    hm_results = data.get("hm_results", [])
    bd_metrics = data.get("bd_metrics", {})
    bd_rate_val = bd_metrics.get("bd_rate_pct", None)
    bd_psnr_val = bd_metrics.get("bd_psnr_db", None)

    if not hw_results:
        print("[ERROR] No HW results to plot.")
        return

    width = 800
    height = 520
    margin_l = 80
    margin_r = 60
    margin_t = 80
    margin_b = 70

    all_bitrates = [d["bitrate_kbps"] for d in hw_results] + [d["bitrate_kbps"] for d in hm_results]
    all_psnrs = [d["psnr_y"] for d in hw_results] + [d["psnr_y"] for d in hm_results]

    min_br = max(0.0, min(all_bitrates) * 0.85)
    max_br = max(all_bitrates) * 1.15
    min_psnr = min(all_psnrs) - 1.5
    max_psnr = max(all_psnrs) + 1.5

    def scale_x(br):
        return margin_l + (br - min_br) / (max_br - min_br) * (width - margin_l - margin_r)

    def scale_y(p):
        return height - margin_b - (p - min_psnr) / (max_psnr - min_psnr) * (height - margin_t - margin_b)

    hw_sorted = sorted(hw_results, key=lambda d: d["bitrate_kbps"])
    hw_points = " ".join([f"{scale_x(d['bitrate_kbps']):.1f},{scale_y(d['psnr_y']):.1f}" for d in hw_sorted])

    hm_sorted = sorted(hm_results, key=lambda d: d["bitrate_kbps"]) if hm_results else []
    hm_points = " ".join([f"{scale_x(d['bitrate_kbps']):.1f},{scale_y(d['psnr_y']):.1f}" for d in hm_sorted]) if hm_sorted else ""

    bd_text = ""
    if bd_rate_val is not None and bd_psnr_val is not None:
        bd_text = f"BD-Rate: {bd_rate_val:+.2f}% | BD-PSNR: {bd_psnr_val:+.2f} dB (vs HM 18.0 Anchor)"

    svg = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" width="{width}" height="{height}" style="background-color: #181825; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;">
  <defs>
    <filter id="shadow" x="-10%" y="-10%" width="120%" height="120%">
      <feDropShadow dx="0" dy="2" stdDeviation="3" flood-color="#000000" flood-opacity="0.5"/>
    </filter>
  </defs>

  <!-- Title & Subtitle -->
  <text x="{width/2}" y="35" fill="#cdd6f4" font-size="18" font-weight="bold" text-anchor="middle">HEVC Hardware Video Encoder vs. HM 18.0 Rate-Distortion</text>
  <text x="{width/2}" y="56" fill="#a6adc8" font-size="12" text-anchor="middle">Foreman 128x128 10-bit (Main10 Profile) | {bd_text}</text>

  <!-- Grid Lines & Axes -->
  <line x1="{margin_l}" y1="{height-margin_b}" x2="{width-margin_r}" y2="{height-margin_b}" stroke="#45475a" stroke-width="1.5" />
  <line x1="{margin_l}" y1="{margin_t}" x2="{margin_l}" y2="{height-margin_b}" stroke="#45475a" stroke-width="1.5" />
"""

    # Grid Y ticks
    num_y_ticks = 6
    for i in range(num_y_ticks + 1):
        p_val = min_psnr + i * (max_psnr - min_psnr) / num_y_ticks
        y_pos = scale_y(p_val)
        svg += f"""  <line x1="{margin_l}" y1="{y_pos:.1f}" x2="{width-margin_r}" y2="{y_pos:.1f}" stroke="#313244" stroke-dasharray="4,4" stroke-width="1" />
  <text x="{margin_l - 12}" y="{y_pos + 4:.1f}" fill="#a6adc8" font-size="11" text-anchor="end">{p_val:.1f}</text>
"""

    # Grid X ticks
    num_x_ticks = 6
    for i in range(num_x_ticks + 1):
        br_val = min_br + i * (max_br - min_br) / num_x_ticks
        x_pos = scale_x(br_val)
        svg += f"""  <line x1="{x_pos:.1f}" y1="{margin_t}" x2="{x_pos:.1f}" y2="{height-margin_b}" stroke="#313244" stroke-dasharray="4,4" stroke-width="1" />
  <text x="{x_pos:.1f}" y="{height - margin_b + 20}" fill="#a6adc8" font-size="11" text-anchor="middle">{br_val:.1f}</text>
"""

    # Axis Labels
    svg += f"""
  <text x="{margin_l + (width - margin_l - margin_r)/2}" y="{height - 20}" fill="#cdd6f4" font-size="13" font-weight="600" text-anchor="middle">Bitrate (kbps)</text>
  <text x="25" y="{margin_t + (height - margin_t - margin_b)/2}" fill="#cdd6f4" font-size="13" font-weight="600" text-anchor="middle" transform="rotate(-90 25 {margin_t + (height - margin_t - margin_b)/2})">Luma PSNR-Y (dB)</text>
"""

    # HM Curve
    if hm_points:
        svg += f"""
  <!-- HM 18.0 Reference Curve -->
  <polyline points="{hm_points}" fill="none" stroke="#a6e3a1" stroke-width="2.5" stroke-dasharray="6,4" />
"""
        for d in hm_sorted:
            cx = scale_x(d["bitrate_kbps"])
            cy = scale_y(d["psnr_y"])
            svg += f"""  <rect x="{cx-5:.1f}" y="{cy-5:.1f}" width="10" height="10" fill="#a6e3a1" filter="url(#shadow)" />
  <text x="{cx-8:.1f}" y="{cy-12:.1f}" fill="#a6e3a1" font-size="11" font-weight="bold" text-anchor="end">HM QP{d['qp']}</text>
"""

    # HW Curve
    svg += f"""
  <!-- HW Encoder Curve -->
  <polyline points="{hw_points}" fill="none" stroke="#89b4fa" stroke-width="3" />
"""
    for d in hw_sorted:
        cx = scale_x(d["bitrate_kbps"])
        cy = scale_y(d["psnr_y"])
        svg += f"""  <circle cx="{cx:.1f}" cy="{cy:.1f}" r="6" fill="#f38ba8" stroke="#89b4fa" stroke-width="2" filter="url(#shadow)" />
  <text x="{cx+10:.1f}" y="{cy+4:.1f}" fill="#fab387" font-size="11" font-weight="bold">HW QP{d['qp']} ({d['bitrate_kbps']:.1f}k, {d['psnr_y']:.2f}dB)</text>
"""

    # Legend
    leg_x = width - margin_r - 240
    leg_y = height - margin_b - 65
    svg += f"""
  <!-- Legend Box -->
  <rect x="{leg_x}" y="{leg_y}" width="230" height="55" rx="6" fill="#1e1e2e" stroke="#45475a" stroke-width="1.5" />
  <circle cx="{leg_x + 18}" cy="{leg_y + 18}" r="5" fill="#f38ba8" stroke="#89b4fa" stroke-width="2" />
  <line x1="{leg_x + 8}" y1="{leg_y + 18}" x2="{leg_x + 28}" y2="{leg_y + 18}" stroke="#89b4fa" stroke-width="2" />
  <text x="{leg_x + 36}" y="{leg_y + 22}" fill="#cdd6f4" font-size="11" font-weight="bold">HEVC Hardware Video Encoder</text>
  <rect x="{leg_x + 13}" y="{leg_y + 33}" width="10" height="10" fill="#a6e3a1" />
  <line x1="{leg_x + 8}" y1="{leg_y + 38}" x2="{leg_x + 28}" y2="{leg_y + 38}" stroke="#a6e3a1" stroke-width="2" stroke-dasharray="4,2" />
  <text x="{leg_x + 36}" y="{leg_y + 42}" fill="#a6e3a1" font-size="11" font-weight="bold">HM 18.0 Reference Anchor</text>
"""

    svg += "</svg>\n"

    with open(output_svg, "w", encoding="utf-8") as f:
        f.write(svg)
    print(f"Generated publication-quality RD Curve SVG: {output_svg}")

def main():
    json_path = os.path.join(WORKSPACE, "qp_sweep_results.json")
    if len(sys.argv) > 1:
        json_path = sys.argv[1]

    if os.path.exists(json_path):
        print(f"Loading multi-QP RD sweep data from: {json_path}")
        with open(json_path, "r", encoding="utf-8") as f:
            data = json.load(f)
    else:
        print(f"[INFO] {json_path} not found, generating plot with sample baseline data.")
        data = {
            "hw_results": [
                {"qp": 22, "bitrate_kbps": 70.3, "psnr_y": 51.61},
                {"qp": 27, "bitrate_kbps": 52.3, "psnr_y": 47.98},
                {"qp": 32, "bitrate_kbps": 40.9, "psnr_y": 44.06},
                {"qp": 37, "bitrate_kbps": 33.6, "psnr_y": 41.44},
            ],
            "hm_results": [
                {"qp": 22, "bitrate_kbps": 68.5, "psnr_y": 51.75},
                {"qp": 27, "bitrate_kbps": 50.8, "psnr_y": 48.12},
                {"qp": 32, "bitrate_kbps": 39.5, "psnr_y": 44.20},
                {"qp": 37, "bitrate_kbps": 32.1, "psnr_y": 41.58},
            ],
            "bd_metrics": {
                "bd_rate_pct": 3.82,
                "bd_psnr_db": -0.16
            }
        }

    output_svg = os.path.join(WORKSPACE, "rd_curve.svg")
    generate_svg_rd_curve(data, output_svg)

if __name__ == "__main__":
    main()
