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

    output reg  [`PIXEL_WIDTH-1:0] p0_f, p1_f, p2_f,   // filtered P samples
    output reg  [`PIXEL_WIDTH-1:0] q0_f, q1_f, q2_f,   // filtered Q samples
    output reg          modified_p,     // 1=P side was modified
    output reg          modified_q      // 1=Q side was modified
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

    //-------------------------------------------------------------------------
    // Immediate single-group mode — ready when no pending output
    //-------------------------------------------------------------------------
    assign in_ready = out_ready || !out_valid;

    //-------------------------------------------------------------------------
    // Threshold computation (combinational from edge_qp and bs)
    //-------------------------------------------------------------------------
    wire [9:0] beta_val = {3'b0, beta_table(edge_qp)} << (`BIT_DEPTH - 8);
    wire [6:0] tc_idx   = {1'b0, edge_qp} + ((bs == 2'd2) ? 7'd2 : 7'd0);
    wire [9:0] tc_val   = {3'b0, tc_table(tc_idx)} << (`BIT_DEPTH - 8);

    //-------------------------------------------------------------------------
    // Per-sample metrics (combinational from p0-p3, q0-q3)
    //-------------------------------------------------------------------------
    wire signed [11:0] dp_raw = $signed({2'b0, p2}) - $signed({1'b0, p1, 1'b0}) + $signed({2'b0, p0});
    wire signed [11:0] dq_raw = $signed({2'b0, q2}) - $signed({1'b0, q1, 1'b0}) + $signed({2'b0, q0});
    wire [10:0] abs_dp = dp_raw[11] ? (~dp_raw[10:0] + 11'd1) : dp_raw[10:0];
    wire [10:0] abs_dq = dq_raw[11] ? (~dq_raw[10:0] + 11'd1) : dq_raw[10:0];

    wire signed [11:0] p3p0_diff = $signed({2'b0, p3}) - $signed({2'b0, p0});
    wire signed [11:0] q3q0_diff = $signed({2'b0, q3}) - $signed({2'b0, q0});
    wire [10:0] abs_p3p0 = p3p0_diff[11] ? (~p3p0_diff[10:0]+11'd1) : p3p0_diff[10:0];
    wire [10:0] abs_q3q0 = q3q0_diff[11] ? (~q3q0_diff[10:0]+11'd1) : q3q0_diff[10:0];
    wire [11:0] ends_val = {1'b0, abs_p3p0} + {1'b0, abs_q3q0};

    wire signed [11:0] p0q0_diff = $signed({2'b0, p0}) - $signed({2'b0, q0});
    wire [10:0] abs_p0q0 = p0q0_diff[11] ? (~p0q0_diff[10:0]+11'd1) : p0q0_diff[10:0];

    //-------------------------------------------------------------------------
    // Strong/Weak decision (approximated per-group: 2×dp, 2×dq)
    //-------------------------------------------------------------------------
    // Block-level uses dp0+dp3; we approximate with 2×current dp
    wire [11:0] dp_blk = {abs_dp, 1'b0};  // 2 × abs_dp
    wire [11:0] dq_blk = {abs_dq, 1'b0};  // 2 × abs_dq
    wire [12:0] d_blk  = {1'b0, dp_blk} + {1'b0, dq_blk};

    wire [7:0] beta_div4 = beta_val[9:2];
    wire [6:0] beta_div8 = beta_val[9:3];
    wire [12:0] tc5_1_2  = ({1'b0, tc_val, 2'b0} + {3'b0, tc_val} + 13'd1) >> 1;

    wire d_lt_beta4     = d_blk < {5'b0, beta_div4};
    wire ends_lt_beta8  = ends_val < {5'b0, beta_div8};
    wire p0q0_lt_tc5    = {1'b0, abs_p0q0} < tc5_1_2[11:0];

    wire use_strong = d_lt_beta4 && ends_lt_beta8 && p0q0_lt_tc5;
    wire use_weak   = !use_strong && (d_blk < {3'b0, beta_val});

    wire [10:0] side_thresh = ({1'b0, beta_val} + {2'b0, beta_val[9:1]}) >> 3;
    wire do_p1_adj = dp_blk < {1'b0, side_thresh};
    wire do_q1_adj = dq_blk < {1'b0, side_thresh};

    //-------------------------------------------------------------------------
    // Strong filter computation
    //-------------------------------------------------------------------------
    wire signed [13:0] tc2 = $signed({4'b0, tc_val}) << 1;

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

    wire [`PIXEL_WIDTH-1:0] sp0 = clip_strong($signed({4'b0, p0}),
        ($signed({4'b0, p2}) + $signed({3'b0, p1, 1'b0}) + $signed({3'b0, p0, 1'b0})
         + $signed({3'b0, q0, 1'b0}) + $signed({4'b0, q1}) + 14'sd4) >>> 3, tc2);

    wire [`PIXEL_WIDTH-1:0] sp1 = clip_strong($signed({4'b0, p1}),
        ($signed({4'b0, p2}) + $signed({4'b0, p1}) + $signed({4'b0, p0})
         + $signed({4'b0, q0}) + 14'sd2) >>> 2, tc2);

    wire [`PIXEL_WIDTH-1:0] sp2 = clip_strong($signed({4'b0, p2}),
        ($signed({3'b0, p3, 1'b0}) + $signed({3'b0, p2, 1'b0}) + $signed({4'b0, p2})
         + $signed({4'b0, p1}) + $signed({4'b0, p0}) + $signed({4'b0, q0}) + 14'sd4) >>> 3, tc2);

    wire [`PIXEL_WIDTH-1:0] sq0 = clip_strong($signed({4'b0, q0}),
        ($signed({4'b0, p1}) + $signed({3'b0, p0, 1'b0}) + $signed({3'b0, q0, 1'b0})
         + $signed({3'b0, q1, 1'b0}) + $signed({4'b0, q2}) + 14'sd4) >>> 3, tc2);

    wire [`PIXEL_WIDTH-1:0] sq1 = clip_strong($signed({4'b0, q1}),
        ($signed({4'b0, p0}) + $signed({4'b0, q0}) + $signed({4'b0, q1})
         + $signed({4'b0, q2}) + 14'sd2) >>> 2, tc2);

    wire [`PIXEL_WIDTH-1:0] sq2 = clip_strong($signed({4'b0, q2}),
        ($signed({4'b0, p0}) + $signed({4'b0, q0}) + $signed({4'b0, q1})
         + $signed({3'b0, q2, 1'b0}) + $signed({4'b0, q2}) + $signed({3'b0, q3, 1'b0})
         + 14'sd4) >>> 3, tc2);

    //-------------------------------------------------------------------------
    // Weak filter computation
    //-------------------------------------------------------------------------
    wire signed [11:0] q0_p0  = $signed({2'b0, q0}) - $signed({2'b0, p0});
    wire signed [11:0] q1_p1  = $signed({2'b0, q1}) - $signed({2'b0, p1});
    wire signed [14:0] nine_diff  = $signed({{3{q0_p0[11]}}, q0_p0}) * 15'sd9;
    wire signed [14:0] three_diff = $signed({{3{q1_p1[11]}}, q1_p1}) * 15'sd3;
    wire signed [14:0] raw_delta  = (nine_diff - three_diff + 15'sd8) >>> 4;

    wire [14:0] abs_raw_delta = raw_delta[14] ? (~raw_delta + 15'd1) : raw_delta;
    wire [13:0] tc10_v = ({4'b0, tc_val} << 3) + ({4'b0, tc_val} << 1);
    wire delta_valid = (abs_raw_delta < {1'b0, tc10_v});

    wire signed [11:0] tc_pos = $signed({2'b0, tc_val});
    wire signed [11:0] tc_neg = -$signed({2'b0, tc_val});
    wire signed [11:0] delta  = delta_valid ? clip3(tc_neg, tc_pos, raw_delta[11:0]) : 12'sd0;

    wire do_p1 = delta_valid && do_p1_adj;
    wire do_q1 = delta_valid && do_q1_adj;

    wire signed [11:0] tc_half_pos = $signed({3'b0, tc_val[9:1]});
    wire signed [11:0] tc_half_neg = -$signed({3'b0, tc_val[9:1]});

    wire signed [11:0] p2_p0_avg  = ($signed({2'b0, p2}) + $signed({2'b0, p0}) + 12'sd1) >>> 1;
    wire signed [12:0] deltap_raw = (p2_p0_avg - $signed({2'b0, p1}) + delta) >>> 1;
    wire signed [11:0] deltap     = clip3(tc_half_neg, tc_half_pos, deltap_raw[11:0]);

    wire signed [11:0] q2_q0_avg  = ($signed({2'b0, q2}) + $signed({2'b0, q0}) + 12'sd1) >>> 1;
    wire signed [12:0] deltaq_raw = (q2_q0_avg - $signed({2'b0, q1}) - delta) >>> 1;
    wire signed [11:0] deltaq     = clip3(tc_half_neg, tc_half_pos, deltaq_raw[11:0]);

    wire [`PIXEL_WIDTH-1:0] wp0 = clip1($signed({2'b0, p0}) + delta);
    wire [`PIXEL_WIDTH-1:0] wq0 = clip1($signed({2'b0, q0}) - delta);
    wire [`PIXEL_WIDTH-1:0] wp1 = do_p1 ? clip1($signed({2'b0, p1}) + deltap) : p1;
    wire [`PIXEL_WIDTH-1:0] wq1 = do_q1 ? clip1($signed({2'b0, q1}) + deltaq) : q1;

    //-------------------------------------------------------------------------
    // Output register — single-cycle latency
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            out_valid  <= 1'b0;
            modified_p <= 1'b0;
            modified_q <= 1'b0;
            p0_f <= 0; p1_f <= 0; p2_f <= 0;
            q0_f <= 0; q1_f <= 0; q2_f <= 0;
        end else begin
            if (out_ready) out_valid <= 1'b0;

            if (in_valid && in_ready) begin
                out_valid <= 1'b1;

                if (bs == 2'd0) begin
                    // BS=0: pass-through
                    p0_f <= p0; p1_f <= p1; p2_f <= p2;
                    q0_f <= q0; q1_f <= q1; q2_f <= q2;
                    modified_p <= 1'b0; modified_q <= 1'b0;
                end else if (use_strong) begin
                    p0_f <= sp0; p1_f <= sp1; p2_f <= sp2;
                    q0_f <= sq0; q1_f <= sq1; q2_f <= sq2;
                    modified_p <= 1'b1; modified_q <= 1'b1;
                end else if (use_weak) begin
                    p0_f <= wp0; p1_f <= wp1; p2_f <= p2;
                    q0_f <= wq0; q1_f <= wq1; q2_f <= q2;
                    modified_p <= 1'b1; modified_q <= 1'b1;
                end else begin
                    // Filter decision: no modification
                    p0_f <= p0; p1_f <= p1; p2_f <= p2;
                    q0_f <= q0; q1_f <= q1; q2_f <= q2;
                    modified_p <= 1'b0; modified_q <= 1'b0;
                end
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