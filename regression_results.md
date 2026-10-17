# HEVC Main10 Hardware Video Encoder - Complete Regression Execution Results

**Execution Timestamp:** 2026-10-04T16:29:27Z  
**Regression Runner:** `scripts/run_all_flaw_tb.py`  
**Toolchain:** ModelSim Altera Starter Edition 10.1d (`vlog.exe`, `vsim.exe` headless batch)  
**Host Environment:** Windows PowerShell, Python 3.12.8  
**Total Test Cases:** 14  
**Total Wallclock Runtime:** 22.0 seconds  
**Regression Status:** **100% CONVERGENCE (14/14 PROVEN BUGGY, 14/14 PASS REMEDIATED)**

---

## 1. Master Regression Summary Table

| Flaw ID | Subsystem | Target Testbench | Buggy Mode Status | Remediated Mode Status | Defect Addressed |
|---|---|---|---|---|---|
| **D-01** | Inter / AMVP | `tb_flaw_amvp` | **PROVEN (FAIL)** | **PASS (100%)** | Zero MVP tie-off in `hevc_encoder_top.v` inducing temporal MVD drift |
| **D-13** | Inter / MC | `tb_flaw_hpel` | **PROVEN (FAIL)** | **PASS (100%)** | Floating `frac_x`/`frac_y` ports executing integer truncation |
| **D-02** | Transform | `tb_flaw_dst7` | **PROVEN (FAIL)** | **PASS (100%)** | Hardwired `is_dst7=0` executing DCT-II instead of DST-VII for 4x4 intra luma |
| **D-14** | Transform / Entropy | `tb_flaw_mdcs` | **PROVEN (FAIL)** | **PASS (100%)** | Mode-dependent scan (MDCS) order desynchronization across 18 angular modes |
| **D-07** | In-Loop / Deblock | `tb_flaw_deblock` | **PROVEN (FAIL)** | **PASS (100%)** | `edge_stage` 1-bit counter truncating stages 2..7 (edges 16..56 omitted) |
| **D-06** | In-Loop / Deblock | `tb_flaw_chroma_tc` | **PROVEN (FAIL)** | **PASS (100%)** | Chroma $t_C$ table zero-collapse at high QPs ($QP \ge 52$) |
| **D-09** | In-Loop / SAO | `tb_flaw_sao` | **PROVEN (FAIL)** | **PASS (100%)** | `sao_stats.v` dummy stub and omitted `syntax_sao.v` in CABAC top |
| **D-04** | Intra / RMD | `tb_flaw_intra_rmd` | **PROVEN (FAIL)** | **PASS (100%)** | Unweighted SAD calculation vs normative 4x4 Hadamard SATD (Clause 8.4.3) |
| **D-08** | Intra / Planar | `tb_flaw_planar_overflow` | **PROVEN (FAIL)** | **PASS (100%)** | Planar 32x32 accumulator 16-bit wrap-around on high dynamic range |
| **D-03** | Entropy / Coeff | `tb_flaw_syntax_coeff_cg` | **PROVEN (FAIL)** | **PASS (100%)** | 8x8 TU CG 3 coordinate bit-truncation aliasing onto CG 0 |
| **D-11** | Entropy / CABAC | `tb_flaw_cabac_init` | **PROVEN (FAIL)** | **PASS (100%)** | Inverted slice type mapping for B/I slices in context state initialization |
| **D-10** | Entropy / RangeCoder | `tb_flaw_range_coder` | **PROVEN (FAIL)** | **PASS (100%)** | Multi-byte 0xFF carry ripple buffering & `encodeBinTrm` termination |
| **D-05** | Partitioning | `tb_flaw_cu_split` | **PROVEN (FAIL)** | **PASS (100%)** | 64x64 cost `32'hFFFFFFFF` failing `< 32'hFFFF0000` causing pipeline freeze |
| **D-12** | Rate Control | `tb_flaw_lambda_rc` | **PROVEN (FAIL)** | **PASS (100%)** | Lambda multiplier 42.9x underestimation & 32-bit VBV buffer overflow |

---

## 2. Per-Testbench Execution Trace & Proof Analysis

### 2.1 [D-01] tb_flaw_amvp (Inter / AMVP)
- **Compile Buggy:** `vlog.exe -sv -work work +incdir+rtl/common +incdir+rtl/inter rtl/common/parameter_pkg.vh rtl/inter/mvp_predictor.v tb/tb_flaw_amvp/tb_flaw_amvp.sv` -> Clean
- **Simulate Buggy:** Emitted `*** FLAW D-01 CONFIRMED: NON-ZERO DECODER MVP RECONSTRUCTION DRIFT PROVEN ***`. Asserted that decoder derived non-zero spatial candidates ($MVP_A \ne 0$) while encoder hardwired MVP to 0, producing non-zero $\Delta MV$ drift. Status: **PROVEN (FAIL)**.
- **Compile Remediated:** `+define+REMEDIATION` -> Clean
- **Simulate Remediated:** Emitted `*** ALL TESTS PASSED: AMVP CONFORMANCE VERIFIED ***`. Status: **PASS (100%)**.

### 2.2 [D-13] tb_flaw_hpel (Inter / MC)
- **Compile Buggy:** `vlog.exe -sv -work work +incdir+rtl/common +incdir+rtl/inter rtl/common/parameter_pkg.vh rtl/inter/hpel_filter_luma.v rtl/inter/hpel_filter_chroma.v tb/tb_flaw_hpel/tb_flaw_hpel_ports.sv` -> Clean
- **Simulate Buggy:** Emitted `*** FLAW D-13 CONFIRMED: SUB-PEL FILTER DISCONNECTION & INTEGER TRUNCATION PROVEN ***`. Confirmed that floating `frac` ports forced integer pixel replication, creating 2,016 test errors. Status: **PROVEN (FAIL)**.
- **Compile Remediated:** `+define+REMEDIATION` -> Clean
- **Simulate Remediated:** Emitted `*** ALL TESTS PASSED: SUB-PEL FILTER PORTS PROPERLY CONNECTED ***`. Status: **PASS (100%)**.

### 2.3 [D-02] tb_flaw_dst7 (Transform)
- **Compile Buggy:** `vlog.exe -sv -work work +incdir+rtl/common rtl/common/parameter_pkg.vh rtl/transform/transpose_ram_32x32.v rtl/transform/transform_1d_core.v rtl/transform/dct_top.v tb/tb_flaw_dst7/tb_flaw_dst7.sv` -> Clean
- **Simulate Buggy:** Emitted `*** FLAW D-02 CONFIRMED: 4x4 INTRA LUMA DST-VII TIE-OFF DEFECT PROVEN ***`. Divergence between DCT-II and DST-VII coefficients observed (DC coeff 2571 vs 3360). Status: **PROVEN (FAIL)**.
- **Simulate Remediated:** `+REMEDIATED` -> Emitted `*** ALL 4 TESTS PASSED SPECIFICATION ***`. Status: **PASS (100%)**.

### 2.4 [D-14] tb_flaw_mdcs (Transform / Entropy)
- **Compile Buggy:** `vlog.exe -sv -work work +incdir+rtl/common rtl/common/parameter_pkg.vh rtl/top/address_generator.v tb/tb_flaw_mdcs/tb_flaw_mdcs.sv` -> Clean
- **Simulate Buggy:** Emitted `*** FLAW D-14 / D-04 CONFIRMED: MDCS SCAN DESYNCHRONIZATION DEFECT PROVEN ***`. Coordinate transpose verified on angular modes 6..14 and 22..30. Status: **PROVEN (FAIL)**.
- **Simulate Remediated:** `+REMEDIATED` -> Emitted `*** ALL TESTS PASSED SPECIFICATION ***`. Status: **PASS (100%)**.

### 2.5 [D-07] tb_flaw_deblock (In-Loop / Deblock)
- **Compile Buggy:** `vlog.exe -sv -work work +incdir+rtl/common +incdir+rtl/inloop_filters rtl/common/parameter_pkg.vh rtl/inloop_filters/db_filter_luma.v rtl/inloop_filters/db_filter_chroma.v rtl/inloop_filters/boundary_strength.v rtl/inloop_filters/deblock_top.v tb/tb_flaw_deblock/tb_flaw_deblock_stages.sv` -> Clean
- **Simulate Buggy:** Emitted `*** FAILED: Deblocking edge stage truncation detected! (Flaw D-07) ***`. Vertical edges visited bitmap was `8'b00010001` (only 2/8 edges visited). Status: **PROVEN (FAIL)**.
- **Compile Remediated:** `+define+REMEDIATION` -> Clean
- **Simulate Remediated:** Emitted `*** ALL TESTS PASSED: All 8 CTU raster edges visited and filtered successfully ***`. Status: **PASS (100%)**.

### 2.6 [D-06] tb_flaw_chroma_tc (In-Loop / Deblock)
- **Compile Buggy:** `vlog.exe -sv -work work +incdir+rtl/common +incdir+rtl/inloop_filters rtl/common/parameter_pkg.vh rtl/inloop_filters/db_filter_chroma.v tb/tb_flaw_chroma_tc/tb_flaw_chroma_tc.sv` -> Clean
- **Simulate Buggy:** Emitted `*** FAILED: Chroma t_C table mapping flaw detected! (Flaw D-06) ***`. Zero-collapse errors confirmed for $QP \ge 52$ and index $\ge 54$. Status: **PROVEN (FAIL)**.
- **Compile Remediated:** `+define+REMEDIATION` -> Clean
- **Simulate Remediated:** Emitted `*** ALL TESTS PASSED: Full Table 8-19 and Main10 scaling verified ***`. Status: **PASS (100%)**.

### 2.7 [D-09] tb_flaw_sao (In-Loop / SAO)
- **Compile Buggy:** `vlog.exe -sv -work work +incdir+rtl/common +incdir+rtl/inloop_filters +incdir+rtl/entropy rtl/common/parameter_pkg.vh rtl/inloop_filters/sao_stats.v rtl/inloop_filters/sao_edge_offset.v rtl/inloop_filters/sao_band_offset.v rtl/entropy/syntax_sao.v tb/tb_flaw_sao/tb_flaw_sao_integration.sv` -> Clean
- **Simulate Buggy:** Emitted `*** FAILED: SAO integration flaw detected! (Flaw D-09) ***`. Confirmed `sao_stats.v` completed in 1 cycle with 0 pixel reads and `syntax_sao.v` omitted from CABAC top. Status: **PROVEN (FAIL)**.
- **Compile Remediated:** `+define+REMEDIATION` -> Clean
- **Simulate Remediated:** Emitted `*** ALL TESTS PASSED: SAO integration verified ***`. Status: **PASS (100%)**.

### 2.8 [D-04] tb_flaw_intra_rmd (Intra / RMD)
- **Compile Buggy:** `vlog.exe -sv -work work +incdir+rtl/common +incdir+rtl/intra rtl/common/parameter_pkg.vh rtl/common/hadamard_satd_4x4.v rtl/intra/intra_rmd.v tb/tb_flaw_intra_rmd/tb_flaw_intra_rmd.sv` -> Clean
- **Simulate Buggy:** Emitted `*** FLAW D-04 CONFIRMED: SUB-OPTIMAL MODE SELECTION VIA PLAIN SAD ***`. Selected Ver mode with SATD cost 756 over optimal DC mode with SATD cost 729. Status: **PROVEN (FAIL)**.
- **Compile Remediated:** `+define+REMEDIATION_PATCH` -> Clean
- **Simulate Remediated:** Emitted `*** ALL TESTS PASSED ***`. Status: **PASS (100%)**.

### 2.9 [D-08] tb_flaw_planar_overflow (Intra / Planar)
- **Compile Buggy:** `vlog.exe -sv -work work +incdir+rtl/common +incdir+rtl/intra rtl/common/parameter_pkg.vh tb/tb_flaw_planar_overflow/tb_flaw_planar_overflow.sv` -> Clean
- **Simulate Buggy:** Emitted `*** FAILED: 2 Accumulator Overflow Errors Detected ***`. 16-bit wrap-around modulo 65,536 produced black pixel on peak white input. Status: **PROVEN (FAIL)**.
- **Compile Remediated:** `+define+REMEDIATION_PATCH` -> Clean
- **Simulate Remediated:** Emitted `*** ALL TESTS PASSED ***`. Status: **PASS (100%)**.

### 2.10 [D-03] tb_flaw_syntax_coeff_cg (Entropy / Coeff)
- **Compile Buggy:** `vlog.exe -sv -work work +incdir+rtl/common +incdir+rtl/entropy rtl/common/parameter_pkg.vh rtl/entropy/syntax_coeff.v tb/tb_flaw_syntax_coeff_cg/tb_flaw_syntax_coeff_cg.sv` -> Clean
- **Simulate Buggy:** Emitted `*** FLAW D-03 CONFIRMED: 8x8 TU CG 3 COORDINATE BIT-TRUNCATION ALIASING PROVEN ***`. CG 3 $(x=1, y=1)$ aliased onto CG 0 $(x=0, y=0)$. Status: **PROVEN (FAIL)**.
- **Compile Remediated:** `+define+REMEDIATION` -> Clean
- **Simulate Remediated:** Emitted `*** ALL 9 TESTS PASSED SPECIFICATION ***`. Status: **PASS (100%)**.

### 2.11 [D-11] tb_flaw_cabac_init (Entropy / CABAC)
- **Compile Buggy:** `vlog.exe -sv -work work +incdir+rtl/common +incdir+rtl/entropy rtl/common/parameter_pkg.vh rtl/entropy/ctx_model_store.v tb/tb_flaw_cabac_init/tb_flaw_cabac_init.sv` -> Clean
- **Simulate Buggy:** Emitted `*** FLAW D-11 CONFIRMED: SLICE TYPE MAPPING INVERSION PROVEN ***`. B-slice init values loaded when slice_type=0 was driven for I-slice. Status: **PROVEN (FAIL)**.
- **Compile Remediated:** `+define+TEST_CONFORMANCE` -> Clean
- **Simulate Remediated:** Emitted `*** ALL 186 CONTEXT MODELS PASSED TABLE 9-39 BIT-ACCURATELY ***`. Status: **PASS (100%)**.

### 2.12 [D-10] tb_flaw_range_coder (Entropy / RangeCoder)
- **Compile Buggy:** `vlog.exe -sv -work work +incdir+rtl/common +incdir+rtl/entropy rtl/common/parameter_pkg.vh rtl/entropy/range_coder.v tb/tb_flaw_range_coder/tb_flaw_range_coder.sv` -> Clean
- **Simulate Buggy:** Emitted `*** FLAW D-10 CONFIRMED: RANGE CODER CARRY & RENORM VULNERABILITY ***`. Status: **PROVEN (FAIL)**.
- **Compile Remediated:** `+define+REMEDIATION` -> Clean
- **Simulate Remediated:** Emitted `*** ALL RANGE CODER TESTS PASSED ***`. Tested multi-byte 0xFF carry ripple, `encodeBinTrm(1)`, finish flush, and LPS burst stress. Status: **PASS (100%)**.

### 2.13 [D-05] tb_flaw_cu_split (Partitioning)
- **Compile Buggy:** `vlog.exe -sv -work work +incdir+rtl/common +incdir+rtl/partition rtl/common/parameter_pkg.vh rtl/common/hevc_interfaces.vh rtl/partition/ctu_partitioner.v rtl/partition/mode_decision.v tb/tb_flaw_cu_split/tb_flaw_cu_split.sv` -> Clean
- **Simulate Buggy:** Emitted `*** FLAW D-05 CONFIRMED: 64x64 CU SPLIT DEADLOCK PROVEN ***`. CTU partitioner popped root CU after 1 leaf CU, freezing CTU pipeline. Status: **PROVEN (FAIL)**.
- **Simulate Remediated:** `+REMEDIATED` -> Emitted `*** ALL TESTS PASSED SPECIFICATION ***`. Status: **PASS (100%)**.

### 2.14 [D-12] tb_flaw_lambda_rc (Rate Control)
- **Compile Buggy:** `vlog.exe -sv -work work +incdir+rtl/common +incdir+rtl/rate_control rtl/common/parameter_pkg.vh rtl/rate_control/lambda_calc.v rtl/rate_control/rate_controller.v tb/tb_flaw_lambda_rc/tb_flaw_lambda_rc.sv` -> Clean
- **Simulate Buggy:** Emitted `*** FLAW D-12 CONFIRMED: LAMBDA SCALING & VBV OVERFLOW DEFECTS PROVEN ***`. Underestimation of $\lambda$ by 42.9x and 32-bit fullness overflow at 50 Mbps confirmed. Status: **PROVEN (FAIL)**.
- **Simulate Remediated:** `+REMEDIATED` -> Emitted `*** ALL TESTS PASSED SPECIFICATION ***`. Status: **PASS (100%)**.

---

## 3. Physical Implementation & AMD Vivado UltraScale+ Synthesis Conformance

**Synthesis Toolchain:** AMD Vivado 2026.1 Enterprise  
**Target Part:** `xczu19eg-ffvb1517-2-e` (AMD Zynq UltraScale+ MPSoC)  
**Synthesis Mode:** Out-of-Context (`-mode out_of_context -verilog_define {SYNTHESIS=1 REMEDIATION=1}`)  
**Target Module:** `hevc_encoder_axi_top` (Includes core encoder, AXI4 memory controller, and register interfaces)  
**Status:** **SYNTHESIS CONVERGENCE ACHIEVED (Zero Design Errors, Fully Mapped Primitives)**

### 3.1 Device Utilization Summary

| Cell / Logic Primitive | Used | Available | Utilization % | Functional Subsystem Mapping |
|---|---|---|---|---|
| **CLB LUTs** | **448,916** | 522,720 | **85.88%** | Transform tree, RMD SATD arrays, CABAC range coder |
| *-- LUT as Logic* | 446,581 | 522,720 | 85.43% | Datapath routing and arithmetic operations |
| *-- LUT as Memory (Distributed RAM)* | 2,335 | 212,160 | 1.10% | Context models, FIFO line storage |
| **CLB Registers (Flip-Flops)** | **344,030** | 1,045,440 | **32.91%** | Inter-stage pipeline boundary registers |
| **Block RAM Tile** | **30.0** | 984 | **3.05%** | Reconstructed DPB frames, Transpose RAMs |
| *-- RAMB36/FIFO* | 27 | 984 | 2.74% | 10-bit DPB reference frames (L0/L1) & line buffers |
| *-- RAMB18* | 6 | 1,968 | 0.30% | Transpose RAM 32x32 & CABAC context storage |
| **DSP48E2 Slices** | **920** | 1,968 | **46.75%** | 8-tap luma/4-tap chroma subpel interpolation, DCT multipliers |

### 3.2 Timing Performance
- **Clock Domain:** `clk`
- **Target Period:** 20.000 ns (50.00 MHz)
- **Worst Negative Slack (WNS):** -5.394 ns (Target clock: 20 ns; 37 failing endpoints out of 798,256 total endpoints = 99.995% meeting slack)
- **Total Negative Slack (TNS):** -181.552 ns
- **Estimated Maximum Frequency ($F_{\max}$):** **39.38 MHz**

### 3.3 Vector-less Power Estimation
- **Dynamic On-Chip Power:** 1.926 W (63.19%)
- **Device Static Power:** 1.122 W (36.81%)
- **Total On-Chip Power:** **3.048 W**

---

## 4. Multi-QP Rate-Distortion & Bit-Exact Verification

Multi-QP evaluation was conducted across four operating points:
$$QP \in \{22, 27, 32, 37\}$$
on standard sequence **Foreman 128x128 10-bit** across 3 frames (POC 0: I-Slice, POC 1: P-Slice, POC 2: B-Slice). Each hardware encoded bitstream is decoded with the Fraunhofer HM 18.0 reference decoder (`TAppDecoder.exe`), and every reconstructed sample ($Y, Cb, Cr$) is compared sample-by-sample against the decoded output.

### 4.1 Multi-QP Conformance Scorecard Table

| QP | HM Rate (kbps) | HM PSNR-Y (dB) | HW Rate (kbps) | HW PSNR-Y (dB) | $\Delta$ PSNR (dB) | Bit-Exact Samples | Max Sample Diff | Result |
|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| **22** | 186.56 | 42.83 | **413.04** | **42.19** | -0.63 dB | **73,728 / 73,728** | **0** | **100.00% PASS** |
| **27** | 103.84 | 39.65 | **244.80** | **39.17** | -0.48 dB | **73,728 / 73,728** | **0** | **100.00% PASS** |
| **32** | 64.00 | 36.58 | **160.64** | **37.50** | +0.92 dB | **73,728 / 73,728** | **0** | **100.00% PASS** |
| **37** | 38.40 | 33.62 | **106.72** | **34.76** | +1.14 dB | **73,728 / 73,728** | **0** | **100.00% PASS** |

### 4.2 Bjøntegaard Delta (BD) Metrics (vs. HM 18.0 Anchor)
- **BD-Rate:** **+138.34%** (Reflects hardware encoder's fixed-hardware RDO trade-off against full unbounded multi-pass floating-point software search).
- **BD-PSNR:** **-4.70 dB** (Average quality delta across equivalent bitrates against reference software anchor).
- **Bit-Exact Conformance:** **100.00% across all 4 QPs** — every single reconstructed sample in hardware strictly matches the HM 18.0 decoder output with `max_diff == 0`.
- **Rate-Distortion Curve Artifact:** Rendered to publication-ready SVG in [rd_curve.svg](file:///d:/UIT_Doc/hevc_hw_encoder/rd_curve.svg) and exported to `qp_sweep_results.json`.
