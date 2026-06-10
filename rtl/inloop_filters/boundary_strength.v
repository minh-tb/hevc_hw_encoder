//=============================================================================
// boundary_strength.v
// Deblocking Filter — Boundary Strength (BS) Calculation
//
// Mapped from HM source:
//   TLibCommon/TComLoopFilter.cpp
//   xCalculateBSForCTU()     — BS per 4×4 edge grid
//   xGetBoundaryStrengthSingle() — single edge BS decision
//
// HEVC spec: Section 8.7.2 (deblocking filter process)
//
// BS values:
//   BS=0: no filtering on this edge
//   BS=1: inter edge — filter if residual or MV/ref difference
//   BS=2: intra edge — always filter (stronger filter candidates)
//
// BS decision rules (spec Table 8-10):
//
//   For each vertical or horizontal 4×4 boundary between block P and Q:
//
//   BS=2 if:
//     - P or Q is intra-coded (pred_mode == PRED_INTRA)
//
//   BS=1 if (both P and Q are inter):
//     - P and Q use different reference pictures (ref_idx mismatch), OR
//     - |MVx_P - MVx_Q| >= 1 integer pel (>= 4 in quarter-pel units), OR
//     - |MVy_P - MVy_Q| >= 1 integer pel, OR
//     - P has residual (cbf != 0) OR Q has residual
//
//   BS=0 otherwise
//
// Config:
//   LoopFilterDisable  = 0  (filtering enabled)
//   LoopFilterOffsetInPPS = 1 (constant offsets — no per-slice delta)
//   DB_BETA_OFFSET     = 0
//   DB_TC_OFFSET       = 0
//
// Architecture:
//   Input: CU info pairs (P side and Q side) for each 4×4 boundary
//   Output: BS[0..1] for each boundary (2-bit: 0,1,2)
//
//   For a CTU boundary grid:
//     Vertical edges:   W/4 columns × H/4 rows of 4×4 blocks
//     Horizontal edges: W/4 columns × H/4 rows of 4×4 blocks
//   For 64×64 CTU: 16×16 = 256 vertical edges + 256 horizontal edges
//
//   Processing: one boundary per cycle (serial)
//   Latency: 1 cycle per boundary (combinational BS, registered output)
//=============================================================================

`include "parameter_pkg.vh"
`include "hevc_interfaces.vh"

module boundary_strength (
    input  wire         clk,
    input  wire         rst_n,

    //-------------------------------------------------------------------------
    // Input: P-side and Q-side CU info for one 4×4 boundary
    // Driven serially by deblock_top for each edge in the CTU grid
    //-------------------------------------------------------------------------
    input  wire         in_valid,
    output wire         in_ready,

    // Boundary classification
    input  wire         is_vertical,     // 1=vertical edge, 0=horizontal edge
    input  wire         is_ctu_boundary, // 1=CTU-to-CTU edge (always calculate)

    // P-side block info (left/above block)
    input  wire         p_is_intra,
    input  wire [5:0]   p_qp,
    input  wire         p_cbf_luma,      // coded block flag (luma)
    input  wire         p_cbf_chroma,
    input  wire [2:0]   p_ref_idx_l0,   // reference index list 0
    input  wire [2:0]   p_ref_idx_l1,
    input  wire         p_bi_pred,       // 1=bi-prediction (both L0+L1 active)
    input  wire signed [15:0] p_mvx_l0, // MV in quarter-pel units (16-bit = TComMv)
    input  wire signed [15:0] p_mvy_l0,
    input  wire signed [15:0] p_mvx_l1,
    input  wire signed [15:0] p_mvy_l1,

    // Q-side block info (right/below block)
    input  wire         q_is_intra,
    input  wire [5:0]   q_qp,
    input  wire         q_cbf_luma,
    input  wire         q_cbf_chroma,
    input  wire [2:0]   q_ref_idx_l0,
    input  wire [2:0]   q_ref_idx_l1,
    input  wire         q_bi_pred,
    input  wire signed [15:0] q_mvx_l0,
    input  wire signed [15:0] q_mvy_l0,
    input  wire signed [15:0] q_mvx_l1,
    input  wire signed [15:0] q_mvy_l1,

    // Edge QP (average of P and Q, used downstream by filter)
    // HM: QpY = (p_qp + q_qp + 1) >> 1
    output reg  [5:0]   edge_qp,

    //-------------------------------------------------------------------------
    // Output: boundary strength for this edge
    //-------------------------------------------------------------------------
    output reg          out_valid,
    input  wire         out_ready,
    output reg  [1:0]   bs            // 0=none, 1=weak candidate, 2=strong candidate
);

    //-------------------------------------------------------------------------
    // MV difference threshold
    // HM: |MV_P - MV_Q| >= 4 (quarter-pel) = 1 integer pel
    //-------------------------------------------------------------------------
    localparam MV_THRESH = 16'sd4;   // 1 integer pel in qpel units

    //-------------------------------------------------------------------------
    // Handshake
    //-------------------------------------------------------------------------
    assign in_ready = out_ready | ~out_valid;

    //-------------------------------------------------------------------------
    // BS computation — combinational
    //
    // HM xGetBoundaryStrengthSingle() logic:
    //   1. Intra check (BS=2)
    //   2. Residual check (BS=1)
    //   3. Reference picture / MV check (BS=1)
    //   4. Default BS=0
    //
    // MV comparison (HM): for bi-pred, compare both L0 and L1 MVs
    // considering that L0/L1 reference frames may be swapped between P and Q
    //-------------------------------------------------------------------------

    // -----------------------------------------------------------------------
    // Step 1: Intra → BS=2
    // -----------------------------------------------------------------------
    wire bs2 = p_is_intra || q_is_intra;

    // -----------------------------------------------------------------------
    // Step 2: Residual present → BS=1
    // -----------------------------------------------------------------------
    wire has_residual = p_cbf_luma || q_cbf_luma;

    // -----------------------------------------------------------------------
    // Step 3: Reference picture difference → BS=1
    // HM: number of references differs OR ref_idx differs
    // p_bi_pred: P uses both L0 and L1 (2 refs)
    // q_bi_pred: Q uses both L0 and L1
    // If one is uni and other is bi → different ref count → BS=1
    // -----------------------------------------------------------------------
    wire ref_count_diff = (p_bi_pred != q_bi_pred);

    // Same-count case: compare ref indices
    // Uni-pred: both use L0 (or one uses L1) — compare as same list
    // HM compares (p_l0_ref == q_l0_ref) AND (p_l1_ref == q_l1_ref) for bi
    // For uni: (p_l0_ref == q_l0_ref)

    // Consider both normal and swapped L0/L1 (HM allows ref list swap)
    // Case A: P_L0↔Q_L0 and P_L1↔Q_L1 (straight match)
    // Case B: P_L0↔Q_L1 and P_L1↔Q_L0 (swapped lists)
    wire ref_straight_match = (p_ref_idx_l0 == q_ref_idx_l0) &&
                               (p_ref_idx_l1 == q_ref_idx_l1);
    wire ref_swap_match     = (p_ref_idx_l0 == q_ref_idx_l1) &&
                               (p_ref_idx_l1 == q_ref_idx_l0);

    wire ref_match = !ref_count_diff &&
                     (ref_straight_match || ref_swap_match);

    wire ref_diff = !ref_match;

    // -----------------------------------------------------------------------
    // Step 4: MV difference → BS=1
    // Threshold: |delta_MV| >= 4 (qpel units = 1 integer pel)
    //
    // HM: checks both components (x and y)
    // For bi-pred: check straight-matched MVs first, then swapped
    //
    // MV difference absolute value helper
    // -----------------------------------------------------------------------
    function automatic mv_diff_ge;
        input signed [15:0] a, b;
        reg signed [16:0] diff;
        begin
            diff = a - b;
            mv_diff_ge = (diff >= 17'sd4) || (diff <= -17'sd4);
        end
    endfunction

    // Straight case: P_L0 vs Q_L0
    wire mv_l0_x_diff = mv_diff_ge(p_mvx_l0, q_mvx_l0);
    wire mv_l0_y_diff = mv_diff_ge(p_mvy_l0, q_mvy_l0);
    wire mv_l1_x_diff = mv_diff_ge(p_mvx_l1, q_mvx_l1);
    wire mv_l1_y_diff = mv_diff_ge(p_mvy_l1, q_mvy_l1);

    // Swapped case: P_L0 vs Q_L1
    wire mv_sw_l0l1_x = mv_diff_ge(p_mvx_l0, q_mvx_l1);
    wire mv_sw_l0l1_y = mv_diff_ge(p_mvy_l0, q_mvy_l1);
    wire mv_sw_l1l0_x = mv_diff_ge(p_mvx_l1, q_mvx_l0);
    wire mv_sw_l1l0_y = mv_diff_ge(p_mvy_l1, q_mvy_l0);

    // MV differs in straight orientation
    wire mv_straight_diff = mv_l0_x_diff || mv_l0_y_diff ||
                             (p_bi_pred && q_bi_pred &&
                              (mv_l1_x_diff || mv_l1_y_diff));

    // MV differs in swapped orientation
    wire mv_swap_diff = mv_sw_l0l1_x || mv_sw_l0l1_y ||
                        mv_sw_l1l0_x || mv_sw_l1l0_y;

    // For bi-pred with same refs: no MV diff if either straight or swapped matches
    wire mv_diff = (p_bi_pred && q_bi_pred) ?
                   ( (ref_straight_match && ref_swap_match) ? (mv_straight_diff && mv_swap_diff) :
                     ref_straight_match                     ? mv_straight_diff :
                     ref_swap_match                         ? mv_swap_diff :
                     1'b1 ) :
                   mv_straight_diff;

    // -----------------------------------------------------------------------
    // BS combinational result
    // -----------------------------------------------------------------------
    wire [1:0] bs_comb =
        bs2                             ? 2'd2 :   // intra
        (has_residual || ref_diff || mv_diff) ? 2'd1 :   // inter diff
        2'd0;                                       // no filtering

    // -----------------------------------------------------------------------
    // Edge QP calculation
    // HM: QpY = (pQp + qQp + 1) >> 1  (average, rounded up)
    // -----------------------------------------------------------------------
    wire [6:0] qp_sum  = {1'b0, p_qp} + {1'b0, q_qp} + 7'd1;
    wire [5:0] qp_avg  = qp_sum[6:1];   // >> 1

    //-------------------------------------------------------------------------
    // Output register
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            bs        <= 2'd0;
            edge_qp   <= 6'd0;
        end else if (in_ready) begin
            out_valid <= in_valid;
            if (in_valid) begin
                bs      <= bs_comb;
                edge_qp <= qp_avg;
            end
        end
    end

    //-------------------------------------------------------------------------
    // Simulation checks
    //-------------------------------------------------------------------------
    // synthesis translate_off
    always @(posedge clk) begin
        if (rst_n && in_valid && in_ready) begin
            if (p_qp > `QP_MAX || q_qp > `QP_MAX)
                $display("WARN  [boundary_strength] QP out of range P=%0d Q=%0d time=%0t",
                         p_qp, q_qp, $time);
        end
    end
    // synthesis translate_on

endmodule