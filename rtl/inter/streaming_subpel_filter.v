//=============================================================================
// streaming_subpel_filter.v
// Pipelined Streaming Sub-Pel Interpolation Filter for Hardware Synthesis
//
// Normative References:
//   - ITU-T H.265 Clause 8.5.3.3.3 (Fractional sample interpolation)
//   - ITU-T H.265 Clause 8.5.3.3.4.2 (Weighted sample bi-prediction)
//   - HM 18.0 TComInterpolationFilter & TComYuv::addAvg
//
// Architecture (200 MHz timing closure target):
//   - Line buffer window cache (7-line buffer for luma, 3-line for chroma)
//   - Pipelined 8-tap luma and 4-tap chroma Wiener FIR engines
//   - Stage 1: Horizontal FIR with Clause 8.5.3.3.3 plain truncation (>>> 2)
//   - Stage 2: Vertical FIR with Clause 8.5.3.3.3 folding
//   - Stage 3: Bi-prediction Clause 8.5.3.3.4.2 weighted averaging & clipping
//=============================================================================

`timescale 1ns/1ps
`include "parameter_pkg.vh"

module streaming_subpel_filter #(
    parameter PIXEL_WIDTH  = `PIXEL_WIDTH,  // 10
    parameter INTERM_WIDTH = PIXEL_WIDTH + 6 // 16: intermediate precision
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     valid_in,
    input  wire [1:0]               comp,        // 0: Y, 1: Cb, 2: Cr
    input  wire                     is_bi_pred,
    input  wire [2:0]               frac_x,
    input  wire [2:0]               frac_y,

    // Window inputs for List 0 (flattened 8x8 luma or 4x4 chroma)
    input  wire [PIXEL_WIDTH*64-1:0] win_l0_flat,
    // Window inputs for List 1 (flattened 8x8 luma or 4x4 chroma)
    input  wire [PIXEL_WIDTH*64-1:0] win_l1_flat,

    output reg                      valid_out,
    output reg  [PIXEL_WIDTH-1:0]   pred_pixel
);

    // =========================================================================
    // Filter Coefficients Lookup
    // =========================================================================
    function automatic signed [6:0] get_luma_coeff;
        input [1:0] phase;
        input [2:0] tap;
        reg signed [6:0] c;
        begin
            case (phase)
                2'd0: c = (tap == 3) ? 7'sd64 : 7'sd0;
                2'd1: case (tap)
                    3'd0: c = -7'sd1;
                    3'd1: c =  7'sd4;
                    3'd2: c = -7'sd10;
                    3'd3: c =  7'sd58;
                    3'd4: c =  7'sd17;
                    3'd5: c = -7'sd5;
                    3'd6: c =  7'sd1;
                    default: c = 7'sd0;
                endcase
                2'd2: case (tap)
                    3'd0: c = -7'sd1;
                    3'd1: c =  7'sd4;
                    3'd2: c = -7'sd11;
                    3'd3: c =  7'sd40;
                    3'd4: c =  7'sd40;
                    3'd5: c = -7'sd11;
                    3'd6: c =  7'sd4;
                    default: c = -7'sd1;
                endcase
                default: case (tap) // 2'd3
                    3'd0: c =  7'sd0;
                    3'd1: c =  7'sd1;
                    3'd2: c = -7'sd5;
                    3'd3: c =  7'sd17;
                    3'd4: c =  7'sd58;
                    3'd5: c = -7'sd10;
                    3'd6: c =  7'sd4;
                    default: c = -7'sd1;
                endcase
            endcase
            get_luma_coeff = c;
        end
    endfunction

    function automatic signed [6:0] get_chroma_coeff;
        input [2:0] phase;
        input [1:0] tap;
        reg signed [6:0] c;
        begin
            case (phase)
                3'd0: c = (tap == 1) ? 7'sd64 : 7'sd0;
                3'd1: case (tap) 2'd0: c = -7'sd2; 2'd1: c =  7'sd58; 2'd2: c =  7'sd10; default: c = -7'sd2; endcase
                3'd2: case (tap) 2'd0: c = -7'sd4; 2'd1: c =  7'sd54; 2'd2: c =  7'sd16; default: c = -7'sd2; endcase
                3'd3: case (tap) 2'd0: c = -7'sd6; 2'd1: c =  7'sd46; 2'd2: c =  7'sd28; default: c = -7'sd4; endcase
                3'd4: case (tap) 2'd0: c = -7'sd4; 2'd1: c =  7'sd36; 2'd2: c =  7'sd36; default: c = -7'sd4; endcase
                3'd5: case (tap) 2'd0: c = -7'sd4; 2'd1: c =  7'sd28; 2'd2: c =  7'sd46; default: c = -7'sd6; endcase
                3'd6: case (tap) 2'd0: c = -7'sd2; 2'd1: c =  7'sd16; 2'd2: c =  7'sd54; default: c = -7'sd4; endcase
                default: case (tap) // 3'd7
                    2'd0: c = -7'sd2; 2'd1: c =  7'sd10; 2'd2: c =  7'sd58; default: c = -7'sd2;
                endcase
            endcase
            get_chroma_coeff = c;
        end
    endfunction

    // Pixel extraction helper (stride 8 for luma 8x8, stride 4 for chroma 4x4)
    function automatic [PIXEL_WIDTH-1:0] get_win_px;
        input [PIXEL_WIDTH*64-1:0] flat;
        input integer r, c;
        input [1:0] c_comp;
        begin
            if (c_comp == 2'd0)
                get_win_px = flat[PIXEL_WIDTH*(r*8 + c) +: PIXEL_WIDTH];
            else
                get_win_px = flat[PIXEL_WIDTH*(r*4 + c) +: PIXEL_WIDTH];
        end
    endfunction

    // Clip to 10 bits
    function automatic [PIXEL_WIDTH-1:0] clip_10;
        input signed [24:0] val;
        begin
            if (val < 0) clip_10 = 10'd0;
            else if (val > 1023) clip_10 = 10'd1023;
            else clip_10 = val[9:0];
        end
    endfunction

    // =========================================================================
    // Pipeline Registers
    // =========================================================================
    // Stage 1: Horizontal Pass
    reg        s1_valid;
    reg [1:0]  s1_comp;
    reg        s1_is_bi;
    reg [2:0]  s1_fy;
    reg [2:0]  s1_fx;
    reg signed [INTERM_WIDTH-1:0] s1_hint_l0 [0:7];
    reg signed [INTERM_WIDTH-1:0] s1_hint_l1 [0:7];
    reg signed [24:0]             s1_vsum_l0;
    reg signed [24:0]             s1_vsum_l1;
    reg [PIXEL_WIDTH-1:0]         s1_int_l0;
    reg [PIXEL_WIDTH-1:0]         s1_int_l1;

    integer r_idx, k_idx;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid <= 1'b0;
            s1_comp  <= 2'd0;
            s1_is_bi <= 1'b0;
            s1_fy    <= 3'd0;
            s1_fx    <= 3'd0;
            s1_vsum_l0 <= 25'sd0;
            s1_vsum_l1 <= 25'sd0;
            s1_int_l0  <= 10'd0;
            s1_int_l1  <= 10'd0;
            for (r_idx = 0; r_idx < 8; r_idx = r_idx + 1) begin
                s1_hint_l0[r_idx] <= {INTERM_WIDTH{1'b0}};
                s1_hint_l1[r_idx] <= {INTERM_WIDTH{1'b0}};
            end
        end else begin
            s1_valid <= valid_in;
            s1_comp  <= comp;
            s1_is_bi <= is_bi_pred;
            s1_fy    <= frac_y;
            s1_fx    <= frac_x;

            if (comp == 2'd0) begin
                // Luma (8x8)
                s1_int_l0 <= get_win_px(win_l0_flat, 3, 3, comp);
                s1_int_l1 <= get_win_px(win_l1_flat, 3, 3, comp);

                // Horizontal rows 0..7
                for (r_idx = 0; r_idx < 8; r_idx = r_idx + 1) begin
                    reg signed [24:0] acc_l0, acc_l1;
                    acc_l0 = 0;
                    acc_l1 = 0;
                    for (k_idx = 0; k_idx < 8; k_idx = k_idx + 1) begin
                        acc_l0 = acc_l0 + get_luma_coeff(frac_x[1:0], k_idx[2:0]) * $signed({1'b0, get_win_px(win_l0_flat, r_idx, k_idx, comp)});
                        acc_l1 = acc_l1 + get_luma_coeff(frac_x[1:0], k_idx[2:0]) * $signed({1'b0, get_win_px(win_l1_flat, r_idx, k_idx, comp)});
                    end
                    s1_hint_l0[r_idx] <= acc_l0 >>> 2;
                    s1_hint_l1[r_idx] <= acc_l1 >>> 2;
                end

                // V-only pass on col 3
                begin : luma_v
                    reg signed [24:0] vacc_l0, vacc_l1;
                    vacc_l0 = 0;
                    vacc_l1 = 0;
                    for (k_idx = 0; k_idx < 8; k_idx = k_idx + 1) begin
                        vacc_l0 = vacc_l0 + get_luma_coeff(frac_y[1:0], k_idx[2:0]) * $signed({1'b0, get_win_px(win_l0_flat, k_idx, 3, comp)});
                        vacc_l1 = vacc_l1 + get_luma_coeff(frac_y[1:0], k_idx[2:0]) * $signed({1'b0, get_win_px(win_l1_flat, k_idx, 3, comp)});
                    end
                    s1_vsum_l0 <= vacc_l0;
                    s1_vsum_l1 <= vacc_l1;
                end
            end else begin
                // Chroma (4x4)
                s1_int_l0 <= get_win_px(win_l0_flat, 1, 1, comp);
                s1_int_l1 <= get_win_px(win_l1_flat, 1, 1, comp);

                for (r_idx = 0; r_idx < 4; r_idx = r_idx + 1) begin
                    reg signed [24:0] acc_l0, acc_l1;
                    acc_l0 = 0;
                    acc_l1 = 0;
                    for (k_idx = 0; k_idx < 4; k_idx = k_idx + 1) begin
                        acc_l0 = acc_l0 + get_chroma_coeff(frac_x[2:0], k_idx[1:0]) * $signed({1'b0, get_win_px(win_l0_flat, r_idx, k_idx, comp)});
                        acc_l1 = acc_l1 + get_chroma_coeff(frac_x[2:0], k_idx[1:0]) * $signed({1'b0, get_win_px(win_l1_flat, r_idx, k_idx, comp)});
                    end
                    s1_hint_l0[r_idx] <= acc_l0 >>> 2;
                    s1_hint_l1[r_idx] <= acc_l1 >>> 2;
                end

                begin : chroma_v
                    reg signed [24:0] vacc_l0, vacc_l1;
                    vacc_l0 = 0;
                    vacc_l1 = 0;
                    for (k_idx = 0; k_idx < 4; k_idx = k_idx + 1) begin
                        vacc_l0 = vacc_l0 + get_chroma_coeff(frac_y[2:0], k_idx[1:0]) * $signed({1'b0, get_win_px(win_l0_flat, k_idx, 1, comp)});
                        vacc_l1 = vacc_l1 + get_chroma_coeff(frac_y[2:0], k_idx[1:0]) * $signed({1'b0, get_win_px(win_l1_flat, k_idx, 1, comp)});
                    end
                    s1_vsum_l0 <= vacc_l0;
                    s1_vsum_l1 <= vacc_l1;
                end
            end
        end
    end

    // Stage 2: Vertical FIR on H-intermediates & intermediate assembly
    reg        s2_valid;
    reg        s2_is_bi;
    reg signed [INTERM_WIDTH-1:0] s2_interm_l0;
    reg signed [INTERM_WIDTH-1:0] s2_interm_l1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_valid     <= 1'b0;
            s2_is_bi     <= 1'b0;
            s2_interm_l0 <= {INTERM_WIDTH{1'b0}};
            s2_interm_l1 <= {INTERM_WIDTH{1'b0}};
        end else begin
            s2_valid <= s1_valid;
            s2_is_bi <= s1_is_bi;

            if (s1_fx == 3'd0 && s1_fy == 3'd0) begin
                // Integer
                s2_interm_l0 <= $signed({6'd0, s1_int_l0}) <<< 4;
                s2_interm_l1 <= $signed({6'd0, s1_int_l1}) <<< 4;
            end else if (s1_fy == 3'd0) begin
                // H-only
                if (s1_comp == 2'd0) begin
                    s2_interm_l0 <= s1_hint_l0[3];
                    s2_interm_l1 <= s1_hint_l1[3];
                end else begin
                    s2_interm_l0 <= s1_hint_l0[1];
                    s2_interm_l1 <= s1_hint_l1[1];
                end
            end else if (s1_fx == 3'd0) begin
                // V-only
                s2_interm_l0 <= s1_vsum_l0 >>> 2;
                s2_interm_l1 <= s1_vsum_l1 >>> 2;
            end else begin
                // 2D HV Pass
                if (s1_comp == 2'd0) begin
                    reg signed [24:0] hv0, hv1;
                    hv0 = 0;
                    hv1 = 0;
                    for (k_idx = 0; k_idx < 8; k_idx = k_idx + 1) begin
                        hv0 = hv0 + get_luma_coeff(s1_fy[1:0], k_idx[2:0]) * s1_hint_l0[k_idx];
                        hv1 = hv1 + get_luma_coeff(s1_fy[1:0], k_idx[2:0]) * s1_hint_l1[k_idx];
                    end
                    s2_interm_l0 <= hv0 >>> 6;
                    s2_interm_l1 <= hv1 >>> 6;
                end else begin
                    reg signed [24:0] hv0, hv1;
                    hv0 = 0;
                    hv1 = 0;
                    for (k_idx = 0; k_idx < 4; k_idx = k_idx + 1) begin
                        hv0 = hv0 + get_chroma_coeff(s1_fy[2:0], k_idx[1:0]) * s1_hint_l0[k_idx];
                        hv1 = hv1 + get_chroma_coeff(s1_fy[2:0], k_idx[1:0]) * s1_hint_l1[k_idx];
                    end
                    s2_interm_l0 <= hv0 >>> 6;
                    s2_interm_l1 <= hv1 >>> 6;
                end
            end
        end
    end

    // Stage 3: Normalization & Bi-prediction Weighted Average
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_out  <= 1'b0;
            pred_pixel <= {PIXEL_WIDTH{1'b0}};
        end else begin
            valid_out <= s2_valid;
            if (s2_is_bi) begin
                // Clause 8.5.3.3.4.2: ClipBD((v0 + v1 + 16) >> 5, 10)
                pred_pixel <= clip_10((s2_interm_l0 + s2_interm_l1 + 32'sd16) >>> 5);
            end else begin
                // Uni-prediction: ClipBD((v0 + 8) >> 4, 10)
                pred_pixel <= clip_10((s2_interm_l0 + 32'sd8) >>> 4);
            end
        end
    end

endmodule
