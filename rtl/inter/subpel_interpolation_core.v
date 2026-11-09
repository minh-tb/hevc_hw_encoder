//=============================================================================
// subpel_interpolation_core.v
// HEVC Fractional Sample Interpolation Core (Main10 Profile)
//
// Normative References:
//   - ITU-T H.265 Clause 8.5.3.3.3 (Fractional sample interpolation)
//   - ITU-T H.265 Clause 8.5.3.3.4.2 (Weighted sample bi-prediction)
//   - HM 18.0 TComInterpolationFilter & TComYuv::addAvg
//=============================================================================

`timescale 1ns/1ps
`include "parameter_pkg.vh"

(* use_dsp = "no" *)
module subpel_interpolation_core #(
    parameter PIXEL_WIDTH  = `PIXEL_WIDTH,   // 10
    parameter INTERM_WIDTH = 16              // 16-bit intermediate signed
)(
    input  wire                           clk,
    input  wire                           rst_n,
    input  wire                           valid_in,
    input  wire                           is_chroma,
    input  wire [2:0]                     frac_x,
    input  wire [2:0]                     frac_y,
    input  wire [PIXEL_WIDTH*64-1:0]      win_luma_flat,
    input  wire [PIXEL_WIDTH*16-1:0]      win_chroma_flat,
    output reg                            valid_out,
    output reg  signed [INTERM_WIDTH-1:0] interm_val
);

    //-------------------------------------------------------------------------
    // Pixel Extraction Helpers
    //-------------------------------------------------------------------------
    function automatic [PIXEL_WIDTH-1:0] get_win_sample;
        input [PIXEL_WIDTH*64-1:0] flat;
        input integer r, c;
        begin
            get_win_sample = flat[PIXEL_WIDTH*(r*8 + c) +: PIXEL_WIDTH];
        end
    endfunction

    function automatic [PIXEL_WIDTH-1:0] get_chroma_sample;
        input [PIXEL_WIDTH*16-1:0] flat;
        input integer r, c;
        begin
            get_chroma_sample = flat[PIXEL_WIDTH*(r*4 + c) +: PIXEL_WIDTH];
        end
    endfunction

    //-------------------------------------------------------------------------
    // ITU-T H.265 Table 8-8: 8-tap Luma Interpolation Filter Coefficients
    //-------------------------------------------------------------------------
    function automatic signed [6:0] coeff_luma;
        input [1:0] frac;
        input integer tap;
        begin
            case (frac)
                2'd0: case (tap)
                    3: coeff_luma = 7'sd64;
                    default: coeff_luma = 7'sd0;
                endcase
                2'd1: case (tap)
                    0: coeff_luma = -7'sd1;
                    1: coeff_luma =  7'sd4;
                    2: coeff_luma = -7'sd10;
                    3: coeff_luma =  7'sd58;
                    4: coeff_luma =  7'sd17;
                    5: coeff_luma = -7'sd5;
                    6: coeff_luma =  7'sd1;
                    default: coeff_luma = 7'sd0;
                endcase
                2'd2: case (tap)
                    0: coeff_luma = -7'sd1;
                    1: coeff_luma =  7'sd4;
                    2: coeff_luma = -7'sd11;
                    3: coeff_luma =  7'sd40;
                    4: coeff_luma =  7'sd40;
                    5: coeff_luma = -7'sd11;
                    6: coeff_luma =  7'sd4;
                    default: coeff_luma = -7'sd1;
                endcase
                default: case (tap) // 2'd3
                    0: coeff_luma =  7'sd0;
                    1: coeff_luma =  7'sd1;
                    2: coeff_luma = -7'sd5;
                    3: coeff_luma =  7'sd17;
                    4: coeff_luma =  7'sd58;
                    5: coeff_luma = -7'sd10;
                    6: coeff_luma =  7'sd4;
                    default: coeff_luma = -7'sd1;
                endcase
            endcase
        end
    endfunction

    //-------------------------------------------------------------------------
    // ITU-T H.265 Table 8-9: 4-tap Chroma Interpolation Filter Coefficients
    //-------------------------------------------------------------------------
    function automatic signed [6:0] coeff_chroma;
        input [2:0] frac;
        input integer tap;
        begin
            case (frac)
                3'd0: case (tap)
                    1: coeff_chroma = 7'sd64;
                    default: coeff_chroma = 7'sd0;
                endcase
                3'd1: case (tap)
                    0: coeff_chroma = -7'sd2;
                    1: coeff_chroma =  7'sd58;
                    2: coeff_chroma =  7'sd10;
                    default: coeff_chroma = -7'sd2;
                endcase
                3'd2: case (tap)
                    0: coeff_chroma = -7'sd4;
                    1: coeff_chroma =  7'sd54;
                    2: coeff_chroma =  7'sd16;
                    default: coeff_chroma = -7'sd2;
                endcase
                3'd3: case (tap)
                    0: coeff_chroma = -7'sd6;
                    1: coeff_chroma =  7'sd46;
                    2: coeff_chroma =  7'sd28;
                    default: coeff_chroma = -7'sd4;
                endcase
                3'd4: case (tap)
                    0: coeff_chroma = -7'sd4;
                    1: coeff_chroma =  7'sd36;
                    2: coeff_chroma =  7'sd36;
                    default: coeff_chroma = -7'sd4;
                endcase
                3'd5: case (tap)
                    0: coeff_chroma = -7'sd4;
                    1: coeff_chroma =  7'sd28;
                    2: coeff_chroma =  7'sd46;
                    default: coeff_chroma = -7'sd6;
                endcase
                3'd6: case (tap)
                    0: coeff_chroma = -7'sd2;
                    1: coeff_chroma =  7'sd16;
                    2: coeff_chroma =  7'sd54;
                    default: coeff_chroma = -7'sd4;
                endcase
                default: case (tap) // 3'd7
                    0: coeff_chroma = -7'sd2;
                    1: coeff_chroma =  7'sd10;
                    2: coeff_chroma =  7'sd58;
                    default: coeff_chroma = -7'sd2;
                endcase
            endcase
        end
    endfunction

    //-------------------------------------------------------------------------
    // Stage 1 Filtering Helpers
    //-------------------------------------------------------------------------
    function automatic signed [24:0] fir8_luma_row;
        input [1:0] fx;
        input [PIXEL_WIDTH*64-1:0] flat;
        input integer r;
        reg signed [24:0] sum;
        integer k;
        begin
            sum = 25'sd0;
            for (k = 0; k < 8; k = k + 1)
                sum = sum + coeff_luma(fx, k) * $signed({1'b0, get_win_sample(flat, r, k)});
            fir8_luma_row = sum;
        end
    endfunction

    function automatic signed [24:0] fir8_luma_col;
        input [1:0] fy;
        input [PIXEL_WIDTH*64-1:0] flat;
        input integer c;
        reg signed [24:0] sum;
        integer k;
        begin
            sum = 25'sd0;
            for (k = 0; k < 8; k = k + 1)
                sum = sum + coeff_luma(fy, k) * $signed({1'b0, get_win_sample(flat, k, c)});
            fir8_luma_col = sum;
        end
    endfunction

    function automatic signed [24:0] fir4_chroma_row;
        input [2:0] fx;
        input [PIXEL_WIDTH*16-1:0] flat;
        input integer r;
        reg signed [24:0] sum;
        integer k;
        begin
            sum = 25'sd0;
            for (k = 0; k < 4; k = k + 1)
                sum = sum + coeff_chroma(fx, k) * $signed({1'b0, get_chroma_sample(flat, r, k)});
            fir4_chroma_row = sum;
        end
    endfunction

    function automatic signed [24:0] fir4_chroma_col;
        input [2:0] fy;
        input [PIXEL_WIDTH*16-1:0] flat;
        input integer c;
        reg signed [24:0] sum;
        integer k;
        begin
            sum = 25'sd0;
            for (k = 0; k < 4; k = k + 1)
                sum = sum + coeff_chroma(fy, k) * $signed({1'b0, get_chroma_sample(flat, k, c)});
            fir4_chroma_col = sum;
        end
    endfunction

    //-------------------------------------------------------------------------
    // Stage 1 Pipeline Registers (Cycle T -> T+1)
    //-------------------------------------------------------------------------
    reg                            s1_valid;
    reg                            s1_is_chroma;
    reg [2:0]                      s1_frac_x;
    reg [2:0]                      s1_frac_y;
    reg signed [17:0]              s1_h_luma   [0:7];
    reg signed [17:0]              s1_h_chroma [0:3];
    reg signed [INTERM_WIDTH-1:0]  s1_v_luma;
    reg signed [INTERM_WIDTH-1:0]  s1_v_chroma;
    reg signed [INTERM_WIDTH-1:0]  s1_int_luma;
    reg signed [INTERM_WIDTH-1:0]  s1_int_chroma;

    integer r_idx;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid      <= 1'b0;
            s1_is_chroma  <= 1'b0;
            s1_frac_x     <= 3'd0;
            s1_frac_y     <= 3'd0;
            s1_v_luma     <= {INTERM_WIDTH{1'b0}};
            s1_v_chroma   <= {INTERM_WIDTH{1'b0}};
            s1_int_luma   <= {INTERM_WIDTH{1'b0}};
            s1_int_chroma <= {INTERM_WIDTH{1'b0}};
            for (r_idx = 0; r_idx < 8; r_idx = r_idx + 1)
                s1_h_luma[r_idx] <= 18'sd0;
            for (r_idx = 0; r_idx < 4; r_idx = r_idx + 1)
                s1_h_chroma[r_idx] <= 18'sd0;
        end else begin
            s1_valid <= valid_in;
            if (valid_in) begin
                s1_is_chroma  <= is_chroma;
                s1_frac_x     <= frac_x;
                s1_frac_y     <= frac_y;

                for (r_idx = 0; r_idx < 8; r_idx = r_idx + 1)
                    s1_h_luma[r_idx] <= fir8_luma_row(frac_x[1:0], win_luma_flat, r_idx) >>> 2;

                for (r_idx = 0; r_idx < 4; r_idx = r_idx + 1)
                    s1_h_chroma[r_idx] <= fir4_chroma_row(frac_x, win_chroma_flat, r_idx) >>> 2;

                s1_v_luma     <= fir8_luma_col(frac_y[1:0], win_luma_flat, 3) >>> 2;
                s1_v_chroma   <= fir4_chroma_col(frac_y, win_chroma_flat, 1) >>> 2;
                s1_int_luma   <= $signed({6'd0, get_win_sample(win_luma_flat, 3, 3)}) <<< 4;
                s1_int_chroma <= $signed({6'd0, get_chroma_sample(win_chroma_flat, 1, 1)}) <<< 4;
            end
        end
    end

    //-------------------------------------------------------------------------
    // Stage 2 Combinational Logic: Vertical FIR & Mode Mux
    //-------------------------------------------------------------------------
    (* use_dsp = "no" *) reg signed [24:0] sum_hv_luma;
    (* use_dsp = "no" *) reg signed [24:0] sum_hv_chroma;
    reg signed [INTERM_WIDTH-1:0] res_luma;
    reg signed [INTERM_WIDTH-1:0] res_chroma;
    integer k_v;

    always @(*) begin
        sum_hv_luma = 25'sd0;
        for (k_v = 0; k_v < 8; k_v = k_v + 1)
            sum_hv_luma = sum_hv_luma + coeff_luma(s1_frac_y[1:0], k_v) * s1_h_luma[k_v];

        sum_hv_chroma = 25'sd0;
        for (k_v = 0; k_v < 4; k_v = k_v + 1)
            sum_hv_chroma = sum_hv_chroma + coeff_chroma(s1_frac_y, k_v) * s1_h_chroma[k_v];

        if (s1_frac_x[1:0] == 2'd0 && s1_frac_y[1:0] == 2'd0)
            res_luma = s1_int_luma;
        else if (s1_frac_y[1:0] == 2'd0)
            res_luma = s1_h_luma[3][INTERM_WIDTH-1:0];
        else if (s1_frac_x[1:0] == 2'd0)
            res_luma = s1_v_luma;
        else
            res_luma = sum_hv_luma >>> 6;

        if (s1_frac_x == 3'd0 && s1_frac_y == 3'd0)
            res_chroma = s1_int_chroma;
        else if (s1_frac_y == 3'd0)
            res_chroma = s1_h_chroma[1][INTERM_WIDTH-1:0];
        else if (s1_frac_x == 3'd0)
            res_chroma = s1_v_chroma;
        else
            res_chroma = sum_hv_chroma >>> 6;
    end

    //-------------------------------------------------------------------------
    // Stage 2 Pipeline Registers (Cycle T+1 -> T+2)
    //-------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_out  <= 1'b0;
            interm_val <= {INTERM_WIDTH{1'b0}};
        end else begin
            valid_out <= s1_valid;
            if (s1_valid) begin
                interm_val <= s1_is_chroma ? res_chroma : res_luma;
            end
        end
    end

endmodule
