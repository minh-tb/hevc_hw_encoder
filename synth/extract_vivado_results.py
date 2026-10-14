#!/usr/bin/env python3
"""
extract_vivado_results.py
Parses AMD Vivado synthesis and timing reports for the HEVC Hardware Video Encoder.
Extracts:
  - Resource utilization (CLB LUTs, Registers, BRAMs, DSPs, etc.)
  - Timing metrics (WNS, TNS, Clock Period, Estimated Fmax)
  - Power consumption (Dynamic, Device Static, Total On-Chip Power)
"""

import os
import re
import sys

def parse_utilization(rpt_path):
    if not os.path.exists(rpt_path):
        return None

    results = {}
    with open(rpt_path, "r", encoding="utf-8", errors="ignore") as f:
        content = f.read()

    # Design and device info
    m_dev = re.search(r"\|\s*Device\s*:\s*(\S+)", content)
    if m_dev:
        results["device"] = m_dev.group(1).strip()
    m_top = re.search(r"\|\s*Design\s*:\s*(\S+)", content)
    if m_top:
        results["design"] = m_top.group(1).strip()

    def parse_table_row(pattern):
        m = re.search(pattern, content)
        if m:
            used = m.group(1).strip().replace(",", "")
            avail = m.group(2).strip().replace(",", "")
            util = m.group(3).strip().replace(",", "")
            return {"used": used, "available": avail, "util_pct": util}
        return None

    # CLB LUTs
    res = parse_table_row(r"\|\s*CLB LUTs\*?\s*\|\s*(\d+)\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*(\d+)\s*\|\s*([0-9\.]+)\s*\|")
    if res:
        results["lut"] = res

    # LUT as Logic
    res = parse_table_row(r"\|\s*LUT as Logic\s*\|\s*(\d+)\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*(\d+)\s*\|\s*([0-9\.]+)\s*\|")
    if res:
        results["lut_logic"] = res

    # CLB Registers
    res = parse_table_row(r"\|\s*CLB Registers\s*\|\s*(\d+)\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*(\d+)\s*\|\s*([0-9\.]+)\s*\|")
    if res:
        results["ff"] = res

    # Block RAM Tile
    res = parse_table_row(r"\|\s*Block RAM Tile\s*\|\s*(\d+)\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*(\d+)\s*\|\s*([0-9\.]+)\s*\|")
    if res:
        results["bram_tile"] = res

    # RAMB36/FIFO
    res = parse_table_row(r"\|\s*RAMB36/FIFO\*?\s*\|\s*(\d+)\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*(\d+)\s*\|\s*([0-9\.]+)\s*\|")
    if res:
        results["ramb36"] = res

    # RAMB18
    res = parse_table_row(r"\|\s*RAMB18\s*\|\s*(\d+)\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*(\d+)\s*\|\s*([0-9\.]+)\s*\|")
    if res:
        results["ramb18"] = res

    # DSPs
    res = parse_table_row(r"\|\s*DSPs\s*\|\s*(\d+)\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*(\d+)\s*\|\s*([0-9\.]+)\s*\|")
    if res:
        results["dsp"] = res

    return results

def parse_timing(rpt_path):
    if not os.path.exists(rpt_path):
        return None

    results = {}
    with open(rpt_path, "r", encoding="utf-8", errors="ignore") as f:
        content = f.read()

    lines = content.splitlines()

    # Find Design Timing Summary WNS / TNS
    for i, line in enumerate(lines):
        if "WNS(ns)" in line and "TNS(ns)" in line:
            for j in range(i + 1, min(i + 5, len(lines))):
                data_line = lines[j].strip()
                if not data_line or set(data_line) <= {"-", " "}:
                    continue
                parts = data_line.split()
                if len(parts) >= 4:
                    try:
                        results["wns"] = float(parts[0])
                        results["tns"] = float(parts[1])
                        results["failing_endpoints"] = int(parts[2])
                        results["total_endpoints"] = int(parts[3])
                        break
                    except ValueError:
                        pass
            break

    # Clock summary
    m_clk = re.search(
        r"Clock\s+Waveform\(ns\)\s+Period\(ns\)\s+Frequency\(MHz\)\s*[\r\n]+"
        r"[-|\s]+[\r\n]+"
        r"(\S+)\s+\{[^}]+\}\s+([\d\.]+)\s+([\d\.]+)",
        content
    )
    if m_clk:
        results["clock_name"] = m_clk.group(1)
        results["target_period_ns"] = float(m_clk.group(2))
        results["target_freq_mhz"] = float(m_clk.group(3))

        if "wns" in results:
            wns = results["wns"]
            t_clk = results["target_period_ns"]
            min_period = t_clk - wns
            if min_period > 0:
                results["fmax_mhz"] = 1000.0 / min_period

    return results

def parse_power(rpt_path):
    if not os.path.exists(rpt_path):
        return None

    results = {}
    with open(rpt_path, "r", encoding="utf-8", errors="ignore") as f:
        content = f.read()

    m_total = re.search(r"\|\s*Total On-Chip Power \(W\)\s*\|\s*([\d\.]+)", content)
    if m_total:
        results["total_power_w"] = float(m_total.group(1))

    m_dyn = re.search(r"\|\s*Dynamic \(W\)\s*\|\s*([\d\.]+)", content)
    if m_dyn:
        results["dynamic_power_w"] = float(m_dyn.group(1))

    m_stat = re.search(r"\|\s*Device Static \(W\)\s*\|\s*([\d\.]+)", content)
    if m_stat:
        results["static_power_w"] = float(m_stat.group(1))

    return results

def main():
    base_dir = os.path.join(os.path.dirname(__file__), "vivado_output")
    if len(sys.argv) > 1:
        base_dir = sys.argv[1]

    util_rpt = os.path.join(base_dir, "utilization_synth.rpt")
    timing_rpt = os.path.join(base_dir, "timing_summary_synth.rpt")
    power_rpt = os.path.join(base_dir, "power_synth.rpt")

    print("================================================================================")
    print("        AMD Vivado Synthesis & Implementation Results Summary                   ")
    print("================================================================================")

    util = parse_utilization(util_rpt)
    if util:
        print(f" Design Top:       {util.get('design', 'N/A')}")
        print(f" Target Device:    {util.get('device', 'N/A')}")
        print("--------------------------------------------------------------------------------")
        print(f" {'Resource':<24} | {'Used':>10} | {'Available':>12} | {'Utilization %':>15}")
        print("--------------------------------------------------------------------------------")
        if "lut" in util:
            print(f" {'CLB LUTs':<24} | {util['lut']['used']:>10} | {util['lut']['available']:>12} | {util['lut']['util_pct'] + '%':>15}")
        if "lut_logic" in util:
            print(f"   - Logic LUTs           | {util['lut_logic']['used']:>10} | {util['lut_logic']['available']:>12} | {util['lut_logic']['util_pct'] + '%':>15}")
        if "ff" in util:
            print(f" {'CLB Registers (FF)':<24} | {util['ff']['used']:>10} | {util['ff']['available']:>12} | {util['ff']['util_pct'] + '%':>15}")
        if "bram_tile" in util:
            print(f" {'Block RAM Tiles':<24} | {util['bram_tile']['used']:>10} | {util['bram_tile']['available']:>12} | {util['bram_tile']['util_pct'] + '%':>15}")
        if "ramb36" in util:
            print(f"   - RAMB36/FIFO          | {util['ramb36']['used']:>10} | {util['ramb36']['available']:>12} | {util['ramb36']['util_pct'] + '%':>15}")
        if "ramb18" in util:
            print(f"   - RAMB18               | {util['ramb18']['used']:>10} | {util['ramb18']['available']:>12} | {util['ramb18']['util_pct'] + '%':>15}")
        if "dsp" in util:
            print(f" {'DSP Slices':<24} | {util['dsp']['used']:>10} | {util['dsp']['available']:>12} | {util['dsp']['util_pct'] + '%':>15}")
        print("--------------------------------------------------------------------------------")
    else:
        print(f" [WARNING] Utilization report not found at {util_rpt}")

    timing = parse_timing(timing_rpt)
    if timing:
        print("\n--- [Timing Analysis] ---")
        clk_name = timing.get("clock_name", "clk")
        target_t = timing.get("target_period_ns", 0.0)
        target_f = timing.get("target_freq_mhz", 0.0)
        wns = timing.get("wns", 0.0)
        tns = timing.get("tns", 0.0)
        failing = timing.get("failing_endpoints", 0)
        total_ep = timing.get("total_endpoints", 0)
        fmax = timing.get("fmax_mhz", 0.0)

        print(f" Clock Domain:     {clk_name}")
        print(f" Target Period:    {target_t:.3f} ns ({target_f:.2f} MHz)")
        print(f" Setup Slack (WNS):{wns:+.3f} ns {'(MET)' if wns >= 0 else '(VIOLATED)'}")
        print(f" Total Slack (TNS):{tns:+.3f} ns ({failing} / {total_ep} failing endpoints)")
        if fmax > 0:
            print(f" Estimated Fmax:   {fmax:.2f} MHz")
        print("--------------------------------------------------------------------------------")
    else:
        print(f" [WARNING] Timing summary report not found at {timing_rpt}")

    power = parse_power(power_rpt)
    if power:
        print("\n--- [Power Estimation] ---")
        print(f" Total On-Chip:    {power.get('total_power_w', 0.0):.3f} W")
        print(f" Dynamic:          {power.get('dynamic_power_w', 0.0):.3f} W")
        print(f" Device Static:    {power.get('static_power_w', 0.0):.3f} W")
        print("--------------------------------------------------------------------------------")

if __name__ == "__main__":
    main()
