//=============================================================================
// db_filter_luma.v
// Deblocking Filter — Luma Edge Filter (Single-Group Mode)
//
// Immediate 1-in, 1-out: accepts one sample group (p0-p3, q0-q3) and
// outputs filtered (p0_f-p2_f, q0_f-q2_f) on the next cycle.
//
// Strong/weak decision uses per-sample dp/dq doubled (2×dp, 2×dq)
// to approximate the HEVC block-level dp0+dp3 metrics.
//
// HEVC spec: Section 8.7.2.4 (filtering process for luma samples)
//=============================================================================

`include "parameter_pkg.vh"

module db_filter_luma (
    input  wire         clk,
    input  wire         rst_n,

    // Input — one 4-sample group per transaction
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

    output wire [`PIXEL_WIDTH-1:0] p0_f, p1_f, p2_f,   // filtered P samples
    output wire [`PIXEL_WIDTH-1:0] q0_f, q1_f, q2_f,   // filtered Q samples
    output wire         modified_p,     // 1=P side was modified
    output wire         modified_q      // 1=Q side was modified
);

    //-------------------------------------------------------------------------
    // Beta table — HEVC spec Table 8-11, indexed by QP 0..51
    //-------------------------------------------------------------------------
    function automatic [6:0] beta_table;
        input [5:0] qp;
        case (qp)
            6'd0:  beta_table = 7'd0;   6'd1:  beta_table = 7'd0;   6'd2:  beta_table = 7'd0;   6'd3:  beta_table = 7'd0;
            6'd4:  beta_table = 7'd0;   6'd5:  beta_table = 7'd0;   6'd6:  beta_table = 7'd0;   6'd7:  beta_table = 7'd0;
            6'd8:  beta_table = 7'd0;   6'd9:  beta_table = 7'd0;   6'd10: beta_table = 7'd0;   6'd11: beta_table = 7'd0;
            6'd12: beta_table = 7'd0;   6'd13: beta_table = 7'd0;   6'd14: beta_table = 7'd0;   6'd15: beta_table = 7'd0;
            6'd16: beta_table = 7'd6;   6'd17: beta_table = 7'd7;   6'd18: beta_table = 7'd8;   6'd19: beta_table = 7'd9;
            6'd20: beta_table = 7'd10;  6'd21: beta_table = 7'd11;  6'd22: beta_table = 7'd12;  6'd23: beta_table = 7'd13;
            6'd24: beta_table = 7'd14;  6'd25: beta_table = 7'd15;  6'd26: beta_table = 7'd16;  6'd27: beta_table = 7'd17;
            6'd28: beta_table = 7'd18;  6'd29: beta_table = 7'd20;  6'd30: beta_table = 7'd22;  6'd31: beta_table = 7'd24;
            6'd32: beta_table = 7'd26;  6'd33: beta_table = 7'd28;  6'd34: beta_table = 7'd30;  6'd35: beta_table = 7'd32;
            6'd36: beta_table = 7'd34;  6'd37: beta_table = 7'd36;  6'd38: beta_table = 7'd38;  6'd39: beta_table = 7'd40;
            6'd40: beta_table = 7'd42;  6'd41: beta_table = 7'd44;  6'd42: beta_table = 7'd46;  6'd43: beta_table = 7'd48;
            6'd44: beta_table = 7'd50;  6'd45: beta_table = 7'd52;  6'd46: beta_table = 7'd54;  6'd47: beta_table = 7'd56;
            6'd48: beta_table = 7'd58;  6'd49: beta_table = 7'd60;  6'd50: beta_table = 7'd62;  6'd51: beta_table = 7'd64;
            default: beta_table = 7'd0;
        endcase
    endfunction

    //-------------------------------------------------------------------------
    // Tc table — HEVC spec Table 8-10, indexed by QP+offset 0..53
    //-------------------------------------------------------------------------
    function automatic [6:0] tc_table;
        input [6:0] qp;
        case (qp)
            7'd0:  tc_table = 7'd0;  7'd1:  tc_table = 7'd0;  7'd2:  tc_table = 7'd0;  7'd3:  tc_table = 7'd0;
            7'd4:  tc_table = 7'd0;  7'd5:  tc_table = 7'd0;  7'd6:  tc_table = 7'd0;  7'd7:  tc_table = 7'd0;
            7'd8:  tc_table = 7'd0;  7'd9:  tc_table = 7'd0;  7'd10: tc_table = 7'd0;  7'd11: tc_table = 7'd0;
            7'd12: tc_table = 7'd0;  7'd13: tc_table = 7'd0;  7'd14: tc_table = 7'd0;  7'd15: tc_table = 7'd0;
            7'd16: tc_table = 7'd0;  7'd17: tc_table = 7'd0;  7'd18: tc_table = 7'd1;  7'd19: tc_table = 7'd1;
            7'd20: tc_table = 7'd1;  7'd21: tc_table = 7'd1;  7'd22: tc_table = 7'd1;  7'd23: tc_table = 7'd1;
            7'd24: tc_table = 7'd1;  7'd25: tc_table = 7'd1;  7'd26: tc_table = 7'd1;  7'd27: tc_table = 7'd2;
            7'd28: tc_table = 7'd2;  7'd29: tc_table = 7'd2;  7'd30: tc_table = 7'd2;  7'd31: tc_table = 7'd3;
            7'd32: tc_table = 7'd3;  7'd33: tc_table = 7'd3;  7'd34: tc_table = 7'd3;  7'd35: tc_table = 7'd4;
            7'd36: tc_table = 7'd4;  7'd37: tc_table = 7'd4;  7'd38: tc_table = 7'd5;  7'd39: tc_table = 7'd5;
            7'd40: tc_table = 7'd6;  7'd41: tc_table = 7'd6;  7'd42: tc_table = 7'd7;  7'd43: tc_table = 7'd8;
            7'd44: tc_table = 7'd9;  7'd45: tc_table = 7'd10; 7'd46: tc_table = 7'd11; 7'd47: tc_table = 7'd13;
            7'd48: tc_table = 7'd14; 7'd49: tc_table = 7'd16; 7'd50: tc_table = 7'd18; 7'd51: tc_table = 7'd20;
            7'd52: tc_table = 7'd22; 7'd53: tc_table = 7'd24;
            default: tc_table = 7'd0;
        endcase
    endfunction

    //-------------------------------------------------------------------------
    // Clip helpers
    //-------------------------------------------------------------------------
    localparam signed [11:0] CLIP1_MAX = (1 << `BIT_DEPTH) - 1;  // 1023

    function automatic [`PIXEL_WIDTH-1:0] clip1;
        input signed [11:0] val;
        begin
            if      (val > CLIP1_MAX) clip1 = CLIP1_MAX[`PIXEL_WIDTH-1:0];
            else if (val < 12'sd0)    clip1 = {`PIXEL_WIDTH{1'b0}};
            else                      clip1 = val[`PIXEL_WIDTH-1:0];
        end
    endfunction

    function automatic signed [11:0] clip3;
        input signed [11:0] lo, hi, val;
        begin
            if      (val < lo) clip3 = lo;
            else if (val > hi) clip3 = hi;
            else               clip3 = val;
        end
    endfunction


    function automatic [`PIXEL_WIDTH-1:0] clip_strong;
        input signed [13:0] px, flt, tc2_val;
        reg signed [13:0] min_val, max_val;
        begin
            min_val = px - tc2_val;
            max_val = px + tc2_val;
            if      (flt < min_val) clip_strong = clip1(min_val[11:0]);
            else if (flt > max_val) clip_strong = clip1(max_val[11:0]);
            else                    clip_strong = clip1(flt[11:0]);
        end
    endfunction

    //-------------------------------------------------------------------------
    // Ping-Pong Bank Storage (2 banks x 4 lines each)
    //-------------------------------------------------------------------------
    reg [`PIXEL_WIDTH-1:0] b_p0 [0:1][0:3];
    reg [`PIXEL_WIDTH-1:0] b_p1 [0:1][0:3];
    reg [`PIXEL_WIDTH-1:0] b_p2 [0:1][0:3];
    reg [`PIXEL_WIDTH-1:0] b_p3 [0:1][0:3];
    reg [`PIXEL_WIDTH-1:0] b_q0 [0:1][0:3];
    reg [`PIXEL_WIDTH-1:0] b_q1 [0:1][0:3];
    reg [`PIXEL_WIDTH-1:0] b_q2 [0:1][0:3];
    reg [`PIXEL_WIDTH-1:0] b_q3 [0:1][0:3];

    reg [1:0]  b_bs         [0:1];
    reg [9:0]  b_beta       [0:1];
    reg [9:0]  b_tc         [0:1];
    reg [10:0] b_dp0        [0:1];
    reg [10:0] b_dq0        [0:1];
    reg [11:0] b_d0         [0:1];
    reg        b_st0        [0:1];

    reg        b_use_strong [0:1];
    reg        b_use_weak   [0:1];
    reg        b_do_p1_adj  [0:1];
    reg        b_do_q1_adj  [0:1];
    reg        b_ready      [0:1];

    reg        wr_bank;
    reg [1:0]  wr_idx;
    reg        rd_bank;
    reg [1:0]  rd_idx;

    assign in_ready = !b_ready[wr_bank];

    //-------------------------------------------------------------------------
    // Combinational metrics for incoming line (p0..p3, q0..q3)
    //-------------------------------------------------------------------------
    wire signed [11:0] in_dp_raw = $signed({2'b0, p2}) - $signed({1'b0, p1, 1'b0}) + $signed({2'b0, p0});
    wire signed [11:0] in_dq_raw = $signed({2'b0, q2}) - $signed({1'b0, q1, 1'b0}) + $signed({2'b0, q0});
    wire [10:0] in_abs_dp = in_dp_raw[11] ? (~in_dp_raw[10:0] + 11'd1) : in_dp_raw[10:0];
    wire [10:0] in_abs_dq = in_dq_raw[11] ? (~in_dq_raw[10:0] + 11'd1) : in_dq_raw[10:0];
    wire [11:0] in_d_val  = {1'b0, in_abs_dp} + {1'b0, in_abs_dq};

    wire signed [11:0] in_p3p0 = $signed({2'b0, p3}) - $signed({2'b0, p0});
    wire signed [11:0] in_q3q0 = $signed({2'b0, q3}) - $signed({2'b0, q0});
    wire [10:0] in_abs_p3p0 = in_p3p0[11] ? (~in_p3p0[10:0] + 11'd1) : in_p3p0[10:0];
    wire [10:0] in_abs_q3q0 = in_q3q0[11] ? (~in_q3q0[10:0] + 11'd1) : in_q3q0[10:0];
    wire [11:0] in_ends_val = {1'b0, in_abs_p3p0} + {1'b0, in_abs_q3q0};

    wire signed [11:0] in_p0q0 = $signed({2'b0, p0}) - $signed({2'b0, q0});
    wire [10:0] in_abs_p0q0 = in_p0q0[11] ? (~in_p0q0[10:0] + 11'd1) : in_p0q0[10:0];

    // Line 0 thresholds and strong decision
    wire [9:0] in_beta0 = {3'b0, beta_table(edge_qp)} << (`BIT_DEPTH - 8);
    wire [6:0] in_tc_idx0 = {1'b0, edge_qp} + ((bs == 2'd2) ? 7'd2 : 7'd0);
    wire [9:0] in_tc0   = {3'b0, tc_table(in_tc_idx0)} << (`BIT_DEPTH - 8);
    wire [12:0] tc5_1_2_0 = ({1'b0, in_tc0, 2'b0} + {3'b0, in_tc0} + 13'd1) >> 1;

    wire in_st0 = ({in_d_val, 1'b0} < {5'b0, in_beta0[9:2]}) &&
                  (in_ends_val < {5'b0, in_beta0[9:3]}) &&
                  ({1'b0, in_abs_p0q0} < tc5_1_2_0[11:0]);

    // Line 3 strong decision using latched bank beta/tc
    wire [9:0] cur_b_beta = b_beta[wr_bank];
    wire [9:0] cur_b_tc   = b_tc[wr_bank];
    wire [12:0] tc5_1_2_3 = ({1'b0, cur_b_tc, 2'b0} + {3'b0, cur_b_tc} + 13'd1) >> 1;

    wire in_st3 = ({in_d_val, 1'b0} < {5'b0, cur_b_beta[9:2]}) &&
                  (in_ends_val < {5'b0, cur_b_beta[9:3]}) &&
                  ({1'b0, in_abs_p0q0} < tc5_1_2_3[11:0]);

    // Block decisions evaluated at line 3
    wire [11:0] blk_dp = {1'b0, b_dp0[wr_bank]} + {1'b0, in_abs_dp};
    wire [11:0] blk_dq = {1'b0, b_dq0[wr_bank]} + {1'b0, in_abs_dq};
    wire [12:0] blk_d  = {1'b0, blk_dp} + {1'b0, blk_dq};
    wire [10:0] blk_side_thresh = ({1'b0, cur_b_beta} + {2'b0, cur_b_beta[9:1]}) >> 3;

    wire blk_filter_en = (b_bs[wr_bank] != 2'd0) && (blk_d < {3'b0, cur_b_beta});
    wire blk_strong    = blk_filter_en && b_st0[wr_bank] && in_st3;
    wire blk_weak      = blk_filter_en && !(b_st0[wr_bank] && in_st3);
    wire blk_do_p1     = blk_dp < {1'b0, blk_side_thresh};
    wire blk_do_q1     = blk_dq < {1'b0, blk_side_thresh};

    //-------------------------------------------------------------------------
    // Combinational filter for readout line (rd_bank, rd_idx)
    //-------------------------------------------------------------------------
    wire [`PIXEL_WIDTH-1:0] cur_p0 = b_p0[rd_bank][rd_idx];
    wire [`PIXEL_WIDTH-1:0] cur_p1 = b_p1[rd_bank][rd_idx];
    wire [`PIXEL_WIDTH-1:0] cur_p2 = b_p2[rd_bank][rd_idx];
    wire [`PIXEL_WIDTH-1:0] cur_p3 = b_p3[rd_bank][rd_idx];
    wire [`PIXEL_WIDTH-1:0] cur_q0 = b_q0[rd_bank][rd_idx];
    wire [`PIXEL_WIDTH-1:0] cur_q1 = b_q1[rd_bank][rd_idx];
    wire [`PIXEL_WIDTH-1:0] cur_q2 = b_q2[rd_bank][rd_idx];
    wire [`PIXEL_WIDTH-1:0] cur_q3 = b_q3[rd_bank][rd_idx];

    wire [9:0] cur_tc = b_tc[rd_bank];
    wire signed [13:0] tc2_sel = $signed({4'b0, cur_tc}) << 1;

    // Strong filter outputs
    wire [`PIXEL_WIDTH-1:0] sp0 = clip_strong($signed({4'b0, cur_p0}),
        ($signed({4'b0, cur_p2}) + $signed({3'b0, cur_p1, 1'b0}) + $signed({3'b0, cur_p0, 1'b0})
         + $signed({3'b0, cur_q0, 1'b0}) + $signed({4'b0, cur_q1}) + 14'sd4) >>> 3, tc2_sel);

    wire [`PIXEL_WIDTH-1:0] sp1 = clip_strong($signed({4'b0, cur_p1}),
        ($signed({4'b0, cur_p2}) + $signed({4'b0, cur_p1}) + $signed({4'b0, cur_p0})
         + $signed({4'b0, cur_q0}) + 14'sd2) >>> 2, tc2_sel);

    wire [`PIXEL_WIDTH-1:0] sp2 = clip_strong($signed({4'b0, cur_p2}),
        ($signed({3'b0, cur_p3, 1'b0}) + $signed({3'b0, cur_p2, 1'b0}) + $signed({4'b0, cur_p2})
         + $signed({4'b0, cur_p1}) + $signed({4'b0, cur_p0}) + $signed({4'b0, cur_q0}) + 14'sd4) >>> 3, tc2_sel);

    wire [`PIXEL_WIDTH-1:0] sq0 = clip_strong($signed({4'b0, cur_q0}),
        ($signed({4'b0, cur_p1}) + $signed({3'b0, cur_p0, 1'b0}) + $signed({3'b0, cur_q0, 1'b0})
         + $signed({3'b0, cur_q1, 1'b0}) + $signed({4'b0, cur_q2}) + 14'sd4) >>> 3, tc2_sel);

    wire [`PIXEL_WIDTH-1:0] sq1 = clip_strong($signed({4'b0, cur_q1}),
        ($signed({4'b0, cur_p0}) + $signed({4'b0, cur_q0}) + $signed({4'b0, cur_q1})
         + $signed({4'b0, cur_q2}) + 14'sd2) >>> 2, tc2_sel);

    wire [`PIXEL_WIDTH-1:0] sq2 = clip_strong($signed({4'b0, cur_q2}),
        ($signed({4'b0, cur_p0}) + $signed({4'b0, cur_q0}) + $signed({4'b0, cur_q1})
         + $signed({3'b0, cur_q2, 1'b0}) + $signed({4'b0, cur_q2}) + $signed({3'b0, cur_q3, 1'b0})
         + 14'sd4) >>> 3, tc2_sel);

    // Weak filter outputs
    wire signed [11:0] q0_p0  = $signed({2'b0, cur_q0}) - $signed({2'b0, cur_p0});
    wire signed [11:0] q1_p1  = $signed({2'b0, cur_q1}) - $signed({2'b0, cur_p1});
    wire signed [14:0] nine_diff  = $signed({{3{q0_p0[11]}}, q0_p0}) * 15'sd9;
    wire signed [14:0] three_diff = $signed({{3{q1_p1[11]}}, q1_p1}) * 15'sd3;
    wire signed [14:0] raw_delta  = (nine_diff - three_diff + 15'sd8) >>> 4;

    wire [14:0] abs_raw_delta = raw_delta[14] ? (~raw_delta + 15'd1) : raw_delta;
    wire [13:0] tc10_v = ({4'b0, cur_tc} << 3) + ({4'b0, cur_tc} << 1);
    wire delta_valid = (abs_raw_delta < {1'b0, tc10_v});

    wire signed [11:0] tc_pos = $signed({2'b0, cur_tc});
    wire signed [11:0] tc_neg = -$signed({2'b0, cur_tc});
    wire signed [11:0] delta  = delta_valid ? clip3(tc_neg, tc_pos, raw_delta[11:0]) : 12'sd0;

    wire do_p1 = delta_valid && b_do_p1_adj[rd_bank];
    wire do_q1 = delta_valid && b_do_q1_adj[rd_bank];

    wire signed [11:0] tc_half_pos = $signed({3'b0, cur_tc[9:1]});
    wire signed [11:0] tc_half_neg = -$signed({3'b0, cur_tc[9:1]});

    wire signed [11:0] p2_p0_avg  = ($signed({2'b0, cur_p2}) + $signed({2'b0, cur_p0}) + 12'sd1) >>> 1;
    wire signed [12:0] deltap_raw = (p2_p0_avg - $signed({2'b0, cur_p1}) + delta) >>> 1;
    wire signed [11:0] deltap     = clip3(tc_half_neg, tc_half_pos, deltap_raw[11:0]);

    wire signed [11:0] q2_q0_avg  = ($signed({2'b0, cur_q2}) + $signed({2'b0, cur_q0}) + 12'sd1) >>> 1;
    wire signed [12:0] deltaq_raw = (q2_q0_avg - $signed({2'b0, cur_q1}) - delta) >>> 1;
    wire signed [11:0] deltaq     = clip3(tc_half_neg, tc_half_pos, deltaq_raw[11:0]);

    wire [`PIXEL_WIDTH-1:0] wp0 = clip1($signed({2'b0, cur_p0}) + delta);
    wire [`PIXEL_WIDTH-1:0] wq0 = clip1($signed({2'b0, cur_q0}) - delta);
    wire [`PIXEL_WIDTH-1:0] wp1 = do_p1 ? clip1($signed({2'b0, cur_p1}) + deltap) : cur_p1;
    wire [`PIXEL_WIDTH-1:0] wq1 = do_q1 ? clip1($signed({2'b0, cur_q1}) + deltaq) : cur_q1;

    // Filtered selection
    wire [`PIXEL_WIDTH-1:0] cur_p0f = (b_bs[rd_bank] == 2'd0)     ? cur_p0 :
                                      b_use_strong[rd_bank]       ? sp0 :
                                      b_use_weak[rd_bank]         ? wp0 : cur_p0;
    wire [`PIXEL_WIDTH-1:0] cur_p1f = (b_bs[rd_bank] == 2'd0)     ? cur_p1 :
                                      b_use_strong[rd_bank]       ? sp1 :
                                      b_use_weak[rd_bank]         ? wp1 : cur_p1;
    wire [`PIXEL_WIDTH-1:0] cur_p2f = (b_bs[rd_bank] == 2'd0)     ? cur_p2 :
                                      b_use_strong[rd_bank]       ? sp2 : cur_p2;

    wire [`PIXEL_WIDTH-1:0] cur_q0f = (b_bs[rd_bank] == 2'd0)     ? cur_q0 :
                                      b_use_strong[rd_bank]       ? sq0 :
                                      b_use_weak[rd_bank]         ? wq0 : cur_q0;
    wire [`PIXEL_WIDTH-1:0] cur_q1f = (b_bs[rd_bank] == 2'd0)     ? cur_q1 :
                                      b_use_strong[rd_bank]       ? sq1 :
                                      b_use_weak[rd_bank]         ? wq1 : cur_q1;
    wire [`PIXEL_WIDTH-1:0] cur_q2f = (b_bs[rd_bank] == 2'd0)     ? cur_q2 :
                                      b_use_strong[rd_bank]       ? sq2 : cur_q2;

    wire cur_mod_p = (b_bs[rd_bank] != 2'd0) && (b_use_strong[rd_bank] || b_use_weak[rd_bank]);
    wire cur_mod_q = (b_bs[rd_bank] != 2'd0) && (b_use_strong[rd_bank] || b_use_weak[rd_bank]);

    // Handshake helper wires
    wire in_fire  = in_valid && in_ready;
    wire out_fire = out_valid && out_ready;

    // Check if read bank has data ready to output
    wire rd_bank_has_data = b_ready[rd_bank] || (in_fire && (wr_idx == 2'd3) && (wr_bank == rd_bank));

    assign p0_f       = cur_p0f;
    assign p1_f       = cur_p1f;
    assign p2_f       = cur_p2f;
    assign q0_f       = cur_q0f;
    assign q1_f       = cur_q1f;
    assign q2_f       = cur_q2f;
    assign modified_p = cur_mod_p;
    assign modified_q = cur_mod_q;

    //-------------------------------------------------------------------------
    // Main Sequential Process
    //-------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_bank      <= 1'b0;
            wr_idx       <= 2'd0;
            rd_bank      <= 1'b0;
            rd_idx       <= 2'd0;
            b_ready[0]   <= 1'b0;
            b_ready[1]   <= 1'b0;
            out_valid    <= 1'b0;
        end else begin
            // -----------------------------------------------------------------
            // Input / Write Side
            // -----------------------------------------------------------------
            if (in_fire) begin
                b_p0[wr_bank][wr_idx] <= p0;
                b_p1[wr_bank][wr_idx] <= p1;
                b_p2[wr_bank][wr_idx] <= p2;
                b_p3[wr_bank][wr_idx] <= p3;
                b_q0[wr_bank][wr_idx] <= q0;
                b_q1[wr_bank][wr_idx] <= q1;
                b_q2[wr_bank][wr_idx] <= q2;
                b_q3[wr_bank][wr_idx] <= q3;

                if (wr_idx == 2'd0) begin
                    b_bs[wr_bank]   <= bs;
                    b_beta[wr_bank] <= in_beta0;
                    b_tc[wr_bank]   <= in_tc0;
                    b_dp0[wr_bank]  <= in_abs_dp;
                    b_dq0[wr_bank]  <= in_abs_dq;
                    b_d0[wr_bank]   <= in_d_val;
                    b_st0[wr_bank]  <= in_st0;
                    wr_idx          <= 2'd1;
                end else if (wr_idx == 2'd1) begin
                    wr_idx <= 2'd2;
                end else if (wr_idx == 2'd2) begin
                    wr_idx <= 2'd3;
                end else if (wr_idx == 2'd3) begin
                    b_use_strong[wr_bank] <= blk_strong;
                    b_use_weak[wr_bank]   <= blk_weak;
                    b_do_p1_adj[wr_bank]  <= blk_do_p1;
                    b_do_q1_adj[wr_bank]  <= blk_do_q1;
                    b_ready[wr_bank]      <= 1'b1;
                    wr_bank               <= ~wr_bank;
                    wr_idx                <= 2'd0;
                end
            end

            // -----------------------------------------------------------------
            // Output / Read Side
            // -----------------------------------------------------------------
            if (out_fire) begin
                if (rd_idx < 2'd3) begin
                    rd_idx <= rd_idx + 2'd1;
                    // out_valid remains 1
                end else begin
                    // Finished reading current bank
                    b_ready[rd_bank] <= 1'b0;
                    rd_bank          <= ~rd_bank;
                    rd_idx           <= 2'd0;
                    // Check if other bank has data ready
                    if (b_ready[~rd_bank] || (in_fire && (wr_idx == 2'd3) && (wr_bank == ~rd_bank))) begin
                        out_valid <= 1'b1;
                    end else begin
                        out_valid <= 1'b0;
                    end
                end
            end else if (!out_valid && rd_bank_has_data) begin
                out_valid <= 1'b1;
                rd_idx    <= 2'd0;
            end
        end
    end

    // synthesis translate_off
    always @(posedge clk) begin
        if (rst_n && in_valid && in_ready) begin
            /* if (tc_val == 10'd0 && bs != 2'd0)
                $display("INFO  [db_filter_luma] TC=0 at QP=%0d BS=%0d — no filtering",
                         edge_qp, bs); */
        end
    end
    // synthesis translate_on

endmodule