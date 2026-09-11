"""
plot_rd_curves.py
Generates SVG and ASCII Rate-Distortion Plots (PSNR vs Bitrate)
"""

def generate_svg_rd_curve(qp_data, output_svg="rd_curve.svg"):
    width = 700
    height = 450
    margin = 70

    # Data points
    bitrates = [d["bitrate_kbps"] for d in qp_data]
    psnrs = [d["psnr_y"] for d in qp_data]

    min_br, max_br = min(bitrates) * 0.8, max(bitrates) * 1.15
    min_psnr, max_psnr = min(psnrs) - 2.0, max(psnrs) + 2.0

    def scale_x(br):
        return margin + (br - min_br) / (max_br - min_br) * (width - 2 * margin)

    def scale_y(p):
        return height - margin - (p - min_psnr) / (max_psnr - min_psnr) * (height - 2 * margin)

    points = " ".join([f"{scale_x(br):.1f},{scale_y(p):.1f}" for br, p in zip(bitrates, psnrs)])

    svg = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" width="{width}" height="{height}" style="background-color: #1e1e2e; font-family: sans-serif;">
  <text x="{width/2}" y="35" fill="#cdd6f4" font-size="18" font-weight="bold" text-anchor="middle">HEVC Rate-Distortion Curve (QP 22 to 37)</text>
  
  <!-- Axes -->
  <line x1="{margin}" y1="{height-margin}" x2="{width-margin}" y2="{height-margin}" stroke="#a6adc8" stroke-width="2" />
  <line x1="{margin}" y1="{margin}" x2="{margin}" y2="{height-margin}" stroke="#a6adc8" stroke-width="2" />
  
  <!-- Axis Labels -->
  <text x="{width/2}" y="{height-20}" fill="#cdd6f4" font-size="14" text-anchor="middle">Bitrate (kbps)</text>
  <text x="25" y="{height/2}" fill="#cdd6f4" font-size="14" text-anchor="middle" transform="rotate(-90 25 {height/2})">Luma PSNR (dB)</text>
  
  <!-- RD Curve -->
  <polyline points="{points}" fill="none" stroke="#89b4fa" stroke-width="3" />
"""

    for d in qp_data:
        cx = scale_x(d["bitrate_kbps"])
        cy = scale_y(d["psnr_y"])
        svg += f"""
  <circle cx="{cx:.1f}" cy="{cy:.1f}" r="6" fill="#f38ba8" />
  <text x="{cx+10:.1f}" y="{cy-10:.1f}" fill="#fab387" font-size="12" font-weight="bold">QP{d['qp']} ({d['bitrate_kbps']:.1f}k, {d['psnr_y']:.1f}dB)</text>
"""

    svg += "</svg>"

    with open(output_svg, "w") as f:
        f.write(svg)
    print(f"Generated RD Curve SVG: {output_svg}")

if __name__ == "__main__":
    sample_data = [
        {"qp": 22, "bitrate_kbps": 70.3, "psnr_y": 51.61},
        {"qp": 27, "bitrate_kbps": 52.3, "psnr_y": 47.98},
        {"qp": 32, "bitrate_kbps": 40.9, "psnr_y": 44.06},
        {"qp": 37, "bitrate_kbps": 33.6, "psnr_y": 41.44},
    ]
    generate_svg_rd_curve(sample_data)
