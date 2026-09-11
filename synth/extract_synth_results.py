import os
import re
import sys

def parse_fit_summary(fit_rpt):
    if not os.path.exists(fit_rpt):
        return {}
    results = {}
    with open(fit_rpt, "r", encoding="utf-8", errors="ignore") as f:
        content = f.read()
    
    # Fitter Summary table
    m = re.search(r"; Fitter Status\s*;\s*([^;]+);", content)
    if m: results["status"] = m.group(1).strip()
    
    m = re.search(r"; Logic utilization \(in ALMs\)\s*;\s*([^;]+);", content)
    if m: results["alms"] = m.group(1).strip()
    
    m = re.search(r"; Total registers\s*;\s*([^;]+);", content)
    if m: results["registers"] = m.group(1).strip()
    
    m = re.search(r"; Total block memory bits\s*;\s*([^;]+);", content)
    if m: results["memory_bits"] = m.group(1).strip()
    
    m = re.search(r"; Total RAM Blocks\s*;\s*([^;]+);", content)
    if m: results["ram_blocks"] = m.group(1).strip()
    
    m = re.search(r"; Total DSP Blocks\s*;\s*([^;]+);", content)
    if m: results["dsp_blocks"] = m.group(1).strip()
    
    m = re.search(r"; Total pins\s*;\s*([^;]+);", content)
    if m: results["pins"] = m.group(1).strip()
    
    m = re.search(r"; Total virtual pins\s*;\s*([^;]+);", content)
    if m: results["virtual_pins"] = m.group(1).strip()
    
    return results

def parse_sta_summary(sta_rpt):
    if not os.path.exists(sta_rpt):
        return {}
    results = {}
    with open(sta_rpt, "r", encoding="utf-8", errors="ignore") as f:
        lines = f.readlines()
    
    # Look for Fmax Summary
    for i, line in enumerate(lines):
        if "Fmax Summary" in line:
            for j in range(i, min(i+30, len(lines))):
                if "clk" in lines[j] and ";" in lines[j]:
                    parts = [p.strip() for p in lines[j].split(";")]
                    if len(parts) >= 3:
                        results["fmax"] = parts[1]
                        results["target_fmax"] = parts[2]
                        break
        if "Worst-case Slack" in line or "Slow 1100mV 85C Model" in line or "Slow 1100mV 0C Model" in line or "Fast 1100mV 0C Model" in line:
            pass
            
    # Setup slack
    m = re.search(r"; Setup\s*;\s*clk\s*;\s*([^;]+);", "".join(lines))
    if m: results["setup_slack"] = m.group(1).strip()

    # Hold slack
    m = re.search(r"; Hold\s*;\s*clk\s*;\s*([^;]+);", "".join(lines))
    if m: results["hold_slack"] = m.group(1).strip()

    return results

def main():
    base_dir = "output_files"
    map_rpt = os.path.join(base_dir, "hevc_encoder_top.map.rpt")
    fit_rpt = os.path.join(base_dir, "hevc_encoder_top.fit.rpt")
    sta_rpt = os.path.join(base_dir, "hevc_encoder_top.sta.rpt")
    
    print("=================================================================")
    print(" FPGA Synthesis & Implementation Summary: hevc_encoder_top")
    print("=================================================================")
    
    fit_res = parse_fit_summary(fit_rpt)
    print("\n--- [Resource Utilization] ---")
    for k, v in fit_res.items():
        print(f"  {k:20s}: {v}")
        
    sta_res = parse_sta_summary(sta_rpt)
    print("\n--- [Timing Summary] ---")
    for k, v in sta_res.items():
        print(f"  {k:20s}: {v}")

if __name__ == "__main__":
    main()
