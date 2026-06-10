//=============================================================================
// db_filter_luma.v
// Deblocking Filter — Luma Edge Filter
//
// Mapped from HM source:
//   TLibCommon/TComLoopFilter.cpp
//   xEdgeFilterLuma()         — outer loop over 4-sample groups
//   xPelFilterLuma()          — per-sample filter decision and application
//
// HEVC spec: Section 8.7.2.4 (filtering process for luma samples)
//
// Algorithm overview:
//   For each 4-sample group along an edge (4 groups per 16-sample edge):
//
//   1. Load 4 samples each side: p[0..3], q[0..3]
//      p0 is closest to boundary, p3 is furthest
//
//   2. Compute thresholds from edge_qp (from boundary_strength):
//      beta = Beta[edge_qp + beta_offset]   (offset=0 from config)
//      tc   = Tc[edge_qp + tc_offset]       (offset=0 from config)
//
//   3. Decision: use strong filter or weak filter?
//      d  = |p2-2*p1+p0| + |q2-2*q1+q0|   (second derivative)
//      dp = |p2-2*p1+p0|
//      dq = |q2-2*q1+q0|
//
//      Strong filter condition (all must hold):
//        d    < beta/8
//        |p3-p0| + |q3-q0| < beta/8
//        |p0-q0| < (5*tc+1)/2
//
//      Weak filter condition:
//        d < beta
//
//   4a. Strong filter (BS=2 or strong condition met with BS=1):
//       p[0] = (p2 + 2*p1 + 2*p0 + 2*q0 + q1 + 4) >> 3
//       p[1] = (p2 + p1  + p0  + q0 + 2)           >> 2
//       p[2] = (2*p3 + 3*p2 + p1 + p0 + q0 + 4)    >> 3
//       q[0] = (p1 + 2*p0 + 2*q0 + 2*q1 + q2 + 4)  >> 3
//       q[1] = (p0 + q0   + q1   + q2 + 2)          >> 2
//       q[2] = (p0 + q0 + q1 + 3*q2 + 2*q3 + 4)     >> 3
//
//   4b. Weak filter (BS=1):
//       delta = Clip3(-tc, tc,
//               ((9*(q0-p0) - 3*(q1-p1) + 8) >> 4))
//       p[0] = Clip1(p0 + delta)    if |2*p1-p2-p0| < 10*tc
//       q[0] = Clip1(q0 - delta)    if |2*q1-q2-q0| < 10*tc
//       deltap = Clip3(-tc/2, tc/2, ( ((p2+p0+1)>>1) - p1 + delta) >> 1)
//       deltaq = Clip3(-tc/2, tc/2, ( ((q2+q0+1)>>1) - q1 - delta) >> 1)
//       p[1] = Clip1(p1 + deltap)   conditional
//       q[1] = Clip1(q1 - deltaq)   conditional
//
// Beta/Tc tables (HEVC spec Table 8-11, clipped to QP 0..51):
//   Beta[qp]: 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
//              6 7 8 9 10 11 12 13 14 15 16 17 18 20 22 24
//              26 28 30 32 34 36 38 40 42 44 46 48 50 52 54
//   Tc[qp]:   0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
//              0 0 0 0 0 0 0 1 1 1 1 1 1 1 1 1
//              1 2 2 2 2 3 3 3 4 4 4 4 4 5 5 6 6 7 7 8 9 10
//
// Config:
//   LoopFilterBetaOffset_div2 = 0  → no QP offset
//   LoopFilterTcOffset_div2   = 0
//   InternalBitDepth = 10
//
// Pipeline:
//   Input:  p[0..3], q[0..3] (8 samples), BS, edge_qp (from boundary_strength)
//   Output: p[0..2], q[0..2] (6 filtered samples — p3/q3 never modified)
//   Latency: 2 cycles (threshold lookup + filter compute)
//=============================================================================

`include "parameter_pkg.vh"

module db_filter_luma (
    input  wire         clk,
    input  wire         rst_n,

    // Input — one 4-sample group per cycle
    input  wire         in_valid,
    output wire         in_ready,

    input  wire [1:0]   bs,             // from boundary_strength (0,1,2)
    input  wire [5:0]   edge_qp,        // averaged QP from boundary_strength

    // 8 luma samples (10-bit each), p closest to boundary
    input  wire [`PIXEL_WIDTH-1:0] p0, p1, p2, p3,
    input  wire [`PIXEL_WIDTH-1:0] q0, q1, q2, q3,

    // Output — filtered samples (p3/q3 unchanged, not output)
    output reg          out_valid,
    input  wire         out_ready,

    output reg  [`PIXEL_WIDTH-1:0] p0_f, p1_f, p2_f,   // filtered P samples
    output reg  [`PIXEL_WIDTH-1:0] q0_f, q1_f, q2_f,   // filtered Q samples
    output reg          modified_p,     // 1=P side was modified
    output reg          modified_q      // 1=Q side was modified
);

    //-------------------------------------------------------------------------
    // Beta table — HEVC spec Table 8-11, indexed by QP 0..51
    // Values: beta = BetaTable[QP]
    //-------------------------------------------------------------------------
    function automatic [6:0] beta_table;
        input [5:0] qp;
        case (qp)
            6'd0,6'd1,6'd2,6'd3,6'd4,6'd5,6'd6,6'd7,
            6'd8,6'd9,6'd10,6'd11,6'd12,6'd13,6'd14,6'd15: beta_table = 7'd0;
            6'd16: beta_table = 7'd6;  6'd17: beta_table = 7'd7;
            6'd18: beta_table = 7'd8;  6'd19: beta_table = 7'd9;
            6'd20: beta_table = 7'd10; 6'd21: beta_table = 7'd11;
            6'd22: beta_table = 7'd12; 6'd23: beta_table = 7'd13;
            6'd24: beta_table = 7'd14; 6'd25: beta_table = 7'd15;
            6'd26: beta_table = 7'd16; 6'd27: beta_table = 7'd17;
            6'd28: beta_table = 7'd18; 6'd29: beta_table = 7'd20;
            6'd30: beta_table = 7'd22; 6'd31: beta_table = 7'd24;
            6'd32: beta_table = 7'd26; 6'd33: beta_table = 7'd28;
            6'd34: beta_table = 7'd30; 6'd35: beta_table = 7'd32;
            6'd36: beta_table = 7'd34; 6'd37: beta_table = 7'd36;
            6'd38: beta_table = 7'd38; 6'd39: beta_table = 7'd40;
            6'd40: beta_table = 7'd42; 6'd41: beta_table = 7'd44;
            6'd42: beta_table = 7'd46; 6'd43: beta_table = 7'd48;
            6'd44: beta_table = 7'd50; 6'd45: beta_table = 7'd52;
            6'd46: beta_table = 7'd54; 6'd47: beta_table = 7'd56;
            6'd48: beta_table = 7'd58; 6'd49: beta_table = 7'd60;
            6'd50: beta_table = 7'd62; 6'd51: beta_table = 7'd64;
            default: beta_table = 7'd0;
        endcase
    endfunction

    //-------------------------------------------------------------------------
    // Tc table — HEVC spec Table 8-11, indexed by QP 0..53 (with BS offset)
    // Tc index = QP + 2*(BS-1)  →  BS=1: QP+0, BS=2: QP+2
    // Table values (7-bit to handle QP+2 extension):
    //-------------------------------------------------------------------------
    function automatic [6:0] tc_table;
        input [6:0] idx;  // 7-bit: QP + BS_offset (0..53)
        case (idx)
            7'd0,7'd1,7'd2,7'd3,7'd4,7'd5,7'd6,7'd7,
            7'd8,7'd9,7'd10,7'd11,7'd12,7'd13,7'd14,7'd15,
            7'd16,7'd17: tc_table = 7'd0;
            7'd18,7'd19,7'd20,7'd21,7'd22,7'd23: tc_table = 7'd1;
            7'd24,7'd25,7'd26,7'd27: tc_table = 7'd2;
            7'd28,7'd29,7'd30,7'd31: tc_table = 7'd3;
            7'd32,7'd33,7'd34: tc_table = 7'd4;
            7'd35,7'd36: tc_table = 7'd5;
            7'd37,7'd38: tc_table = 7'd6;
            7'd39: tc_table = 7'd7;
            7'd40: tc_table = 7'd8;
            7'd41: tc_table = 7'd9;
            7'd42: tc_table = 7'd10;
            7'd43: tc_table = 7'd11;
            7'd44: tc_table = 7'd13;
            7'd45: tc_table = 7'd14;
            7'd46: tc_table = 7'd16;
            7'd47: tc_table = 7'd18;
            7'd48: tc_table = 7'd20;
            7'd49: tc_table = 7'd22;
            7'd50: tc_table = 7'd24;
            7'd51: tc_table = 7'd26;
            7'd52: tc_table = 7'd28;
            7'd53: tc_table = 7'd30;
            default: tc_table = 7'd0;
        endcase
    endfunction

    //-------------------------------------------------------------------------
    // Clip helpers
    //-------------------------------------------------------------------------
    // Clip1 — clamp to [0, (1<<BIT_DEPTH)-1]
    localparam signed [11:0] CLIP1_MAX = (1 << `BIT_DEPTH) - 1;  // 1023

    function automatic [`PIXEL_WIDTH-1:0] clip1;
        input signed [11:0] val;
        begin
            if      (val > CLIP1_MAX) clip1 = CLIP1_MAX[`PIXEL_WIDTH-1:0];
            else if (val < 12'sd0)    clip1 = {`PIXEL_WIDTH{1'b0}};
            else                      clip1 = val[`PIXEL_WIDTH-1:0];
        end
    endfunction

    // Clip3(lo, hi, val)
    function automatic signed [11:0] clip3;
        input signed [11:0] lo, hi, val;
        begin
            if      (val < lo) clip3 = lo;
            else if (val > hi) clip3 = hi;
            else               clip3 = val;
        end
    endfunction

    //-------------------------------------------------------------------------
    // Combinatorial metrics for the incoming row
    //-------------------------------------------------------------------------
    wire signed [11:0] dp_in = $signed({2'b0, p2}) - $signed({1'b0, p1, 1'b0}) + $signed({2'b0, p0});
    wire signed [11:0] dq_in = $signed({2'b0, q2}) - $signed({1'b0, q1, 1'b0}) + $signed({2'b0, q0});
    wire [10:0] abs_dp_in = dp_in[11] ? (~dp_in[10:0] + 11'd1) : dp_in[10:0];
    wire [10:0] abs_dq_in = dq_in[11] ? (~dq_in[10:0] + 11'd1) : dq_in[10:0];
    
    wire signed [11:0] p3p0_diff = $signed({2'b0,p3}) - $signed({2'b0,p0});
    wire signed [11:0] q3q0_diff = $signed({2'b0,q3}) - $signed({2'b0,q0});
    wire [10:0] abs_p3p0 = p3p0_diff[11] ? (~p3p0_diff[10:0]+11'd1) : p3p0_diff[10:0];
    wire [10:0] abs_q3q0 = q3q0_diff[11] ? (~q3q0_diff[10:0]+11'd1) : q3q0_diff[10:0];
    wire [11:0] ends_in  = {1'b0, abs_p3p0} + {1'b0, abs_q3q0};

    wire signed [11:0] p0q0_diff = $signed({2'b0,p0}) - $signed({2'b0,q0});
    wire [10:0] abs_p0q0_in = p0q0_diff[11] ? (~p0q0_diff[10:0]+11'd1) : p0q0_diff[10:0];

    //-------------------------------------------------------------------------
    // 4-Row Buffer and Metric Accumulator State Machine
    //-------------------------------------------------------------------------
    reg [2:0] state;
    localparam S_FILL  = 3'd0;
    localparam S_DRAIN = 3'd1;

    reg [1:0] wr_idx;
    reg [1:0] rd_idx;

    reg [`PIXEL_WIDTH-1:0] b_p0 [0:3], b_p1 [0:3], b_p2 [0:3], b_p3 [0:3];
    reg [`PIXEL_WIDTH-1:0] b_q0 [0:3], b_q1 [0:3], b_q2 [0:3], b_q3 [0:3];
    reg [1:0] b_bs;
    reg [5:0] b_edge_qp;

    reg [11:0] m_dp0, m_dq0, m_ends0, m_p0q0_0;
    reg [11:0] m_dp3, m_dq3, m_ends3, m_p0q0_3;

    assign in_ready = (state == S_FILL) && (out_ready || !out_valid);

    // Pointers for filter logic
    wire [`PIXEL_WIDTH-1:0] s1_p0 = b_p0[rd_idx];
    wire [`PIXEL_WIDTH-1:0] s1_p1 = b_p1[rd_idx];
    wire [`PIXEL_WIDTH-1:0] s1_p2 = b_p2[rd_idx];
    wire [`PIXEL_WIDTH-1:0] s1_p3 = b_p3[rd_idx];
    wire [`PIXEL_WIDTH-1:0] s1_q0 = b_q0[rd_idx];
    wire [`PIXEL_WIDTH-1:0] s1_q1 = b_q1[rd_idx];
    wire [`PIXEL_WIDTH-1:0] s1_q2 = b_q2[rd_idx];
    wire [`PIXEL_WIDTH-1:0] s1_q3 = b_q3[rd_idx];
    wire [1:0]  s1_bs = b_bs;
    wire [5:0]  s1_edge_qp = b_edge_qp;

    wire [9:0]  s1_beta = {3'b0, beta_table(s1_edge_qp)} << (`BIT_DEPTH - 8);
    wire [6:0]  tc_idx  = {1'b0, s1_edge_qp} + ((s1_bs == 2'd2) ? 7'd2 : 7'd0);
    wire [9:0]  s1_tc   = {3'b0, tc_table(tc_idx)} << (`BIT_DEPTH - 8);

    // HEVC Block-Level Filter Decisions
    wire [11:0] dp_blk = m_dp0 + m_dp3;
    wire [11:0] dq_blk = m_dq0 + m_dq3;
    wire [12:0] d_blk  = {1'b0, dp_blk} + {1'b0, dq_blk};

    wire [6:0] beta_div8 = s1_beta[9:3];  // beta >> 3
    wire [12:0] tc5_1_2 = ({1'b0, s1_tc, 2'b0} + {3'b0, s1_tc} + 13'd1) >> 1;

    wire d0_lt_beta8    = (m_dp0 + m_dq0) < {6'b0, beta_div8};
    wire d3_lt_beta8    = (m_dp3 + m_dq3) < {6'b0, beta_div8};
    wire ends0_lt_beta8 = m_ends0 < {6'b0, beta_div8};
    wire ends3_lt_beta8 = m_ends3 < {6'b0, beta_div8};
    wire p0q0_0_lt_tc5  = m_p0q0_0 < tc5_1_2;
    wire p0q0_3_lt_tc5  = m_p0q0_3 < tc5_1_2;

    wire use_strong = d0_lt_beta8 && d3_lt_beta8 && ends0_lt_beta8 && ends3_lt_beta8 && p0q0_0_lt_tc5 && p0q0_3_lt_tc5;
    wire use_weak   = !use_strong && (d_blk < {3'b0, s1_beta});

    wire [10:0] side_thresh = ({1'b0, s1_beta} + {2'b0, s1_beta[9:1]}) >> 3;
    wire do_p1_adj_blk  = dp_blk < {1'b0, side_thresh};
    wire do_q1_adj_blk  = dq_blk < {1'b0, side_thresh};

    //-------------------------------------------------------------------------
    // Strong filter computation (HM xPelFilterLuma strong path)
    //-------------------------------------------------------------------------
    wire signed [13:0] tc2 = $signed({4'b0, s1_tc}) << 1;

    // Helper for strong filter clipping: Clip3(px - 2*tc, px + 2*tc, flt)
    function automatic [`PIXEL_WIDTH-1:0] clip_strong;
        input signed [13:0] px;     // Original pixel value
        input signed [13:0] flt;    // Filtered pixel value
        input signed [13:0] tc2_val;
        reg signed [13:0] min_val, max_val;
        begin
            min_val = px - tc2_val;
            max_val = px + tc2_val;
            if      (flt < min_val) clip_strong = clip1(min_val[11:0]);
            else if (flt > max_val) clip_strong = clip1(max_val[11:0]);
            else                    clip_strong = clip1(flt[11:0]);
        end
    endfunction

    wire [`PIXEL_WIDTH-1:0] sp0 = clip_strong( $signed({4'b0, s1_p0}), 
                                       ( $signed({4'b0, s1_p2})
                                         + $signed({3'b0, s1_p1, 1'b0})
                                         + $signed({3'b0, s1_p0, 1'b0})
                                         + $signed({3'b0, s1_q0, 1'b0})
                                         + $signed({4'b0, s1_q1})
                                         + 14'sd4 ) >>> 3, tc2 );

    wire [`PIXEL_WIDTH-1:0] sp1 = clip_strong( $signed({4'b0, s1_p1}), 
                                       ( $signed({4'b0, s1_p2})
                                         + $signed({4'b0, s1_p1})
                                         + $signed({4'b0, s1_p0})
                                         + $signed({4'b0, s1_q0})
                                         + 14'sd2 ) >>> 2, tc2 );

    wire [`PIXEL_WIDTH-1:0] sp2 = clip_strong( $signed({4'b0, s1_p2}), 
                                       ( $signed({3'b0, s1_p3, 1'b0}) // 2*p3
                                         + $signed({3'b0, s1_p2, 1'b0}) // 2*p2
                                         + $signed({4'b0, s1_p2})       // +1*p2 = 3*p2
                                         + $signed({4'b0, s1_p1})
                                         + $signed({4'b0, s1_p0})
                                         + $signed({4'b0, s1_q0})
                                         + 14'sd4 ) >>> 3, tc2 );

    wire [`PIXEL_WIDTH-1:0] sq0 = clip_strong( $signed({4'b0, s1_q0}), 
                                       ( $signed({4'b0, s1_p1})
                                         + $signed({3'b0, s1_p0, 1'b0})
                                         + $signed({3'b0, s1_q0, 1'b0})
                                         + $signed({3'b0, s1_q1, 1'b0})
                                         + $signed({4'b0, s1_q2})
                                         + 14'sd4 ) >>> 3, tc2 );

    wire [`PIXEL_WIDTH-1:0] sq1 = clip_strong( $signed({4'b0, s1_q1}), 
                                       ( $signed({4'b0, s1_p0})
                                         + $signed({4'b0, s1_q0})
                                         + $signed({4'b0, s1_q1})
                                         + $signed({4'b0, s1_q2})
                                         + 14'sd2 ) >>> 2, tc2 );

    wire [`PIXEL_WIDTH-1:0] sq2 = clip_strong( $signed({4'b0, s1_q2}), 
                                       ( $signed({4'b0, s1_p0})
                                         + $signed({4'b0, s1_q0})
                                         + $signed({4'b0, s1_q1})
                                         + $signed({3'b0, s1_q2, 1'b0}) // 2*q2
                                         + $signed({4'b0, s1_q2})       // +1*q2 = 3*q2
                                         + $signed({3'b0, s1_q3, 1'b0}) // 2*q3
                                         + 14'sd4 ) >>> 3, tc2 );

    //-------------------------------------------------------------------------
    // Weak filter computation (HM xPelFilterLuma weak path)
    //-------------------------------------------------------------------------
    // raw_delta = (9*(q0-p0) - 3*(q1-p1) + 8) >> 4
    wire signed [11:0] q0_p0   = $signed({2'b0,s1_q0}) - $signed({2'b0,s1_p0});
    wire signed [11:0] q1_p1   = $signed({2'b0,s1_q1}) - $signed({2'b0,s1_p1});

    // 9*(q0-p0): max = 9*1023 = 9207 → Requires 15 bits
    wire signed [14:0] nine_diff  = $signed({{3{q0_p0[11]}}, q0_p0}) * 15'sd9; 
    wire signed [14:0] three_diff = $signed({{3{q1_p1[11]}}, q1_p1}) * 15'sd3;
    wire signed [14:0] raw_delta  = (nine_diff - three_diff + 15'sd8) >>> 4;

    // HM: if (abs(delta) < iThrCut), where iThrCut = 10 * tc
    wire [14:0] abs_raw_delta = raw_delta[14] ? (~raw_delta + 15'd1) : raw_delta;
    wire [13:0] tc10_v        = ({4'b0, s1_tc} << 3) + ({4'b0, s1_tc} << 1);  // 8tc + 2tc
    wire        delta_valid   = (abs_raw_delta < {1'b0, tc10_v});

    // delta = Clip3(-tc, tc, raw_delta)
    wire signed [11:0] tc_pos  =  $signed({2'b0, s1_tc});
    wire signed [11:0] tc_neg  = -$signed({2'b0, s1_tc});
    wire signed [11:0] delta   = delta_valid ? clip3(tc_neg, tc_pos, raw_delta[11:0]) : 12'sd0;

    wire do_p1_adj  = delta_valid && do_p1_adj_blk;
    wire do_q1_adj  = delta_valid && do_q1_adj_blk;

    wire signed [11:0] tc_half_pos  =  $signed({3'b0, s1_tc[9:1]});  // tc/2
    wire signed [11:0] tc_half_neg  = -$signed({3'b0, s1_tc[9:1]});

    // deltap = Clip3(-tc/2, tc/2, ( ((p2+p0+1)>>1) - p1 + delta) >> 1 )
    wire signed [11:0] p2_p0_avg  = ( $signed({2'b0, s1_p2}) + $signed({2'b0, s1_p0}) + 12'sd1 ) >>> 1;
    wire signed [12:0] deltap_raw = ( p2_p0_avg - $signed({2'b0, s1_p1}) + delta ) >>> 1;
    wire signed [11:0] deltap     = clip3(tc_half_neg, tc_half_pos, deltap_raw[11:0]);

    // deltaq = Clip3(-tc/2, tc/2, ( ((q2+q0+1)>>1) - q1 - delta) >> 1 )
    wire signed [11:0] q2_q0_avg  = ( $signed({2'b0, s1_q2}) + $signed({2'b0, s1_q0}) + 12'sd1 ) >>> 1;
    wire signed [12:0] deltaq_raw = ( q2_q0_avg - $signed({2'b0, s1_q1}) - delta ) >>> 1;
    wire signed [11:0] deltaq     = clip3(tc_half_neg, tc_half_pos, deltaq_raw[11:0]);

    // Weak filtered samples
    wire [`PIXEL_WIDTH-1:0] wp0 = clip1($signed({2'b0,s1_p0}) + delta);
    wire [`PIXEL_WIDTH-1:0] wq0 = clip1($signed({2'b0,s1_q0}) - delta);
    wire [`PIXEL_WIDTH-1:0] wp1 = do_p1_adj ?
                                   clip1($signed({2'b0,s1_p1}) + deltap) :
                                   s1_p1;
    wire [`PIXEL_WIDTH-1:0] wq1 = do_q1_adj ?
                                   clip1($signed({2'b0,s1_q1}) - deltaq) :
                                   s1_q1;

    //-------------------------------------------------------------------------
    // Output register
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            state      <= S_FILL;
            wr_idx     <= 2'd0;
            rd_idx     <= 2'd0;
            out_valid  <= 1'b0;
            modified_p <= 1'b0;
            modified_q <= 1'b0;
            p0_f <= 0; p1_f <= 0; p2_f <= 0;
            q0_f <= 0; q1_f <= 0; q2_f <= 0;
        end else begin
            // Allow pipeline drain
            if (out_ready) out_valid <= 1'b0;

            if (state == S_FILL) begin
                if (in_valid && in_ready) begin
                    if (bs == 2'd0) begin
                        // Bypassed block edge - Instant pass-through logic
                        out_valid <= 1'b1;
                        p0_f <= p0; p1_f <= p1; p2_f <= p2;
                        q0_f <= q0; q1_f <= q1; q2_f <= q2;
                        modified_p <= 1'b0; modified_q <= 1'b0;
                    end else begin
                        // Pipeline to block accumulator buffer
                        b_p0[wr_idx] <= p0; b_p1[wr_idx] <= p1; b_p2[wr_idx] <= p2; b_p3[wr_idx] <= p3;
                        b_q0[wr_idx] <= q0; b_q1[wr_idx] <= q1; b_q2[wr_idx] <= q2; b_q3[wr_idx] <= q3;
                        
                        if (wr_idx == 2'd0) begin
                            b_bs <= bs; 
                            b_edge_qp <= edge_qp;
                            m_dp0 <= {1'b0, abs_dp_in}; m_dq0 <= {1'b0, abs_dq_in};
                            m_ends0 <= ends_in; m_p0q0_0 <= {1'b0, abs_p0q0_in};
                        end else if (wr_idx == 2'd3) begin
                            m_dp3 <= {1'b0, abs_dp_in}; m_dq3 <= {1'b0, abs_dq_in};
                            m_ends3 <= ends_in; m_p0q0_3 <= {1'b0, abs_p0q0_in};
                            state <= S_DRAIN;
                        end
                        wr_idx <= wr_idx + 2'd1;
                    end
                end
            end else if (state == S_DRAIN) begin
                if (out_ready || !out_valid) begin
                    out_valid <= 1'b1;
                    
                    if (use_strong) begin
                        p0_f <= sp0; p1_f <= sp1; p2_f <= sp2;
                        q0_f <= sq0; q1_f <= sq1; q2_f <= sq2;
                        modified_p <= 1'b1; modified_q <= 1'b1;
                    end else if (use_weak) begin
                        p0_f <= wp0; p1_f <= wp1; p2_f <= s1_p2;
                        q0_f <= wq0; q1_f <= wq1; q2_f <= s1_q2;
                        modified_p <= 1'b1; modified_q <= 1'b1;
                    end else begin
                        // Filter conditions evaluated false
                        p0_f <= s1_p0; p1_f <= s1_p1; p2_f <= s1_p2;
                        q0_f <= s1_q0; q1_f <= s1_q1; q2_f <= s1_q2;
                        modified_p <= 1'b0; modified_q <= 1'b0;
                    end

                    if (rd_idx == 2'd3) begin
                        state <= S_FILL;
                        rd_idx <= 2'd0;
                        wr_idx <= 2'd0;
                    end else begin
                        rd_idx <= rd_idx + 2'd1;
                    end
                end
            end
        end
    end

    //-------------------------------------------------------------------------
    // Simulation checks
    //-------------------------------------------------------------------------
    // synthesis translate_off
    always @(posedge clk) begin
        if (rst_n && state == S_DRAIN && (out_ready || !out_valid)) begin
            if (s1_tc == 10'd0 && s1_bs != 2'd0)
                $display("INFO  [db_filter_luma] TC=0 at QP=%0d BS=%0d — no filtering",
                         s1_edge_qp, s1_bs);
        end
    end
    // synthesis translate_on

endmodule