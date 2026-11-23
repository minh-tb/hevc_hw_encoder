#!/usr/bin/env python3
"""
Unified Dual-Tier UVM Verification Suite Runner (Gate G8)
for the HEVC / H.265 Main10 Hardware Video Encoder.

Supports both AMD Vivado 2026.1 xsim (Windows local) and Siemens QuestaSim 2021.2_1
(asiclab Linux server via uvm/sim/Makefile).

Executes:
  - Tier 1: CABAC M-Coder Block-Level UVM (uvm/uvm_cabac)
  - Tier 2: SoC AXI Top UVM + UVM RAL + HM 18.0 Closed-Loop Decode (uvm/uvm_axi_top)
  - Gate G6: SHA-256 Parity Check between rtl/ and ip_repo/hevc_encoder_v1_0/src/
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Tuple


VIVADO_BIN = Path(r"D:\Xilinx\2026.1\Vivado\bin")
XVLOG_BAT = VIVADO_BIN / "xvlog.bat"
XELAB_BAT = VIVADO_BIN / "xelab.bat"
XSIM_BAT = VIVADO_BIN / "xsim.bat"
DEFAULT_LICENSE_FILE = r"C:\Users\Admin\.Xilinx\Xilinx.lic"

EXPECTED_YUV_BYTES_64X64_10BIT = 12288  # 64*64*2 (Y) + 2*32*32*2 (Cb, Cr)
EXPECTED_RTL_FILE_COUNT = 64


@dataclass
class CheckResult:
    name: str
    status: str  # PASS, FAIL, SKIPPED
    metrics: str
    errors_fatals: str
    duration_s: float = 0.0
    details: List[str] = field(default_factory=list)


def get_repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def has_xsim() -> bool:
    return XVLOG_BAT.is_file() and XELAB_BAT.is_file() and XSIM_BAT.is_file()


def has_questa() -> bool:
    return (shutil.which("vsim") is not None) and (shutil.which("vopt") is not None)


def resolve_simulator(sim_arg: str) -> str:
    if sim_arg != "auto":
        return sim_arg
    if has_xsim():
        return "xsim"
    if has_questa():
        return "questa"
    return "none"


def build_vivado_env() -> Dict[str, str]:
    env = os.environ.copy()
    env["XILINXD_LICENSE_FILE"] = DEFAULT_LICENSE_FILE
    return env


def build_questa_env(repo_root: Path) -> Dict[str, str]:
    env = os.environ.copy()
    env.setdefault("HEVC_UVM_DIR", str(repo_root / "uvm"))
    env.setdefault("HEVC_ROOT_DIR", str(repo_root))
    return env


def quote_cmd_arg(arg: str) -> str:
    if any(ch in arg for ch in (" ", "\t", '"', "=")):
        escaped = arg.replace('"', '\\"')
        return f'"{escaped}"'
    return arg


def run_bat_command(
    cmd: List[str],
    cwd: Path,
    env: Dict[str, str],
    verbose: bool = False,
) -> Tuple[int, str, float]:
    """
    Execute a Windows .bat tool (xvlog/xelab/xsim) through cmd.exe quoting so
    arguments containing '=' (such as -testplusarg "UVM_TESTNAME=...") are not
    split by batch %1/%* delimiter rules.
    """
    cmd_str = " ".join(quote_cmd_arg(c) for c in cmd)
    if verbose:
        print(f"  [CMD] ({cwd}) {cmd_str}")
    t0 = time.monotonic()
    proc = subprocess.run(
        cmd_str,
        cwd=str(cwd),
        env=env,
        shell=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    elapsed = time.monotonic() - t0
    if verbose and proc.stdout:
        print(proc.stdout)
    return proc.returncode, proc.stdout or "", elapsed


def run_exe_command(
    cmd: List[str],
    cwd: Path,
    env: Dict[str, str],
    verbose: bool = False,
) -> Tuple[int, str, float]:
    if verbose:
        print(f"  [CMD] ({cwd}) {' '.join(cmd)}")
    t0 = time.monotonic()
    proc = subprocess.run(
        cmd,
        cwd=str(cwd),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    elapsed = time.monotonic() - t0
    if verbose and proc.stdout:
        print(proc.stdout)
    return proc.returncode, proc.stdout or "", elapsed


def parse_rtl_files_from_tcl(tcl_path: Path, repo_root: Path) -> List[Path]:
    text = tcl_path.read_text(encoding="utf-8")
    match = re.search(r"set\s+rtl_files\s+\[list(.*?)\]", text, re.DOTALL)
    if not match:
        raise RuntimeError(f"Could not locate 'set rtl_files [list ...]' in {tcl_path}")
    rel_paths = re.findall(r'"([^"]+)"', match.group(1))
    resolved: List[Path] = []
    for rel in rel_paths:
        p = (repo_root / rel).resolve()
        if not p.is_file():
            raise FileNotFoundError(f"RTL file listed in synth_vivado.tcl not found: {p}")
        resolved.append(p)
    return resolved


def parse_uvm_report_counts(log_text: str) -> Dict[str, int]:
    counts = {"UVM_INFO": -1, "UVM_WARNING": -1, "UVM_ERROR": -1, "UVM_FATAL": -1}
    for sev in counts:
        matches = re.findall(rf"^\s*(?:#\s*)?{sev}\s*:\s*(\d+)\s*$", log_text, re.MULTILINE)
        if matches:
            counts[sev] = int(matches[-1])
    return counts


def count_sva_or_sim_errors(log_text: str) -> List[str]:
    hits: List[str] = []
    for line in log_text.splitlines():
        if re.search(r"\[(?:CABAC_IF|SVA)\].*(?:SVA|violat|Error)", line, re.IGNORECASE):
            hits.append(line.strip())
        elif re.match(r"^\s*(?:#\s*)?(?:ERROR|FATAL_ERROR)\s*:", line):
            hits.append(line.strip())
        elif "ERROR [range_coder]" in line:
            hits.append(line.strip())
        elif re.match(r"^\s*(?:#\s*)?\*\*\s*(?:Error|Fatal)(?:\s*\([^)]*\))?\s*:", line):
            hits.append(line.strip())
        else:
            m = re.match(r"^\s*(?:#\s*)?Errors\s*:\s*(\d+)\s*,\s*Warnings\s*:\s*(\d+)", line)
            if m and int(m.group(1)) > 0:
                hits.append(line.strip())
    return hits


def evaluate_tier1_log(
    log_text: str,
    rc: int,
    elapsed: float,
    fallback_out: str = "",
) -> CheckResult:
    rep = parse_uvm_report_counts(log_text)
    sva_hits = count_sva_or_sim_errors(log_text)

    def extract_int(pattern: str, default: int = -1) -> int:
        m = re.search(pattern, log_text)
        return int(m.group(1)) if m else default

    def extract_float(pattern: str, default: float = -1.0) -> float:
        m = re.search(pattern, log_text)
        return float(m.group(1)) if m else default

    bins_coded = extract_int(r"Total Bins Coded\s*:\s*(\d+)")
    bytes_exp = extract_int(r"Bytes Expected\s*:\s*(\d+)")
    bytes_rcvd = extract_int(r"Bytes Received\s*:\s*(\d+)")
    byte_mismatches = extract_int(r"Byte Mismatches\s*:\s*(\d+)")
    flush_mismatches = extract_int(r"Flush Mismatches\s*:\s*(\d+)")
    rem_bytes = extract_int(r"Remaining Bytes\s*:\s*(\d+)")
    carry_ripples = extract_int(r"Carry Ripples\s*\(>1\)\s*:\s*(\d+)")
    cov_pct = extract_float(r"Overall cg_cabac\s*:\s*([0-9.]+)%")
    bp_match = re.search(
        r"Backpressure observed:\s*(\d+)\s+byte_valid stall cycles out of\s*(\d+)",
        log_text,
    )
    bp_str = f"{bp_match.group(1)}/{bp_match.group(2)}" if bp_match else "N/A"

    passed = (
        rc == 0
        and rep["UVM_ERROR"] == 0
        and rep["UVM_FATAL"] == 0
        and len(sva_hits) == 0
        and bins_coded >= 5000
        and bytes_exp > 0
        and bytes_exp == bytes_rcvd
        and byte_mismatches == 0
        and flush_mismatches == 0
        and rem_bytes == 0
        and cov_pct >= 95.0
    )

    metrics = (
        f"Bins={bins_coded}, Bytes={bytes_rcvd}/{bytes_exp} (Mis={byte_mismatches}), "
        f"Ripples={carry_ripples}, Stall={bp_str}, cg_cabac={cov_pct:.2f}%"
    )
    err_str = f"ERR={rep['UVM_ERROR']} FAT={rep['UVM_FATAL']} SVA={len(sva_hits)}"
    details: List[str] = []
    if not passed:
        details = sva_hits[:10] if sva_hits else (fallback_out or log_text).splitlines()[-15:]
    return CheckResult(
        "Tier 1: CABAC M-Coder",
        "PASS" if passed else "FAIL",
        metrics,
        err_str,
        elapsed,
        details,
    )


def evaluate_tier2_ral_log(
    log_text: str,
    rc: int,
    elapsed: float,
    fallback_out: str = "",
) -> CheckResult:
    rep = parse_uvm_report_counts(log_text)
    sva_hits = count_sva_or_sim_errors(log_text)

    hw_rst_m = re.search(r"\[uvm_reg_hw_reset_seq\]\s+(\d+)", log_text)
    bit_bash_m = re.search(r"\[uvm_reg_bit_bash_seq\]\s+(\d+)", log_text)
    hw_rst_cnt = int(hw_rst_m.group(1)) if hw_rst_m else 0
    bit_bash_cnt = int(bit_bash_m.group(1)) if bit_bash_m else 0

    sb_err_m = re.search(r"Scoreboard Errors\s*:\s*(\d+)", log_text)
    sb_errors = int(sb_err_m.group(1)) if sb_err_m else -1

    lite_m = re.search(r"AXI4-Lite Reads/Writes\s*:\s*(\d+)\s*/\s*(\d+)", log_text)
    lite_str = f"{lite_m.group(1)}R/{lite_m.group(2)}W" if lite_m else "N/A"

    cov_m = re.search(r"Overall cg_soc_axi\s*:\s*([0-9.]+)%", log_text)
    cov_pct = float(cov_m.group(1)) if cov_m else -1.0

    test_passed = "*** TEST PASSED: hevc_ral_audit_test ***" in log_text

    passed = (
        rc == 0
        and rep["UVM_ERROR"] == 0
        and rep["UVM_FATAL"] == 0
        and len(sva_hits) == 0
        and hw_rst_cnt == 10
        and bit_bash_cnt == 10
        and sb_errors == 0
        and test_passed
    )

    metrics = (
        f"hw_rst={hw_rst_cnt}/10, bit_bash={bit_bash_cnt}/10, "
        f"Lite={lite_str}, SB_Err={sb_errors}, cg_soc_axi={cov_pct:.2f}%"
    )
    err_str = f"ERR={rep['UVM_ERROR']} FAT={rep['UVM_FATAL']} SVA={len(sva_hits)}"
    details: List[str] = []
    if not passed:
        details = sva_hits[:10] if sva_hits else (fallback_out or log_text).splitlines()[-15:]
    return CheckResult(
        "Tier 2A: SoC RAL Audit",
        "PASS" if passed else "FAIL",
        metrics,
        err_str,
        elapsed,
        details,
    )


def evaluate_tier2_full_log(
    log_text: str,
    rc: int,
    elapsed: float,
    fallback_out: str = "",
) -> Tuple[CheckResult, int]:
    rep = parse_uvm_report_counts(log_text)
    sva_hits = count_sva_or_sim_errors(log_text)

    bs_m = re.search(r"Bitstream Packets\s*:\s*(\d+)\s*\((\d+)\s*bytes\)", log_text)
    bs_pkts = int(bs_m.group(1)) if bs_m else 0
    bs_bytes = int(bs_m.group(2)) if bs_m else 0

    dram_wr_m = re.search(r"DRAM Write Txns/Beats\s*:\s*(\d+)\s*/\s*(\d+)", log_text)
    dram_wr_str = f"{dram_wr_m.group(1)}/{dram_wr_m.group(2)}" if dram_wr_m else "N/A"

    sb_err_m = re.search(r"Scoreboard Errors\s*:\s*(\d+)", log_text)
    sb_errors = int(sb_err_m.group(1)) if sb_err_m else -1

    cov_m = re.search(r"Overall cg_soc_axi\s*:\s*([0-9.]+)%", log_text)
    cov_pct = float(cov_m.group(1)) if cov_m else -1.0

    hs_m = re.search(r"BS Handshake \(St/Rd\)\s*:\s*(\d+)\s*/\s*(\d+)\s*cycles", log_text)
    hs_str = f"{hs_m.group(1)}/{hs_m.group(2)}" if hs_m else "N/A"

    nal_matches = re.findall(r"\[nal_writer\]\s+NAL done type=(\d+)\s+bytes=(\d+)", log_text)
    nal_cnt = len(nal_matches)

    test_passed = "*** TEST PASSED: hevc_full_uvm_test ***" in log_text

    passed = (
        rc == 0
        and rep["UVM_ERROR"] == 0
        and rep["UVM_FATAL"] == 0
        and len(sva_hits) == 0
        and sb_errors == 0
        and bs_pkts >= 1
        and bs_bytes > 0
        and cov_pct >= 95.0
        and test_passed
    )

    metrics = (
        f"NALs={nal_cnt}, Bitstream={bs_bytes}B, DRAM_WR={dram_wr_str}, "
        f"Stall/Rd={hs_str}, cg_soc_axi={cov_pct:.2f}%"
    )
    err_str = f"ERR={rep['UVM_ERROR']} FAT={rep['UVM_FATAL']} SVA={len(sva_hits)}"
    details: List[str] = []
    if not passed:
        details = sva_hits[:10] if sva_hits else (fallback_out or log_text).splitlines()[-15:]
    return (
        CheckResult(
            "Tier 2B: Full SoC AXI UVM",
            "PASS" if passed else "FAIL",
            metrics,
            err_str,
            elapsed,
            details,
        ),
        bs_bytes,
    )


def run_xsim_tier1_cabac(
    repo_root: Path,
    env: Dict[str, str],
    skip_compile: bool,
    verbose: bool,
) -> CheckResult:
    build_dir = repo_root / "uvm" / "uvm_cabac" / "build_xsim"
    build_dir.mkdir(parents=True, exist_ok=True)
    rtl_common = (repo_root / "rtl" / "common").as_posix()
    param_vh = (repo_root / "rtl" / "common" / "parameter_pkg.vh").resolve()
    range_coder_v = (repo_root / "rtl" / "entropy" / "range_coder.v").resolve()

    if not param_vh.is_file():
        return CheckResult("Tier 1: CABAC M-Coder", "FAIL", "Missing parameter_pkg.vh", "N/A")

    t_start = time.monotonic()

    if not skip_compile:
        xvlog_cmd = [
            str(XVLOG_BAT),
            "-sv",
            "-L", "uvm",
            "-i", rtl_common,
            range_coder_v.as_posix(),
            "../cabac_if.sv",
            "../cabac_uvm_pkg.sv",
            "../tb_uvm_cabac.sv",
        ]
        rc, out, _ = run_bat_command(xvlog_cmd, build_dir, env, verbose=verbose)
        if rc != 0:
            return CheckResult(
                "Tier 1: CABAC M-Coder",
                "FAIL",
                f"xvlog failed (rc={rc})",
                "Compile Error",
                time.monotonic() - t_start,
                out.splitlines()[-25:],
            )

        xelab_cmd = [
            str(XELAB_BAT),
            "-L", "uvm",
            "-timescale", "1ns/1ps",
            "tb_uvm_cabac",
            "-s", "tb_uvm_cabac_sim",
        ]
        rc, out, _ = run_bat_command(xelab_cmd, build_dir, env, verbose=verbose)
        if rc != 0:
            return CheckResult(
                "Tier 1: CABAC M-Coder",
                "FAIL",
                f"xelab failed (rc={rc})",
                "Elab Error",
                time.monotonic() - t_start,
                out.splitlines()[-25:],
            )
    else:
        snap_dir = build_dir / "xsim.dir" / "tb_uvm_cabac_sim"
        if not snap_dir.is_dir():
            return CheckResult(
                "Tier 1: CABAC M-Coder",
                "FAIL",
                "Missing snapshot tb_uvm_cabac_sim",
                "N/A",
                time.monotonic() - t_start,
            )

    xsim_cmd = [
        str(XSIM_BAT),
        "tb_uvm_cabac_sim",
        "-R",
        "-log", "xsim_run.log",
    ]
    rc, out, _ = run_bat_command(xsim_cmd, build_dir, env, verbose=verbose)
    elapsed = time.monotonic() - t_start

    log_path = build_dir / "xsim_run.log"
    if not log_path.is_file():
        return CheckResult(
            "Tier 1: CABAC M-Coder",
            "FAIL",
            f"Missing xsim_run.log (rc={rc})",
            "N/A",
            elapsed,
            out.splitlines()[-25:],
        )

    log_text = log_path.read_text(encoding="utf-8", errors="replace")
    return evaluate_tier1_log(log_text, rc, elapsed, out)


def compile_xsim_tier2_axi_top(
    repo_root: Path,
    build_dir: Path,
    env: Dict[str, str],
    verbose: bool,
) -> Tuple[bool, str, float, List[str]]:
    tcl_path = repo_root / "synth" / "synth_vivado.tcl"
    rtl_files = parse_rtl_files_from_tcl(tcl_path, repo_root)
    rtl_common = (repo_root / "rtl" / "common").as_posix()

    vip_files = [
        "../vip/hevc_axi_if.sv",
        "../vip/hevc_ral_pkg.sv",
        "../vip/hevc_axi_vip_pkg.sv",
    ]
    env_files = [
        "../env/hevc_axi_env_pkg.sv",
        "../tests/hevc_axi_tests_pkg.sv",
        "../tb_uvm_axi_top.sv",
    ]

    t_start = time.monotonic()
    xvlog_cmd = (
        [
            str(XVLOG_BAT),
            "-sv",
            "-L", "uvm",
            "-i", rtl_common,
        ]
        + [p.as_posix() for p in rtl_files]
        + vip_files
        + env_files
    )
    rc, out, _ = run_bat_command(xvlog_cmd, build_dir, env, verbose=verbose)
    if rc != 0:
        return False, f"xvlog failed (rc={rc})", time.monotonic() - t_start, out.splitlines()[-25:]

    xelab_cmd = [
        str(XELAB_BAT),
        "-L", "uvm",
        "-timescale", "1ns/1ps",
        "tb_uvm_axi_top",
        "-s", "tb_uvm_axi_top_sim",
    ]
    rc, out, _ = run_bat_command(xelab_cmd, build_dir, env, verbose=verbose)
    elapsed = time.monotonic() - t_start
    if rc != 0:
        return False, f"xelab failed (rc={rc})", elapsed, out.splitlines()[-25:]

    return True, f"Compiled {len(rtl_files)} RTL + 6 UVM SV files", elapsed, []


def run_xsim_tier2_ral_audit(
    build_dir: Path,
    env: Dict[str, str],
    verbose: bool,
) -> CheckResult:
    t_start = time.monotonic()
    xsim_cmd = [
        str(XSIM_BAT),
        "tb_uvm_axi_top_sim",
        "-testplusarg", "UVM_TESTNAME=hevc_ral_audit_test",
        "-R",
        "-log", "xsim_ral.log",
    ]
    rc, out, _ = run_bat_command(xsim_cmd, build_dir, env, verbose=verbose)
    elapsed = time.monotonic() - t_start

    log_path = build_dir / "xsim_ral.log"
    if not log_path.is_file():
        return CheckResult(
            "Tier 2A: SoC RAL Audit",
            "FAIL",
            f"Missing xsim_ral.log (rc={rc})",
            "N/A",
            elapsed,
            out.splitlines()[-25:],
        )

    log_text = log_path.read_text(encoding="utf-8", errors="replace")
    return evaluate_tier2_ral_log(log_text, rc, elapsed, out)


def run_xsim_tier2_full_uvm(
    build_dir: Path,
    env: Dict[str, str],
    verbose: bool,
) -> Tuple[CheckResult, int]:
    t_start = time.monotonic()
    xsim_cmd = [
        str(XSIM_BAT),
        "tb_uvm_axi_top_sim",
        "-testplusarg", "UVM_TESTNAME=hevc_full_uvm_test",
        "-R",
        "-log", "xsim_full.log",
    ]
    rc, out, _ = run_bat_command(xsim_cmd, build_dir, env, verbose=verbose)
    elapsed = time.monotonic() - t_start

    log_path = build_dir / "xsim_full.log"
    if not log_path.is_file():
        return (
            CheckResult(
                "Tier 2B: Full SoC AXI UVM",
                "FAIL",
                f"Missing xsim_full.log (rc={rc})",
                "N/A",
                elapsed,
                out.splitlines()[-25:],
            ),
            0,
        )

    log_text = log_path.read_text(encoding="utf-8", errors="replace")
    return evaluate_tier2_full_log(log_text, rc, elapsed, out)


def find_hm_decoder(repo_root: Path) -> Optional[Path]:
    if os.name == "nt":
        win_default = (
            repo_root / "HM" / "bin" / "mgwmake" / "gcc-mingw-14.2" / "x86_64" / "release" / "TAppDecoder.exe"
        )
        if win_default.is_file():
            return win_default
        for name in ("TAppDecoder.exe", "TAppDecoder"):
            found = shutil.which(name)
            if found:
                return Path(found)
        return None

    for name in ("TAppDecoderStatic", "TAppDecoder"):
        found = shutil.which(name)
        if found:
            return Path(found)

    hm_dir = repo_root / "HM"
    if hm_dir.is_dir():
        for root_sub in (hm_dir / "bin", hm_dir / "build", hm_dir / "build_cmake"):
            if not root_sub.is_dir():
                continue
            for cand in sorted(root_sub.rglob("TAppDecoder*")):
                if cand.is_file() and cand.suffix.lower() != ".exe" and os.access(cand, os.X_OK):
                    return cand
    return None


def run_tier2_hm_decode(
    repo_root: Path,
    work_dir: Path,
    env: Dict[str, str],
    expected_bs_bytes: int,
    verbose: bool,
    require_hm: bool = True,
) -> CheckResult:
    bin_path = work_dir / "uvm_axi_out.bin"
    yuv_path = work_dir / "uvm_axi_dec.yuv"

    if not bin_path.is_file():
        return CheckResult("Tier 2C: HM 18.0 Decode", "FAIL", "Missing uvm_axi_out.bin", "Input Missing")

    decoder_exe = find_hm_decoder(repo_root)
    if decoder_exe is None:
        if require_hm:
            expected_path = (
                repo_root / "HM" / "bin" / "mgwmake" / "gcc-mingw-14.2" / "x86_64" / "release" / "TAppDecoder.exe"
            )
            return CheckResult("Tier 2C: HM 18.0 Decode", "FAIL", f"Missing {expected_path}", "Tool Missing")

        t0 = time.monotonic()
        raw_bs = bin_path.read_bytes()
        bin_size = len(raw_bs)
        bs_size_ok = (expected_bs_bytes <= 0 and bin_size > 0) or (bin_size == expected_bs_bytes)
        starts_annex_b = raw_bs.startswith(b"\x00\x00\x00\x01")
        nal_sc_cnt = len(re.findall(b"\x00\x00\x00\x01", raw_bs))
        passed = bs_size_ok and starts_annex_b and nal_sc_cnt >= 1
        elapsed = time.monotonic() - t0
        metrics = (
            f"In={bin_size}B (exp {expected_bs_bytes}B), AnnexB={nal_sc_cnt} NALs "
            f"(TAppDecoder not found)"
        )
        err_str = "Bin OK (No HM)" if passed else "Bin Invalid"
        return CheckResult(
            "Tier 2C: HM 18.0 Decode",
            "PASS" if passed else "FAIL",
            metrics,
            err_str,
            elapsed,
        )

    if yuv_path.exists():
        yuv_path.unlink()

    cmd = [
        str(decoder_exe),
        "-b", "uvm_axi_out.bin",
        "-o", "uvm_axi_dec.yuv",
        "-d", "10",
    ]
    rc, out, elapsed = run_exe_command(cmd, work_dir, env, verbose=verbose)

    bin_size = bin_path.stat().st_size if bin_path.is_file() else 0
    yuv_size = yuv_path.stat().st_size if yuv_path.is_file() else 0

    poc_m = re.search(r"(POC\s+0\s+TId:\s*\d+\s*\([^)]+\))", out)
    poc_str = re.sub(r"\s+", " ", poc_m.group(1).strip()) if poc_m else "POC 0 N/A"

    bs_size_ok = (expected_bs_bytes <= 0 and bin_size > 0) or (bin_size == expected_bs_bytes)
    passed = (
        rc == 0
        and bs_size_ok
        and yuv_size == EXPECTED_YUV_BYTES_64X64_10BIT
    )

    metrics = f"In={bin_size}B, Out={yuv_size}B (exp {EXPECTED_YUV_BYTES_64X64_10BIT}B), {poc_str}"
    err_str = f"exit={rc}"
    details = out.splitlines()[-20:] if not passed else []
    return CheckResult(
        "Tier 2C: HM 18.0 Decode",
        "PASS" if passed else "FAIL",
        metrics,
        err_str,
        elapsed,
        details,
    )


def run_gate_g6_sha256_parity(repo_root: Path) -> CheckResult:
    t_start = time.monotonic()
    rtl_root = repo_root / "rtl"
    ip_src_root = repo_root / "ip_repo" / "hevc_encoder_v1_0" / "src"

    rtl_files = {p.name: p for p in rtl_root.rglob("*") if p.is_file() and p.suffix in (".v", ".vh")}
    ip_files = {p.name: p for p in ip_src_root.rglob("*") if p.is_file() and p.suffix in (".v", ".vh")}

    missing_in_ip = sorted(set(rtl_files.keys()) - set(ip_files.keys()))
    extra_in_ip = sorted(set(ip_files.keys()) - set(rtl_files.keys()))

    matched = 0
    mismatches: List[str] = []
    for name, rtl_path in sorted(rtl_files.items()):
        ip_path = ip_files.get(name)
        if ip_path is None:
            continue
        rtl_hash = hashlib.sha256(rtl_path.read_bytes()).hexdigest()
        ip_hash = hashlib.sha256(ip_path.read_bytes()).hexdigest()
        if rtl_hash == ip_hash:
            matched += 1
        else:
            mismatches.append(name)

    elapsed = time.monotonic() - t_start
    total_rtl = len(rtl_files)
    passed = (
        total_rtl == EXPECTED_RTL_FILE_COUNT
        and len(ip_files) == EXPECTED_RTL_FILE_COUNT
        and matched == total_rtl
        and len(missing_in_ip) == 0
        and len(extra_in_ip) == 0
        and len(mismatches) == 0
    )

    metrics = (
        f"Matched={matched}/{total_rtl}, Missing={len(missing_in_ip)}, "
        f"Extra={len(extra_in_ip)}, SHA256_Diff={len(mismatches)}"
    )
    err_str = f"DIFF={len(mismatches) + len(missing_in_ip) + len(extra_in_ip)}"
    details: List[str] = []
    if missing_in_ip:
        details.append(f"Missing in ip_repo: {', '.join(missing_in_ip)}")
    if extra_in_ip:
        details.append(f"Extra in ip_repo: {', '.join(extra_in_ip)}")
    if mismatches:
        details.append(f"SHA-256 mismatches: {', '.join(mismatches)}")

    return CheckResult(
        "Gate G6: IP SHA-256 Parity",
        "PASS" if passed else "FAIL",
        metrics,
        err_str,
        elapsed,
        details,
    )


def run_questa_make(
    sim_dir: Path,
    targets_and_vars: List[str],
    env: Dict[str, str],
    verbose: bool,
) -> Tuple[int, str, float]:
    cmd = ["make", "-C", str(sim_dir)] + targets_and_vars
    return run_exe_command(cmd, sim_dir, env, verbose=verbose)


def run_questa_suite(
    repo_root: Path,
    run_t1: bool,
    run_t2: bool,
    skip_compile: bool,
    verbose: bool,
) -> List[CheckResult]:
    sim_dir = repo_root / "uvm" / "sim"
    env = build_questa_env(repo_root)
    results: List[CheckResult] = []

    if shutil.which("make") is None or not has_questa():
        msg = "Required tools (make, vsim, vopt) not found on PATH"
        if run_t1:
            results.append(CheckResult("Tier 1: CABAC M-Coder", "FAIL", msg, "Tool Missing"))
        else:
            results.append(CheckResult("Tier 1: CABAC M-Coder", "SKIPPED", "Skipped by --tier 2", "N/A"))
        if run_t2:
            results.append(CheckResult("Tier 2A: SoC RAL Audit", "FAIL", msg, "Tool Missing"))
            results.append(CheckResult("Tier 2B: Full SoC AXI UVM", "FAIL", msg, "Tool Missing"))
            results.append(CheckResult("Tier 2C: HM 18.0 Decode", "FAIL", msg, "Tool Missing"))
        else:
            results.append(CheckResult("Tier 2A: SoC RAL Audit", "SKIPPED", "Skipped by --tier 1", "N/A"))
            results.append(CheckResult("Tier 2B: Full SoC AXI UVM", "SKIPPED", "Skipped by --tier 1", "N/A"))
            results.append(CheckResult("Tier 2C: HM 18.0 Decode", "SKIPPED", "Skipped by --tier 1", "N/A"))
        return results

    shared_compile_s = 0.0
    if not skip_compile and run_t1 and run_t2:
        print("\n[0/3] Compiling Tier 1 + Tier 2 via make -C uvm/sim compile_all...")
        rc, out, shared_compile_s = run_questa_make(sim_dir, ["compile_all"], env, verbose)
        if rc != 0:
            err_lines = out.splitlines()[-25:]
            results.append(
                CheckResult("Tier 1: CABAC M-Coder", "FAIL", f"compile_all failed (rc={rc})", "Compile/Elab Error", shared_compile_s, err_lines)
            )
            results.append(
                CheckResult("Tier 2A: SoC RAL Audit", "FAIL", f"compile_all failed (rc={rc})", "Compile/Elab Error", 0.0, err_lines)
            )
            results.append(
                CheckResult("Tier 2B: Full SoC AXI UVM", "FAIL", "Skipped due to compile failure", "N/A", 0.0)
            )
            results.append(
                CheckResult("Tier 2C: HM 18.0 Decode", "FAIL", "Skipped due to compile failure", "N/A", 0.0)
            )
            return results

    if run_t1:
        print("\n[1/3] Running Tier 1: CABAC M-Coder UVM (QuestaSim)...")
        t1_compile_s = 0.0
        t1_ok = True
        t1_err = ""
        t1_details: List[str] = []
        if not skip_compile and not run_t2:
            rc, out, t1_compile_s = run_questa_make(sim_dir, ["compile_cabac"], env, verbose)
            if rc != 0:
                t1_ok = False
                t1_err = f"compile_cabac failed (rc={rc})"
                t1_details = out.splitlines()[-25:]
        elif skip_compile and not (sim_dir / "work").is_dir():
            t1_ok = False
            t1_err = "Missing QuestaSim work library in uvm/sim/work"

        if not t1_ok:
            results.append(CheckResult("Tier 1: CABAC M-Coder", "FAIL", t1_err, "Compile/Elab Error", t1_compile_s, t1_details))
        else:
            log_file = sim_dir / "vsim_cabac.log"
            if log_file.exists():
                log_file.unlink()
            rc, out, run_s = run_questa_make(
                sim_dir, ["vopt_run_cabac", "cmd_args=-l vsim_cabac.log"], env, verbose
            )
            log_text = log_file.read_text(encoding="utf-8", errors="replace") if log_file.is_file() else out
            res1 = evaluate_tier1_log(log_text, rc, t1_compile_s + run_s, out)
            results.append(res1)
    else:
        results.append(CheckResult("Tier 1: CABAC M-Coder", "SKIPPED", "Skipped by --tier 2", "N/A", 0.0))

    if run_t2:
        print("\n[2/3] Running Tier 2: SoC AXI Top UVM + RAL + HM Decode (QuestaSim)...")
        t2_compile_s = shared_compile_s
        t2_ok = True
        t2_err = ""
        t2_details: List[str] = []

        if not skip_compile and not run_t1:
            rc, out, t2_compile_s = run_questa_make(sim_dir, ["compile_axi"], env, verbose)
            if rc != 0:
                t2_ok = False
                t2_err = f"compile_axi failed (rc={rc})"
                t2_details = out.splitlines()[-25:]
        elif skip_compile and not (sim_dir / "work").is_dir():
            t2_ok = False
            t2_err = "Missing QuestaSim work library in uvm/sim/work"

        if not t2_ok:
            results.append(
                CheckResult("Tier 2A: SoC RAL Audit", "FAIL", t2_err, "Compile/Elab Error", t2_compile_s, t2_details)
            )
            results.append(
                CheckResult("Tier 2B: Full SoC AXI UVM", "FAIL", t2_err, "Compile/Elab Error", 0.0)
            )
            results.append(
                CheckResult("Tier 2C: HM 18.0 Decode", "FAIL", "Skipped due to compile failure", "N/A", 0.0)
            )
        else:
            ral_log = sim_dir / "vsim_ral.log"
            if ral_log.exists():
                ral_log.unlink()
            rc_ral, out_ral, ral_s = run_questa_make(
                sim_dir,
                ["vopt_run", "test_name=hevc_ral_audit_test", "cmd_args=-l vsim_ral.log"],
                env,
                verbose,
            )
            ral_text = ral_log.read_text(encoding="utf-8", errors="replace") if ral_log.is_file() else out_ral
            ral_res = evaluate_tier2_ral_log(ral_text, rc_ral, t2_compile_s + ral_s, out_ral)
            results.append(ral_res)

            full_log = sim_dir / "vsim_full.log"
            if full_log.exists():
                full_log.unlink()
            rc_full, out_full, full_s = run_questa_make(
                sim_dir,
                ["vopt_run", "test_name=hevc_full_uvm_test", "cmd_args=-l vsim_full.log"],
                env,
                verbose,
            )
            full_text = full_log.read_text(encoding="utf-8", errors="replace") if full_log.is_file() else out_full
            full_res, bs_bytes = evaluate_tier2_full_log(full_text, rc_full, full_s, out_full)
            results.append(full_res)

            if full_res.status == "PASS":
                hm_res = run_tier2_hm_decode(repo_root, sim_dir, env, bs_bytes, verbose, require_hm=False)
                results.append(hm_res)
            else:
                results.append(
                    CheckResult(
                        "Tier 2C: HM 18.0 Decode",
                        "FAIL",
                        "Skipped because hevc_full_uvm_test failed",
                        "N/A",
                        0.0,
                    )
                )
    else:
        results.append(CheckResult("Tier 2A: SoC RAL Audit", "SKIPPED", "Skipped by --tier 1", "N/A", 0.0))
        results.append(CheckResult("Tier 2B: Full SoC AXI UVM", "SKIPPED", "Skipped by --tier 1", "N/A", 0.0))
        results.append(CheckResult("Tier 2C: HM 18.0 Decode", "SKIPPED", "Skipped by --tier 1", "N/A", 0.0))

    return results


def run_xsim_suite(
    repo_root: Path,
    run_t1: bool,
    run_t2: bool,
    skip_compile: bool,
    verbose: bool,
) -> List[CheckResult]:
    env = build_vivado_env()
    print(f"[Gate G8] XILINXD_LICENSE   : {env['XILINXD_LICENSE_FILE']}")
    results: List[CheckResult] = []

    if run_t1:
        print("\n[1/3] Running Tier 1: CABAC M-Coder UVM...")
        results.append(run_xsim_tier1_cabac(repo_root, env, skip_compile, verbose))
    else:
        results.append(CheckResult("Tier 1: CABAC M-Coder", "SKIPPED", "Skipped by --tier 2", "N/A", 0.0))

    if run_t2:
        print("\n[2/3] Running Tier 2: SoC AXI Top UVM + RAL + HM 18.0 Decode...")
        t2_build_dir = repo_root / "uvm" / "uvm_axi_top" / "build_xsim"
        t2_build_dir.mkdir(parents=True, exist_ok=True)
        compile_ok = True
        compile_err_msg = ""
        compile_details: List[str] = []
        compile_elapsed = 0.0

        if not skip_compile:
            compile_ok, compile_err_msg, compile_elapsed, compile_details = compile_xsim_tier2_axi_top(
                repo_root, t2_build_dir, env, verbose
            )
        elif not (t2_build_dir / "xsim.dir" / "tb_uvm_axi_top_sim").is_dir():
            compile_ok = False
            compile_err_msg = "Missing snapshot tb_uvm_axi_top_sim"

        if not compile_ok:
            results.append(
                CheckResult("Tier 2A: SoC RAL Audit", "FAIL", compile_err_msg, "Compile/Elab Error", compile_elapsed, compile_details)
            )
            results.append(
                CheckResult("Tier 2B: Full SoC AXI UVM", "FAIL", compile_err_msg, "Compile/Elab Error", 0.0)
            )
            results.append(
                CheckResult("Tier 2C: HM 18.0 Decode", "FAIL", "Skipped due to compile failure", "N/A", 0.0)
            )
        else:
            ral_res = run_xsim_tier2_ral_audit(t2_build_dir, env, verbose)
            ral_res.duration_s += compile_elapsed
            results.append(ral_res)

            full_res, bs_bytes = run_xsim_tier2_full_uvm(t2_build_dir, env, verbose)
            results.append(full_res)

            if full_res.status == "PASS":
                hm_res = run_tier2_hm_decode(repo_root, t2_build_dir, env, bs_bytes, verbose, require_hm=True)
                results.append(hm_res)
            else:
                results.append(
                    CheckResult(
                        "Tier 2C: HM 18.0 Decode",
                        "FAIL",
                        "Skipped because hevc_full_uvm_test failed",
                        "N/A",
                        0.0,
                    )
                )
    else:
        results.append(CheckResult("Tier 2A: SoC RAL Audit", "SKIPPED", "Skipped by --tier 1", "N/A", 0.0))
        results.append(CheckResult("Tier 2B: Full SoC AXI UVM", "SKIPPED", "Skipped by --tier 1", "N/A", 0.0))
        results.append(CheckResult("Tier 2C: HM 18.0 Decode", "SKIPPED", "Skipped by --tier 1", "N/A", 0.0))

    return results


def print_summary_table(results: List[CheckResult], total_elapsed: float, overall_pass: bool) -> None:
    col_name = max(len("Check"), *(len(r.name) for r in results))
    col_stat = max(len("Status"), *(len(r.status) for r in results))
    col_err = max(len("Errors / Exit"), *(len(r.errors_fatals) for r in results))
    col_time = max(len("Time(s)"), 7)
    col_met = max(len("Observed Metrics"), *(len(r.metrics) for r in results))
    width = col_name + col_stat + col_err + col_time + col_met + 16

    print("\n" + "=" * width)
    print(" GATE G8 DUAL-TIER UVM VERIFICATION SUMMARY")
    print("=" * width)
    header = (
        f"| {'Check':<{col_name}} | {'Status':<{col_stat}} | "
        f"{'Errors / Exit':<{col_err}} | {'Time(s)':>{col_time}} | {'Observed Metrics':<{col_met}} |"
    )
    sep = (
        f"|{'-' * (col_name + 2)}|{'-' * (col_stat + 2)}|"
        f"{'-' * (col_err + 2)}|{'-' * (col_time + 2)}|{'-' * (col_met + 2)}|"
    )
    print(header)
    print(sep)
    for res in results:
        print(
            f"| {res.name:<{col_name}} | {res.status:<{col_stat}} | "
            f"{res.errors_fatals:<{col_err}} | {res.duration_s:>{col_time}.2f} | "
            f"{res.metrics:<{col_met}} |"
        )
    print("=" * width)
    verdict = "PASS (ALL GATES CONVERGED)" if overall_pass else "FAIL (SEE DIAGNOSTICS)"
    print(f" Overall Gate G8 Verdict : {verdict} | Total Wall Time: {total_elapsed:.2f}s")
    print("=" * width)

    for res in results:
        if res.status == "FAIL" and res.details:
            print(f"\n[DIAGNOSTICS] {res.name}:")
            for line in res.details:
                print(f"  {line}")


def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Unified Dual-Tier UVM Verification Runner (Gate G8) for HEVC Encoder"
    )
    group = parser.add_mutually_exclusive_group()
    group.add_argument(
        "--tier",
        choices=["1", "2"],
        help="Run only Tier 1 (CABAC M-Coder) or Tier 2 (SoC AXI Top + RAL + HM Decode).",
    )
    group.add_argument(
        "--all",
        action="store_true",
        help="Run both Tier 1 and Tier 2 plus Gate G6 SHA-256 parity check (default).",
    )
    parser.add_argument(
        "--simulator",
        choices=["auto", "xsim", "questa"],
        default="auto",
        help=(
            "Simulator backend: 'auto' chooses Vivado xsim when available or QuestaSim "
            "when vsim+vopt are on PATH; 'xsim' uses Vivado xsim.bat; 'questa' drives "
            "make -C uvm/sim (QuestaSim 2021.2_1)."
        ),
    )
    parser.add_argument(
        "--skip-compile",
        action="store_true",
        help="Skip compilation/elaboration and run on existing snapshots (xsim) or work lib (questa).",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Stream underlying tool commands and stdout while executing.",
    )
    return parser.parse_args(argv)


def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(argv)
    run_t1 = args.all or (args.tier is None) or (args.tier == "1")
    run_t2 = args.all or (args.tier is None) or (args.tier == "2")

    repo_root = get_repo_root()
    sim_choice = resolve_simulator(args.simulator)
    t0 = time.monotonic()

    print(f"[Gate G8] Repo Root         : {repo_root}")
    print(f"[Gate G8] Simulator         : {sim_choice} (requested={args.simulator})")
    print(f"[Gate G8] Mode              : tier1={run_t1}, tier2={run_t2}, skip_compile={args.skip_compile}")

    if sim_choice == "none":
        print(
            "[Gate G8] ERROR: Neither Vivado xsim (D:\\Xilinx\\2026.1\\Vivado\\bin\\xsim.bat) "
            "nor QuestaSim (vsim + vopt on PATH) was detected.",
            file=sys.stderr,
        )
        return 1

    if sim_choice == "xsim":
        results = run_xsim_suite(repo_root, run_t1, run_t2, args.skip_compile, args.verbose)
    else:
        results = run_questa_suite(repo_root, run_t1, run_t2, args.skip_compile, args.verbose)

    print("\n[3/3] Running Gate G6: RTL <-> ip_repo SHA-256 Parity Check...")
    results.append(run_gate_g6_sha256_parity(repo_root))

    total_elapsed = time.monotonic() - t0
    overall_pass = all(r.status in ("PASS", "SKIPPED") for r in results) and any(
        r.status == "PASS" for r in results
    )
    print_summary_table(results, total_elapsed, overall_pass)
    return 0 if overall_pass else 1


if __name__ == "__main__":
    sys.exit(main())
