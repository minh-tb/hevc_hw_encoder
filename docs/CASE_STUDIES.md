# HEVC Hardware Video Encoder: Comprehensive Engineering Case Studies

This document compiles the complete technical case studies, root-cause analyses, architectural trade-offs, and hardware verification records developed during the design, remediation, and physical optimization of the **HEVC / H.265 Main10 Hardware Video Encoder** on AMD Zynq UltraScale+ FPGA (`xczu19eg-ffvb1517-2-e`).

---

## Table of Contents

1. [Executive Summary: The PPA Transformation Journey](#1-executive-summary-the-ppa-transformation-journey)
2. [Case Study 1: Timing Closure — Collapsing a 96-Logic-Level Rice Binarizer (`syntax_coeff.v`)](#2-case-study-1-timing-closure--collapsing-a-96-logic-level-rice-binarizer-syntax_coeffv)
3. [Case Study 2: Parallel Bus & Register Inflation — The 10-Array Transform Mux Crisis (`dct_top.v` & `hevc_encoder_top.v`)](#3-case-study-2-parallel-bus--register-inflation--the-10-array-transform-mux-crisis-dct_topv--hevc_encoder_topv)
4. [Case Study 3: Variable Multiply-Indexing vs. Constant Muxing — The 81k-LUT FME Extractor (`fme_search.v`)](#4-case-study-3-variable-multiply-indexing-vs-constant-muxing--the-81k-lut-fme-extractor-fme_searchv)
5. [Case Study 4: Synthesis Boundaries & Unconnected Logic — The `keep_hierarchy` Trap (`hpel_filter_luma.v` & `mc_unit.v`)](#5-case-study-4-synthesis-boundaries--unconnected-logic--the-keep_hierarchy-trap-hpel_filter_lumav--mc_unitv)
6. [Case Study 5: Algebraic Symmetry ($M = M^T$) & Multi-Branch Transform Deduplication (`transform_1d_core.v`)](#6-case-study-5-algebraic-symmetry-m--mt--multi-branch-transform-deduplication-transform_1d_corev)
7. [Case Study 6: Inter-CTU Deblocking Commutativity & Boundary Race Conditions (`deblock_top.v`)](#7-case-study-6-inter-ctu-deblocking-commutativity--boundary-race-conditions-deblock_topv)
8. [Case Study 7: Chroma DC Level-1 Dequantization Scaling Across Arbitrary QPs (`hevc_encoder_top.v`)](#8-case-study-7-chroma-dc-level-1-dequantization-scaling-across-arbitrary-qps-hevc_encoder_topv)
9. [Case Study 8: System Audit — Compliant HEVC Subsets vs. Synthesis Bypasses](#9-case-study-8-system-audit--compliant-hevc-subsets-vs-synthesis-bypasses)
10. [Case Study 9: End-to-End SAO & Rate Control Conformance and Bit-Exact Reconstruction](#10-case-study-9-end-to-end-sao--rate-control-conformance-and-bit-exact-reconstruction)
11. [Case Study 10: Synchronous BRAM Architecture, Zero-Overhead Handshakes & 100% Bit-Exact In-Loop Pipeline](#11-case-study-10-synchronous-bram-architecture-zero-overhead-handshakes--100-bit-exact-in-loop-pipeline)
12. [Case Study 11: Dual-Tier UVM Verification Suite (Gate G8), Cross-Simulator Portability & SoC Backpressure Bug Discovery](#12-case-study-11-dual-tier-uvm-verification-suite-gate-g8-cross-simulator-portability--soc-backpressure-bug-discovery)

---

## 1. Executive Summary: The PPA Transformation Journey

### Master Hardware Metric Progression

All metrics extracted from post-synthesis Vivado 2026.1 reports targeting `xczu19eg-ffvb1517-2-e` at 50 MHz:

| Metric | Initial Baseline | Phase 1 Post-Optimization | Phase 2 Un-bypassed | **Sign-Off Final** | Total Reduction vs. Baseline |
|---|---:|---:|---:|---:|---|
| **CLB LUTs** | 448,916 (85.88%) | 342,547 (65.53%) | 225,933 (43.22%) | **226,544 (43.34%)** | **-222,372 LUTs (-49.54%)** |
| *-- LUT as Logic* | 446,581 (85.43%) | 340,166 (65.08%) | 223,550 (42.77%) | **218,785 (41.86%)** | **-227,796 LUTs (-51.01%)** |
| *-- LUT as Memory (LUTRAM + SRL)* | 6,991 (4.33%) | 6,991 (4.33%) | 6,991 (4.33%) | **7,759 (4.81%)** | 7,728 LUTRAM + 31 SRL |
| **CLB Registers (FFs)** | 344,030 (32.91%) | 253,425 (24.24%) | 249,980 (23.91%) | **140,046 (13.40%)** | **-203,984 FFs (-59.29%)** |
| **Unique Control Sets** | 14,641 (11.20%) | 10,812 (8.27%) | 10,733 (8.21%) | **7,679 (5.88%)** | **-6,962 sets (-47.55%)** |
| **DSP48E2 Slices** | 920 (46.75%) | 878 (44.61%) | 209 (10.62%) | **63 (3.20%)** | **-857 DSPs (-93.15%)** |
| **Block RAM** | 12.5 Tiles (1.27%) | 30.0 Tiles (3.05%) | 30.0 Tiles (3.05%) | **33 RAMB36 + 17 RAMB18** | **+29.0 BRAM Tiles (41.5 Tiles / 4.22%, 0 extra from TDP)** |
| **Setup Slack (WNS)** | -5.394 ns (VIOLATED) | +1.485 ns (MET) | +10.497 ns (MET) | **+10.360 ns (MET)** | **+15.754 ns timing slack** |
| **Failing Endpoints** | 37 failing endpoints | 0 failing endpoints | 0 / 543,058 | **0 / 389,569** | **100% Timing Closure** |
| **Estimated $F_{\max}$** | 39.38 MHz | 54.01 MHz | 105.23 MHz | **103.73 MHz** | **+163.4% Clock Speedup** |
| **Dynamic Power** | 1.926 W | 1.304 W | 0.831 W | **1.085 W** | **-43.7% Dynamic Power** |
| **Total On-Chip Power** | 3.048 W | 2.420 W | 1.943 W | **2.199 W** | **-27.9% Total Power** |
| **Methodology `LUTAR-1`** | 1 Advisory | 1 Advisory | 1 Advisory | **0 Advisories** | Eliminated via sync `core_rst_n_reg` |

```
Initial Baseline: 448,916 LUTs (85.88%) | 344,030 FFs (32.91%) | 920 DSPs (46.75%) | WNS = -5.394 ns (39.38 MHz)
Phase 1:          342,547 LUTs (65.53%) | 253,425 FFs (24.24%) | 878 DSPs (44.61%) | WNS = +1.485 ns (54.01 MHz)
Phase 2:          225,933 LUTs (43.22%) | 249,980 FFs (23.91%) | 209 DSPs (10.62%) | WNS = +10.497 ns (105.23 MHz)
Sign-Off Final:   226,544 LUTs (43.34%) | 140,046 FFs (13.40%) | 63 DSPs (3.20%)   | WNS = +10.360 ns (103.73 MHz)
```

---

## 2. Case Study 1: Timing Closure — Collapsing a 96-Logic-Level Rice Binarizer (`syntax_coeff.v`)

### Problem Statement
In initial synthesis runs at 50 MHz ($T = 20.000\text{ ns}$), Vivado reported **37 failing timing endpoints** with a Worst Negative Slack of **WNS = -5.394 ns** ($F_{\max} = 39.38\text{ MHz}$).
Every failing endpoint terminated on registers inside the CABAC entropy coder:
- 32 bits of `rem_val_reg[0..31]`
- 5 bits of `rem_cnt_reg[1..5]`

### Root Cause Analysis
Inspecting [`rtl/entropy/syntax_coeff.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/entropy/syntax_coeff.v) revealed an iterative while loop implementing the ITU-T H.265 Section 9.3.3.2 Golomb-Rice and Exponential-Golomb binarization:
```verilog
// Legacy implementation: Iterative serial loop synthesized as 96 chained logic levels
while (val >= (1 << k)) begin
    rem_bins = {rem_bins[30:0], 1'b1};
    val = val - (1 << k);
    rem_cnt = rem_cnt + 1;
    if (rem_cnt == 4) begin
        // Switch to Exp-Golomb
        k = k + 1;
    end
end
```
Because the loop condition depended on intermediate values updated across variable steps, Vivado synthesized an unrolled ripple subtractor and cascade multiplexer spanning **96 levels of logic**. With logic delay ($12.4\text{ ns}$) and routing delay ($12.8\text{ ns}$), path delay reached **$25.18\text{ ns}$**, severely exceeding the $20.0\text{ ns}$ clock period.

### Technical Solution
Because transform coefficients after quantization are bounded by 16-bit dynamic range ($val < 65536$), the prefix count $\lfloor val / 2^k \rfloor$ can be determined in **$O(1)$ time** using a direct priority encoder:
```verilog
// Optimized O(1) Priority-Encoder Architecture in syntax_coeff.v
wire [15:0] shifted_val = val >> rice_param;
reg [2:0]   prefix_len;
reg [15:0]  suffix_val;

always @(*) begin
    if (shifted_val < 16'd3) begin
        prefix_len = shifted_val[1:0];
        suffix_val = val & ((1 << rice_param) - 1);
    end else begin
        // Exp-Golomb thresholding computed combinational in parallel
        prefix_len = 3'd4;
        ...
    end
end
```

### Impact & Results
- **Logic levels collapsed**: From 96 levels down to **8 levels of logic**.
- **Data path delay**: Reduced from $25.18\text{ ns}$ to **$4.42\text{ ns}$**.
- **Timing Closure**: All 37 failing endpoints were eliminated in a single pass. Slack jumped from $-5.394\text{ ns}$ to **$+1.485\text{ ns}$** (Phase 1) and later **$+10.497\text{ ns}$** (Phase 2).

---

## 3. Case Study 2: Parallel Bus & Register Inflation — The 10-Array Transform Mux Crisis (`dct_top.v` & `hevc_encoder_top.v`)

### Problem Statement
The initial hardware encoder design required **448,916 CLB LUTs (85.88%)** and **344,030 Flip-Flops (32.91%)**, leaving the device dangerously close to place-and-route failure. Despite this massive fabric utilization, only **30 Block RAM tiles (3.05%)** were utilized.

### Root Cause Analysis
In [`rtl/transform/dct_top.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/transform/dct_top.v), the 2D transform engine exposed a 16,384-bit wide parallel input and output interface:
```verilog
input  wire [16383:0] in_data,   // 32 x 32 x 16-bit parallel bus
output wire [16383:0] out_data   // 32 x 32 x 16-bit parallel bus
```
Because the entire $32 \times 32$ block was presented simultaneously, Vivado could not map the buffers to Block RAM (BRAM) or UltraRAM. To support this bus, `hevc_encoder_top.v` and `dct_top.v` maintained **ten separate $32 \times 32 \times 16$-bit flip-flop arrays**:
1. `residual_buffer[0:31][0:31]` ($16,384\text{ FFs}$)
2. `dct_out_hold[0:31][0:31]` ($16,384\text{ FFs}$)
3. `s2p_buffer[0:31][0:31]` ($16,384\text{ FFs}$)
4. `idct_out_hold[0:31][0:31]` ($16,384\text{ FFs}$)
5. `u_dct_top/in_buf[0:31][0:31]` ($16,384\text{ FFs}$)
6. `u_dct_top/out_data_reg[0:31][0:31]` ($16,384\text{ FFs}$)
7. `u_dct_top/transpose_ram` ($16,384\text{ FFs}$)
8. `u_idct_top/in_buf[0:31][0:31]` ($16,384\text{ FFs}$)
9. `u_idct_top/out_data_reg[0:31][0:31]` ($16,384\text{ FFs}$)
10. `u_idct_top/transpose_ram` ($16,384\text{ FFs}$)

Total registers dedicated purely to holding transform data: **$163,840\text{ Flip-Flops}$**! Furthermore, reading from these arrays into serial quantizers required **massive 1,024-to-1 16-bit multiplexer trees**, consuming over **$200,000\text{ LUTs}$**.

### Architectural Solution & Verification Pitfalls
1. **Unification of Forward and Inverse DCT (`u_dct_top`)**:
   Forward DCT (residual $\to$ coefficients) and Inverse DCT (dequantized coefficients $\to$ reconstructed residual) are strictly sequential per Transform Unit (TU). The duplicated instance `u_idct_top` was removed and replaced by a single shared core.
2. **Elimination of Intermediate Holding Arrays**:
   `dct_out_hold` and `idct_out_hold` were eliminated. Quantization and reconstruction read directly from `u_dct_top.out_data_reg`.
3. **Critical Verilog Pitfall Avoided**:
   In `hevc_encoder_top.v`, `idct_start` is a **1-cycle pulse** asserted in `S_IDLE`. If `in_buf` was removed and `.in_data` was multiplexed solely on `idct_start`, the input bus would revert back to the forward residual bus on cycle 2 while the 32-cycle inverse column pass was still running! The solution latched the pass type and gated the bus selector with:
   ```verilog
   wire use_idct_bus = idct_start || (!shared_xform_out_fwd_inv_n && !dct_in_valid);
   ```

### Impact & Results
- **CLB LUTs**: Reduced by **$106,369\text{ LUTs}$** (-23.7%).
- **CLB Registers**: Reduced by **$90,605\text{ FFs}$** (-26.3%).
- **DSP Slices**: Reduced by **$335\text{ DSPs}$** (from 920 to 585).

---

## 4. Case Study 3: Variable Multiply-Indexing vs. Constant Muxing — The 81k-LUT FME Extractor (`fme_search.v`)

### Problem Statement
In post-Phase 1 hierarchical utilization reports ([`utilization_hierarchical.rpt`](file:///d:/UIT_Doc/hevc_hw_encoder/synth/vivado_output/utilization_hierarchical.rpt)), a single wrapper block in Fractional Motion Estimation (`u_inter_pred/u_fme_search`) accounted for **$81,799\text{ LUTs}$** (nearly 24% of the entire FPGA).

### Root Cause Analysis
Inspecting lines 98–117 of [`rtl/inter/fme_search.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/inter/fme_search.v) revealed:
```verilog
// Legacy RTL in fme_search.v
wire signed [2:0] w_off_x = t_int_x - (base_mv_x - 1);
wire signed [2:0] w_off_y = t_int_y - (base_mv_y - 1);

(* keep = "true" *) reg [PIXEL_WIDTH*121-1:0] ext_11x11;
integer r, c;
always @(*) begin
    for (r = 0; r < 11; r = r + 1) begin
        for (c = 0; c < 11; c = c + 1) begin
            ext_11x11[PIXEL_WIDTH*(r*11 + c) +: PIXEL_WIDTH] = 
                ref_12x12[PIXEL_WIDTH*((r + w_off_y)*12 + (c + w_off_x)) +: PIXEL_WIDTH];
        end
    end
end
```
Because `w_off_x` and `w_off_y` were declared as `signed [2:0]`, the expression `(r + w_off_y) * 12 + (c + w_off_x)` was treated by Vivado as a **32-bit signed variable index** involving run-time multiplication by 12. For each of the 121 output pixels ($1,210\text{ bits}$), Vivado constructed a dynamic 1,440-bit barrel shifter.

### Mathematical Proof & Hardware Transformation
Fractional Motion Estimation evaluates half-pel ($\pm 2$ qpel) and quarter-pel ($\pm 1$ qpel) positions around the integer base motion vector `base_mv`.
$$\text{target}_{\text{mv}} \in [4 \cdot \text{base}_{\text{mv}} - 3, \; 4 \cdot \text{base}_{\text{mv}} + 3]$$
Performing arithmetic right shift by 2:
$$t_{\text{int}} = \text{target}_{\text{mv}} \gg 2 \in [\text{base}_{\text{mv}} - 1, \; \text{base}_{\text{mv}}]$$
Subtracting $(\text{base}_{\text{mv}} - 1)$:
$$w_{\text{off}} = t_{\text{int}} - (\text{base}_{\text{mv}} - 1) \in \{0, 1\} \quad \text{strictly!}$$
The variable offset can **only ever equal 0 or 1**!
Instead of dynamic multiplication, each tap in `ext_11x11` is simply a 4:1 multiplexer among four compile-time constant bit-slices of `ref_12x12`:
```verilog
wire off_x = (t_int_x == base_mv_x);
wire off_y = (t_int_y == base_mv_y);

(* keep = "true" *) wire [PIXEL_WIDTH*121-1:0] ext_11x11;
genvar gr, gc;
generate
    for (gr = 0; gr < 11; gr = gr + 1) begin : gen_ext_r
        for (gc = 0; gc < 11; gc = gc + 1) begin : gen_ext_c
            wire [PIXEL_WIDTH-1:0] px00 = ref_12x12[PIXEL_WIDTH*( gr   *12 +  gc   ) +: PIXEL_WIDTH];
            wire [PIXEL_WIDTH-1:0] px01 = ref_12x12[PIXEL_WIDTH*( gr   *12 + (gc+1)) +: PIXEL_WIDTH];
            wire [PIXEL_WIDTH-1:0] px10 = ref_12x12[PIXEL_WIDTH*((gr+1)*12 +  gc   ) +: PIXEL_WIDTH];
            wire [PIXEL_WIDTH-1:0] px11 = ref_12x12[PIXEL_WIDTH*((gr+1)*12 + (gc+1)) +: PIXEL_WIDTH];
            assign ext_11x11[PIXEL_WIDTH*(gr*11 + gc) +: PIXEL_WIDTH] =
                off_y ? (off_x ? px11 : px10) : (off_x ? px01 : px00);
        end
    end
endgenerate
```

### Impact & Results
- Each tap synthesized into a single LUT6.
- `u_fme_search` logic plummeted from **$81,799\text{ LUTs}$ down to $4,184\text{ LUTs}$** (**saving $77,615\text{ LUTs}$ / -94.9%**).
- Zero change in pixel bitstream output (100% bit-exact).

---

## 5. Case Study 4: Synthesis Boundaries & Unconnected Logic — The `keep_hierarchy` Trap (`hpel_filter_luma.v` & `mc_unit.v`)

### Problem Statement
In `utilization_hierarchical.rpt`, `u_inter_pred/u_mc_unit/u_filt_y` consumed **$24,391\text{ LUTs}$** and **$3,230\text{ FFs}$**, while adjacent chroma filters (`u_filt_cb`, `u_filt_cr`) synthesized to **$4\text{ LUTs}$**.

### Root Cause Analysis
In `hevc_encoder_top.v`, actual motion compensation was read directly from the on-chip `dpb_*_ram`. The pixel prediction outputs of `u_mc_unit` (`mc_pred_y_flat`, `mc_pred_cb_flat`, `mc_pred_cr_flat`) were dangling wires; `mc_unit` ran solely as a timing handshake state machine (`mc_start` $\to$ `mc_done`).
Vivado easily pruned `u_filt_cb` and `u_filt_cr`. However, in `hpel_filter_luma.v` line 73:
```verilog
(* use_dsp = "no", keep_hierarchy = "yes" *)
module hpel_filter_luma #( ... );
```
The `keep_hierarchy = "yes"` constraint instructed Vivado's synthesis engine to preserve module boundaries strictly, forbidding cross-boundary optimization and forcing Vivado to synthesize the entire 8-tap 3-stage 10-bit luma filter tree even though its outputs were discarded.

### Technical Solution
1. Removed `keep_hierarchy = "yes"` from [`rtl/inter/hpel_filter_luma.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/inter/hpel_filter_luma.v), leaving `(* use_dsp = "no" *)`.
2. Verified that `(* keep = "true" *)` on `ext_11x11` in `fme_search.v` maintained synthesis separation from the reference buffer.

### Impact & Results
- Vivado automatically swept the dead luma datapath in `u_mc_unit`, preserving only the 3-cycle `valid_out` shift register.
- `u_mc_unit` utilization dropped from **$24,503\text{ LUTs}$ to $112\text{ LUTs}$** (**saving $24,391\text{ LUTs}$ and $3,227\text{ FFs}$**).

---

## 6. Case Study 5: Algebraic Symmetry ($M = M^T$) & Multi-Branch Transform Deduplication (`transform_1d_core.v`)

### Problem Statement
Despite unifying Forward and Inverse DCT in Phase 1, `u_dct_top/u_core` ([`rtl/transform/transform_1d_core.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/transform/transform_1d_core.v)) still required **$62,918\text{ LUTs}$** and **$673\text{ DSP48E2 slices}$** (76.7% of all DSPs on the chip).

### Root Cause Analysis
Inspecting `transform_1d_core.v` revealed that:
1. Forward and Inverse DCT branches were split into independent `if (fwd_inv_n) ... else ...` blocks.
2. Inside each block, separate code paths existed for `tu_size_log2 == 2, 3, 4, 5`.
3. Total synthesized constant multiplications: **912 multiplications**!

### Mathematical Proof of DCT-II Odd Matrix Symmetry
The HEVC DCT-II transform matrix entries $T_N(i, j)$ are defined by:
$$T_N(i, j) = \text{round}\left( 64 \cdot \sqrt{\frac{2}{N}} \cdot \cos\left( \frac{\pi (2j + 1) i}{2N} \right) \right)$$
For the odd submatrix $M_N$ operating on odd rows $(2i + 1)$ and odd inputs $(2j + 1)$:
$$M_N(i, j) \propto \cos\left( \frac{\pi (2i + 1)(2j + 1)}{2N} \right)$$
Because multiplication in the cosine argument is commutative:
$$(2i + 1)(2j + 1) = (2j + 1)(2i + 1) \implies M_N(i, j) = M_N(j, i)$$
**The odd transform matrix is 100% symmetric ($M = M^T$) across all sizes ($N \in \{4, 8, 16, 32\}$)!**
The Inverse odd transform matrix $M^T$ is identical to the Forward odd transform matrix $M$.

### Hardware Architecture: Shared Basis Multiplier Engines
Instead of instantiating separate multiplier trees per TU size and direction, vector inputs are multiplexed *prior* to a single shared set of matrix engines:
- **`M32` ($16 \times 16$ odd matrix)**: Shared between 32-pt Forward and 32-pt Inverse.
- **`M16` ($8 \times 8$ odd matrix)**: Shared across 16-pt Fwd/Inv and 32-pt even layers.
- **`M8` ($4 \times 4$ odd matrix)**: Shared across 8-pt, 16-pt, and 32-pt passes.
- **`M4` ($2 \times 2$ odd matrix)**: Shared across 4-pt through 32-pt passes.
- **`DST-VII` (4-point)**: Shared between 4x4 intra luma forward and inverse passes.

Balanced binary adder trees `(((a + b) + (c + d)) + ...)` were maintained to ensure zero serial DSP cascade delay.

### Impact & Results
- Constant multipliers dropped from **912 down to 348 (-61.8%)**.
- Total DSP48E2 slices across the entire chip dropped from **878 down to 206 (-76.5%)**.
- Fabric LUTs in `transform_1d_core.v` dropped by **$12,988\text{ LUTs}$**.

---

## 7. Case Study 6: Inter-CTU Deblocking Commutativity & Boundary Race Conditions (`deblock_top.v`)

### Problem Statement
During initial 3-frame conformance verification against HM 18.0, the deblocking filter produced sample mismatches localized exclusively at CTU boundaries (e.g. column 15 of CTU (0,0) and column 0 of CTU (1,0)).

### Root Cause Analysis
HEVC deblocking applies vertical edge filtering (affecting rows across vertical boundaries) followed by horizontal edge filtering (affecting columns across horizontal boundaries).
In hardware:
1. In CTU (0,0), filtering column 14 modified pixels in column 15.
2. When the raster scan transitioned to CTU (1,0), filtering the vertical boundary between CTU (0,0) and CTU (1,0) read the *modified* column 15 pixels instead of the *pre-horizontal-filtered* original pixels required by the ITU-T H.265 specification.
3. Furthermore, CU metadata in `decoder_inloop_filters.v` was reset before the last edge filtering stage completed.

### Technical Solution
In [`rtl/inloop_filters/deblock_top.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/inloop_filters/deblock_top.v):
1. **Edge Gating**: When `has_right_neighbor == 1`, column 14 filtering is inhibited, preserving column 15 pixels in their uncorrupted pre-horizontal state.
2. **Metadata Latching**: Neighbor transform edge maps (`left_map_edge_hor`) are latched before the state machine triggers CU parameter reset.
3. **Corner Precedence**: Prioritized `is_ctu_boundary ? 1'b1 : is_corner_stage ? ...`.

### Impact & Results
- Verified $100.00\%$ bit-exact conformance across all components ($Y, Cb, Cr$) against Fraunhofer HM 18.0 (`max_diff = 0`).

---

## 8. Case Study 7: Chroma DC Level-1 Dequantization Scaling Across Arbitrary QPs (`hevc_encoder_top.v`)

### Problem Statement
While the encoder achieved 100% bit-exactness at $QP = 29$, running a multi-QP rate-distortion sweep ($QP \in \{22, 27, 32, 37\}$) resulted in immediate decoding divergence on Chroma blocks.

### Root Cause Analysis
In `hevc_encoder_top.v`, chroma dequantization contained a hardcoded constant:
```verilog
// Defective line in hevc_encoder_top.v
wire signed [31:0] chroma_dc_dequant = (chroma_level * 32'd72) >>> shift;
```
The number `72` corresponded to $g\_invQuantScales[29 \pmod 6] = 72$ for $QP = 29$ ($29 \pmod 6 = 5$). At any other QP, the scaling factor was mathematically invalid.

### Technical Solution
Implemented a parameterized function `calc_chroma_level1_dequant`:
1. Mapped Slice QP to Chroma QP using ITU-T H.265 Table 8-10 (`chroma_qp_map`).
2. Evaluated `g_invQuantScales[cqp % 6]` dynamically.
3. Implemented standard shift `sh_full = 6 - (cqp/6 + 2) - (5 - log2(size))` with symmetric rounding and 16-bit signed clipping $[-32768, 32767]$.

### Impact & Results
- Full multi-QP rate-distortion sweep across $QP \in \{22, 27, 32, 37\}$ achieved **$100.00\%$ bit-exact match across all 73,728 samples per QP** ($\max(\Delta) = 0$).

---

## 9. Case Study 8: System Audit — Compliant HEVC Subsets vs. Synthesis Bypasses

To ensure academic and industrial transparency, this case study documents all architectural design choices, compliant HEVC Main10 subsets, and synthesis bypasses:

### Compliant HEVC Main10 Baseline Subsets (Decodable by any standard HEVC decoder)
1. **PU Partitions**: Fixed to `PART_2Nx2N` (`part_mode = 2'd0`). Asymmetric motion partitions (AMP) are disabled (`T3-11`).
2. **Transform Tree (RQT)**: Fixed to depth 0 (`tu_size == cu_size` for $8\times8, 16\times16, 32\times32$, `T3-12`).
3. **CU Quadtree**: Depth 0 ($64\times64$) is forced to split into $32\times32$ leaf CUs to match the maximum $32\times32$ transform hardware core.
4. **Chroma Intra Prediction (`T3-14` — Full 5-Candidate Search)**: Evaluates all 5 normative chroma intra prediction modes (`Planar, Vertical, Horizontal, DC, DM_CHROMA`) per ITU-T H.265 Table 8-2 using sequential 1-pixel/cycle reference loading in [`intra_rmd.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/intra/intra_rmd.v), signals `intra_chroma_pred_mode` with context index 14 for bin 0 and bypass 2-bit suffix in [`syntax_pred.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/entropy/syntax_pred.v), and synchronizes $4\times4$ Chroma MDCS scan (`Clause 7.4.9.11`).
5. **Reference Frame Index**: `ref_idx_l0 = 0`, `ref_idx_l1 = 0`, candidate 0 chosen for AMVP.

### Runtime-Configurable Subsystems (Un-bypassed in Final Netlist)
1. **Sample Adaptive Offset (SAO — `T3-13` with CTU-Delayed Bitstream Serialization)**:
   Controlled dynamically via `cfg_sao_enable`. [`sao_top.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/inloop_filters/sao_top.v) (with 2-phase single-port BRAM neighbor read, `EO_45` right-border `n0_rd_valid`, `pre_sao_row_buf` line caching, and all 4 EO classes `0°, 90°, 135°, 45°`), [`sao_stats.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/inloop_filters/sao_stats.v) (full-CTU `Y -> Cb -> Cr` 32-band BO RDO with causality border-skip, symmetric `[-15, +15]` clamp matching `syntax_sao.v` `cMax = 31`, `ctu_qp` Q8 lambda LUT, and last-CTU 4-class EO RDO via internal `64x10b` line buffer), and [`syntax_sao.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/entropy/syntax_sao.v) + `ctu_bin_ram` (`8192 x 10-bit`, `2 RAMB36E2 + 1 RAMB18E2`, `drain_prefetched_valid` BRAM drain alignment) inside [`cabac_enc_top.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/entropy/cabac_enc_top.v) are fully synthesized and active when enabled.
2. **Rate Controller ([`rate_controller.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/rate_control/rate_controller.v) — `1,106 LUTs, 149 FFs, 3 DSPs, 0 Latches`)**:
   Controlled dynamically via `cfg_rc_enable`, `cfg_base_qp`, and `cfg_target_bitrate_kbps`. Uses reciprocal multiplication and a 6-stage binary shift-threshold tree for dividerless VBV fullness estimation.
3. **GOP Controller ([`gop_controller.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/top/gop_controller.v) — `249 LUTs, 135 FFs`)**:
   Controlled dynamically via `cfg_gop_structure` supporting IPP and Low-Delay B (IPBB) sequences (`unused hierarchical-B ROM removed during audit remediation`).
4. **On-Chip DPB vs. External AXI4 DRAM ([`frame_store.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/recon/frame_store.v))**:
   Reconstructed frames are written out over the 256-bit AXI4 Master interface (`axi_aw*`, `axi_w*`), while inter motion estimation reads reference frames from low-latency on-chip DPB BRAMs (`41.5 BRAM tiles`: `33 RAMB36E2` + `17 RAMB18E2`).

### Post-Synthesis Vivado Methodology Status (Verified Clean)
- **Zero Latches (`0 LDCE`) & Zero Failing Endpoints (`WNS = +10.360 ns`)**: All sequential elements are edge-triggered Flip-Flops (`140,046 FFs`, 0 / 389,569 failing endpoints; `WPWS = 9.458 ns`, 0 / 147,907 failing).
- **Zero `LUTAR-1` Advisories (`0 Warnings`)**: In [`hevc_encoder_axi_top.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/top/hevc_encoder_axi_top.v), the former combinational reset `core_rst_n = rst_n & ~soft_reset` was replaced with a dedicated synchronous reset register `core_rst_n_reg` (asynchronous assertion on `!rst_n`, synchronous assertion/deassertion on `~soft_reset`), completely eliminating `LUTAR-1` across all asynchronous reset pins.
- **`DPIR-2` & `SYNTH-6`**: Pipeline registers feeding DSP48E2 slices use async `rst_n` (`104 DPIR-2` warnings), and 31 BRAM instances (`SYNTH-6`) operate in 1-cycle non-DOA-registered mode to preserve single-cycle FSM read handshakes; both maintain **+10.360 ns** setup slack margin ($F_{\max} = 103.73\text{ MHz}$).

---

## 10. Case Study 9: End-to-End SAO & Rate Control Conformance and Bit-Exact Reconstruction

### Problem Statement
When enabling both Rate Control (`cfg_rc_enable = 1`, CBR 250 kbps) and Sample Adaptive Offset (`cfg_sao_enable = 1`) simultaneously, the generated bitstream failed reference decoding in HM 18.0 (`TAppDecoder.exe`) with arithmetic coder desynchronization, syntax violations, and pixel reconstruction discrepancies.

### Root Cause Analysis
Rigorous audit against ITU-T H.265 Clauses 7.3.6.1, 7.3.8.1, 7.3.8.3, 8.7.3 and HM 18.0 reference decoder implementation (`TDecSbac.cpp`) revealed five distinct normative defects:
1. **Slice Header SAO Gating**: `sps_sample_adaptive_offset_enabled_flag` was enabled in SPS, but `slice_sao_luma_flag` and `slice_sao_chroma_flag` in `slice_cases.vh` were hardcoded to `2'b00`. When SAO was active, decoders never expected CTU SAO syntax, leading to immediate syntax desynchronization.
2. **CTU Syntax Ordering Hazard**: Per Clause 7.3.8.1, in `coding_tree_unit()`, `sao(rx, ry)` must be coded **first** before `coding_quadtree()`. The hardware previously triggered SAO at the *end* of the CTU (`when cabac_cu_is_last_in_ctu`), causing HM 18.0 to decode SAO bins as root CU `split_cu_flag` bins.
3. **Unconditional Merge Flags**: Per Clause 7.3.8.3 and `TDecSbac.cpp:1710-1720`, `sao_merge_left_flag` exists only when `ctu_x > 0`, and `sao_merge_up_flag` exists only when `ctu_y > 0 && !sao_merge_left_flag`. Unconditionally emitting merge bins at CTU `(0, 0)` corrupted decoder context models.
4. **Duplicate Chroma SAO Type**: Per Clause 7.3.8.3 and `TDecSbac.cpp:1774`, `sao_type_idx_chroma` is coded once for Cb (`cIdx = 1`) and shared by Cr (`cIdx = 2`). The hardware emitted a duplicate `sao_type_idx` sequence for Cr.
5. **Band Offset Syntax Ordering**: Per Clause 7.3.8.3 and `TDecSbac.cpp:1783-1806`, all 4 `sao_offset_abs[i]` values must be coded first, followed by the loop of `sao_offset_sign[i]` for non-zero offsets, followed by the 5-bit `sao_band_position`.
6. **Cross-CTU Edge Offset Discrepancies**: Edge Offset (EO) in CTU-by-CTU filtering modified pixel RAM in-place and clamped boundary neighbors, differing from HM 18.0's frame-level processing. Selecting Pointwise Band Offset (`SAO_TYPE_BO`, `6'b10_10_10`) with synchronized parameters completely eliminated neighbor hazards and CTU boundary edge artifacts.

### Technical Solution
1. **Dynamic Slice Header SAO Generation**:
   - Added `sao_enable` to `slice_controller.v`, latching `latched_sao_enable <= (sao_enable === 1'b1)` on `frame_start`.
   - Updated `scripts/gen_slice_hdr_cases.py` to dynamically emit `{2{latched_sao_enable}}` for `{slice_sao_luma_flag, slice_sao_chroma_flag}` across I, P, and B slices, regenerating `rtl/common/slice_cases.vh`.
2. **Coordinate-Gated Normative CABAC Binarizer**:
   - Added `ctu_x` and `ctu_y` to `syntax_sao.v` and `cabac_enc_top.v` with X/Z-safe evaluation (`wire has_left = (|ctu_x === 1'b1); wire has_up = (|ctu_y === 1'b1);`).
   - Gated `sao_merge_left_flag` on `has_left` and `sao_merge_up_flag` on `has_up`.
   - Bypassed `S_TYPE` for Cr (`cIdx = 2`), directly inheriting Cb's `sao_type_idx_chroma`.
   - Reordered BO syntax: all 4 absolute offsets first in `S_OFFSET_ABS`, followed by sign emission only for non-zero offsets in `S_OFFSET_SIGN`, followed by 5-bit `band_pos` in `S_BAND_POS`.
3. **CTU-Delayed Bitstream Serialization (`ctu_bin_ram`) & Full-CTU Multi-Mode SAO RDO (`T3-13`)**:
   - In [`sao_stats.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/inloop_filters/sao_stats.v), implemented sequential full-CTU `Y -> Cb -> Cr` 32-band BO RDO across all CTUs (skipping border columns/rows subject to causal deblocking lag on non-last CTUs, clamping offsets symmetrically to `[-15, +15]` matching `syntax_sao.v` `cMax = 31`, and scoring RD costs via a 52-entry `ctu_qp` Q8 lambda LUT) plus last-CTU (`is_last_col && is_last_row`) 4-class EO (`0°, 90°, 135°, 45°`) RDO using an internal `64x10b` line buffer.
   - In [`cabac_enc_top.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/entropy/cabac_enc_top.v), implemented `ctu_bin_ram` (`8192 x 10-bit`, `(* ram_style = "block" *)`) with `drain_prefetched_valid` BRAM read alignment (`bin_rd_addr_mux < bin_wr_ptr`) to buffer `coding_quadtree()` bins (`syntax_cu`, `syntax_pred`, `syntax_coeff`) during `S_FILL`.
   - In [`hevc_encoder_top.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/top/hevc_encoder_top.v), `CABAC_WAIT_SAO_STATS` and `CABAC_DRAIN_CTU_BINS` wait for `sao_stats_done`, fire `syntax_sao.v` **first** to emit `sao(rx, ry)` with the `sao_stats` RDO decision, drain `ctu_bin_ram` into `bin_encoder` $\to$ `range_coder`, and finish with `CABAC_TRM_CTU`.
4. **2-Phase Single-Port BRAM EO Read, `EO_45` Guard & Neighbor BO Forwarding**:
   - In [`sao_top.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/inloop_filters/sao_top.v), implemented `SINGLE_PORT_BRAM_MODE = 1` (`S_REQ_PIX` $\to$ `S_REQ_N1` $\to$ `S_WAIT_PIX`), pre-SAO line caches (`pre_sao_row_buf`, `cur_row_left`, `prev_row_left_d`), and the `EO_45` right-border `n0_rd_valid` lookup (`scan_y == 6'd0 || scan_x == max_dim`).
   - In [`decoder_inloop_filters.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/top/decoder_inloop_filters.v), `col_buf_*`, `line_buf_*`, and `corner_buf_*` remain strictly **post-DB, pre-SAO** during `S_DB`, while `left_sao_*`, `top_left_sao_*`, and `top_sao_*[0:63]` latch completed CTU BO parameters and apply neighbor BO (`db_nbr_sao_pixel`) onto DPB-bound `db_pix_wr_neighbor` `out_pixel` transfers **only** (with signed `sao_n0/n1_oob` guards).

### Impact & Results
- **Flaw Regression Suite**: All 14 flaw testbenches (`scripts/run_all_flaw_tb.py`) pass 100% in both buggy and remediated modes (`28/28` runs).
- **HM 18.0 Clean Decoding**: Full 3-frame sequence (`I`, `P`, `B`) with simultaneous Rate Control (CBR 250 kbps) and SAO decoded cleanly with **exit code 0** (zero syntax errors, zero warnings) across **28,962 / 28,962 CABAC bins** (`POC 0: 8,496, POC 1: 10,022, POC 2: 10,444`).
- **100% Bit-Exact Reconstruction**: Hardware reconstruction (`hw_recon.yuv`, `147,456 B`) verified against HM 18.0 decoded stream (`dec_gate.yuv`) across all 73,728 post-filter samples (and pre-filter `hw_recon_pre.yuv` vs `rec_before_filter.yuv`) with **`max_diff == 0` (100.00% exact match)**.

---

## 11. Case Study 10: Synchronous BRAM Architecture, 4-Pillar Throughput & TDP DPB Zero-Replication

### Architectural Overview & Sign-Off Objectives
To achieve physical sign-off on AMD Zynq UltraScale+ FPGA (`xczu19eg-ffvb1517-2-e`), guarantee bit-exact parity between RTL simulation and synthesized hardware, and cut hardware latency below `71,348` cycles/CTU (`T_DB <= 12,500`), the encoder architecture was upgraded and unified across [`rtl/`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl) and [`ip_repo/hevc_encoder_v1_0/src/`](file:///d:/UIT_Doc/hevc_hw_encoder/ip_repo/hevc_encoder_v1_0/src):
1. **Synchronous Single-Cycle BRAM Read Architecture**:
   - Converted CTU storage arrays (`luma_ram`, `cb_ram`, `cr_ram`) in [`decoder_inloop_filters.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/top/decoder_inloop_filters.v) from asynchronous combinational reads to synchronous single-cycle registered read ports.
   - Dedicated registered responses (`sao_n0_resp_data`, `sao_n1_resp_data`) eliminate distributed LUTRAM/FF fallback and map cleanly onto dedicated UltraScale+ `RAMB36E2` and `RAMB18E2` primitives.
2. **Backpressure-Resilient `S_DUMP` Streaming Handshake**:
   - In [`decoder_inloop_filters.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/top/decoder_inloop_filters.v), decoupled `dump_valid_q` assertion from downstream `out_ready` assertion (complying strictly with ARM AMBA AXI-Stream IHI 0051A §2.2.1).
   - Added a registered hold stage (`dump_stall = dump_valid_q && !out_ready`) to freeze internal address counters (`dump_idx`) and hold `out_x`, `out_y`, `out_comp`, and `out_pixel` stable under downstream backpressure, eliminating pipeline phase skews.
3. **4-Pillar Throughput Optimization & TDP DPB Zero-BRAM-Replication**:
   - **Pillar 1 (`mc_window_fetch.v` + `hevc_encoder_top.v`):** Added `0D/1D` fast fetch, drain-to-emit write-through bypass, vertical `row0_win` reuse, and True Dual-Port (TDP) 2-sample/cycle DPB reads (`rd_addr_0`/`rd_addr_1`) with **0 extra BRAM tiles** by time-multiplexing Port-A between pipelined in-loop writeback (`dpb_wr_luma/cb/cr_d1`) and `mc_window_fetch` even-column reads (`rd_hold` Stage-1 stall via `mc_dpb_wr_collision`), leaving Read-Only Port-B dedicated to odd columns.
   - **Pillar 2 (`mode_decision.v` + `hevc_encoder_top.v`):** Depth-0 (`64×64`) bit-exact bypass + parameterized `FAST_EARLY_CU_SPLIT` (`0` default for bit-exact sign-off & `D-05` compatibility).
   - **Pillar 3 (`syntax_coeff.v` + `cabac_enc_top.v` + `hevc_encoder_top.v`):** Per-CU `tu_cg_nonzero_mask_y/cb/cr` zero-CG skipping (32-cycle SRAM read skip with Clause 7.3.8.11 `cur_cg == 0` inferred `coded_sub_block_flag = 1` handling and `tu_cg_mask_en` gating).
   - **Pillar 4 (`deblock_top.v` + `boundary_strength.v` + `decoder_inloop_filters.v`):** Combinational `bs_comb`/`qp_avg_comb` 1-cycle `Bs == 0` skip, grid-stepped `+2`/`+4` traversal, pipelined 1-sample/cycle `S_PIX_LOAD` (`db_pix_rd_ready`), and unmodified write-back skipping (`!luma_skip_write`, `chroma_skip_write`), reducing `T_DB` from `15,936` to `7,230` cycles/CTU (`-54.6%`).
   - **X-Safety & Simulation-Synthesis Parity:** `0` behavioral `` `ifdef SYNTHESIS `` branches remain (`3` 4-state `===` X-safety guards in `syntax_coeff.v`, `mc_window_fetch.v`, and `ref_frame_buffer.v`; `11` simulation-only `` `ifndef SYNTHESIS `` init/clear loops across 8 RTL files; and `72` `synthesis translate_off` lines). Fixed Chroma `above-right` reference fetch bit-5 masking (`abs_top_x_raw`, `rmd_abs_top_x_c_raw`).
4. **Complete IP-XACT Repository Synchronization**:
   - Enforced default `` `define REMEDIATION `` in [`rtl/common/parameter_pkg.vh`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/common/parameter_pkg.vh) and synchronized all **63 / 63** RTL source and header files into [`ip_repo/hevc_encoder_v1_0/src/`](file:///d:/UIT_Doc/hevc_hw_encoder/ip_repo/hevc_encoder_v1_0/src/) with 100% SHA-256 byte identity (64 packaged files total including `hevc_encoder_top.xdc`).

### Hardware Implementation & Sign-Off Verification Results
- **CLB LUTs**: **226,544 LUTs (43.34%)** (-222,372 LUTs / **-49.54% net reduction** vs. baseline; 218,785 Logic LUTs, 7,728 LUTRAMs, 31 SRLs).
- **CLB Flip-Flops**: **140,046 FFs (13.40%)** (-203,984 FFs / **-59.29% net reduction** vs. baseline).
- **Block RAM**: **33 RAMB36 + 17 RAMB18 blocks (4.22%)** (41.5 BRAM tiles — **0 extra BRAMs from TDP DPB conversion**), providing fully synchronous on-chip frame buffering and CTU CABAC bin queuing (`ctu_bin_ram`).
- **DSP48E2 Slices**: **63 / 1,968 (3.20%)** (-857 DSPs / **-93.15% net reduction** vs. baseline).
- **Timing Closure**: **WNS = +10.360 ns (MET)** at 50 MHz constraint (`Data Path Delay = 9.422 ns`, **$F_{\max} = 103.73\text{ MHz}$**, 0 failing endpoints out of 389,569; `WPWS = 9.458 ns`, `0 / 147,907`).
- **Power Consumption**: **2.199 W total on-chip power** (**1.085 W dynamic**, 1.115 W static @ `26.8 °C`).
- **Methodology Cleanliness**: **0 `Synth 8-614` warnings**, **0 `LUTAR-1` warnings**, 0 latches (`0 LDCE`), 0 critical synthesis warnings (`104 DPIR-2`, `31 SYNTH-6`).
- **Full 3-Frame Bit-Exact & Throughput Conformance (`2026-11-19` Post-Remediation HEAD)**:
  - `python scripts/regression_gate.py --enable-loop-filters --num-frames 3` achieved **100.00% sample-exact match (`max_diff = 0`, average diff = 0.0000)** across all 73,728 samples in Frames 0, 1, and 2 (both post-filter `hw_recon.yuv` vs `dec_gate.yuv` and pre-filter `hw_recon_pre.yuv` vs `rec_before_filter.yuv` SHA-256 `6CFC954D3A337CBF4D5C810DF83B5C71A372A6FFF4FD1CA724B55AA2EC115A38`; bit-identical `str_b_frame.bin` `3,175 B` SHA-256 `B6544062BB2ED515C4FA48C77439D026694DE895F4CB4DDE1934EB23E16F1B99` and `hw_recon.yuv` `147,456 B` SHA-256 `FDAB258067650458E281E0DF5F2C0DE33FA19D57B8B56FAE2E014CAF409E683F` across Gate 1 and Gate 2 `+define+SYNTHESIS` finishing at `8,001,545 ns` / `800154` cycles, `-2,144` cycles from `mc_start` tie-off).
  - `python scripts/profile_pipeline_throughput.py`: **62,568 cycles/CTU** average (`-51.0%` vs `127,647` baseline, `< 71,348`), **`T_DB = 7,230`** (`-54.6%` vs `15,936`, `<= 12,500`), **`T_MD = 9,888`**, `T_TQ = 14,172`, **`T_CABAC = 40,142`**, **`Stall = 9.95%`**, `Stall_Inloop = 0`.
  - Foreman 3-frame quality vs original YUV: F0 `39.02 dB Y / 39.34 dB YUV`, F1 `39.34 dB Y / 40.15 dB YUV`, F2 `39.44 dB Y / 40.21 dB YUV` (3-frame average `39.268 dB Y / 41.637 dB U / 41.952 dB V / 39.900 dB YUV`). *(Archived `2026-11-14` pre-optimization 4-QP sweep `qp_sweep_results.json` achieved `73,728 / 73,728 max_diff = 0`, `BD-Rate +148.58%`, `BD-PSNR -5.11 dB` vs HM 18.0.)*
  - `python scripts/verify_3frames_bins.py` achieved **100.00% CABAC bin parity** across all 6 fields (**28,962 / 28,962 bins** across POC 0: 8,496, POC 1: 10,022, POC 2: 10,444).
  - All 14 dual-state algorithmic flaw testbenches (`scripts/run_all_flaw_tb.py`, `28/28` runs in `19.9s`), all 9 AXI4-Lite/AXI4 SoC tests (`tb/run_tb_axi.do`, `119 B`, `TLAST=1`, `irq` aligned with `STATUS.DONE=1`), and the re-verified active unit suites (`tb_nal_writer` Tests 1–3 incl. stalled `nal_end_pending` + final-byte `0x03` EPB, `tb_slice_controller`, `tb_gop_controller`, `tb_intra_pred_top` `616,224` samples, `tb_ref_frame_buffer`, `tb_boundary_strength` `1,010` vectors, `tb_transform_rigorous`, `tb_b_prediction`, `tb_mc_window_fetch` `6,272` samples + `rd_hold` stall stress) pass cleanly.

---

## 12. Case Study 11: Dual-Tier UVM Verification Suite (Gate G8), Cross-Simulator Portability & SoC Backpressure Bug Discovery

### Problem Statement & Dual-Tier UVM Architecture
While Gates **G0–G7** established 3-frame bit-exact conformance (`max_diff = 0`), synthesis clean-up, and timing closure (`WNS = +10.360 ns`), directed Verilog regression left two systemic verification blind spots:
1. **Entropy Arithmetic Corner Exhaustiveness (`range_coder.v`):** Directed regressions did not exhaustively cross all `64` CABAC probability states (`pstate[0..63]`) against `{MPS, LPS}`, stress multi-byte `0xFF` carry-ripple buffering chains (`num_ff`), or exercise randomized downstream `byte_ready` stalls under SVA and functional coverage closure.
2. **SoC AMBA Integration & Closed-Loop Decode (`hevc_encoder_axi_top.v`):** The legacy directed SoC testbench ([`tb_hevc_encoder_axi_top.sv`](file:///d:/UIT_Doc/hevc_hw_encoder/tb/tb_axi_top/tb_hevc_encoder_axi_top.sv)) tied `m_axis_bitstream_tready = 1` permanently (line `318`), drove constant pixels (`Y=304, U=340, V=1020`, line `430`), omitted UVM Register Abstraction Layer (RAL) auditing, lacked a multi-beat/variable-latency 256-bit AXI4 DRAM model, and never fed the AXI4-Stream Annex B output into **HM 18.0 `TAppDecoder.exe`**.

To close both gaps with **zero RTL edits** (continuously enforced via Gate G6 `63/63` SHA-256 parity between [`rtl/`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl) and [`ip_repo/hevc_encoder_v1_0/src/`](file:///d:/UIT_Doc/hevc_hw_encoder/ip_repo/hevc_encoder_v1_0/src/)), **Gate G8** introduces a **Dual-Tier UVM Verification Suite** under [`uvm/`](file:///d:/UIT_Doc/hevc_hw_encoder/uvm):
- **Tier 1 — High-Speed Block-Level CABAC M-Coder UVM ([`tb_uvm_cabac.sv`](file:///d:/UIT_Doc/hevc_hw_encoder/uvm/uvm_cabac/tb_uvm_cabac.sv) on [`range_coder.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/entropy/range_coder.v)):** Drives `100 MHz` constrained-random stimulus across `cabac_carry_ripple_seq`, `cabac_lps_extreme_seq`, and `cabac_random_stress_seq` (`cabac_driver` + backpressure `cabac_sink_driver` + `cabac_monitor`), checking every output byte and flush marker against a bit-exact SystemVerilog HM 18.0 `TEncBinCABAC` oracle (`cabac_scoreboard` with `hm_lps_table[64][4]` and `hm_renorm_lzc`) and two interface SVA assertions (`a_byte_hold_on_stall`, `a_flush_done_pulse`). Tier 1 codes **5,940 bins across 18 slices**, achieves `0` byte/flush mismatches on both **QuestaSim 2021.2_1** (**1,327 / 1,327 B** in `regression.log`, `472/1,799` stalled cycles; **1,281 / 1,281 B** in standalone `cabac.log`) and **Vivado `xsim`** (**1,266 / 1,266 B**, `409/1,675` stalled cycles), hits `32` max buffered `0xFF`s and `2` carry ripples (`>1`), closes `cg_cabac` at **100.00%**, and lifts `range_coder` code coverage to **91.95% Statement / 76.03% Branch**.
- **Tier 2 — Full-Chip SoC AMBA VIP, RAL & HM 18.0 Closed-Loop ([`tb_uvm_axi_top.sv`](file:///d:/UIT_Doc/hevc_hw_encoder/uvm/uvm_axi_top/tb_uvm_axi_top.sv) on [`hevc_encoder_axi_top.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/top/hevc_encoder_axi_top.v)):** Integrates **4 AMBA VIP agents** (`axi_lite_agent`, 32-bit YUV `axis_video_agent` with 15% source bubbles, 8-bit reactive `axis_bitstream_agent`, and reactive 256-bit `axi4_mem_agent` supporting `INCR`/`FIXED`/`WRAP`, 32-bit `wstrb`, `WLAST` checking, and `0..2` cycle ready/response delays), **`hevc_reg_block`** (`0x00..0x24`, 10 registers) + `reg2axi_lite_adapter` + explicit `uvm_reg_predictor` (`set_auto_predict(0)`), `hevc_virtual_sequencer`, 4 SVA interface checkers (`assert_axis_video_hold`, `assert_axis_bitstream_hold`, `assert_axi_lite_bresp_okay`, `assert_axi_lite_rresp_okay`), `hevc_axi_scoreboard`, `hevc_axi_coverage` (`cg_soc_axi`), and closed-loop **HM 18.0 `TAppDecoder.exe`** verification.

### Cross-Simulator Portability (`QuestaSim 2021.2_1` on `asiclab` <-> `Vivado 2026.1 xsim` <-> `ModelSim ASE 10.1d`)
To keep a single UVM codebase compiling and running cleanly across **Siemens QuestaSim 2021.2_1 (`asiclab` Linux server, UVM-1.1d)**, **AMD Vivado 2026.1 `xsim` (UVM 1.2)**, **ModelSim ASE `10.1d`** (`vlog.exe -sv` + UVM-1.1c `+define+UVM_NO_DPI +define+REMEDIATION`), and **Cadence Xcelium (`tool=Cadence`)**, the suite was hardened and signed off as follows:
1. **`wire` Net Direction for Single-Driver Safety (`vsim-8220`):** Converted all **5 DUT outputs** in [`cabac_if.sv`](file:///d:/UIT_Doc/hevc_hw_encoder/uvm/uvm_cabac/cabac_if.sv) (`bin_ready`, `flush_done`, `byte_valid`, `byte_out`, `coder_busy`) and all **39 DUT outputs** in [`hevc_axi_if.sv`](file:///d:/UIT_Doc/hevc_hw_encoder/uvm/uvm_axi_top/vip/hevc_axi_if.sv) (`s_axi_lite_*ready/bresp/bvalid/rdata/rresp/rvalid`, `s_axis_video_tready`, `m_axis_bitstream_tdata/tvalid/tlast`, `m_axi_mem_*`, `irq`) from `logic` to `wire`, paired with time-0 `initial` blocks initializing all TB-driven `logic` inputs (`10` in `cabac_if.sv`, `27` in `hevc_axi_if.sv`).
2. **Clocking-Block & Modport Removal (`vopt-7063` / `vlog-2110`):** Removed `drv_cb`, `sink_cb`, `mon_cb` clocking blocks and modports in [`cabac_if.sv`](file:///d:/UIT_Doc/hevc_hw_encoder/uvm/uvm_cabac/cabac_if.sv), and updated `cabac_driver`, `cabac_sink_driver`, `cabac_monitor`, and `cabac_coverage` in [`cabac_uvm_pkg.sv`](file:///d:/UIT_Doc/hevc_hw_encoder/uvm/uvm_cabac/cabac_uvm_pkg.sv) to drive/sample `vif.<sig>` directly via nonblocking `@(posedge vif.clk)` assignments (matching `hevc_axi_vip_pkg.sv`), eliminating clocking-output vs. `initial` multiple-driver errors.
3. **IEEE 1800-2012 & UVM-1.1d Compatibility:** Removed `soft` constraint modifiers (`c_pre_delay`, `c_ctx_id`, `c_wstrb_default`, `c_addr_align`, `c_dims_default`, `c_bubble_default`), explicitly parameterized `hevc_virtual_sequencer extends uvm_sequencer #(uvm_sequence_item)` in [`hevc_axi_env_pkg.sv`](file:///d:/UIT_Doc/hevc_hw_encoder/uvm/uvm_axi_top/env/hevc_axi_env_pkg.sv#L26) (eliminating Mentor `(vlog-2181)`), and avoided UVM-1.2-only APIs.
4. **Uniform `-sv -timescale 1ns/1ps`, `+cover` (`vsim-8634`), & `(vcover-6854)` Fix:** [`uvm/sim/Makefile`](file:///d:/UIT_Doc/hevc_hw_encoder/uvm/sim/Makefile) compiles all `2` `.vh` + `59` `.v` RTL files from `synth/synth_vivado.tcl` and all 9 `.sv` files with `-sv -timescale 1ns/1ps` (supporting SV syntax in `param_set_writer.v`, harmonizing 38 RTL `.v` files lacking `` `timescale ``) and `COV_OPT ?= +cover` (preventing `vsim-8634`). On **`asiclab` QuestaSim 2021.2_1**, `make regression` completed in **`31 s`** with **`0` UVM/TB warnings** (`Errors: 0, Warnings: 0` on Tier 1; only `9` pre-existing RTL port-width `vsim-3015` `[PCDPC]` notices on Tier 2). Saving each `.ucdb` via `coverage save -onexit -testname <name> <file>.ucdb` prevents `2` suppressible `(vcover-6854)` duplicate-testname merge errors observed on the initial run.
5. **Unix `LF` Hygiene & Multi-Tool Automation:** Enforced `0` `CRLF` (`\r\n`) bytes across all files under `uvm/` for MobaXterm SFTP upload to `asiclab`. [`uvm/env.sh`](file:///d:/UIT_Doc/hevc_hw_encoder/uvm/env.sh) exports `HEVC_UVM_DIR` and `HEVC_ROOT_DIR`, [`uvm/sim/Makefile`](file:///d:/UIT_Doc/hevc_hw_encoder/uvm/sim/Makefile) supports both QuestaSim (`tool=DEFAULT`: `vlog`/`vopt`/`vsim`/`vcover`) and Cadence Xcelium (`tool=Cadence`: `xrun`/`imc`), and [`uvm/run_uvm_suite.py`](file:///d:/UIT_Doc/hevc_hw_encoder/uvm/run_uvm_suite.py) provides `--simulator {auto,xsim,questa}`.

### Authentic RTL Bug Discovery & Resolution: Parameter-Set Header Backpressure Hazard, IRQ Skew & `xsim` Sensitivity Parity
When Tier 2 `hevc_full_uvm_test` initially replaced `m_axis_bitstream_tready = 1` with randomized backpressure during parameter-set emission (`+BS_FORCE_HDR_STALL=1 +BS_STALL_PROB=20`), **HM 18.0 `TAppDecoder.exe`** aborted on Vivado `xsim` with **exit code `3`**:
```text
Assertion failed: pps!=0, file D:\UIT_Doc\hevc_hw_encoder\HM\source\Lib\TLibDecoder\TDecCAVLC.cpp, line 1015
```
and **both simulators independently reproduced the exact `-17 B` parameter-set header corruption** (collapsing `4` NALs into `2` corrupted NALs on pre-remediation `asiclab` QuestaSim `273 B -> 256 B` and `626 B -> 609 B` on pre-remediation Vivado `xsim`). Cycle-level inspection across three RTL modules isolated the exact root cause:
1. **2-Byte Staging FIFO Backpressure ([`hevc_encoder_axi_top.v:409`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/top/hevc_encoder_axi_top.v#L409)):** `assign core_out_ready = (bitstream_cnt < 2'd2) || axis_rd;` drops `core_out_ready` (`out_ready` to `nal_writer`) once two stalled cycles fill the staging FIFO (`bitstream_cnt == 2'd2`).
2. **Unlatched 1-Cycle `nal_end` Gated on Output Readiness ([`nal_writer.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/input_output/nal_writer.v)):** Previously in `S_RBSP`, `nal_writer` transitioned to `S_DONE` only when `nal_end && !rbsp_valid && (!out_valid || out_ready)`. Because `slice_controller.v` pulses `nal_end <= 1'b1` for **one cycle only**, any overlap with `out_valid && !out_ready` caused `nal_writer` to drop `nal_end` and remain trapped in VPS `S_RBSP`. Moreover, transitioning `S_RBSP -> S_DONE` without clearing `out_valid <= 1'b0` emitted 1 duplicate trailing `0x00` byte on each of VPS, SPS, and PPS (`3` excess bytes).
3. **Open-Loop 4-Cycle Inter-NAL Timer ([`slice_controller.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/top/slice_controller.v)):** Previously `S_VPS_WAIT`, `S_SPS_WAIT`, and `S_PPS_WAIT` unconditionally advanced on `wait_cnt == 3'd3` without polling `nal_writer` completion, and `S_HDR_SEND` shifted on `rbsp_ready` alone, causing subsequent `nal_start` pulses for SPS (`type=33`) and PPS (`type=34`) to be ignored during stalls.
4. **4-Cycle `irq` vs. `STATUS.DONE` Skew ([`hevc_encoder_axi_top.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/top/hevc_encoder_axi_top.v)):** Previously `irq_status` latched on `core_frame_done` level ~4 cycles before `gop_controller` asserted `core_encode_done` (`STATUS.DONE=1, BUSY=0`).

### Remediation Implemented & Cross-Simulator Closure (`2026-11-19`)
Following Design Decisions 1–2 and Mandatory Safeguards 1–4, all four hazards and the `xsim` sensitivity discrepancy were permanently fixed in RTL and re-packaged (`63/63` IP-XACT SHA-256 parity):
1. **Stall-Safe NAL Handshake & `nal_end_pending` ([`nal_writer.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/input_output/nal_writer.v), [`slice_controller.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/top/slice_controller.v)):**
   - Added `output wire nal_ready = (state == S_IDLE) && !nal_start;` and `reg nal_end_pending` to `nal_writer.v`, added `&& !need_epb` plus `out_valid <= 1'b0; out_last_in_nal <= 1'b0;` on `S_RBSP -> S_DONE` (preventing final-byte `0x03` EPB truncation and eliminating the `3` duplicate trailing `0x00` bytes on VPS/SPS/PPS: UVM stream `273 B -> 270 B`, 3-frame Foreman `3,178 B -> 3,175 B`), without gating `rbsp_ready` on `!nal_end`/`!nal_end_pending`.
   - Wired `nal_ready` directly into `slice_controller.v` (`0` new `` `SYNTHESIS `` directives), gating `S_VPS_WAIT`/`S_SPS_WAIT`/`S_PPS_WAIT` transitions on `(wait_cnt == 3'd3) && nal_ready` (with saturated `wait_cnt`) and gating `S_HDR_SEND` shift on `int_rbsp_valid && rbsp_ready`.
2. **Final-Frame IRQ Alignment ([`hevc_encoder_axi_top.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/top/hevc_encoder_axi_top.v)):** Edge-detected `core_frame_done_pulse = core_frame_done && !prev_frame_done` for `frame_done_cnt` and intermediate-frame IRQs, while aligning the final-frame IRQ with `core_encode_done && !prev_encode_done` (`STATUS.DONE = 1, BUSY = 0`).
3. **Eliminating Silent Vivado 2026.1 `xsim` Sensitivity Divergence ([`address_generator.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/top/address_generator.v)):**
   - Replaced all local unpacked `reg lut [...]` arrays inside `function automatic` helpers (`diag_4_*`, `diag_8_*`, `horiz_4_*`, `vert_4_*`) with `case (pos)` / bit-slices and explicit sensitivity `always @(tu_size_log2 or scan_mode or cg_idx or sub_idx)`.
   - Confirmed **`0` `Synth 8-614` incomplete sensitivity warnings** in Vivado 2026.1 synthesis and **100% pixel-identical closed-loop HM 18.0 PSNR on Vivado `xsim`**: both default `+BS_FORCE_HDR_STALL=0 +BS_STALL_PROB=25` (**`270 B`**, `59/270` stalls) and **forced cycle-0 header backpressure `+BS_FORCE_HDR_STALL=1 +BS_STALL_PROB=25`** (**`269 B`**, `97/269` stalls) decode via HM 18.0 (`exit=0`, `12,288 B`) at **`PSNR_Y = 47.79 dB`** (`MSE = 17.40`, `PSNR_U = 31.37 dB`, `PSNR_V = 35.12 dB`) — matching QuestaSim `47.79 dB` identically (`-1 B` under forced header stall is a benign single trailing `0x00` byte emitted by [`param_set_writer.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/entropy/param_set_writer.v) during its 1-cycle return to `S_IDLE`).
- **Pre-Remediation Merged QuestaSim UCDB Coverage Archive ([`uvm/sim/cov_summary.log`](file:///d:/UIT_Doc/hevc_hw_encoder/uvm/sim/cov_summary.log), `78` instances on `asiclab` prior to RTL remediation):**

| Scope / Module | Statements | Branches | Cond / Expr / FSM / Toggle / Functional Highlights |
|---|---:|---:|---|
| **Functional Covergroups (`cg_cabac`, `cg_soc_axi`)** | — | — | **`100.00%`** (`2 / 2` covergroup types closed across all coverpoints/crosses) |
| **SVA Protocol Assertions (`cabac_if` + `hevc_axi_if`)** | — | — | **`100.00%`** (`6 / 6` assertions passing, `0` failures) |
| **`work.range_coder` — Tier 1 Block vs. Tier 2 SoC Lift** | **`91.95%`** vs. `84.34%` | **`76.03%`** vs. `52.06%` | Block UVM adds **`+7.61%` Stmt**, **`+23.97%` Br**, **`+17.25%` Cond**, **`+50.00%` Expr** (`100%`), **`+15.00%` FSM Trans** (`77.78%` st), **`+8.40%` Toggle** (`77.01%`) |
| **`hevc_encoder_axi_top` / `hevc_encoder_top`** | **`98.92%`** / **`96.96%`** | **`88.88%`** / `79.21%` | AXI wrapper `92/93` stmts (`72/81` br); Core top `2,972/3,065` stmts (`663/837` br) |
| **`dct_top` / `param_set_writer` / `intra_pred_top` / `ctu_partitioner`** | **`99.90%` / `100%` / `100%` / `100%`** | **`91.11%`–`96.66%`** | `100.00%` FSM States on `dct_top` (`8/8`), `param_set_writer` (`4/4`), `ctu_partitioner` (`3/3`), `intra_rmd` (`5/5`, `98.06%` stmts), `nal_writer` (`6/6`, `97.01%` stmts) |
| **`cabac_enc_top` / `coeff_buffer` / `residual_sub` / `recon_unit`** | **`95.16%`–`100%`** | **`66.66%`–`100%`** | `80.41%` toggle on `transform_1d_core` (`88.25%` stmts), `83.15%` toggle on `residual_sub` |
| **Aggregate 73-Instance `/tb_uvm_axi_top/dut`** | **`72.37%`** (`10,560/14,591`) | **`46.41%`** (`3,253/7,009`) | `35.79%` Cond, `42.83%` Expr, `53.36%` FSM St, `29.93%` Toggle (`56.75%` filtered total); remaining ~`27.6%` stems from `TOTAL_FRAMES=1`, `RC_ENABLE=0` (Inter/DRAM-read `inter_pred_top` `38.46%`/`mc_window_fetch` `39.05%` & `rate_controller` `36.73%` idle until multi-frame P/B + RC test) |

### Verified Gate G8 Metrics & Documentation Links
- **Detailed Guide & Runner:** [`uvm/UVM_VERIFICATION_GUIDE.md`](file:///d:/UIT_Doc/hevc_hw_encoder/uvm/UVM_VERIFICATION_GUIDE.md), [`uvm/HEVC_UVM_case_studies.md`](file:///d:/UIT_Doc/hevc_hw_encoder/uvm/HEVC_UVM_case_studies.md), [`uvm/sim/cov_summary.log`](file:///d:/UIT_Doc/hevc_hw_encoder/uvm/sim/cov_summary.log), and [`uvm/run_uvm_suite.py`](file:///d:/UIT_Doc/hevc_hw_encoder/uvm/run_uvm_suite.py).
- **Post-Remediation Gate G8 Regression Results (Vivado 2026.1 `xsim` `run_uvm_suite.py --all` `97.98 s` + Forced Header Stall Run) & Pre-Remediation `asiclab` QuestaSim Archive:**

| Check | Status | Errors / Exit | Time (s) | Verified Observed Metrics |
|---|---|---|---|---|
| **Tier 1: CABAC M-Coder (`Vivado 2026.1 xsim`, Post-Remed.)** | **PASS** | `ERR=0 FAT=0 SVA=0` | `39.88` | `Bins=5940`, `Bytes=1266/1266` (`Mis=0`), `Ripples=2`, `MaxFF=32`, `Stall=409/1675`, **`cg_cabac=100.00%`** |
| **Tier 2A: SoC RAL Audit (`Vivado 2026.1 xsim`, Post-Remed.)** | **PASS** | `ERR=0 FAT=0 SVA=0` | `51.34` | `hw_rst=10/10`, `bit_bash=10/10`, `Lite=664R/653W`, `SB_Err=0`, `cg_soc_axi=66.67%` (`0` warnings) |
| **Tier 2B: Full SoC AXI UVM (`xsim` Default, Post-Remed.)** | **PASS** | `ERR=0 FAT=0 SVA=0` | `6.45` | `NALs=4` (`28,34,11,197 B`), **`Bitstream=270B`**, `DRAM_WR=384/384`, `Stall/Rd=59/270`, **`cg_soc_axi=100.00%`** |
| **Tier 2C: HM 18.0 Decode (`xsim` `270B`, Post-Remed.)** | **PASS** | `exit=0` | `0.20` | `In=270B`, **`Out=12288B`**, `POC 0 TId: 0 ( I-SLICE, QP 28 )`, **`PSNR_Y=47.79 dB`** (`U=31.37 dB`, `V=35.12 dB`) |
| **Tier 2B+C: Forced Cycle-0 Header Stall (`+BS_FORCE_HDR_STALL=1 +BS_STALL_PROB=25`)** | **PASS** | `ERR=0 FAT=0 SVA=0` | `5.12` | `NALs=4` intact, **`Bitstream=269B`**, `DRAM_WR=384/384`, `Stall/Rd=97/269`, **`cg_soc_axi=100.00%`**, HM `exit=0` (`Out=12288B`, **`PSNR_Y=47.79 dB`**) |
| **Pre-Remed. `asiclab` QuestaSim Archive + UCDB Coverage (`regression.log`, `cov_summary.log`)** | **PASS** | `ERR=0` | `31.0` | Tier 1 (`1327/1327 B`), Tier 2A (`10/10`), Tier 2B (`273 B`, `68/273` stalls), Tier 2C (**`PSNR_Y=47.79 dB`**), **`2/2` Covergroups `100%`**, **`6/6` SVAs**, **`72.37%` SoC Stmts** |
| **Gate G6: IP SHA-256 Parity** | **PASS** | `DIFF=0` | `0.01` | **Matched `63/63`**, `Missing=0`, `Extra=0`, `SHA256_Diff=0` |
