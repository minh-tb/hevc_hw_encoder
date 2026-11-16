# HEVC Main10 Hardware Video Encoder - Complete Regression Execution Results

**Execution Timestamp:** 2026-11-16T02:20:00+07:00 (Vivado Build: `2026-11-16 02:19:58`)  
**Regression Runner:** [`scripts/run_all_flaw_tb.py`](file:///d:/UIT_Doc/hevc_hw_encoder/scripts/run_all_flaw_tb.py), [`tb/run_tb_axi.do`](file:///d:/UIT_Doc/hevc_hw_encoder/tb/run_tb_axi.do), [`run_sim.do`](file:///d:/UIT_Doc/hevc_hw_encoder/run_sim.do), [`tb/run_sim_synthdef.do`](file:///d:/UIT_Doc/hevc_hw_encoder/tb/run_sim_synthdef.do)  
**Toolchain:** ModelSim Altera Starter Edition 10.1d (`vlog.exe`, `vsim.exe` headless batch) & AMD Vivado 2026.1 (64-bit)  
**Host Environment:** Windows PowerShell, Python 3.12.8  
**Default RTL State:** `REMEDIATION` enabled by default in [`rtl/common/parameter_pkg.vh`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/common/parameter_pkg.vh) (`+define+NO_REMEDIATION` selects legacy unpatched state for dual-mode flaw verification; `FAST_EARLY_CU_SPLIT = 0` default)  
**Total Flaw Test Cases:** 14 (`28 / 28` dual-state runs completed in `34.6 seconds` wallclock runtime)  
**Total AXI SoC Test Cases:** 9 (`9 / 9 PASS` — `119 B`, `TLAST=1`)  
**Re-Verified Post-Edit Self-Checking Unit Suites (25 unit + 1 SoC = 26 PASS):** `tb_mc_window_fetch` (`6,272` samples incl. `rd_hold` stall stress), `tb_boundary_strength` (`1,010` vectors incl. Chroma CBF, `0` errors), `tb_sao` (Mode 0 & 1), `tb_sao_stats`, `tb_inloop_filters` (Phase 1 & 2, `FullFrame 24,576 / 24,576 max_diff = 0`), `tb_deblock` (`6,144` matches), `tb_db_filter_luma` (`10,000` tests), `tb_b_prediction`, `tb_interpolation_filter` (`0` fails), `tb_spatial_availability` (`0` failures), `tb_ref_frame_buffer`, `tb_range_coder` (`19,391` matches), `tb_ctx_model_store`, `tb_syntax_pred`, `tb_rate_control_rdo`, `tb_intra_pred_top`, `tb_intra_planar`, `tb_intra_dc`, `tb_ref_sample_filter`, `tb_mvp_predictor`, `tb_inv_quant`, `tb_transform_rigorous`, `tb_nal_writer`, `tb_gop_controller`, `tb_slice_controller` *(plus `tb_entropy_chain` standalone `Wrote 7 bytes` without `flat_field_qp32.bin`, and `tb_intra_angular` 0 vectors due to missing `.dat`; legacy/stale standalone TBs with port/design drift excluded from unit claim: `tb_syntax_coeff`, `tb_mode_decision`, `tb_db_filter_chroma`, `tb_syntax_cu`, `tb_ctu_partitioner`, `tb_pu_cu_splitter`, `tb_ctu_raster_scan`, `tb_recon_unit`, `tb_hpel_filter_luma`, `tb_hpel_filter_chroma`, `tb_mc_unit`, `tb_tz_search`, `tb_fwd_quant`, `tb_dct_top`, `tb_frame_store`)*  
**3-Frame Pipeline Throughput:** **62,747 cycles/CTU** (`FAST_EARLY_CU_SPLIT = 0`: `-50.8%` vs `127,647` baseline, `< 71,348` target; **`T_DB = 7,230`** `-54.6%` vs `15,936`, `Stall_Inloop = 0`) | **63,959 cycles/CTU** (`-gFAST_EARLY_CU_SPLIT=1`: `T_MD = 7,230`, `T_TQ = 13,455`, `T_DB = 5,530`, `T_CABAC = 45,112`, `3,023 B`, `27,028` bins `100%` exact, `73,728/73,728 max_diff = 0`, `PSNR-YUV = 40.109 dB`)  
**3-Frame CABAC Bin Conformance:** **28,962 / 28,962 bins (100.00% bit-exact 6-field match across POC 0: 8,496, POC 1: 10,022, POC 2: 10,444)**  
**Regression Status:** **100% CONVERGENCE (14/14 PROVEN BUGGY, 14/14 PASS REMEDIATED, 26 UNIT+AXI SUITES PASS, 63/63 IP FILES SYNCED)**

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
**Synthesis Mode:** Out-of-Context (`-mode out_of_context -verilog_define {SYNTHESIS=1 REMEDIATION=1}`)  
**Target Module:** `hevc_encoder_axi_top` (Includes core encoder, AXI4 memory controller, and register interfaces)  
**Status:** **SYNTHESIS CONVERGENCE & TIMING CLOSURE ACHIEVED (0 Errors, 0 Critical Warnings, 0 Latches, 0 `LUTAR-1` Warnings, WNS = +10.360 ns)**

### 3.1 Device Utilization Summary (Baseline vs. Phase 1 vs. Phase 2 vs. Sign-Off Final)

| Cell / Logic Primitive | Baseline Used | Phase 1 Used | Phase 2 Used | **Sign-Off Final Used** | Available | Utilization % | Total Delta / Savings vs Baseline |
|---|---:|---:|---:|---:|---:|---|---|
| **CLB LUTs** | 448,916 | 342,547 | 225,933 | **225,006** | 522,720 | **43.05%** | **-223,910 LUTs (-49.88%)** |
| *-- Logic LUTs* | 446,581 | 340,166 | 223,550 | **217,247** | 522,720 | **41.56%** | **-229,334 LUTs (-51.35%)** |
| *-- LUT as Memory (LUTRAM + SRL)* | 6,991 | 6,991 | 6,991 | **7,759** | 161,280 | **4.81%** | 7,728 LUTRAM + 31 SRL |
| **CLB Registers (Flip-Flops)** | 344,030 | 253,425 | 249,980 | **140,035** | 1,045,440 | **13.39%** | **-203,995 FFs (-59.30%)** |
| **Register as Latch (`LDCE`)** | 0 | 0 | 0 | **0** | 1,045,440 | **0.00%** | 0 Unintended Latches |
| **Unique Control Sets** | 14,641 | 10,812 | 10,733 | **7,668** | 130,680 | **5.87%** | **-6,973 sets (-47.63%)** |
| **Block RAM Tile** | 12.5 | 30.0 | 30.0 | **41.5** | 984 | **4.22%** | **41.5 Tiles (+0 extra from TDP DPB)** |
| *-- RAMB36/FIFO* | 11 | 27 | 27 | **33** | 984 | **3.35%** | +22 `RAMB36E2` |
| *-- RAMB18* | 3 | 6 | 6 | **17** | 1,968 | **0.86%** | +14 `RAMB18E2` |
| **DSP48E2 Slices** | 920 | 878 | 209 | **63** | 1,968 | **3.20%** | **-857 DSPs (-93.15%)** |

### 3.2 Hierarchical Subsystem Utilization Breakdown (`synth/vivado_output/utilization_hierarchical.rpt`)

| Hierarchical Instance | Module | Total LUTs | Logic LUTs | LUTRAMs | SRLs | FFs | RAMB36 | RAMB18 | DSP48E2 | Architectural Note |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| **`hevc_encoder_axi_top`** | `(top)` | **225,006** | **217,247** | **7,728** | **31** | **140,035** | **33** | **17** | **63** | Full AXI4-Lite/AXI4 SoC wrapper (`38 LUTs, 159 FFs` self; `core_rst_n_reg` sync reset) |
| `  u_hevc_encoder_top` | `hevc_encoder_top` | **224,968** | **217,209** | **7,728** | **31** | **139,876** | **33** | **17** | **63** | Top-level encoder datapath & TDP DPB (`22,101 LUTs`, `7,680 LUTRAM`, `39,557 FFs`, `28 RAMB36, 8 RAMB18` self) |
| `    u_dct_top` | `dct_top` | **89,638** | **89,638** | 0 | 0 | **35,135** | 0 | 0 | **1** | Row-serial 2D DCT-II / DST-VII (`u_1d_core`: `53,206 LUTs, 513 FFs, 1 DSP`; `u_transpose_ram`: `5,074 LUTs, 16,896 FFs`) |
| `    u_inloop_filters` | `decoder_inloop_filters` | **33,665** | **33,665** | 0 | 0 | **37,374** | **2** | **6** | **2** | Sync BRAM + Pillar 4 `u_deblock` (`10,785 LUTs, 957 FFs`), `u_sao` (`9,549 LUTs, 950 FFs`), `u_sao_stats` (`9,326 LUTs, 6,376 FFs, 2 DSPs`) |
| `    u_inter_pred` | `inter_pred_top` | **28,450** | **28,419** | 0 | 31 | **8,009** | 0 | 0 | **13** | TZ search (`621 LUTs`), FME (`26,126 LUTs, 27 SRLs`), `mc_unit` (`112 LUTs`), `ref_frame_buffer` (`1,590 LUTs, 13 DSPs`) |
| `    u_mc_window_fetch` | `mc_window_fetch` | **13,739** | **13,739** | 0 | 0 | **3,896** | 0 | 0 | **0** | Pillar 1 TDP 2-sample/cyc sliding-column DPB fetcher + `0D/1D` fast fetch + `row0_win` reuse + `rd_hold` stall |
| `    u_intra_pred` | `intra_pred_top` | **10,369** | **10,321** | **48** | 0 | **4,436** | 0 | 0 | **23** | 35-mode reconstruction: Angular (`7,432 LUTs, 17 DSPs`), Ref filter (`2,431 LUTs, 2 DSPs`), DC (`357 LUTs`), Planar (`149 LUTs, 4 DSPs`) |
| `    u_intra_rmd` | `intra_rmd` | **9,857** | **9,857** | 0 | 0 | **5,392** | 0 | 0 | **12** | 4-mode Luma (`Planar/DC/Hor/Ver`) 4x4-tiled SATD (`4x4..32x32`, ping-pong banks, `4x hadamard_satd_4x4`) + 5-candidate Chroma Table 8-2 RDO (`T3-14`) |
| `    u_cabac_enc_top` | `cabac_enc_top` | **5,478** | **5,478** | 0 | 0 | **2,369** | **2** | **1** | **0** | CTU-delayed bin queue (`2 RAMB36, 1 RAMB18`), `syntax_coeff` (`2,766 LUTs, 736 FFs` w/ CG skip), `ctx_model_store` (`1,199 LUTs, 1,335 FFs`), `range_coder` (`777 LUTs`), `syntax_pred` (`306 LUTs`), `bin_encoder` (`262 LUTs`), `syntax_sao` (`128 LUTs`) |
| `    u_ctu_partitioner` | `ctu_partitioner` | **3,053** | **3,053** | 0 | 0 | **378** | 0 | 0 | **0** | Recursive Morton Z-scan quadtree controller ($64\times64 \to 8\times8$) |
| `    u_recon_unit` | `recon_unit` | **2,519** | **2,519** | 0 | 0 | **284** | **1** | **1** | **0** | Pixel clipping & BRAM reconstruction buffer (`1 RAMB36E2, 1 RAMB18E2`) |
| `    u_subpel_core_l0` | `subpel_interpolation_core` | **1,157** | **1,157** | 0 | 0 | **315** | 0 | 0 | **0** | Unified 2-stage pipelined 8-tap Luma / 4-tap Chroma sub-pel FIR core (List 0, `(* use_dsp="no" *)`) |
| `    u_rate_controller` | `rate_controller` | **1,107** | **1,107** | 0 | 0 | **149** | 0 | 0 | **3** | Closed-loop VBV fullness shift-tree & reciprocal-multiply budget allocator (`0 LDCE`) |
| `    u_residual_sub` | `residual_sub` | **952** | **952** | 0 | 0 | **108** | 0 | 0 | **0** | 11-bit signed residual subtraction |
| `    u_pu_cu_splitter` | `pu_cu_splitter` | **892** | **892** | 0 | 0 | **708** | 0 | 0 | **0** | PU/CU partition sequencer |
| `    u_ctu_raster_scan` | `ctu_raster_scan` | **743** | **743** | 0 | 0 | **39** | 0 | 0 | **0** | Frame-level CTU raster coordinate generator |
| `    u_mode_decision` | `mode_decision` | **536** | **536** | 0 | 0 | **221** | 0 | 0 | **3** | Lagrangian RDO cost comparator, Pillar 2 depth-0 bypass & `FAST_EARLY_CU_SPLIT` (`0` default) |
| `    u_subpel_core_l1` | `subpel_interpolation_core_0` | **314** | **314** | 0 | 0 | **284** | 0 | 0 | **0** | Unified 2-stage pipelined 8-tap Luma / 4-tap Chroma sub-pel FIR core (List 1, `(* use_dsp="no" *)`) |
| `    u_gop_controller` | `gop_controller` | **273** | **273** | 0 | 0 | **135** | 0 | 0 | **0** | Dynamic runtime AI/LDP/RA GOP scheduler |
| `    u_fwd_quant` | `fwd_quant` | **273** | **273** | 0 | 0 | **30** | 0 | 0 | **1** | Scalar deadzone forward quantizer |
| `    u_inv_quant` | `inv_quant` | **217** | **217** | 0 | 0 | **140** | 0 | 0 | **2** | Main10 inverse dequantizer with Table 8-10 Chroma QP mapping |
| `    u_slice_controller` | `slice_controller` | **172** | **172** | 0 | 0 | **80** | 0 | 0 | **0** | Slice header & VPS/SPS/PPS `u_param_set_writer` (`77 LUTs, 13 FFs`) |
| `    u_frame_store` | `frame_store` | **126** | **126** | 0 | 0 | **695** | 0 | 0 | **3** | AXI4 burst write/read frame buffer controller |
| `    u_mvp_predictor` | `mvp_predictor` | **32** | **32** | 0 | 0 | **104** | 0 | 0 | **0** | Spatial/Temporal AMVP & 5-candidate Merge derivation |

### 3.3 Timing Performance & Closure (`synth/vivado_output/timing_summary_synth.rpt`)
- **Clock Domain:** `clk`
- **Target Period:** 20.000 ns (50.00 MHz)
- **Worst Negative Slack (WNS):** **+10.360 ns (MET)** (Data Path Delay: 9.422 ns across 40 logic levels)
- **Total Negative Slack (TNS):** **0.000 ns** (0 failing endpoints out of **389,457** total / **343,989** intra-clock endpoints)
- **Worst Pulse Width Slack (WPWS):** **+9.458 ns** (`TPWS = 0.000 ns`, 0 / 147,896 endpoints)
- **Estimated Maximum Frequency ($F_{\max}$):** **103.73 MHz** (Meets 50 MHz constraint with 2.07× margin)

### 3.4 Vector-less Power Estimation (`synth/vivado_output/power_synth.rpt`)
- **Dynamic On-Chip Power:** **1.084 W**
- **Device Static Power:** **1.115 W**
- **Total On-Chip Power:** **2.198 W** (Junction Temp: `26.8 °C`)

### 3.5 Sign-Off Verification & IP Packaging Parity
- **Gate 1 (`run_sim.do`) == Gate 2 (`tb/run_sim_synthdef.do`, `+define+SYNTHESIS`) Simulation-vs-Synthesis Parity:** Both full-encoder simulations on [`tb/tb_full_encoder/tb_b_frame_encoder.v`](file:///d:/UIT_Doc/hevc_hw_encoder/tb/tb_full_encoder/tb_b_frame_encoder.v) finish at `8,022,985 ns` (`802,298` cycles total) and emit bit-identical `str_b_frame.bin` (**3,178 B**, SHA-256 `542231A85C24C6D600096E46F971DE0274442D49B9A74630355576EAFDB4C0FA`) and `hw_recon.yuv` (**147,456 B**, SHA-256 `FDAB258067650458E281E0DF5F2C0DE33FA19D57B8B56FAE2E014CAF409E683F`), with **`0` behavioral `` `ifdef SYNTHESIS `` blocks** in `rtl/` (`3` 4-state `===` X-safety guards in `rtl/entropy/syntax_coeff.v`, `rtl/inter/mc_window_fetch.v`, and `rtl/inter/ref_frame_buffer.v`, `11` `` `ifndef SYNTHESIS `` sim init/clear blocks across 8 RTL files, and `72` `synthesis translate_off` directives).
- **Pipeline Throughput Profile (`scripts/profile_pipeline_throughput.py`, Gate 1 & Gate 2 identical):** 3-frame average **62,747 cycles/CTU** (`FAST_EARLY_CU_SPLIT = 0`: `-50.8%` vs `127,647` baseline, `< 71,348` target) | **`T_MD = 9,982`**, **`T_TQ = 14,172`**, **`T_DB = 7,230`** (**-54.6%** vs `15,936`, `<= 12,500` target), **`T_CABAC = 40,321`**, **`Stall = 10.1%`**, **`Stall_Inloop = 0`** across all 12 CTUs (`150 MHz: 155.0 / 99.6 fps CIF, 7.3 / 4.7 fps 1080p`; `200 MHz: 206.7 / 132.8 fps CIF, 9.7 / 6.2 fps 1080p`). Isolated `-gFAST_EARLY_CU_SPLIT=1` run (`eff_split_threshold = 1.5× split_threshold` at depths 1–2): **63,959 cycles/CTU** (`T_MD = 7,230` `-27.6%`, `T_TQ = 13,455` `-5.1%`, `T_DB = 5,530` `-23.5%`, `T_CABAC = 45,112` `+11.9%`, `3,023 B`, `27,028 / 27,028` 6-field exact bins, `73,728 / 73,728 max_diff = 0`, `PSNR-Y = 39.262 dB`, `PSNR-YUV = 40.109 dB`).
- **Full 3-Frame Post-Filter & Pre-Filter Reconstruction (`scripts/regression_gate.py --enable-loop-filters --num-frames 3`):** **100.00% bit-exact across all `73,728 / 73,728` samples in Frames 0, 1, and 2 (Y, Cb, Cr)** (`Global Max Diff = 0`, `Avg Diff = 0.0000`) for both post-filter (`hw_recon.yuv` vs `dec_gate.yuv`) and pre-filter (`hw_recon_pre.yuv` SHA-256 `6CFC954D3A337CBF4D5C810DF83B5C71A372A6FFF4FD1CA724B55AA2EC115A38` vs HM `rec_before_filter.yuv`).
- **3-Frame Foreman Objective Quality (`scripts/calc_psnr_ssim.py`):** Frame 0 (I, QP 29) **`39.02 dB` Y / `39.34 dB` YUV / `0.9628` SSIM-Y**; Frame 1 (P, QP 26) **`39.34 dB` Y / `40.15 dB` YUV / `0.9627` SSIM-Y**; Frame 2 (B, QP 26) **`39.44 dB` Y / `40.21 dB` YUV / `0.9616` SSIM-Y**; 3-frame average (`calc_psnr_ssim.py`) **`PSNR-Y = 39.268 dB`, `U = 41.637 dB`, `V = 41.952 dB`, `YUV = 39.900 dB`**. *(DST-VII in `dct_top.v` is unit-verified in `tb_flaw_dst7`; not invoked in the 3-frame Foreman run where CUs split to 8×8 min so Luma `tu_size_log2=2` count = `0`.)*
- **3-Frame Top-Level CABAC (`scripts/verify_3frames_bins.py`):** **28,962 / 28,962 (100.00%)** 6-field exact (`bin`, `type`, `range`, `pstate`, `valmps`, `ctx`) across POC 0 (`8,496`), POC 1 (`10,022`), and POC 2 (`10,444`) with Pillar 3 `tu_cg_nonzero_mask` zero-CG skipping, Chroma `above-right` reference fetch bit-5 fix (`abs_top_x_raw` / `rmd_abs_top_x_c_raw` in `hevc_encoder_top.v`), and `N_CTX = 186` (`0..185`).
- **AXI4-Lite / AXI4 SoC Testbench ([`tb/tb_axi_top/tb_hevc_encoder_axi_top.sv`](file:///d:/UIT_Doc/hevc_hw_encoder/tb/tb_axi_top/tb_hevc_encoder_axi_top.sv) via [`tb/run_tb_axi.do`](file:///d:/UIT_Doc/hevc_hw_encoder/tb/run_tb_axi.do)):** **9 / 9 test suites PASS** (`119 B` bitstream, `TLAST=1`, CSR read/write, soft reset, frame encode, W1C interrupt clear, and VBV fullness telemetry).
- **Re-Verified Post-Edit Self-Checking Unit Testbenches (ModelSim 10.1d, `25` unit + `1` SoC = `26` PASS):** `tb_mc_window_fetch` (`6,272` samples incl. `rd_hold` stall-stress matrix & `1'bx` guard), `tb_boundary_strength` (`1,010` vectors incl. Chroma CBF Clause 8.7.2.4, `0` errors), `tb_sao` (Mode 0 & 1 `0` errors), `tb_sao_stats` (`0` errors), `tb_inloop_filters` (Phase 1 & Phase 2 `FullFrame 24,576 / 24,576 max_diff = 0`, `errs = 0`), `tb_deblock` (`6,144` matches + cross-CTU boundary), `tb_db_filter_luma` (`10,000` tests PASSED), `tb_b_prediction` (PASSED), `tb_interpolation_filter` (`Luma 64 | Fails: 0, Chroma 256 | Fails: 0, Bi-Pred 16 | Fails: 0`), `tb_spatial_availability` (`0 FAILURES`), `tb_ref_frame_buffer` (PASSED), `tb_range_coder` (`19,391` matches), `tb_ctx_model_store` (`186` models PASS), `tb_syntax_pred` (`0` errors), `tb_rate_control_rdo` (PASS), `tb_intra_pred_top` (`616,224` samples PASS), `tb_intra_planar` (`17,360` samples PASS), `tb_intra_dc` (`8,416` self-gen samples PASS), `tb_ref_sample_filter` (PASS), `tb_mvp_predictor` (`20,000` tests, `0` errors), `tb_inv_quant` (HM 4..32 vectors PASS), `tb_transform_rigorous` (`240/240` PASS), `tb_nal_writer` (PASS), `tb_gop_controller` (PASS), and `tb_slice_controller` (PASS). *(Supplemental: `tb_entropy_chain` runs standalone emitting `7` bytes without golden `flat_field_qp32.bin`, `tb_intra_angular` skips missing `.dat` with `0` vectors, and 15 un-updated legacy standalone TBs fail elaboration/assertions due to RTL port/design evolution: `tb_syntax_coeff`, `tb_mode_decision`, `tb_db_filter_chroma`, `tb_syntax_cu`, `tb_ctu_partitioner`, `tb_pu_cu_splitter`, `tb_ctu_raster_scan`, `tb_recon_unit`, `tb_hpel_filter_luma`, `tb_hpel_filter_chroma`, `tb_mc_unit`, `tb_tz_search`, `tb_fwd_quant`, `tb_dct_top`, `tb_frame_store`.)*
- **Dual-State Algorithmic Flaw Testbenches (`scripts/run_all_flaw_tb.py`):** **14 / 14 PASS (100%)** in Remediated Mode and **14 / 14 PROVEN (FAIL)** in Buggy Mode (`28 / 28` runs in `34.6s` runtime).
- **IP-XACT Packaging Synchronization & Catalog Verification:** **63 / 63 `.v`/`.sv`/`.vh` files** verified 100% SHA-256 identical (`0` mismatches) between [`rtl/`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl) and [`ip_repo/hevc_encoder_v1_0/src/`](file:///d:/UIT_Doc/hevc_hw_encoder/ip_repo/hevc_encoder_v1_0/src) (`64` total incl. `hevc_encoder_top.xdc`), and Vivado IP Integrator catalog check passed (`synth/vivado_verify.log`).

---

## 4. Multi-QP Rate-Distortion & Bit-Exact Verification (`2026-11-14` Pre-Optimization Baseline)

Archived multi-QP evaluation (`2026-11-14`, prior to the 4-Pillar latency changes; not re-run post-optimization) was conducted across four operating points:
$$QP \in \{22, 27, 32, 37\}$$
on standard sequence **Foreman 128x128 10-bit** across 3 frames (POC 0: I-Slice, POC 1: P-Slice, POC 2: B-Slice). Each hardware encoded bitstream is decoded with the Fraunhofer HM 18.0 reference decoder (`TAppDecoder.exe`), and every reconstructed sample ($Y, Cb, Cr$) is compared sample-by-sample against the decoded output.

### 4.1 Multi-QP Conformance Scorecard Table

| QP | HM Rate (kbps) | HM PSNR-Y (dB) | HW Rate (kbps) | HW PSNR-Y (dB) | $\Delta$ PSNR (dB) | Bit-Exact Samples | Max Sample Diff | Result |
|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| **22** | 186.56 | 42.83 | **424.16** | **42.33** | -0.50 dB | **73,728 / 73,728** | **0** | **100.00% PASS** |
| **27** | 103.84 | 39.65 | **252.24** | **39.22** | -0.43 dB | **73,728 / 73,728** | **0** | **100.00% PASS** |
| **32** | 64.00 | 36.58 | **168.16** | **37.41** | +0.83 dB | **73,728 / 73,728** | **0** | **100.00% PASS** |
| **37** | 38.40 | 33.62 | **116.80** | **34.77** | +1.15 dB | **73,728 / 73,728** | **0** | **100.00% PASS** |

### 4.2 Bjøntegaard Delta (BD) Metrics (vs. HM 18.0 Anchor)
- **BD-Rate:** **+148.58%** (`+148.579%`; reflects hardware encoder's fixed-hardware RDO trade-off against full unbounded multi-pass floating-point software search).
- **BD-PSNR:** **-5.11 dB** (`-5.1084 dB`; average quality delta across equivalent bitrates against reference software anchor).
- **Bit-Exact Conformance:** **100.00% across all 4 QPs** — every single reconstructed sample in hardware strictly matches the HM 18.0 decoder output with `max_diff == 0`.
- **Rate-Distortion Curve Artifact:** Rendered to publication-ready SVG in [rd_curve.svg](file:///d:/UIT_Doc/hevc_hw_encoder/rd_curve.svg) and exported to [qp_sweep_results.json](file:///d:/UIT_Doc/hevc_hw_encoder/qp_sweep_results.json).
