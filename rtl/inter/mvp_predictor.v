//=============================================================================
// mvp_predictor.v
// AMVP (Advanced Motion Vector Predictor) and Merge Candidate List Builder
//
// Mapped from HM source:
//   TLibCommon/TComDataCU.cpp :: fillMvpCand()
//   TLibCommon/TComDataCU.cpp :: getInterMergeCandidates()
//   TLibCommon/TComDataCU.cpp :: xAddMVPCandUnscaled()
//   TLibCommon/TComDataCU.cpp :: xCheckSimilarMotion()
//   TLibCommon/TComMotionInfo.h :: AMVPInfo, MvField
//
// HEVC spatial neighbor positions (relative to current CU):
//
//        B2  B1  B0
//        +---+---+
//   A1   |   CU  |
//   +----+-------+
//   A0   |  (below-left neighbor)
//
//   A1 = directly left        (highest priority for left group)
//   A0 = below-left           (second priority for left group)
//   B1 = directly above       (highest priority for above group)
//   B0 = above-right          (second priority for above group)
//   B2 = above-left           (fallback)
//
// AMVP algorithm (HM fillMvpCand, unscaled — same ref_idx only):
//
//   // Left group: check A0 then A1
//   for n in [A0, A1]:
//     if n.inter && n.ref_idx == target_ref_idx:
//       amvp[0] = n.mv;  break
//
//   // Above group: check B0 then B1 then B2
//   for n in [B0, B1, B2]:
//     if n.inter && n.ref_idx == target_ref_idx:
//       amvp[1] = n.mv;  break
//
//   De-duplicate: if both same, keep one and add zero
//   if amvp[0] == amvp[1]: amvp[1] = 0
//
//   Zero-pad to 2 candidates
//   while (pInfo->iN < 2) pInfo->m_acMvCand[pInfo->iN++] = MV(0,0)
//
// Merge candidate algorithm (HM getInterMergeCandidates, spatial only):
//
//   Priority order: A1, B1, B0, A0, B2
//   Duplicate checks (HEVC Spec 8.5.3.2.1):
//     B1 != A1
//     B0 != B1
//     A0 != A1
//     B2 != A1 && B2 != B1
//   TMVP: skipped (temporal MV pred from co-located frame)
//   Zero-pad to N_MERGE=5 candidates
//   while (cnt < N_MERGE): merge[cnt++] = {0, 0, ref_idx=0}
//
//
// Implementation:
//   Fully combinational candidate derivation, single-cycle registered output
//   Latency: 1 cycle (register stage only)
//   No TMVP (temporal MV prediction) — matches hardware simplification target
//
// Neighbor data input (5 neighbors, flat packed):
//   Index mapping:
//     NBR_A1=0, NBR_A0=1, NBR_B1=2, NBR_B0=3, NBR_B2=4
//   nbr_mv_x_flat [MV_W*5-1:0]:   nbr_mv_x[n] = flat[MV_W*n +: MV_W]
//   nbr_mv_y_flat [MV_W*5-1:0]:   (same)
//   nbr_ref_flat  [RIF_W*5-1:0]:  nbr_ref[n]  = flat[RIF_W*n +: RIF_W]
//   nbr_inter     [4:0]:           bit n = 1 if neighbor n is inter-coded
//
// Output:
//   amvp_mv_x/y [MV_W*2-1:0]:      two AMVP candidates (always valid)
//   merge_mv_x/y [MV_W*N_MERGE-1:0]: up to 5 merge candidates
//   merge_ref_flat[RIF_W*N_MERGE-1:0]: reference index per merge candidate
//   merge_valid [N_MERGE-1:0]:      which merge slots are non-padding
//=============================================================================

`include "parameter_pkg.vh"

module mvp_predictor #(
    parameter MV_W      = 10,   // signed MV bits (integer-pel), same as mc_unit
    parameter RIF_W     = 4,    // reference index bits (0..15)
    parameter N_MERGE   = 5,    // HEVC merge candidate count (spec max = 5)
    parameter N_NBR     = 5,    // spatial neighbors: A1, A0, B1, B0, B2

    // Neighbor index aliases — do not override
    parameter NBR_A1    = 0,
    parameter NBR_A0    = 1,
    parameter NBR_B1    = 2,
    parameter NBR_B0    = 3,
    parameter NBR_B2    = 4
)(
    input  wire clk,
    input  wire rst_n,
    input  wire valid_in,

    // Target reference index for AMVP candidate matching
    // HM: iRefIdx parameter of fillMvpCand()
    input  wire [RIF_W-1:0]       target_ref_idx,

    // Spatial neighbor CU motion data (5 neighbors, flat packed)
    input  wire [4:0]              nbr_inter,          // inter-coded flag
    input  wire [MV_W*N_NBR-1:0]  nbr_mv_x_flat,      // MV horizontal
    input  wire [MV_W*N_NBR-1:0]  nbr_mv_y_flat,      // MV vertical
    input  wire [RIF_W*N_NBR-1:0] nbr_ref_flat,        // reference index

    // AMVP output — 2 candidates (always present, zero-padded)
    output reg                     valid_out,
    output reg  [MV_W*2-1:0]       amvp_mv_x_flat,     // candidate 0 at [MV_W-1:0]
    output reg  [MV_W*2-1:0]       amvp_mv_y_flat,

    // Merge output — up to N_MERGE candidates
    output reg  [N_MERGE-1:0]           merge_valid,    // 1=real candidate, 0=zero-pad
    output reg  [MV_W*N_MERGE-1:0]      merge_mv_x_flat,
    output reg  [MV_W*N_MERGE-1:0]      merge_mv_y_flat,
    output reg  [RIF_W*N_MERGE-1:0]     merge_ref_flat
);

    // =========================================================================
    // Neighbor unpack helpers (combinational)
    // =========================================================================
    function signed [MV_W-1:0] nbr_mvx;
        input [MV_W*N_NBR-1:0] flat;
        input integer           n;
        begin nbr_mvx = flat[MV_W*n +: MV_W]; end
    endfunction

    function signed [MV_W-1:0] nbr_mvy;
        input [MV_W*N_NBR-1:0] flat;
        input integer           n;
        begin nbr_mvy = flat[MV_W*n +: MV_W]; end
    endfunction

    function [RIF_W-1:0] nbr_ref;
        input [RIF_W*N_NBR-1:0] flat;
        input integer            n;
        begin nbr_ref = flat[RIF_W*n +: RIF_W]; end
    endfunction

    // =========================================================================
    // Extract specific neighbors for cleaner logic
    // =========================================================================
    wire signed [MV_W-1:0] mvx_A1 = nbr_mvx(nbr_mv_x_flat, NBR_A1);
    wire signed [MV_W-1:0] mvy_A1 = nbr_mvy(nbr_mv_y_flat, NBR_A1);
    wire [RIF_W-1:0]       ref_A1 = nbr_ref(nbr_ref_flat,  NBR_A1);
    wire                   avl_A1 = nbr_inter[NBR_A1];

    wire signed [MV_W-1:0] mvx_A0 = nbr_mvx(nbr_mv_x_flat, NBR_A0);
    wire signed [MV_W-1:0] mvy_A0 = nbr_mvy(nbr_mv_y_flat, NBR_A0);
    wire [RIF_W-1:0]       ref_A0 = nbr_ref(nbr_ref_flat,  NBR_A0);
    wire                   avl_A0 = nbr_inter[NBR_A0];

    wire signed [MV_W-1:0] mvx_B1 = nbr_mvx(nbr_mv_x_flat, NBR_B1);
    wire signed [MV_W-1:0] mvy_B1 = nbr_mvy(nbr_mv_y_flat, NBR_B1);
    wire [RIF_W-1:0]       ref_B1 = nbr_ref(nbr_ref_flat,  NBR_B1);
    wire                   avl_B1 = nbr_inter[NBR_B1];

    wire signed [MV_W-1:0] mvx_B0 = nbr_mvx(nbr_mv_x_flat, NBR_B0);
    wire signed [MV_W-1:0] mvy_B0 = nbr_mvy(nbr_mv_y_flat, NBR_B0);
    wire [RIF_W-1:0]       ref_B0 = nbr_ref(nbr_ref_flat,  NBR_B0);
    wire                   avl_B0 = nbr_inter[NBR_B0];

    wire signed [MV_W-1:0] mvx_B2 = nbr_mvx(nbr_mv_x_flat, NBR_B2);
    wire signed [MV_W-1:0] mvy_B2 = nbr_mvy(nbr_mv_y_flat, NBR_B2);
    wire [RIF_W-1:0]       ref_B2 = nbr_ref(nbr_ref_flat,  NBR_B2);
    wire                   avl_B2 = nbr_inter[NBR_B2];

    // =========================================================================
    // AMVP candidate derivation (combinational)
    // =========================================================================
    reg signed [MV_W-1:0] amvp_c0_x, amvp_c0_y; // left group winner
    reg                    amvp_c0_found;
    reg signed [MV_W-1:0] amvp_c1_x, amvp_c1_y; // above group winner
    reg                    amvp_c1_found;

    always @(*) begin : amvp_left
        // HEVC AMVP Left Group: A0 then A1
        amvp_c0_x     = {MV_W{1'b0}};
        amvp_c0_y     = {MV_W{1'b0}};
        amvp_c0_found = 1'b0;

        if (avl_A0 && (ref_A0 == target_ref_idx)) begin
            amvp_c0_x     = mvx_A0;
            amvp_c0_y     = mvy_A0;
            amvp_c0_found = 1'b1;
        end else if (avl_A1 && (ref_A1 == target_ref_idx)) begin
            amvp_c0_x     = mvx_A1;
            amvp_c0_y     = mvy_A1;
            amvp_c0_found = 1'b1;
        end
    end

    always @(*) begin : amvp_above
        // HEVC AMVP Above Group: B0 then B1 then B2
        amvp_c1_x     = {MV_W{1'b0}};
        amvp_c1_y     = {MV_W{1'b0}};
        amvp_c1_found = 1'b0;

        if (avl_B0 && (ref_B0 == target_ref_idx)) begin
            amvp_c1_x     = mvx_B0;
            amvp_c1_y     = mvy_B0;
            amvp_c1_found = 1'b1;
        end else if (avl_B1 && (ref_B1 == target_ref_idx)) begin
            amvp_c1_x     = mvx_B1;
            amvp_c1_y     = mvy_B1;
            amvp_c1_found = 1'b1;
        end else if (avl_B2 && (ref_B2 == target_ref_idx)) begin
            amvp_c1_x     = mvx_B2;
            amvp_c1_y     = mvy_B2;
            amvp_c1_found = 1'b1;
        end
    end

    // De-duplicate: if both found and identical, replace second with zero
    // HM: if (pInfo->iN == 2 && pInfo->m_acMvCand[0] == pInfo->m_acMvCand[1])
    //         pInfo->iN = 1  (then zero-padded back to 2)
    wire amvp_dup = amvp_c0_found && amvp_c1_found
                 && (amvp_c0_x == amvp_c1_x) && (amvp_c0_y == amvp_c1_y);

    reg signed [MV_W-1:0] amvp_out0_x;
    reg signed [MV_W-1:0] amvp_out0_y;
    reg signed [MV_W-1:0] amvp_out1_x;
    reg signed [MV_W-1:0] amvp_out1_y;

    always @(*) begin
        amvp_out0_x = {MV_W{1'b0}};
        amvp_out0_y = {MV_W{1'b0}};
        amvp_out1_x = {MV_W{1'b0}};
        amvp_out1_y = {MV_W{1'b0}};

        if (amvp_c0_found) begin
            amvp_out0_x = amvp_c0_x;
            amvp_out0_y = amvp_c0_y;
            if (amvp_c1_found && !amvp_dup) begin
                amvp_out1_x = amvp_c1_x;
                amvp_out1_y = amvp_c1_y;
            end
        end else if (amvp_c1_found) begin
            amvp_out0_x = amvp_c1_x;
            amvp_out0_y = amvp_c1_y;
        end
    end

    // =========================================================================
    // Merge candidate derivation (combinational)
    //
    // HM getInterMergeCandidates(): spatial candidates in priority order:
    //   A1, B1, B0, A0, B2  (note: different from AMVP order!)
    // Duplicate check: xCheckSimilarMotion() — same mv AND ref_idx
    // Zero-pad to N_MERGE=5
    // =========================================================================

    // HEVC strict pruning checks (Spec 8.5.3.2.1):
    // B1 != A1, B0 != B1, A0 != A1, B2 != A1 && B2 != B1
    // =========================================================================
    wire match_B1_A1 = (mvx_B1 == mvx_A1) && (mvy_B1 == mvy_A1) && (ref_B1 == ref_A1);
    wire match_B0_B1 = (mvx_B0 == mvx_B1) && (mvy_B0 == mvy_B1) && (ref_B0 == ref_B1);
    wire match_A0_A1 = (mvx_A0 == mvx_A1) && (mvy_A0 == mvy_A1) && (ref_A0 == ref_A1);
    wire match_B2_A1 = (mvx_B2 == mvx_A1) && (mvy_B2 == mvy_A1) && (ref_B2 == ref_A1);
    wire match_B2_B1 = (mvx_B2 == mvx_B1) && (mvy_B2 == mvy_B1) && (ref_B2 == ref_B1);

    wire add_A1 = avl_A1;
    wire add_B1 = avl_B1 && !(avl_A1 && match_B1_A1);
    wire add_B0 = avl_B0 && !(avl_B1 && match_B0_B1);
    wire add_A0 = avl_A0 && !(avl_A1 && match_A0_A1);
    wire add_B2 = avl_B2 && !(avl_A1 && match_B2_A1) && !(avl_B1 && match_B2_B1);

    // Merge candidate slots (combinational)
    reg signed [MV_W-1:0] mc_x  [0:N_MERGE-1];
    reg signed [MV_W-1:0] mc_y  [0:N_MERGE-1];
    reg [RIF_W-1:0]        mc_r  [0:N_MERGE-1];
    reg [N_MERGE-1:0]      mc_v;   // valid (non-pad) flag per slot
    reg [$clog2(N_MERGE):0] mc_cnt;

    

    always @(*) begin : merge_derive
        integer i;
        // Initialize
        mc_cnt = 0;
        mc_v   = {N_MERGE{1'b0}};
        for (i = 0; i < N_MERGE; i = i + 1) begin
            mc_x[i] = {MV_W{1'b0}};
            mc_y[i] = {MV_W{1'b0}};
            mc_r[i] = {RIF_W{1'b0}};
        end

        // Pack active candidates densely (Synthesis inferred as a priority encoder/multiplexer cascade)
        if (add_A1) begin
            mc_x[mc_cnt] = mvx_A1; mc_y[mc_cnt] = mvy_A1; mc_r[mc_cnt] = ref_A1;
            mc_v[mc_cnt] = 1'b1; mc_cnt = mc_cnt + 1;
        end
        if (add_B1 && mc_cnt < N_MERGE) begin
            mc_x[mc_cnt] = mvx_B1; mc_y[mc_cnt] = mvy_B1; mc_r[mc_cnt] = ref_B1;
            mc_v[mc_cnt] = 1'b1; mc_cnt = mc_cnt + 1;
        end
        if (add_B0 && mc_cnt < N_MERGE) begin
            mc_x[mc_cnt] = mvx_B0; mc_y[mc_cnt] = mvy_B0; mc_r[mc_cnt] = ref_B0;
            mc_v[mc_cnt] = 1'b1; mc_cnt = mc_cnt + 1;
        end
        if (add_A0 && mc_cnt < N_MERGE) begin
            mc_x[mc_cnt] = mvx_A0; mc_y[mc_cnt] = mvy_A0; mc_r[mc_cnt] = ref_A0;
            mc_v[mc_cnt] = 1'b1; mc_cnt = mc_cnt + 1;
        end
        if (add_B2 && mc_cnt < 4) begin
            mc_x[mc_cnt] = mvx_B2; mc_y[mc_cnt] = mvy_B2; mc_r[mc_cnt] = ref_B2;
            mc_v[mc_cnt] = 1'b1; mc_cnt = mc_cnt + 1;
        end
    end

    // =========================================================================
    // Output register — latch all combinational results
    // Latency: 1 cycle
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin : output_reg
        integer i;
        if (!rst_n) begin
            valid_out        <= 1'b0;
            amvp_mv_x_flat   <= {(MV_W*2){1'b0}};
            amvp_mv_y_flat   <= {(MV_W*2){1'b0}};
            merge_valid      <= {N_MERGE{1'b0}};
            merge_mv_x_flat  <= {(MV_W*N_MERGE){1'b0}};
            merge_mv_y_flat  <= {(MV_W*N_MERGE){1'b0}};
            merge_ref_flat   <= {(RIF_W*N_MERGE){1'b0}};
        end else begin
            valid_out <= valid_in;

            // AMVP: 2 candidates (zero-padded if not found)
            amvp_mv_x_flat[MV_W*0 +: MV_W] <= amvp_out0_x;
            amvp_mv_x_flat[MV_W*1 +: MV_W] <= amvp_out1_x;
            amvp_mv_y_flat[MV_W*0 +: MV_W] <= amvp_out0_y;
            amvp_mv_y_flat[MV_W*1 +: MV_W] <= amvp_out1_y;

            // Merge: up to 5 candidates (zero-padded)
            merge_valid <= mc_v;
            for (i = 0; i < N_MERGE; i = i + 1) begin
                merge_mv_x_flat[MV_W*i +: MV_W]  <= mc_x[i];
                merge_mv_y_flat[MV_W*i +: MV_W]  <= mc_y[i];
                merge_ref_flat [RIF_W*i +: RIF_W] <= mc_r[i];
            end
        end
    end

    // =========================================================================
    // Simulation assertions
    // =========================================================================
    // synthesis translate_off
    always @(posedge clk) begin : checks
        integer k, total_valid;
        if (valid_out) begin
            // AMVP must always have exactly 2 candidates (possibly zero-padded)
            // No action needed — always outputs 2 by construction

            // Merge: count valid candidates
            total_valid = 0;
            for (k = 0; k < N_MERGE; k = k + 1)
                if (merge_valid[k]) total_valid = total_valid + 1;

            // $display("INFO [mvp_predictor] AMVP: (%0d,%0d) (%0d,%0d) | Merge: %0d real candidates",
            //          $signed(amvp_mv_x_flat[MV_W-1:0]),
            //          $signed(amvp_mv_y_flat[MV_W-1:0]),
            //          $signed(amvp_mv_x_flat[MV_W*2-1:MV_W]),
            //          $signed(amvp_mv_y_flat[MV_W*2-1:MV_W]),
            //          total_valid);

            // Warn if no spatial candidates found (all zero-padded)
            if (total_valid == 0 && |nbr_inter)
                $display("WARN [mvp_predictor] all %0d inter neighbors skipped (possible ref_idx mismatch or duplicate pruning)", nbr_inter[0] + nbr_inter[1] + nbr_inter[2] + nbr_inter[3] + nbr_inter[4]);
        end
    end
    // synthesis translate_on

endmodule