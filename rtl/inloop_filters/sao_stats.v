//=============================================================================
// sao_stats.v
// SAO Statistics Gatherer and RDO Decision
//=============================================================================

`include "parameter_pkg.vh"

module sao_stats #(
    parameter SINGLE_PASS_CAUSAL_SYNC = 0
)(
    input  wire         clk,
    input  wire         rst_n,

    input  wire         start,
    output reg          done,

    // CTU Coordinates and Frame Geometry (X/Z-safe)
    input  wire [5:0]   ctu_x,
    input  wire [5:0]   ctu_y,
    input  wire [11:0]  frame_width_px,
    input  wire [11:0]  frame_height_px,
    input  wire [5:0]   ctu_qp,

    // SRAM Interfaces
    output reg          rec_rd_valid,
    output reg  [5:0]   rec_rd_x,
    output reg  [5:0]   rec_rd_y,
    output reg  [1:0]   rec_rd_comp,
    input  wire [9:0]   rec_resp_data,

    output reg          org_rd_valid,
    output reg  [5:0]   org_rd_x,
    output reg  [5:0]   org_rd_y,
    output reg  [1:0]   org_rd_comp,
    input  wire [9:0]   org_resp_data,

    // Outputs
    output reg [5:0]    sao_type,
    output reg [5:0]    eo_class,
    output reg [74:0]   eo_offset,
    output reg [14:0]   band_pos,
    output reg [59:0]   bo_offset
);

`ifdef REMEDIATION
    localparam [3:0]
        S_IDLE        = 4'd0,
        S_COMP_INIT   = 4'd1,
        S_SCAN        = 4'd2,
        S_FLUSH       = 4'd3,
        S_OPT_LOAD    = 4'd4,
        S_OPT_DIV     = 4'd5,
        S_OPT_ITER_A  = 4'd6,
        S_OPT_ITER_B  = 4'd7,
        S_OPT_NEXT    = 4'd8,
        S_BO_SWEEP_A  = 4'd9,
        S_BO_SWEEP_B  = 4'd10,
        S_COMP_DECIDE = 4'd11,
        S_DONE        = 4'd12;

    reg [3:0] state;
    reg [1:0] comp;

    // X/Z-safe geometry & QP conditioning
    wire geom_w_known = (^frame_width_px  === 1'b0) || (^frame_width_px  === 1'b1);
    wire geom_h_known = (^frame_height_px === 1'b0) || (^frame_height_px === 1'b1);
    wire ctu_x_known  = (^ctu_x === 1'b0) || (^ctu_x === 1'b1);
    wire ctu_y_known  = (^ctu_y === 1'b0) || (^ctu_y === 1'b1);
    wire qp_known     = (^ctu_qp === 1'b0) || (^ctu_qp === 1'b1);

    wire has_geometry = geom_w_known && geom_h_known && (frame_width_px != 12'd0) && (frame_height_px != 12'd0);
    wire [11:0] eff_pic_w = has_geometry ? frame_width_px  : 12'd128;
    wire [11:0] eff_pic_h = has_geometry ? frame_height_px : 12'd128;
    wire [5:0]  eff_ctu_x = ctu_x_known ? ctu_x : 6'd0;
    wire [5:0]  eff_ctu_y = ctu_y_known ? ctu_y : 6'd0;
    wire [5:0]  eff_qp    = (qp_known && (ctu_qp <= 6'd51)) ? ctu_qp : 6'd29;

    wire [5:0] pic_w_ctu = eff_pic_w[11:6] + (|eff_pic_w[5:0] ? 6'd1 : 6'd0);
    wire [5:0] pic_h_ctu = eff_pic_h[11:6] + (|eff_pic_h[5:0] ? 6'd1 : 6'd0);
    wire       is_last_col = ({1'b0, eff_ctu_x} + 7'd1 >= {1'b0, pic_w_ctu});
    wire       is_last_row = ({1'b0, eff_ctu_y} + 7'd1 >= {1'b0, pic_h_ctu});
    wire       allow_eo    = (SINGLE_PASS_CAUSAL_SYNC == 0) && is_last_col && is_last_row;

    wire [11:0] ctu_x_px = {eff_ctu_x, 6'd0};
    wire [11:0] ctu_y_px = {eff_ctu_y, 6'd0};
    wire [11:0] rem_w_y  = (eff_pic_w > ctu_x_px) ? (eff_pic_w - ctu_x_px) : 12'd0;
    wire [11:0] rem_h_y  = (eff_pic_h > ctu_y_px) ? (eff_pic_h - ctu_y_px) : 12'd0;
    wire [6:0]  ctu_w_y  = (rem_w_y >= 12'd64) ? 7'd64 : rem_w_y[6:0];
    wire [6:0]  ctu_h_y  = (rem_h_y >= 12'd64) ? 7'd64 : rem_h_y[6:0];
    wire [6:0]  ctu_w_c  = {1'b0, ctu_w_y[6:1]};
    wire [6:0]  ctu_h_c  = {1'b0, ctu_h_y[6:1]};

    // Skip un-deblocked border columns/rows for non-last CTUs to maintain single-pass causality
    wire [6:0] active_w_y = is_last_col ? ctu_w_y : ((ctu_w_y > 7'd60) ? 7'd60 : ctu_w_y);
    wire [6:0] active_h_y = is_last_row ? ctu_h_y : ((ctu_h_y > 7'd60) ? 7'd60 : ctu_h_y);
    wire [6:0] active_w_c = is_last_col ? ctu_w_c : ((ctu_w_c > 7'd28) ? 7'd28 : ctu_w_c);
    wire [6:0] active_h_c = is_last_row ? ctu_h_c : ((ctu_h_c > 7'd30) ? 7'd30 : ctu_h_c);

    reg [6:0] valid_w;
    reg [6:0] valid_h;

    // HM Table 8-10 Chroma QP Mapping (4:2:0)
    function automatic [5:0] get_qpc;
        input [5:0] qp_luma;
        begin
            case (qp_luma)
                6'd30: get_qpc = 6'd29;
                6'd31: get_qpc = 6'd30;
                6'd32: get_qpc = 6'd31;
                6'd33: get_qpc = 6'd32;
                6'd34, 6'd35: get_qpc = 6'd33;
                6'd36, 6'd37: get_qpc = 6'd34;
                6'd38, 6'd39: get_qpc = 6'd35;
                6'd40, 6'd41: get_qpc = 6'd36;
                6'd42, 6'd43: get_qpc = 6'd37;
                6'd44: get_qpc = 6'd38;
                6'd45: get_qpc = 6'd39;
                6'd46: get_qpc = 6'd40;
                6'd47: get_qpc = 6'd41;
                6'd48: get_qpc = 6'd42;
                6'd49: get_qpc = 6'd43;
                6'd50: get_qpc = 6'd44;
                6'd51: get_qpc = 6'd45;
                default: get_qpc = (qp_luma <= 6'd29) ? qp_luma : 6'd45;
            endcase
        end
    endfunction

    // HM 10-bit (FULL_NBIT=1) Q8 SAO Lambda LUT: round(0.57 * 2^(qp/3) * 256)
    function automatic [24:0] get_lambda_q8;
        input [5:0] qp;
        begin
            case (qp)
                6'd0:  get_lambda_q8 = 25'd146;
                6'd1:  get_lambda_q8 = 25'd184;
                6'd2:  get_lambda_q8 = 25'd232;
                6'd3:  get_lambda_q8 = 25'd292;
                6'd4:  get_lambda_q8 = 25'd368;
                6'd5:  get_lambda_q8 = 25'd463;
                6'd6:  get_lambda_q8 = 25'd584;
                6'd7:  get_lambda_q8 = 25'd735;
                6'd8:  get_lambda_q8 = 25'd927;
                6'd9:  get_lambda_q8 = 25'd1167;
                6'd10: get_lambda_q8 = 25'd1471;
                6'd11: get_lambda_q8 = 25'd1853;
                6'd12: get_lambda_q8 = 25'd2335;
                6'd13: get_lambda_q8 = 25'd2942;
                6'd14: get_lambda_q8 = 25'd3706;
                6'd15: get_lambda_q8 = 25'd4669;
                6'd16: get_lambda_q8 = 25'd5883;
                6'd17: get_lambda_q8 = 25'd7412;
                6'd18: get_lambda_q8 = 25'd9339;
                6'd19: get_lambda_q8 = 25'd11766;
                6'd20: get_lambda_q8 = 25'd14825;
                6'd21: get_lambda_q8 = 25'd18678;
                6'd22: get_lambda_q8 = 25'd23533;
                6'd23: get_lambda_q8 = 25'd29649;
                6'd24: get_lambda_q8 = 25'd37356;
                6'd25: get_lambda_q8 = 25'd47065;
                6'd26: get_lambda_q8 = 25'd59298;
                6'd27: get_lambda_q8 = 25'd74711;
                6'd28: get_lambda_q8 = 25'd94130;
                6'd29: get_lambda_q8 = 25'd118596;
                6'd30: get_lambda_q8 = 25'd149422;
                6'd31: get_lambda_q8 = 25'd188260;
                6'd32: get_lambda_q8 = 25'd237193;
                6'd33: get_lambda_q8 = 25'd298844;
                6'd34: get_lambda_q8 = 25'd376520;
                6'd35: get_lambda_q8 = 25'd474386;
                6'd36: get_lambda_q8 = 25'd597688;
                6'd37: get_lambda_q8 = 25'd753040;
                6'd38: get_lambda_q8 = 25'd948771;
                6'd39: get_lambda_q8 = 25'd1195377;
                6'd40: get_lambda_q8 = 25'd1506080;
                6'd41: get_lambda_q8 = 25'd1897542;
                6'd42: get_lambda_q8 = 25'd2390753;
                6'd43: get_lambda_q8 = 25'd3012160;
                6'd44: get_lambda_q8 = 25'd3795084;
                6'd45: get_lambda_q8 = 25'd4781507;
                6'd46: get_lambda_q8 = 25'd6024321;
                6'd47: get_lambda_q8 = 25'd7590169;
                6'd48: get_lambda_q8 = 25'd9563013;
                6'd49: get_lambda_q8 = 25'd12048642;
                6'd50: get_lambda_q8 = 25'd15180337;
                default: get_lambda_q8 = 25'd19126026;
            endcase
        end
    endfunction

    function automatic signed [1:0] cmp_sign;
        input [9:0] a;
        input [9:0] b;
        begin
            if      (a > b) cmp_sign =  2'sd1;
            else if (a < b) cmp_sign = -2'sd1;
            else            cmp_sign =  2'sd0;
        end
    endfunction

    function automatic [2:0] calc_eo_cat;
        input [9:0] p;
        input [9:0] n0;
        input [9:0] n1;
        reg signed [1:0] s0;
        reg signed [1:0] s1;
        reg signed [2:0] sum_s;
        begin
            s0 = cmp_sign(p, n0);
            s1 = cmp_sign(p, n1);
            sum_s = $signed({s0[1], s0}) + $signed({s1[1], s1});
            calc_eo_cat = sum_s[2:0] + 3'd2;
        end
    endfunction

    function automatic [1:0] eo_hi_idx;
        input [2:0] c;
        begin
            eo_hi_idx = (c == 3'd3) ? 2'd2 : 2'd3;
        end
    endfunction

    wire [24:0] lambda_y_q8 = get_lambda_q8(eff_qp);
    wire [24:0] lambda_c_q8 = get_lambda_q8(get_qpc(eff_qp));
    wire [24:0] lambda_cur_q8 = (comp == 2'd0) ? lambda_y_q8 : lambda_c_q8;

    // 2-stage BRAM read alignment pipeline (rec_rd_valid -> external reg -> resp_data)
    reg [5:0] scan_x;
    reg [5:0] scan_y;
    reg       rd_req_d1, rd_req_d2;
    reg [5:0] rd_x_d1,   rd_x_d2;
    reg [5:0] rd_y_d1,   rd_y_d2;
    reg [1:0] flush_cnt;

    wire signed [10:0] pix_diff = $signed({1'b0, org_resp_data}) - $signed({1'b0, rec_resp_data});
    wire [4:0]         pix_band = rec_resp_data[9:5];

    // Shared 32-band BO statistics
    reg [12:0]        bo_cnt  [0:31];
    reg signed [23:0] bo_diff [0:31];

    // Internal 64-entry line buffers & 3x3 sliding window for last-CTU EO
    reg [9:0]         row_m1_rec  [0:63];
    reg [9:0]         row_m2_rec  [0:63];
    reg signed [10:0] row_m1_diff [0:63];

    reg [9:0]         w_t_m2, w_t_m1;
    reg [9:0]         w_m_m2, w_m_m1;
    reg [9:0]         w_b_m2, w_b_m1;
    reg signed [10:0] w_c_diff;

    reg               eo_win_valid_q;
    reg signed [10:0] eo_win_diff_q;
    reg [2:0]         eo_win_cat_q0, eo_win_cat_q1, eo_win_cat_q2, eo_win_cat_q3;

    // EO accumulators: [class 0..3][slot 0..3] for categories {0, 1, 3, 4}
    reg [12:0]        eo_cnt  [0:3][0:3];
    reg signed [23:0] eo_diff [0:3][0:3];

    // Divider & estIterOffset shared optimizer registers
    reg        opt_is_eo;
    reg [4:0]  opt_idx;

    reg [12:0] opt_cnt;
    reg [22:0] opt_diff_abs;
    reg        opt_neg;

    reg [24:0] div_rem;
    reg [13:0] div_den;
    reg [3:0]  div_q;
    reg [2:0]  div_step;

    reg [3:0]         iter_m;
    reg [3:0]         iter_best_mag;
    reg signed [43:0] iter_best_cost;
    reg [3:0]         pipe_m;
    reg [20:0]        pipe_term1; // cnt (13b) * m^2 (8b)
    reg [27:0]        pipe_term2; // 2*diff_abs (24b) * m (4b)
    reg [29:0]        pipe_rate_cost; // rate (5b) * lambda (25b)

    // Per-component derived BO/EO results
    reg signed [4:0]  bo_band_off  [0:31];
    reg signed [43:0] bo_band_cost [0:31];

    reg [4:0]         bo_bp;
    reg signed [43:0] sweep_pair0;
    reg signed [43:0] sweep_pair1;
    reg [4:0]         best_bo_bp;
    reg signed [43:0] best_bo_cost;
    reg signed [4:0]  best_bo_off0, best_bo_off1, best_bo_off2, best_bo_off3;

    reg signed [4:0]  eo_cls_off   [0:3][0:3];
    reg signed [43:0] eo_cls_cost  [0:3];

    // Saved Cb results for joint Cb+Cr decision
    reg [4:0]         cb_bo_bp;
    reg signed [43:0] cb_bo_cost;
    reg signed [4:0]  cb_bo_off0, cb_bo_off1, cb_bo_off2, cb_bo_off3;
    reg signed [4:0]  cb_eo_off   [0:3][0:3];
    reg signed [43:0] cb_eo_cost  [0:3];

    // Combinational helpers for EO window reads
    wire [9:0]         cur_t_in      = row_m2_rec[rd_x_d2];
    wire [9:0]         cur_m_in      = row_m1_rec[rd_x_d2];
    wire [9:0]         cur_b_in      = rec_resp_data;
    wire signed [10:0] cur_m_diff_in = row_m1_diff[rd_x_d2];

    wire [12:0]        load_cnt_w  = opt_is_eo ? eo_cnt[opt_idx[3:2]][opt_idx[1:0]] : bo_cnt[opt_idx];
    wire signed [23:0] load_diff_w = opt_is_eo ? eo_diff[opt_idx[3:2]][opt_idx[1:0]] : bo_diff[opt_idx];
    wire               load_neg_w  = load_diff_w[23];
    wire [23:0]        load_abs_w  = load_neg_w ? -load_diff_w : load_diff_w;
    wire               eo_sign_ok  = (opt_idx[1:0] < 2'd2) ? (!load_neg_w && (load_abs_w != 24'd0))
                                                         : (load_neg_w  && (load_abs_w != 24'd0));
    wire               load_skip   = (load_cnt_w == 13'd0) || (load_abs_w == 24'd0) || (opt_is_eo && !eo_sign_ok);

    wire [24:0] div_rem_init = {load_abs_w[22:0], 1'b0} + {12'd0, load_cnt_w};
    wire [13:0] div_den_init = {load_cnt_w, 1'b0};
    wire [17:0] div_den_x15  = {div_den, 4'b0} - {4'd0, div_den};
    wire [24:0] div_sub_term = ({11'd0, div_den} << div_step[1:0]);
    wire        div_sub_ge   = (div_rem >= div_sub_term);
    wire [3:0]  div_q_step   = div_q | (div_sub_ge ? (4'd1 << div_step[1:0]) : 4'd0);

    // 16-entry LUT for m^2 (avoids extra multiplier stage)
    function automatic [7:0] sq_4b;
        input [3:0] m;
        begin
            case (m)
                4'd0:  sq_4b = 8'd0;
                4'd1:  sq_4b = 8'd1;
                4'd2:  sq_4b = 8'd4;
                4'd3:  sq_4b = 8'd9;
                4'd4:  sq_4b = 8'd16;
                4'd5:  sq_4b = 8'd25;
                4'd6:  sq_4b = 8'd36;
                4'd7:  sq_4b = 8'd49;
                4'd8:  sq_4b = 8'd64;
                4'd9:  sq_4b = 8'd81;
                4'd10: sq_4b = 8'd100;
                4'd11: sq_4b = 8'd121;
                4'd12: sq_4b = 8'd144;
                4'd13: sq_4b = 8'd169;
                4'd14: sq_4b = 8'd196;
                default: sq_4b = 8'd225;
            endcase
        end
    endfunction

    wire [4:0]  cur_iter_rate = opt_is_eo ? ({1'b0, iter_m} + 5'd1) : ({1'b0, iter_m} + 5'd2);
    wire signed [34:0] pipe_delta_ssd = $signed({14'd0, pipe_term1}) - $signed({7'd0, pipe_term2});
    wire signed [43:0] pipe_cand_cost = $signed({pipe_delta_ssd[34], pipe_delta_ssd, 8'd0}) + $signed({14'd0, pipe_rate_cost});

    wire [4:0] bp0 = bo_bp;
    wire [4:0] bp1 = bo_bp + 5'd1;
    wire [4:0] bp2 = bo_bp + 5'd2;
    wire [4:0] bp3 = bo_bp + 5'd3;

    wire signed [43:0] cur_bo_tot_cost = sweep_pair0 + sweep_pair1 + $signed({16'd0, lambda_cur_q8, 2'd0}) + $signed({19'd0, lambda_cur_q8}); // +5*lambda

    wire signed [4:0] iter_signed_off = (iter_best_mag == 4'd0) ? 5'sd0 :
                                        (opt_neg ? -$signed({1'b0, iter_best_mag}) : $signed({1'b0, iter_best_mag}));

    wire signed [43:0] signed_lambda_cur = $signed({19'd0, lambda_cur_q8});
    wire signed [43:0] y_cost_off = $signed({19'd0, lambda_y_q8});
    wire signed [43:0] y_cost_bo  = best_bo_cost + $signed({18'd0, lambda_y_q8, 1'b0}); // +2*lambda
    wire signed [43:0] y_cost_eo0 = eo_cls_cost[0] + $signed({17'd0, lambda_y_q8, 2'd0}); // +4*lambda
    wire signed [43:0] y_cost_eo1 = eo_cls_cost[1] + $signed({17'd0, lambda_y_q8, 2'd0});
    wire signed [43:0] y_cost_eo2 = eo_cls_cost[2] + $signed({17'd0, lambda_y_q8, 2'd0});
    wire signed [43:0] y_cost_eo3 = eo_cls_cost[3] + $signed({17'd0, lambda_y_q8, 2'd0});

    wire signed [43:0] c_cost_off = $signed({19'd0, lambda_c_q8});
    wire signed [43:0] c_cost_bo  = cb_bo_cost + best_bo_cost + $signed({18'd0, lambda_c_q8, 1'b0}); // +2*lambda shared type
    wire signed [43:0] c_cost_eo0 = cb_eo_cost[0] + eo_cls_cost[0] + $signed({17'd0, lambda_c_q8, 2'd0});
    wire signed [43:0] c_cost_eo1 = cb_eo_cost[1] + eo_cls_cost[1] + $signed({17'd0, lambda_c_q8, 2'd0});
    wire signed [43:0] c_cost_eo2 = cb_eo_cost[2] + eo_cls_cost[2] + $signed({17'd0, lambda_c_q8, 2'd0});
    wire signed [43:0] c_cost_eo3 = cb_eo_cost[3] + eo_cls_cost[3] + $signed({17'd0, lambda_c_q8, 2'd0});

    integer idx;
    integer eo_k;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= S_IDLE;
            done           <= 1'b0;
            comp           <= 2'd0;
            valid_w        <= 7'd0;
            valid_h        <= 7'd0;
            rec_rd_valid   <= 1'b0;
            rec_rd_x       <= 6'd0;
            rec_rd_y       <= 6'd0;
            rec_rd_comp    <= 2'd0;
            org_rd_valid   <= 1'b0;
            org_rd_x       <= 6'd0;
            org_rd_y       <= 6'd0;
            org_rd_comp    <= 2'd0;
            scan_x         <= 6'd0;
            scan_y         <= 6'd0;
            rd_req_d1      <= 1'b0;
            rd_req_d2      <= 1'b0;
            rd_x_d1        <= 6'd0;
            rd_x_d2        <= 6'd0;
            rd_y_d1        <= 6'd0;
            rd_y_d2        <= 6'd0;
            flush_cnt      <= 2'd0;
            eo_win_valid_q <= 1'b0;
            eo_win_diff_q  <= 11'sd0;
            eo_win_cat_q0  <= 3'd2;
            eo_win_cat_q1  <= 3'd2;
            eo_win_cat_q2  <= 3'd2;
            eo_win_cat_q3  <= 3'd2;
            w_t_m2 <= 10'd0; w_t_m1 <= 10'd0;
            w_m_m2 <= 10'd0; w_m_m1 <= 10'd0;
            w_b_m2 <= 10'd0; w_b_m1 <= 10'd0;
            w_c_diff <= 11'sd0;
            opt_is_eo      <= 1'b0;
            opt_idx        <= 5'd0;
            opt_cnt        <= 13'd0;
            opt_diff_abs   <= 23'd0;
            opt_neg        <= 1'b0;
            div_rem        <= 25'd0;
            div_den        <= 14'd0;
            div_q          <= 4'd0;
            div_step       <= 3'd0;
            iter_m         <= 4'd0;
            iter_best_mag  <= 4'd0;
            iter_best_cost <= 44'sd0;
            pipe_m         <= 4'd0;
            pipe_term1     <= 21'd0;
            pipe_term2     <= 28'd0;
            pipe_rate_cost <= 30'd0;
            bo_bp          <= 5'd0;
            sweep_pair0    <= 44'sd0;
            sweep_pair1    <= 44'sd0;
            best_bo_bp     <= 5'd0;
            best_bo_cost   <= 44'sd0;
            best_bo_off0   <= 5'sd0; best_bo_off1 <= 5'sd0; best_bo_off2 <= 5'sd0; best_bo_off3 <= 5'sd0;
            cb_bo_bp       <= 5'd0;
            cb_bo_cost     <= 44'sd0;
            cb_bo_off0     <= 5'sd0; cb_bo_off1 <= 5'sd0; cb_bo_off2 <= 5'sd0; cb_bo_off3 <= 5'sd0;
            sao_type       <= 6'd0;
            eo_class       <= 6'd0;
            eo_offset      <= 75'd0;
            band_pos       <= 15'd0;
            bo_offset      <= 60'd0;
            for (idx = 0; idx < 32; idx = idx + 1) begin
                bo_cnt[idx]       <= 13'd0;
                bo_diff[idx]      <= 24'sd0;
                bo_band_off[idx]  <= 5'sd0;
                bo_band_cost[idx] <= 44'sd0;
            end
            for (idx = 0; idx < 64; idx = idx + 1) begin
                row_m1_rec[idx]  <= 10'd0;
                row_m2_rec[idx]  <= 10'd0;
                row_m1_diff[idx] <= 11'sd0;
            end
            for (eo_k = 0; eo_k < 4; eo_k = eo_k + 1) begin
                eo_cls_cost[eo_k] <= 44'sd0;
                cb_eo_cost[eo_k]  <= 44'sd0;
                for (idx = 0; idx < 4; idx = idx + 1) begin
                    eo_cnt[eo_k][idx]      <= 13'd0;
                    eo_diff[eo_k][idx]     <= 24'sd0;
                    eo_cls_off[eo_k][idx]  <= 5'sd0;
                    cb_eo_off[eo_k][idx]   <= 5'sd0;
                end
            end
        end else begin
            // Default pipeline propagation in scan/flush
            rd_req_d2 <= rd_req_d1;
            rd_x_d2   <= rd_x_d1;
            rd_y_d2   <= rd_y_d1;
            eo_win_valid_q <= 1'b0;

            if (rd_req_d2) begin
                bo_cnt[pix_band]  <= bo_cnt[pix_band] + 13'd1;
                bo_diff[pix_band] <= bo_diff[pix_band] + $signed({{13{pix_diff[10]}}, pix_diff});

                if (allow_eo) begin
                    // 3x3 sliding window update for last-CTU EO evaluation
                    w_t_m2 <= w_t_m1;
                    w_t_m1 <= cur_t_in;
                    w_m_m2 <= w_m_m1;
                    w_m_m1 <= cur_m_in;
                    w_b_m2 <= w_b_m1;
                    w_b_m1 <= cur_b_in;
                    w_c_diff <= cur_m_diff_in;

                    row_m2_rec[rd_x_d2]  <= cur_m_in;
                    row_m1_rec[rd_x_d2]  <= cur_b_in;
                    row_m1_diff[rd_x_d2] <= pix_diff;

                    // Center C = (rd_x_d2 - 1, rd_y_d2 - 1) is interior iff x >= 2 and y >= 2
                    if ((rd_x_d2 >= 6'd2) && (rd_y_d2 >= 6'd2)) begin
                        eo_win_valid_q <= 1'b1;
                        eo_win_diff_q  <= w_c_diff;
                        eo_win_cat_q0  <= calc_eo_cat(w_m_m1, w_m_m2, cur_m_in); // 0 deg: L, R
                        eo_win_cat_q1  <= calc_eo_cat(w_m_m1, w_t_m1, w_b_m1);   // 90 deg: T, B
                        eo_win_cat_q2  <= calc_eo_cat(w_m_m1, w_t_m2, cur_b_in); // 135 deg: TL, BR
                        eo_win_cat_q3  <= calc_eo_cat(w_m_m1, cur_t_in, w_b_m2); // 45 deg: TR, BL
                    end
                end
            end

            if (eo_win_valid_q) begin
                if (eo_win_cat_q0 != 3'd2) begin
                    if (eo_win_cat_q0 < 3'd2) begin
                        eo_cnt[0][eo_win_cat_q0[1:0]]  <= eo_cnt[0][eo_win_cat_q0[1:0]] + 13'd1;
                        eo_diff[0][eo_win_cat_q0[1:0]] <= eo_diff[0][eo_win_cat_q0[1:0]] + $signed({{13{eo_win_diff_q[10]}}, eo_win_diff_q});
                    end else begin
                        eo_cnt[0][eo_hi_idx(eo_win_cat_q0)]  <= eo_cnt[0][eo_hi_idx(eo_win_cat_q0)] + 13'd1;
                        eo_diff[0][eo_hi_idx(eo_win_cat_q0)] <= eo_diff[0][eo_hi_idx(eo_win_cat_q0)] + $signed({{13{eo_win_diff_q[10]}}, eo_win_diff_q});
                    end
                end
                if (eo_win_cat_q1 != 3'd2) begin
                    if (eo_win_cat_q1 < 3'd2) begin
                        eo_cnt[1][eo_win_cat_q1[1:0]]  <= eo_cnt[1][eo_win_cat_q1[1:0]] + 13'd1;
                        eo_diff[1][eo_win_cat_q1[1:0]] <= eo_diff[1][eo_win_cat_q1[1:0]] + $signed({{13{eo_win_diff_q[10]}}, eo_win_diff_q});
                    end else begin
                        eo_cnt[1][eo_hi_idx(eo_win_cat_q1)]  <= eo_cnt[1][eo_hi_idx(eo_win_cat_q1)] + 13'd1;
                        eo_diff[1][eo_hi_idx(eo_win_cat_q1)] <= eo_diff[1][eo_hi_idx(eo_win_cat_q1)] + $signed({{13{eo_win_diff_q[10]}}, eo_win_diff_q});
                    end
                end
                if (eo_win_cat_q2 != 3'd2) begin
                    if (eo_win_cat_q2 < 3'd2) begin
                        eo_cnt[2][eo_win_cat_q2[1:0]]  <= eo_cnt[2][eo_win_cat_q2[1:0]] + 13'd1;
                        eo_diff[2][eo_win_cat_q2[1:0]] <= eo_diff[2][eo_win_cat_q2[1:0]] + $signed({{13{eo_win_diff_q[10]}}, eo_win_diff_q});
                    end else begin
                        eo_cnt[2][eo_hi_idx(eo_win_cat_q2)]  <= eo_cnt[2][eo_hi_idx(eo_win_cat_q2)] + 13'd1;
                        eo_diff[2][eo_hi_idx(eo_win_cat_q2)] <= eo_diff[2][eo_hi_idx(eo_win_cat_q2)] + $signed({{13{eo_win_diff_q[10]}}, eo_win_diff_q});
                    end
                end
                if (eo_win_cat_q3 != 3'd2) begin
                    if (eo_win_cat_q3 < 3'd2) begin
                        eo_cnt[3][eo_win_cat_q3[1:0]]  <= eo_cnt[3][eo_win_cat_q3[1:0]] + 13'd1;
                        eo_diff[3][eo_win_cat_q3[1:0]] <= eo_diff[3][eo_win_cat_q3[1:0]] + $signed({{13{eo_win_diff_q[10]}}, eo_win_diff_q});
                    end else begin
                        eo_cnt[3][eo_hi_idx(eo_win_cat_q3)]  <= eo_cnt[3][eo_hi_idx(eo_win_cat_q3)] + 13'd1;
                        eo_diff[3][eo_hi_idx(eo_win_cat_q3)] <= eo_diff[3][eo_hi_idx(eo_win_cat_q3)] + $signed({{13{eo_win_diff_q[10]}}, eo_win_diff_q});
                    end
                end
            end

            case (state)
                S_IDLE: begin
                    done         <= 1'b0;
                    rec_rd_valid <= 1'b0;
                    org_rd_valid <= 1'b0;
                    rd_req_d1    <= 1'b0;
                    if (start && !done) begin
                        comp  <= 2'd0;
                        state <= S_COMP_INIT;
                    end
                end

                S_COMP_INIT: begin
                    scan_x    <= 6'd0;
                    scan_y    <= 6'd0;
                    rd_req_d1 <= 1'b0;
                    rd_req_d2 <= 1'b0;
                    eo_win_valid_q <= 1'b0;
                    flush_cnt <= 2'd0;
                    for (idx = 0; idx < 32; idx = idx + 1) begin
                        bo_cnt[idx]  <= 13'd0;
                        bo_diff[idx] <= 24'sd0;
                    end
                    for (eo_k = 0; eo_k < 4; eo_k = eo_k + 1) begin
                        eo_cls_cost[eo_k] <= 44'sd0;
                        for (idx = 0; idx < 4; idx = idx + 1) begin
                            eo_cnt[eo_k][idx]  <= 13'd0;
                            eo_diff[eo_k][idx] <= 24'sd0;
                        end
                    end
                    valid_w <= (comp == 2'd0) ? active_w_y : active_w_c;
                    valid_h <= (comp == 2'd0) ? active_h_y : active_h_c;
                    if (((comp == 2'd0) ? (active_w_y == 7'd0 || active_h_y == 7'd0)
                                        : (active_w_c == 7'd0 || active_h_c == 7'd0))) begin
                        // Degenerate empty CTU slice: jump straight to RDO with zero accumulators
                        opt_is_eo <= 1'b0;
                        opt_idx   <= 5'd0;
                        state     <= S_OPT_LOAD;
                    end else begin
                        state <= S_SCAN;
                    end
                end

                S_SCAN: begin
                    rec_rd_valid <= 1'b1;
                    rec_rd_x     <= scan_x;
                    rec_rd_y     <= scan_y;
                    rec_rd_comp  <= comp;
                    org_rd_valid <= 1'b1;
                    org_rd_x     <= scan_x;
                    org_rd_y     <= scan_y;
                    org_rd_comp  <= comp;

                    rd_req_d1    <= 1'b1;
                    rd_x_d1      <= scan_x;
                    rd_y_d1      <= scan_y;

                    if ({1'b0, scan_x} + 7'd1 >= valid_w) begin
                        scan_x <= 6'd0;
                        if ({1'b0, scan_y} + 7'd1 >= valid_h) begin
                            scan_y    <= 6'd0;
                            flush_cnt <= 2'd0;
                            state     <= S_FLUSH;
                        end else begin
                            scan_y <= scan_y + 6'd1;
                        end
                    end else begin
                        scan_x <= scan_x + 6'd1;
                    end
                end

                S_FLUSH: begin
                    rec_rd_valid <= 1'b0;
                    org_rd_valid <= 1'b0;
                    rd_req_d1    <= 1'b0;
                    if (flush_cnt == 2'd2) begin
                        opt_is_eo <= 1'b0;
                        opt_idx   <= 5'd0;
                        state     <= S_OPT_LOAD;
                    end else begin
                        flush_cnt <= flush_cnt + 2'd1;
                    end
                end

                S_OPT_LOAD: begin
                    if (load_skip) begin
                        iter_best_mag  <= 4'd0;
                        iter_best_cost <= signed_lambda_cur;
                        opt_neg        <= 1'b0;
                        state          <= S_OPT_NEXT;
                    end else begin
                        opt_cnt      <= load_cnt_w;
                        opt_diff_abs <= load_abs_w[22:0];
                        opt_neg      <= load_neg_w;
                        div_rem      <= div_rem_init;
                        div_den      <= div_den_init;
                        div_q        <= 4'd0;
                        div_step     <= 3'd4;
                        iter_best_mag  <= 4'd0;
                        iter_best_cost <= signed_lambda_cur;
                        state          <= S_OPT_DIV;
                    end
                end

                S_OPT_DIV: begin
                    if (div_step == 3'd4) begin
                        if ({1'b0, div_rem} >= {8'd0, div_den_x15}) begin
                            iter_m <= 4'd15;
                            state  <= S_OPT_ITER_A;
                        end else begin
                            div_step <= 3'd3;
                        end
                    end else begin
                        if (div_sub_ge)
                            div_rem <= div_rem - div_sub_term;
                        div_q <= div_q_step;
                        if (div_step == 3'd0) begin
                            if (div_q_step == 4'd0) begin
                                state <= S_OPT_NEXT;
                            end else begin
                                iter_m <= div_q_step;
                                state  <= S_OPT_ITER_A;
                            end
                        end else begin
                            div_step <= div_step - 3'd1;
                        end
                    end
                end

                S_OPT_ITER_A: begin
                    pipe_m         <= iter_m;
                    pipe_term1     <= opt_cnt * sq_4b(iter_m);
                    pipe_term2     <= {opt_diff_abs, 1'b0} * iter_m;
                    pipe_rate_cost <= cur_iter_rate * lambda_cur_q8;
                    state          <= S_OPT_ITER_B;
                end

                S_OPT_ITER_B: begin
                    if (pipe_cand_cost < iter_best_cost) begin
                        iter_best_cost <= pipe_cand_cost;
                        iter_best_mag  <= pipe_m;
                    end
                    if (iter_m > 4'd1) begin
                        iter_m <= iter_m - 4'd1;
                        state  <= S_OPT_ITER_A;
                    end else begin
                        state <= S_OPT_NEXT;
                    end
                end

                S_OPT_NEXT: begin
                    if (!opt_is_eo) begin
                        bo_band_off[opt_idx]  <= iter_signed_off;
                        bo_band_cost[opt_idx] <= iter_best_cost;
                        if (opt_idx == 5'd31) begin
                            bo_bp <= 5'd0;
                            state <= S_BO_SWEEP_A;
                        end else begin
                            opt_idx <= opt_idx + 5'd1;
                            state   <= S_OPT_LOAD;
                        end
                    end else begin
                        eo_cls_off[opt_idx[3:2]][opt_idx[1:0]] <= iter_signed_off;
                        eo_cls_cost[opt_idx[3:2]] <= eo_cls_cost[opt_idx[3:2]] + iter_best_cost;
                        if (opt_idx[3:0] == 4'd15) begin
                            state <= S_COMP_DECIDE;
                        end else begin
                            opt_idx <= opt_idx + 5'd1;
                            state   <= S_OPT_LOAD;
                        end
                    end
                end

                S_BO_SWEEP_A: begin
                    sweep_pair0 <= bo_band_cost[bp0] + bo_band_cost[bp1];
                    sweep_pair1 <= bo_band_cost[bp2] + bo_band_cost[bp3];
                    state       <= S_BO_SWEEP_B;
                end

                S_BO_SWEEP_B: begin
                    if ((bo_bp == 5'd0) || (cur_bo_tot_cost < best_bo_cost)) begin
                        best_bo_cost <= cur_bo_tot_cost;
                        best_bo_bp   <= bo_bp;
                        best_bo_off0 <= bo_band_off[bp0];
                        best_bo_off1 <= bo_band_off[bp1];
                        best_bo_off2 <= bo_band_off[bp2];
                        best_bo_off3 <= bo_band_off[bp3];
                    end
                    if (bo_bp == 5'd31) begin
                        if (allow_eo) begin
                            opt_is_eo <= 1'b1;
                            opt_idx   <= 5'd0;
                            state     <= S_OPT_LOAD;
                        end else begin
                            state <= S_COMP_DECIDE;
                        end
                    end else begin
                        bo_bp <= bo_bp + 5'd1;
                        state <= S_BO_SWEEP_A;
                    end
                end

                S_COMP_DECIDE: begin
                    if (comp == 2'd0) begin
                        // Independent Y mode decision
                        if (allow_eo && (y_cost_eo0 < y_cost_off) && (y_cost_eo0 <= y_cost_bo) &&
                            (y_cost_eo0 <= y_cost_eo1) && (y_cost_eo0 <= y_cost_eo2) && (y_cost_eo0 <= y_cost_eo3)) begin
                            sao_type[1:0]   <= 2'd1;
                            eo_class[1:0]   <= 2'd0;
                            eo_offset[24:0] <= {eo_cls_off[0][3], eo_cls_off[0][2], 5'sd0, eo_cls_off[0][1], eo_cls_off[0][0]};
                            band_pos[4:0]   <= 5'd0;
                            bo_offset[19:0] <= 20'd0;
                        end else if (allow_eo && (y_cost_eo1 < y_cost_off) && (y_cost_eo1 <= y_cost_bo) &&
                                     (y_cost_eo1 < y_cost_eo0) && (y_cost_eo1 <= y_cost_eo2) && (y_cost_eo1 <= y_cost_eo3)) begin
                            sao_type[1:0]   <= 2'd1;
                            eo_class[1:0]   <= 2'd1;
                            eo_offset[24:0] <= {eo_cls_off[1][3], eo_cls_off[1][2], 5'sd0, eo_cls_off[1][1], eo_cls_off[1][0]};
                            band_pos[4:0]   <= 5'd0;
                            bo_offset[19:0] <= 20'd0;
                        end else if (allow_eo && (y_cost_eo2 < y_cost_off) && (y_cost_eo2 <= y_cost_bo) &&
                                     (y_cost_eo2 < y_cost_eo0) && (y_cost_eo2 < y_cost_eo1) && (y_cost_eo2 <= y_cost_eo3)) begin
                            sao_type[1:0]   <= 2'd1;
                            eo_class[1:0]   <= 2'd2;
                            eo_offset[24:0] <= {eo_cls_off[2][3], eo_cls_off[2][2], 5'sd0, eo_cls_off[2][1], eo_cls_off[2][0]};
                            band_pos[4:0]   <= 5'd0;
                            bo_offset[19:0] <= 20'd0;
                        end else if (allow_eo && (y_cost_eo3 < y_cost_off) && (y_cost_eo3 <= y_cost_bo) &&
                                     (y_cost_eo3 < y_cost_eo0) && (y_cost_eo3 < y_cost_eo1) && (y_cost_eo3 < y_cost_eo2)) begin
                            sao_type[1:0]   <= 2'd1;
                            eo_class[1:0]   <= 2'd3;
                            eo_offset[24:0] <= {eo_cls_off[3][3], eo_cls_off[3][2], 5'sd0, eo_cls_off[3][1], eo_cls_off[3][0]};
                            band_pos[4:0]   <= 5'd0;
                            bo_offset[19:0] <= 20'd0;
                        end else if (y_cost_bo < y_cost_off) begin
                            sao_type[1:0]   <= 2'd2;
                            eo_class[1:0]   <= 2'd0;
                            eo_offset[24:0] <= 25'd0;
                            band_pos[4:0]   <= best_bo_bp;
                            bo_offset[19:0] <= {best_bo_off3, best_bo_off2, best_bo_off1, best_bo_off0};
                        end else begin
                            sao_type[1:0]   <= 2'd0;
                            eo_class[1:0]   <= 2'd0;
                            eo_offset[24:0] <= 25'd0;
                            band_pos[4:0]   <= 5'd0;
                            bo_offset[19:0] <= 20'd0;
                        end
                        comp  <= 2'd1;
                        state <= S_COMP_INIT;
                    end else if (comp == 2'd1) begin
                        // Save Cb candidates for joint Cb+Cr RDO
                        cb_bo_bp   <= best_bo_bp;
                        cb_bo_cost <= best_bo_cost;
                        cb_bo_off0 <= best_bo_off0;
                        cb_bo_off1 <= best_bo_off1;
                        cb_bo_off2 <= best_bo_off2;
                        cb_bo_off3 <= best_bo_off3;
                        for (eo_k = 0; eo_k < 4; eo_k = eo_k + 1) begin
                            cb_eo_cost[eo_k] <= eo_cls_cost[eo_k];
                            for (idx = 0; idx < 4; idx = idx + 1)
                                cb_eo_off[eo_k][idx] <= eo_cls_off[eo_k][idx];
                        end
                        comp  <= 2'd2;
                        state <= S_COMP_INIT;
                    end else begin
                        // Joint Cb+Cr mode decision matching syntax_sao.v
                        if (allow_eo && (c_cost_eo0 < c_cost_off) && (c_cost_eo0 <= c_cost_bo) &&
                            (c_cost_eo0 <= c_cost_eo1) && (c_cost_eo0 <= c_cost_eo2) && (c_cost_eo0 <= c_cost_eo3)) begin
                            sao_type[5:2]   <= {2'd1, 2'd1};
                            eo_class[5:2]   <= {2'd0, 2'd0};
                            eo_offset[49:25]<= {cb_eo_off[0][3], cb_eo_off[0][2], 5'sd0, cb_eo_off[0][1], cb_eo_off[0][0]};
                            eo_offset[74:50]<= {eo_cls_off[0][3], eo_cls_off[0][2], 5'sd0, eo_cls_off[0][1], eo_cls_off[0][0]};
                            band_pos[14:5]  <= 10'd0;
                            bo_offset[59:20]<= 40'd0;
                        end else if (allow_eo && (c_cost_eo1 < c_cost_off) && (c_cost_eo1 <= c_cost_bo) &&
                                     (c_cost_eo1 < c_cost_eo0) && (c_cost_eo1 <= c_cost_eo2) && (c_cost_eo1 <= c_cost_eo3)) begin
                            sao_type[5:2]   <= {2'd1, 2'd1};
                            eo_class[5:2]   <= {2'd1, 2'd1};
                            eo_offset[49:25]<= {cb_eo_off[1][3], cb_eo_off[1][2], 5'sd0, cb_eo_off[1][1], cb_eo_off[1][0]};
                            eo_offset[74:50]<= {eo_cls_off[1][3], eo_cls_off[1][2], 5'sd0, eo_cls_off[1][1], eo_cls_off[1][0]};
                            band_pos[14:5]  <= 10'd0;
                            bo_offset[59:20]<= 40'd0;
                        end else if (allow_eo && (c_cost_eo2 < c_cost_off) && (c_cost_eo2 <= c_cost_bo) &&
                                     (c_cost_eo2 < c_cost_eo0) && (c_cost_eo2 < c_cost_eo1) && (c_cost_eo2 <= c_cost_eo3)) begin
                            sao_type[5:2]   <= {2'd1, 2'd1};
                            eo_class[5:2]   <= {2'd2, 2'd2};
                            eo_offset[49:25]<= {cb_eo_off[2][3], cb_eo_off[2][2], 5'sd0, cb_eo_off[2][1], cb_eo_off[2][0]};
                            eo_offset[74:50]<= {eo_cls_off[2][3], eo_cls_off[2][2], 5'sd0, eo_cls_off[2][1], eo_cls_off[2][0]};
                            band_pos[14:5]  <= 10'd0;
                            bo_offset[59:20]<= 40'd0;
                        end else if (allow_eo && (c_cost_eo3 < c_cost_off) && (c_cost_eo3 <= c_cost_bo) &&
                                     (c_cost_eo3 < c_cost_eo0) && (c_cost_eo3 < c_cost_eo1) && (c_cost_eo3 < c_cost_eo2)) begin
                            sao_type[5:2]   <= {2'd1, 2'd1};
                            eo_class[5:2]   <= {2'd3, 2'd3};
                            eo_offset[49:25]<= {cb_eo_off[3][3], cb_eo_off[3][2], 5'sd0, cb_eo_off[3][1], cb_eo_off[3][0]};
                            eo_offset[74:50]<= {eo_cls_off[3][3], eo_cls_off[3][2], 5'sd0, eo_cls_off[3][1], eo_cls_off[3][0]};
                            band_pos[14:5]  <= 10'd0;
                            bo_offset[59:20]<= 40'd0;
                        end else if (c_cost_bo < c_cost_off) begin
                            sao_type[5:2]   <= {2'd2, 2'd2};
                            eo_class[5:2]   <= 4'd0;
                            eo_offset[74:25]<= 50'd0;
                            band_pos[9:5]   <= cb_bo_bp;
                            band_pos[14:10] <= best_bo_bp;
                            bo_offset[39:20]<= {cb_bo_off3, cb_bo_off2, cb_bo_off1, cb_bo_off0};
                            bo_offset[59:40]<= {best_bo_off3, best_bo_off2, best_bo_off1, best_bo_off0};
                        end else begin
                            sao_type[5:2]   <= 4'd0;
                            eo_class[5:2]   <= 4'd0;
                            eo_offset[74:25]<= 50'd0;
                            band_pos[14:5]  <= 10'd0;
                            bo_offset[59:20]<= 40'd0;
                        end
                        state <= S_DONE;
                    end
                end

                S_DONE: begin
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
`else
    wire has_geometry = (|frame_width_px === 1'b1);
    wire [5:0] pic_width_in_ctu = has_geometry ? (frame_width_px[11:6] + (|frame_width_px[5:0] ? 6'd1 : 6'd0)) : 6'd2;
    wire [5:0] pic_height_in_ctu = has_geometry ? (frame_height_px[11:6] + (|frame_height_px[5:0] ? 6'd1 : 6'd0)) : 6'd2;
    wire is_last_col = (ctu_x + 6'd1 >= pic_width_in_ctu);
    wire is_last_row = (ctu_y + 6'd1 >= pic_height_in_ctu);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            done <= 0;
            rec_rd_valid <= 0; org_rd_valid <= 0;
            sao_type <= 0; eo_class <= 0; eo_offset <= 0; band_pos <= 0; bo_offset <= 0;
        end else begin
            rec_rd_valid <= 0;
            org_rd_valid <= 0;
            if (start && !done) begin
                done <= 1;
                sao_type <= 0;
                eo_class <= 0;
                eo_offset <= 0;
                band_pos <= 0;
                bo_offset <= 0;
            end else begin
                done <= 0;
            end
        end
    end
`endif

endmodule
