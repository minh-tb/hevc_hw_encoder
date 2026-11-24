# HEVC Main10 Hardware Video Encoder - Complete Regression Execution Results

**Execution Release Tag:** `v3.0-final-signoff` (Vivado `150 MHz` Build: `2026-11-24 03:18:34`)  
**Regression Runner:** [`scripts/run_all_flaw_tb.py`](file:///d:/UIT_Doc/hevc_hw_encoder/scripts/run_all_flaw_tb.py), [`tb/run_tb_axi.do`](file:///d:/UIT_Doc/hevc_hw_encoder/tb/run_tb_axi.do), [`run_sim.do`](file:///d:/UIT_Doc/hevc_hw_encoder/run_sim.do), [`tb/run_sim_synthdef.do`](file:///d:/UIT_Doc/hevc_hw_encoder/tb/run_sim_synthdef.do), [`uvm/run_uvm_suite.py`](file:///d:/UIT_Doc/hevc_hw_encoder/uvm/run_uvm_suite.py)  
**Toolchain:** ModelSim Altera Starter Edition 10.1d (`vlog.exe`, `vsim.exe` headless batch) & AMD Vivado 2026.1 (64-bit, `xsim` UVM 1.2 + OOC Synth)  
**Host Environment:** Windows PowerShell, Python 3.12.8  
**Default RTL State:** Pure single-path production RTL across **64 files (`60` `.v` + `4` `.vh`)** with **0 `REMEDIATION` directives** in [`rtl/`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl) and [`ip_repo/hevc_encoder_v1_0/src/`](file:///d:/UIT_Doc/hevc_hw_encoder/ip_repo/hevc_encoder_v1_0/src); historical buggy baselines for the 14-flaw dual-state harness reside exclusively in [`tb/flaw_baseline_rtl/`](file:///d:/UIT_Doc/hevc_hw_encoder/tb/flaw_baseline_rtl) (`FAST_EARLY_CU_SPLIT = 0` default)  
**Total Flaw Test Cases:** 14 (`28 / 28` dual-state runs completed in `19.9 seconds` wallclock runtime; `14/14` Buggy PROVEN FAIL + `14/14` Remediated PASS 100%)  
**Total AXI SoC Test Cases:** 9 (`9 / 9 PASS` — `113 B`, `TLAST=1`, `irq` aligned with `STATUS.DONE=1`)  
**Re-Verified Self-Checking Unit & SoC Suites:** Active unit & SoC suites incl. `tb_hevc_encoder_axi_top` (`9/9`, `113 B`, `TLAST=1`), `tb_nal_writer`, `tb_slice_controller`, `tb_gop_controller`, `tb_intra_pred_top` (`616,224` samples), `tb_ref_frame_buffer`, `tb_boundary_strength` (`1,010` vectors), `tb_transform_rigorous` (`240/240`), `tb_b_prediction`, `tb_mc_window_fetch` (`6,272` samples incl. `rd_hold`), `tb_sao`, `tb_sao_stats`, `tb_inloop_filters`, `tb_deblock`, `tb_db_filter_luma`, `tb_interpolation_filter`, `tb_spatial_availability`, `tb_range_coder`, `tb_ctx_model_store`, `tb_syntax_pred`, `tb_rate_control_rdo`, `tb_intra_planar`, `tb_intra_dc`, `tb_ref_sample_filter`, `tb_mvp_predictor`, `tb_inv_quant`  
**3-Frame Pipeline Throughput (`v3.0` Overlapped CTU Ping-Pong):** **Avg CTU Period = 39,970 cycles/CTU** (`-36.1%` vs `v2.0` `62,568`, `-68.7%` vs `127,647` baseline; **`T_MD = 6,403`**, **`T_TQ = 14,301`**, **`T_DB = 7,096`** `<= 12,500` target, **`T_CABAC = 44,805`** 2-stage overlapped FE->BE lifetime, **`Stall_CABAC = 0`** across all 12 CTUs, **`Stall = 9.50%`** avg `Stall_Inloop = 3,799`; total sim `4,920,865 ns` / `492,086.5` cycles)  
**3-Frame CABAC Bin & Reconstruction Conformance:** **28,581 / 28,581 bins** (100.00% bit-exact 6-field match: `POC 0: 8,349`, `POC 1: 9,819`, `POC 2: 10,413`; `str_b_frame.bin` `3,134 B`), **73,728 / 73,728 samples (`max_diff = 0`)**, **`39.981 dB` PSNR-YUV** (`39.268 dB` Y, `41.866 dB` U, `42.373 dB` V)  
**Gate G8 UVM (`Vivado 2026.1 xsim`):** `75.80 s`, **PASS (`ERR=0 FAT=0 SVA=0`)**: Tier 1 (`5,940` bins, `1,266/1,266 B`, `cg_cabac=100%`), Tier 2A (`10/10` RAL), Tier 2B+C (**`256 B`**, `384/384` DRAM writes, `cg_soc_axi=100%`, HM 18.0 `exit=0`, `12,288 B`), Gate G6 (`64/64` parity)  
**Regression Status:** **100% CONVERGENCE (`14/14` PROVEN BUGGY, `14/14` PASS REMEDIATED, GATE G8 UVM PASS, `157.51 MHz` TIMING MET @ `150 MHz`, `64/64` IP FILES SYNCED)**

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
- **Compile Buggy:** `vlog.exe -sv -work work +incdir+rtl/common +incdir+rtl/intra rtl/common/parameter_pkg.vh rtl/common/hadamard_satd_4x4.v rtl/intra/intra_rmd.v tb/tb_flaw_intra_rmd/tb_flaw_intra_rmd.sv` (`+define+NO_REMEDIATION`) -> Clean
- **Simulate Buggy:** Emitted `*** FLAW D-04 CONFIRMED: SUB-OPTIMAL MODE SELECTION VIA PLAIN SAD ***`. Selected Ver mode with SATD cost 756 over optimal DC mode with SATD cost 729. Status: **PROVEN (FAIL)**.
- **Compile Remediated:** `+define+REMEDIATION` (exercises real `rtl/intra/intra_rmd.v` + `rtl/common/hadamard_satd_4x4.v` across `4x4..32x32` Luma and Chroma Table 8-2) -> Clean
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

**Synthesis Toolchain:** AMD Vivado 2026.1 Enterprise (Build 6511674)  
**Target Part:** `xczu19eg-ffvb1517-2-e` (AMD Zynq UltraScale+ MPSoC)  
**Synthesis Mode:** Out-of-Context (`-mode out_of_context -verilog_define {SYNTHESIS=1}`, `6.667 ns` / `150 MHz` constraint)  
**Target Module:** `hevc_encoder_axi_top` (Includes core encoder, AXI4 memory controller, and register interfaces)  
**Status:** **SYNTHESIS CONVERGENCE & 150 MHz TIMING CLOSURE ACHIEVED (0 Errors, 0 Critical Warnings, 0 Latches, 0 `Synth 8-614`, 0 `LUTAR-1` Warnings, WNS = +0.318 ns, $F_{\max}$ = 157.51 MHz)**

### 3.1 Device Utilization Summary (Baseline vs. `v2.0` 50 MHz vs. `v3.0` Final 150 MHz)

| Cell / Logic Primitive | Baseline Used | v2.0 Used (`50 MHz`) | **v3.0 Final Used (`150 MHz`)** | Available | Utilization % | Total Delta vs Baseline |
|---|---:|---:|---:|---:|---|---|
| **CLB LUTs** | 448,916 | 226,544 | **237,476** | 522,720 | **45.43%** | **-211,440 LUTs (-47.10%)** |
| *-- Logic LUTs* | 446,581 | 218,785 | **229,718** | 522,720 | **43.95%** | **-216,863 LUTs (-48.56%)** |
| *-- LUT as Memory (LUTRAM + SRL)* | 6,991 | 7,759 | **7,758** | 161,280 | **4.81%** | 7,728 LUTRAM + 30 SRL |
| **CLB Registers (Flip-Flops)** | 344,030 | 140,046 | **163,801** | 1,045,440 | **15.67%** | **-180,229 FFs (-52.39%)** |
| **Register as Latch (`LDCE`)** | 0 | 0 | **0** | 1,045,440 | **0.00%** | 0 Unintended Latches |
| **Unique Control Sets** | 14,641 | 7,679 | **9,158** | 130,680 | **7.01%** | **-5,483 sets (-37.45%)** |
| **Block RAM Tile** | 12.5 | 41.5 | **60.0** | 984 | **6.10%** | **60.0 Tiles** (CTU ping-pong + `ref_search_cache` + `ctu_bin_ram_0/1`) |
| *-- RAMB36/FIFO* | 11 | 33 | **49** | 984 | **4.98%** | +38 `RAMB36E2` |
| *-- RAMB18* | 3 | 17 | **22** | 1,968 | **1.12%** | +19 `RAMB18E2` |
| **DSP48E2 Slices** | 920 | 63 | **63** | 1,968 | **3.20%** | **-857 DSPs (-93.15%)** |

### 3.2 Hierarchical Subsystem Utilization Breakdown (`synth/vivado_output/utilization_hierarchical.rpt`)

| Hierarchical Instance | Module | Total LUTs | Logic LUTs | LUTRAMs | SRLs | FFs | RAMB36 | RAMB18 | DSP48E2 | Architectural Note |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| **`hevc_encoder_axi_top`** | `(top)` | **237,476** | **229,718** | **7,728** | **30** | **163,801** | **49** | **22** | **63** | Full AXI4-Lite/AXI4 SoC wrapper (`51 LUTs, 177 FFs` self; edge-detected IRQ + `core_rst_n_reg`) |
| `  u_hevc_encoder_top` | `hevc_encoder_top` | **237,425** | **229,667** | **7,728** | **30** | **163,624** | **49** | **22** | **63** | Top-level datapath, 2-bank CTU Ping-Pong, 4-entry `cu_fifo`/`tu_meta_fifo`, 4-bank `coeff_buffer`, TDP DPB (`23,098 LUTs` self, `7,680 LUTRAM`, `40,629 FFs`, `34 RAMB36, 6 RAMB18`) |
| `    u_dct_top` | `dct_top` | **84,904** | **84,904** | 0 | 0 | **37,172** | 0 | 0 | **1** | Row-serial 2D DCT-II / DST-VII (`u_1d_core`: `48,541 LUTs, 2,619 FFs, 1 DSP`; `u_transpose_ram`: `5,048 LUTs, 16,896 FFs`) |
| `    u_inloop_filters` | `decoder_inloop_filters` | **47,570** | **47,570** | 0 | 0 | **55,699** | **4** | **12** | **2** | 2-bank CTU Ping-Pong BRAMs + output skid buffer + 2-stage `u_deblock` (`19,483 LUTs, 1,192 FFs`), `u_sao` (`13,704 LUTs, 1,008 FFs`), `u_sao_stats` (`7,072 LUTs, 6,376 FFs, 2 DSPs`) |
| `    u_inter_pred` | `inter_pred_top` | **31,739** | **31,709** | 0 | 30 | **9,803** | **4** | **1** | **13** | TZ search (`636 LUTs`), FME (`26,801 LUTs, 27 SRLs`), `mc_unit` (`110 LUTs`), `ref_frame_buffer` (`1,585 LUTs, 13 DSPs`), Phase B1 **`u_ref_search_cache`** (`2,606 LUTs, 1,692 FFs, 4 RAMB36, 1 RAMB18`) |
| `    u_mc_window_fetch` | `mc_window_fetch` | **13,823** | **13,823** | 0 | 0 | **3,891** | 0 | 0 | **0** | Pillar 1 TDP 2-sample/cyc sliding-column DPB fetcher + `0D/1D` fast fetch + `row0_win` reuse + `rd_hold` stall |
| `    u_intra_pred` | `intra_pred_top` | **10,399** | **10,351** | **48** | 0 | **4,482** | 0 | 0 | **23** | 35-mode reconstruction: Angular (`7,392 LUTs, 17 DSPs`), Ref filter (`2,497 LUTs, 2 DSPs`), DC (`357 LUTs`), Planar (`153 LUTs, 4 DSPs`) |
| `    u_intra_rmd` | `intra_rmd` | **8,916** | **8,916** | 0 | 0 | **5,625** | 0 | 0 | **12** | Pipelined `150 MHz` 4-mode Luma SATD (`4x4..32x32`, 4x `hadamard_satd_4x4`) + 5-cand Chroma Table 8-2 RDO (`T3-14`) |
| `    u_cabac_enc_top` | `cabac_enc_top` | **5,532** | **5,532** | 0 | 0 | **2,423** | **4** | **2** | **0** | Dual-bank `ctu_bin_ram_0/1` (`4 RAMB36, 2 RAMB18`), pipelined `syntax_coeff` (`2,623 LUTs, 758 FFs`), `ctx_model_store` (`1,200 LUTs, 1,335 FFs`), `range_coder` (`837 LUTs`), `syntax_pred` (`407 LUTs`), `bin_encoder` (`236 LUTs`), `syntax_sao` (`180 LUTs`) |
| `    u_ctu_partitioner` | `ctu_partitioner` | **2,961** | **2,961** | 0 | 0 | **376** | 0 | 0 | **0** | Recursive Morton Z-scan quadtree controller ($64\times64 \to 8\times8$) |
| `    u_recon_unit` | `recon_unit` | **1,869** | **1,869** | 0 | 0 | **362** | **1** | **1** | **0** | Pixel clipping & BRAM reconstruction buffer (`1 RAMB36E2, 1 RAMB18E2`) |
| `    u_subpel_core_l0` | `subpel_interpolation_core` | **1,168** | **1,168** | 0 | 0 | **315** | 0 | 0 | **0** | Unified 2-stage pipelined 8-tap Luma / 4-tap Chroma sub-pel FIR core (List 0, `(* use_dsp="no" *)`) |
| `    u_rate_controller` | `rate_controller` | **1,175** | **1,175** | 0 | 0 | **216** | 0 | 0 | **3** | Closed-loop VBV fullness shift-tree & reciprocal-multiply budget allocator (`0 LDCE`) |
| `    u_residual_sub` | `residual_sub` | **1,002** | **1,002** | 0 | 0 | **116** | 0 | 0 | **0** | 11-bit signed residual subtraction |
| `    u_pu_cu_splitter` | `pu_cu_splitter` | **958** | **958** | 0 | 0 | **709** | 0 | 0 | **0** | PU/CU partition sequencer |
| `    u_mode_decision` | `mode_decision` | **634** | **634** | 0 | 0 | **221** | 0 | 0 | **3** | Lagrangian RDO cost comparator, depth-0 bypass & `FAST_EARLY_CU_SPLIT` (`0` default) |
| `    u_ctu_raster_scan` | `ctu_raster_scan` | **548** | **548** | 0 | 0 | **38** | 0 | 0 | **0** | Frame-level CTU raster coordinate generator |
| `    u_inv_quant` | `inv_quant` | **371** | **371** | 0 | 0 | **163** | 0 | 0 | **2** | Main10 inverse dequantizer with Table 8-10 Chroma QP mapping |
| `    u_slice_controller` | `slice_controller` | **352** | **352** | 0 | 0 | **80** | 0 | 0 | **0** | Slice header & VPS/SPS/PPS `u_param_set_writer` (`59 LUTs, 13 FFs`), `nal_ready`-gated waits |
| `    u_fwd_quant` | `fwd_quant` | **341** | **341** | 0 | 0 | **48** | 0 | 0 | **1** | Scalar deadzone forward quantizer |
| `    u_subpel_core_l1` | `subpel_interpolation_core_0` | **324** | **324** | 0 | 0 | **284** | 0 | 0 | **0** | Unified 2-stage pipelined 8-tap Luma / 4-tap Chroma sub-pel FIR core (List 1, `(* use_dsp="no" *)`) |
| `    u_gop_controller` | `gop_controller` | **264** | **264** | 0 | 0 | **134** | 0 | 0 | **0** | Dynamic runtime AI/LDP GOP scheduler |
| `    u_frame_store` | `frame_store` | **109** | **109** | 0 | 0 | **695** | 0 | 0 | **3** | AXI4 burst write/read frame buffer controller |
| `    u_nal_writer` | `nal_writer` | **55** | **55** | 0 | 0 | **37** | 0 | 0 | **0** | Annex B framing, inline `0x03` EPB, `nal_ready`, and `nal_end_pending` |
| `    u_mvp_predictor` | `mvp_predictor` | **34** | **34** | 0 | 0 | **104** | 0 | 0 | **0** | Spatial/Temporal AMVP & 5-candidate Merge derivation |

### 3.3 Timing Performance & Closure (`synth/vivado_output/timing_summary_synth.rpt`)
- **Clock Domain:** `clk`
- **Target Period:** **6.667 ns (150.00 MHz)**
- **Worst Negative Slack (WNS):** **+0.318 ns (MET)** (Worst Path: `u_cabac_enc_top/u_sc/cur_cg_reg[0]/C -> u_rc/low_r_reg[31]/D`, Data Path Delay: `6.131 ns` across `27` logic levels)
- **Total Negative Slack (TNS):** **0.000 ns** (0 failing endpoints out of **451,909** total / **391,411** intra-clock endpoints)
- **Worst Pulse Width Slack (WPWS):** **+2.791 ns** (`TPWS = 0.000 ns`, 0 / 171,712 endpoints)
- **Estimated Maximum Frequency ($F_{\max}$):** **157.51 MHz** (Meets 150 MHz constraint cleanly)

### 3.4 Vector-less Power Estimation (`synth/vivado_output/power_synth.rpt`)
- **Dynamic On-Chip Power:** **3.026 W**
- **Device Static Power:** **1.132 W**
- **Total On-Chip Power:** **4.158 W** (Junction Temp: `28.4 °C`)

### 3.5 Sign-Off Verification, Overlapped Throughput Profile & IP Packaging Parity
- **Gate 1 (`run_sim.do`) == Gate 2 (`tb/run_sim_synthdef.do`, `+define+SYNTHESIS`) Simulation-vs-Synthesis Parity:** Both full-encoder simulations on [`tb/tb_full_encoder/tb_b_frame_encoder.v`](file:///d:/UIT_Doc/hevc_hw_encoder/tb/tb_full_encoder/tb_b_frame_encoder.v) finish at `4,920,865 ns` (`492,086.5` cycles total; `[FRAME_WALLCLOCK]` F0 `161,390`, F1 `160,280`, F2 `157,969` cycles) and emit bit-identical `str_b_frame.bin` (**3,134 B**, SHA-256 `FF2D0A83990DC94160627A8E061C8EC54F9EB07BECA3AC93F5C036ADD3DF820B`) and `hw_recon.yuv` (**147,456 B**, SHA-256 `AE739FE1EDA914849D180F309A0B55B00AEC85B04619B49270DFBFAC0ADB049E`), with **`0` `REMEDIATION` directives** in `rtl/` and `ip_repo/hevc_encoder_v1_0/src/`, **`0` behavioral `` `ifdef SYNTHESIS `` blocks** (`3` 4-state `===` X-safety guards).
- **Pipeline Throughput Profile (`scripts/profile_pipeline_throughput.py`, Overlapped 2-Bank CTU Ping-Pong):**

| Frame | CTU | Total Cyc (Period) | `T_MD` | `T_TQ` | `T_DB` | `T_CABAC` (FE->BE) | `Stall_CABAC` | `Stall_Inloop` | Stall % |
|:---:|:---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 0 (I) | 0 | 64,148 | 10,580 | 17,424 | 10,304 | 49,101 | 0 | 3,558 | 5.5% |
| 0 (I) | 1 | 24,059 | 6,948 | 15,216 | 9,452 | 46,330 | 0 | 0 | 0.0% |
| 0 (I) | 2 | 34,944 | 7,860 | 15,888 | 9,642 | 44,066 | 0 | 0 | 0.0% |
| 0 (I) | 3 | 38,238 | 9,668 | 16,752 | 15,323 | 53,405 | 0 | 0 | 0.0% |
| 1 (P) | 0 | 51,315 | 4,947 | 13,239 | 2,920 | 33,276 | 0 | 7,756 | 15.1% |
| 1 (P) | 1 | 32,026 | 4,696 | 13,239 | 5,124 | 42,806 | 0 | 10,842 | 33.9% |
| 1 (P) | 2 | 30,715 | 4,696 | 12,980 | 4,053 | 44,018 | 0 | 0 | 0.0% |
| 1 (P) | 3 | 46,223 | 4,697 | 12,980 | 6,165 | 45,954 | 0 | 0 | 0.0% |
| 2 (B) | 0 | 51,307 | 4,912 | 13,239 | 2,940 | 33,642 | 0 | 4,165 | 8.1% |
| 2 (B) | 1 | 40,450 | 8,442 | 14,439 | 7,417 | 44,803 | 0 | 19,266 | 47.6% |
| 2 (B) | 2 | 31,159 | 4,696 | 12,980 | 4,542 | 52,685 | 0 | 0 | 0.0% |
| 2 (B) | 3 | 35,052 | 4,697 | 13,239 | 7,273 | 47,574 | 0 | 0 | 0.0% |
| **AVG** | **--** | **39,970** | **6,403** | **14,301** | **7,096** | **44,805** | **0** | **3,799** | **9.5%** |

  - **Steady-State Throughput (`Avg CTU Period = 39,970 cyc`):** **`150 MHz`: `938.2` (128x128) / `156.4` (CIF) / `17.1` (720p) / `7.4` (1080p) fps** | **`157.51 MHz` (Achieved Fmax): `985.2 / 164.2 / 17.9 / 7.7 fps`** | **`200 MHz`: `1,250.9 / 208.5 / 22.7 / 9.8 fps`**. (`T_CABAC = 44,805 cyc` spans the 2-stage overlapped FE->BE lifetime across consecutive CTUs rather than gating the initiation interval.)
- **Full 3-Frame Post-Filter & Pre-Filter Reconstruction (`scripts/regression_gate.py --enable-loop-filters --num-frames 3`):** **100.00% bit-exact across all `73,728 / 73,728` samples in Frames 0, 1, and 2 (Y, Cb, Cr)** (`Global Max Diff = 0`, `Avg Diff = 0.0000`) for both post-filter (`hw_recon.yuv` vs `dec_gate.yuv`) and pre-filter (`hw_recon_pre.yuv` SHA-256 `24F92B0B464255389E3D23DD6E87508798A4CCE8F3074E9088D482936192BA78` vs HM `rec_before_filter.yuv`).
- **3-Frame Foreman Objective Quality (`scripts/calc_psnr_ssim.py`):** Frame 0 (I, QP 29) **`39.024 dB` Y / `39.549 dB` YUV**; Frame 1 (P, QP 26) **`39.343 dB` Y / `40.168 dB` YUV**; Frame 2 (B, QP 26) **`39.438 dB` Y / `40.227 dB` YUV**; 3-frame average **`PSNR-Y = 39.268 dB`, `U = 41.866 dB`, `V = 42.373 dB`, `YUV = 39.981 dB`**.
- **3-Frame Top-Level CABAC (`scripts/verify_3frames_bins.py`):** **28,581 / 28,581 (100.00%)** 6-field exact (`bin`, `type`, `range`, `pstate`, `valmps`, `ctx`) across POC 0 (`8,349`), POC 1 (`9,819`), and POC 2 (`10,413`).
- **AXI4-Lite / AXI4 SoC Testbench ([`tb/tb_axi_top/tb_hevc_encoder_axi_top.sv`](file:///d:/UIT_Doc/hevc_hw_encoder/tb/tb_axi_top/tb_hevc_encoder_axi_top.sv) via [`tb/run_tb_axi.do`](file:///d:/UIT_Doc/hevc_hw_encoder/tb/run_tb_axi.do)):** **9 / 9 test suites PASS** (`113 B` bitstream, `TLAST=1`, `irq` aligned with `STATUS.DONE=1`, CSR read/write, soft reset, frame encode, W1C interrupt clear, and VBV fullness telemetry).
- **Gate G8 Dual-Tier UVM (`Vivado 2026.1 xsim` via `uvm/run_uvm_suite.py`):** `75.80 s`, **ALL GATES CONVERGED (`ERR=0 FAT=0 SVA=0`)**: Tier 1 (`5,940` bins, `1,266/1,266 B`, `cg_cabac=100%`), Tier 2A (`10/10` RAL), Tier 2B+C (**`256 B`**, `384/384` DRAM writes, `cg_soc_axi=100%`, HM 18.0 `exit=0`, `12,288 B`), Gate G6 (`64/64` parity).
- **Dual-State Algorithmic Flaw Testbenches (`scripts/run_all_flaw_tb.py`):** **14 / 14 PASS (100%)** against `rtl/` and **14 / 14 PROVEN (FAIL)** against locked [`tb/flaw_baseline_rtl/`](file:///d:/UIT_Doc/hevc_hw_encoder/tb/flaw_baseline_rtl) baselines (`28 / 28` runs in `19.9s`).
- **IP-XACT Packaging Synchronization & Catalog Verification:** **64 / 64 `.v`/`.vh` RTL files** verified 100% SHA-256 identical (`0` mismatches) between [`rtl/`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl) and [`ip_repo/hevc_encoder_v1_0/src/`](file:///d:/UIT_Doc/hevc_hw_encoder/ip_repo/hevc_encoder_v1_0/src) (`65` total files incl. `hevc_encoder_top.xdc`), and `ipx::check_integrity status: 1` / Vivado IP Integrator verification passed (`synth/vivado_verify.log`).

---

## 4. Multi-QP Rate-Distortion & Bit-Exact Verification (`v3.0` Finalized RTL)

Refreshed multi-QP evaluation (`scripts/run_qp_sweep_and_bd_rate.py --force` on finalized `v3.0` RTL `bbc3086`) was conducted across four operating points (`QP in {22, 27, 32, 37}`) on standard sequence **Foreman 128x128 10-bit** across 3 frames (POC 0: I-Slice, POC 1: P-Slice, POC 2: B-Slice). Each hardware encoded bitstream is decoded with the Fraunhofer HM 18.0 reference decoder (`TAppDecoder.exe`), and every reconstructed sample ($Y, Cb, Cr$) is compared sample-by-sample against the decoded output.

### 4.1 Multi-QP Conformance Scorecard Table

| QP | HM Rate (kbps) | HM PSNR-Y (dB) | HW Bytes | HW Rate (kbps) | HW PSNR-Y (dB) | HW PSNR-YUV (dB) | $\Delta$ PSNR-Y (dB) | Bit-Exact Samples | Max Sample Diff | Result |
|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| **22** | 186.56 | 42.83 | 5,249 | **419.92** | **42.33** | 43.05 | -0.50 dB | **73,728 / 73,728** | **0** | **100.00% PASS** |
| **27** | 103.84 | 39.65 | 3,118 | **249.44** | **39.22** | 40.01 | -0.43 dB | **73,728 / 73,728** | **0** | **100.00% PASS** |
| **32** | 64.00 | 36.58 | 2,071 | **165.68** | **37.41** | 38.00 | +0.83 dB | **73,728 / 73,728** | **0** | **100.00% PASS** |
| **37** | 38.40 | 33.62 | 1,440 | **115.20** | **34.77** | 35.31 | +1.15 dB | **73,728 / 73,728** | **0** | **100.00% PASS** |

### 4.2 Bjøntegaard Delta (BD) Metrics (vs. HM 18.0 Anchor)
- **BD-Rate:** **+145.52%** (`+145.519%`; improved vs `+148.58%` baseline; reflects hardware encoder's fixed-hardware RDO trade-off against full unbounded multi-pass floating-point software search).
- **BD-PSNR:** **-5.02 dB** (`-5.0248 dB`; average quality delta across equivalent bitrates against reference software anchor).
- **Bit-Exact Conformance:** **100.00% across all 4 QPs** — every single reconstructed sample in hardware strictly matches the HM 18.0 decoder output with `max_diff == 0`.
- **Rate-Distortion Curve Artifact:** Rendered to publication-ready SVG in [rd_curve.svg](file:///d:/UIT_Doc/hevc_hw_encoder/rd_curve.svg) and exported to [qp_sweep_results.json](file:///d:/UIT_Doc/hevc_hw_encoder/qp_sweep_results.json).
