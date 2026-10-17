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

module subpel_interpolation_core #(
    parameter PIXEL_WIDTH  = `PIXEL_WIDTH,   // 10
    parameter INTERM_WIDTH = 16              // 16-bit intermediate signed
)(
    input  wire                      is_chroma,
    input  wire [2:0]                frac_x,
    input  wire [2:0]                frac_y,
    input  wire [PIXEL_WIDTH*64-1:0] win_luma_flat,
    input  wire [PIXEL_WIDTH*16-1:0] win_chroma_flat,
    output wire signed [INTERM_WIDTH-1:0] interm_val
);

    function automatic [9:0] get_win_sample;
        input [PIXEL_WIDTH*64-1:0] flat;
        input integer r, c;
        begin
            get_win_sample = flat[PIXEL_WIDTH*(r*8 + c) +: PIXEL_WIDTH];
        end
    endfunction

    function automatic signed [15:0] filter_luma_subpel_interm;
        input [1:0] fx;
        input [1:0] fy;
        input [PIXEL_WIDTH*64-1:0] win_flat;
        reg signed [24:0] sum_h [0:7];
        reg signed [17:0] h_int [0:7];
        reg signed [24:0] sum_v;
        integer r, k;
        reg signed [6:0] c_h [0:7];
        reg signed [6:0] c_v [0:7];
        begin
            case (fx)
                2'd0: begin c_h[0]=0; c_h[1]=0; c_h[2]=0; c_h[3]=64; c_h[4]=0; c_h[5]=0; c_h[6]=0; c_h[7]=0; end
                2'd1: begin c_h[0]=-1; c_h[1]=4; c_h[2]=-10; c_h[3]=58; c_h[4]=17; c_h[5]=-5; c_h[6]=1; c_h[7]=0; end
                2'd2: begin c_h[0]=-1; c_h[1]=4; c_h[2]=-11; c_h[3]=40; c_h[4]=40; c_h[5]=-11; c_h[6]=4; c_h[7]=-1; end
                default: begin c_h[0]=0; c_h[1]=1; c_h[2]=-5; c_h[3]=17; c_h[4]=58; c_h[5]=-10; c_h[6]=4; c_h[7]=-1; end
            endcase
            case (fy)
                2'd0: begin c_v[0]=0; c_v[1]=0; c_v[2]=0; c_v[3]=64; c_v[4]=0; c_v[5]=0; c_v[6]=0; c_v[7]=0; end
                2'd1: begin c_v[0]=-1; c_v[1]=4; c_v[2]=-10; c_v[3]=58; c_v[4]=17; c_v[5]=-5; c_v[6]=1; c_v[7]=0; end
                2'd2: begin c_v[0]=-1; c_v[1]=4; c_v[2]=-11; c_v[3]=40; c_v[4]=40; c_v[5]=-11; c_v[6]=4; c_v[7]=-1; end
                default: begin c_v[0]=0; c_v[1]=1; c_v[2]=-5; c_v[3]=17; c_v[4]=58; c_v[5]=-10; c_v[6]=4; c_v[7]=-1; end
            endcase

            if (fx == 2'd0 && fy == 2'd0) begin
                filter_luma_subpel_interm = $signed({6'd0, get_win_sample(win_flat, 3, 3)}) <<< 4;
            end else if (fy == 2'd0) begin
                sum_h[3] = 0;
                for (k = 0; k < 8; k = k + 1)
                    sum_h[3] = sum_h[3] + c_h[k] * $signed({1'b0, get_win_sample(win_flat, 3, k)});
                filter_luma_subpel_interm = sum_h[3] >>> 2;
            end else if (fx == 2'd0) begin
                sum_v = 0;
                for (k = 0; k < 8; k = k + 1)
                    sum_v = sum_v + c_v[k] * $signed({1'b0, get_win_sample(win_flat, k, 3)});
                filter_luma_subpel_interm = sum_v >>> 2;
            end else begin
                // Two-pass HV
                for (r = 0; r < 8; r = r + 1) begin
                    sum_h[r] = 0;
                    for (k = 0; k < 8; k = k + 1)
                        sum_h[r] = sum_h[r] + c_h[k] * $signed({1'b0, get_win_sample(win_flat, r, k)});
                    h_int[r] = sum_h[r] >>> 2; // Plain truncation per Clause 8.5.3.3.3
                end
                sum_v = 0;
                for (k = 0; k < 8; k = k + 1)
                    sum_v = sum_v + c_v[k] * h_int[k];
                filter_luma_subpel_interm = sum_v >>> 6;
            end
        end
    endfunction

    function automatic signed [15:0] filter_chroma_subpel_interm;
        input [2:0] fx;
        input [2:0] fy;
        input [PIXEL_WIDTH*16-1:0] win_flat;
        reg signed [24:0] sum_h [0:3];
        reg signed [17:0] h_int [0:3];
        reg signed [24:0] sum_v;
        integer r, k;
        reg signed [6:0] c_h [0:3];
        reg signed [6:0] c_v [0:3];
        begin
            case (fx)
                3'd0: begin c_h[0]=0;  c_h[1]=64; c_h[2]=0;  c_h[3]=0;  end
                3'd1: begin c_h[0]=-2; c_h[1]=58; c_h[2]=10; c_h[3]=-2; end
                3'd2: begin c_h[0]=-4; c_h[1]=54; c_h[2]=16; c_h[3]=-2; end
                3'd3: begin c_h[0]=-6; c_h[1]=46; c_h[2]=28; c_h[3]=-4; end
                3'd4: begin c_h[0]=-4; c_h[1]=36; c_h[2]=36; c_h[3]=-4; end
                3'd5: begin c_h[0]=-4; c_h[1]=28; c_h[2]=46; c_h[3]=-6; end
                3'd6: begin c_h[0]=-2; c_h[1]=16; c_h[2]=54; c_h[3]=-4; end
                default: begin c_h[0]=-2; c_h[1]=10; c_h[2]=58; c_h[3]=-2; end
            endcase
            case (fy)
                3'd0: begin c_v[0]=0;  c_v[1]=64; c_v[2]=0;  c_v[3]=0;  end
                3'd1: begin c_v[0]=-2; c_v[1]=58; c_v[2]=10; c_v[3]=-2; end
                3'd2: begin c_v[0]=-4; c_v[1]=54; c_v[2]=16; c_v[3]=-2; end
                3'd3: begin c_v[0]=-6; c_v[1]=46; c_v[2]=28; c_v[3]=-4; end
                3'd4: begin c_v[0]=-4; c_v[1]=36; c_v[2]=36; c_v[3]=-4; end
                3'd5: begin c_v[0]=-4; c_v[1]=28; c_v[2]=46; c_v[3]=-6; end
                3'd6: begin c_v[0]=-2; c_v[1]=16; c_v[2]=54; c_v[3]=-4; end
                default: begin c_v[0]=-2; c_v[1]=10; c_v[2]=58; c_v[3]=-2; end
            endcase

            if (fx == 3'd0 && fy == 3'd0) begin
                filter_chroma_subpel_interm = $signed({6'd0, win_flat[PIXEL_WIDTH*(1*4 + 1) +: PIXEL_WIDTH]}) <<< 4;
            end else if (fy == 3'd0) begin
                sum_h[1] = 0;
                for (k = 0; k < 4; k = k + 1)
                    sum_h[1] = sum_h[1] + c_h[k] * $signed({1'b0, win_flat[PIXEL_WIDTH*(1*4 + k) +: PIXEL_WIDTH]});
                filter_chroma_subpel_interm = sum_h[1] >>> 2;
            end else if (fx == 3'd0) begin
                sum_v = 0;
                for (k = 0; k < 4; k = k + 1)
                    sum_v = sum_v + c_v[k] * $signed({1'b0, win_flat[PIXEL_WIDTH*(k*4 + 1) +: PIXEL_WIDTH]});
                filter_chroma_subpel_interm = sum_v >>> 2;
            end else begin
                // Two-pass HV
                for (r = 0; r < 4; r = r + 1) begin
                    sum_h[r] = 0;
                    for (k = 0; k < 4; k = k + 1)
                        sum_h[r] = sum_h[r] + c_h[k] * $signed({1'b0, win_flat[PIXEL_WIDTH*(r*4 + k) +: PIXEL_WIDTH]});
                    h_int[r] = sum_h[r] >>> 2;
                end
                sum_v = 0;
                for (k = 0; k < 4; k = k + 1)
                    sum_v = sum_v + c_v[k] * h_int[k];
                filter_chroma_subpel_interm = sum_v >>> 6;
            end
        end
    endfunction

    assign interm_val = is_chroma ? filter_chroma_subpel_interm(frac_x, frac_y, win_chroma_flat)
                                  : filter_luma_subpel_interm(frac_x[1:0], frac_y[1:0], win_luma_flat);

endmodule
