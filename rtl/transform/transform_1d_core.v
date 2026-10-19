//=============================================================================
// transform_1d_core.v
// Unified 1D Forward and Inverse Transform Core for HEVC
// Supports:
//   - 4-point, 8-point, 16-point, 32-point 1D DCT-II (HEVC Table 9-15)
//   - 4-point 1D DST-VII for 4x4 Intra Luma (HEVC Table 9-16 / Section 8.4.5.3.1.2)
//
// Mapped from HM 18.0:
//   TLibCommon/TComTrQuant.cpp
//   - partialButterfly4(), partialButterfly8(), partialButterfly16(), partialButterfly32()
//   - fastForwardDst(), fastInverseDst()
//   - partialButterflyInverse4(), partialButterflyInverse8(), etc.
//=============================================================================

`timescale 1ns / 1ps
`include "parameter_pkg.vh"

module transform_1d_core (
    input  wire         clk,
    input  wire         rst_n,

    // Control
    input  wire         fwd_inv_n,          // 1=Forward, 0=Inverse
    input  wire [2:0]   tu_size_log2,       // 2=4pt, 3=8pt, 4=16pt, 5=32pt
    input  wire         is_dst7,            // 1=DST-VII (4x4 Intra Luma only)
    input  wire         is_second_pass,     // 0=Row Pass (1st), 1=Col Pass (2nd)

    // Streaming 1D vector input (up to 32 samples)
    input  wire         in_valid,
    output wire         in_ready,
    input  wire [511:0] in_vec,             // 32 x signed 16-bit samples

    // Streaming 1D vector output (up to 32 samples)
    output reg          out_valid,
    input  wire         out_ready,
    output reg  [511:0] out_vec             // 32 x signed 16-bit coefficients
);

    assign in_ready = out_ready | ~out_valid;

    // Unpack input vector
    wire signed [15:0] src [0:31];
    genvar gi;
    generate
        for (gi = 0; gi < 32; gi = gi + 1) begin : gen_src
            assign src[gi] = in_vec[gi*16 +: 16];
        end
    endgenerate

    //-------------------------------------------------------------------------
    // Shift & Rounding Values (Parameterized for BIT_DEPTH = 8 or 10)
    // Forward:
    //   shift_1st = tu_size_log2 - 2 + 1 + BitDepth - 8 = tu_size_log2 + (BitDepth - 9)
    //   shift_2nd = tu_size_log2 - 2 + 8                = tu_size_log2 + 6
    // Inverse:
    //   shift_1st = 7
    //   shift_2nd = 20 - BitDepth (10 for 10-bit, 12 for 8-bit)
    //-------------------------------------------------------------------------
    localparam integer FWD_SHIFT_OFFSET = `BIT_DEPTH - 9;
    reg [4:0] shift_val;
    always @(*) begin
        if (fwd_inv_n) begin
            // Forward
            if (!is_second_pass)
                shift_val = {2'd0, tu_size_log2} + FWD_SHIFT_OFFSET[4:0];
            else
                shift_val = {2'd0, tu_size_log2} + 5'd6;
        end else begin
            // Inverse
            if (!is_second_pass)
                shift_val = 5'd7;
            else
                shift_val = 5'd20 - `BIT_DEPTH;
        end
    end

    // Clipping helper
    localparam signed [31:0] MIN_VAL = -32768;
    localparam signed [31:0] MAX_VAL = 32767;

    function automatic signed [15:0] clip_s16;
        input signed [31:0] val;
        begin
            if (val > MAX_VAL) clip_s16 = 16'sd32767;
            else if (val < MIN_VAL) clip_s16 = -16'sd32768;
            else clip_s16 = val[15:0];
        end
    endfunction

    //-------------------------------------------------------------------------
    // 1D Transform Transform Computations
    //-------------------------------------------------------------------------
    //-------------------------------------------------------------------------
    // Sign-extended 32-bit input samples
    //-------------------------------------------------------------------------
    wire signed [31:0] s [0:31];
    genvar gs;
    generate
        for (gs = 0; gs < 32; gs = gs + 1) begin : gen_s
            assign s[gs] = $signed({{16{src[gs][15]}}, src[gs]});
        end
    endgenerate

    //=========================================================================
    // Forward Even/Odd Butterfly Cascade
    //=========================================================================
    wire signed [31:0] e32_f [0:15];
    wire signed [31:0] o32_f [0:15];
    genvar k32;
    generate
        for (k32 = 0; k32 < 16; k32 = k32 + 1) begin : gen_bf_32
            assign e32_f[k32] = s[k32] + s[31 - k32];
            assign o32_f[k32] = s[k32] - s[31 - k32];
        end
    endgenerate

    wire signed [31:0] in16 [0:15];
    wire signed [31:0] e16_f [0:7];
    wire signed [31:0] o16_f [0:7];
    genvar k16;
    generate
        for (k16 = 0; k16 < 16; k16 = k16 + 1) begin : gen_in16
            assign in16[k16] = (tu_size_log2 == 3'd5) ? e32_f[k16] : s[k16];
        end
        for (k16 = 0; k16 < 8; k16 = k16 + 1) begin : gen_bf_16
            assign e16_f[k16] = in16[k16] + in16[15 - k16];
            assign o16_f[k16] = in16[k16] - in16[15 - k16];
        end
    endgenerate

    wire signed [31:0] in8 [0:7];
    wire signed [31:0] e8_f [0:3];
    wire signed [31:0] o8_f [0:3];
    genvar k8;
    generate
        for (k8 = 0; k8 < 8; k8 = k8 + 1) begin : gen_in8
            assign in8[k8] = (tu_size_log2 >= 3'd4) ? e16_f[k8] : s[k8];
        end
        for (k8 = 0; k8 < 4; k8 = k8 + 1) begin : gen_bf_8
            assign e8_f[k8] = in8[k8] + in8[7 - k8];
            assign o8_f[k8] = in8[k8] - in8[7 - k8];
        end
    endgenerate

    wire signed [31:0] in4 [0:3];
    genvar k4;
    generate
        for (k4 = 0; k4 < 4; k4 = k4 + 1) begin : gen_in4
            assign in4[k4] = (tu_size_log2 >= 3'd3) ? e8_f[k4] : s[k4];
        end
    endgenerate

    wire signed [31:0] e4_f [0:1];
    wire signed [31:0] o4_f [0:1];
    assign e4_f[0] = in4[0] + in4[3];
    assign e4_f[1] = in4[1] + in4[2];
    assign o4_f[0] = in4[0] - in4[3];
    assign o4_f[1] = in4[1] - in4[2];

    //=========================================================================
    // Multiplexed Odd Vector Inputs (Shared between Forward and Inverse)
    //=========================================================================
    wire signed [31:0] v32 [0:15];
    genvar kv32;
    generate
        for (kv32 = 0; kv32 < 16; kv32 = kv32 + 1) begin : gen_v32
            assign v32[kv32] = fwd_inv_n ? o32_f[kv32] : s[2*kv32 + 1];
        end
    endgenerate

    wire signed [31:0] v16 [0:7];
    genvar kv16;
    generate
        for (kv16 = 0; kv16 < 8; kv16 = kv16 + 1) begin : gen_v16
            assign v16[kv16] = fwd_inv_n ? o16_f[kv16] : ((tu_size_log2 == 3'd5) ? s[4*kv16 + 2] : s[2*kv16 + 1]);
        end
    endgenerate

    wire signed [31:0] v8 [0:3];
    genvar kv8;
    generate
        for (kv8 = 0; kv8 < 4; kv8 = kv8 + 1) begin : gen_v8
            assign v8[kv8] = fwd_inv_n ? o8_f[kv8] : ((tu_size_log2 == 3'd5) ? s[8*kv8 + 4] :
                                                      (tu_size_log2 == 3'd4) ? s[4*kv8 + 2] : s[2*kv8 + 1]);
        end
    endgenerate

    wire signed [31:0] v4 [0:1];
    genvar kv4;
    generate
        for (kv4 = 0; kv4 < 2; kv4 = kv4 + 1) begin : gen_v4
            assign v4[kv4] = fwd_inv_n ? o4_f[kv4] : ((tu_size_log2 == 3'd5) ? s[16*kv4 + 8] :
                                                      (tu_size_log2 == 3'd4) ? s[8*kv4 + 4]  :
                                                      (tu_size_log2 == 3'd3) ? s[4*kv4 + 2]  : s[2*kv4 + 1]);
        end
    endgenerate

    wire signed [31:0] ev4 [0:1];
    assign ev4[0] = fwd_inv_n ? e4_f[0] : s[0];
    assign ev4[1] = fwd_inv_n ? e4_f[1] : ((tu_size_log2 == 3'd5) ? s[16] :
                                           (tu_size_log2 == 3'd4) ? s[8]  :
                                           (tu_size_log2 == 3'd3) ? s[4]  : s[2]);

    //=========================================================================
    // Single Shared Basis Multiplier Engines (M = M^T Symmetry)
    //=========================================================================

    // 2-point Even Core (e4)
    wire signed [31:0] e4_out [0:1];
    assign e4_out[0] = 32'sd64 * (ev4[0] + ev4[1]);
    assign e4_out[1] = 32'sd64 * (ev4[0] - ev4[1]);

    // 2-point Odd Core (M4)
    wire signed [31:0] m4_out [0:1];
    assign m4_out[0] = 32'sd83 * v4[0] + 32'sd36 * v4[1];
    assign m4_out[1] = 32'sd36 * v4[0] - 32'sd83 * v4[1];

    // 4-point Odd Core (M8) - Balanced 2-level binary adder tree
    wire signed [31:0] m8_out [0:3];
    assign m8_out[0] = ((32'sd89 * v8[0] + 32'sd75 * v8[1]) + (32'sd50 * v8[2] + 32'sd18 * v8[3]));
    assign m8_out[1] = ((32'sd75 * v8[0] - 32'sd18 * v8[1]) - (32'sd89 * v8[2] + 32'sd50 * v8[3]));
    assign m8_out[2] = ((32'sd50 * v8[0] - 32'sd89 * v8[1]) + (32'sd18 * v8[2] + 32'sd75 * v8[3]));
    assign m8_out[3] = ((32'sd18 * v8[0] - 32'sd50 * v8[1]) + (32'sd75 * v8[2] - 32'sd89 * v8[3]));

    // 8-point Odd Core (M16) - Balanced 3-level binary adder tree
    wire signed [31:0] m16_out [0:7];
    assign m16_out[0] = (((32'sd90*v16[0] + 32'sd87*v16[1]) + (32'sd80*v16[2] + 32'sd70*v16[3])) + ((32'sd57*v16[4] + 32'sd43*v16[5]) + (32'sd25*v16[6] + 32'sd9 *v16[7])));
    assign m16_out[1] = (((32'sd87*v16[0] + 32'sd57*v16[1]) + (32'sd9 *v16[2] - 32'sd43*v16[3])) + (((-32'sd80*v16[4]) - 32'sd90*v16[5]) + ((-32'sd70*v16[6]) - 32'sd25*v16[7])));
    assign m16_out[2] = (((32'sd80*v16[0] + 32'sd9 *v16[1]) + ((-32'sd70*v16[2]) - 32'sd87*v16[3])) + (((-32'sd25*v16[4]) + 32'sd57*v16[5]) + (32'sd90*v16[6] + 32'sd43*v16[7])));
    assign m16_out[3] = (((32'sd70*v16[0] - 32'sd43*v16[1]) + ((-32'sd87*v16[2]) + 32'sd9 *v16[3])) + ((32'sd90*v16[4] + 32'sd25*v16[5]) + ((-32'sd80*v16[6]) - 32'sd57*v16[7])));
    assign m16_out[4] = (((32'sd57*v16[0] - 32'sd80*v16[1]) + ((-32'sd25*v16[2]) + 32'sd90*v16[3])) + (((-32'sd9 *v16[4]) - 32'sd87*v16[5]) + (32'sd43*v16[6] + 32'sd70*v16[7])));
    assign m16_out[5] = (((32'sd43*v16[0] - 32'sd90*v16[1]) + (32'sd57*v16[2] + 32'sd25*v16[3])) + (((-32'sd87*v16[4]) + 32'sd70*v16[5]) + (32'sd9 *v16[6] - 32'sd80*v16[7])));
    assign m16_out[6] = (((32'sd25*v16[0] - 32'sd70*v16[1]) + (32'sd90*v16[2] - 32'sd80*v16[3])) + ((32'sd43*v16[4] + 32'sd9 *v16[5]) + ((-32'sd57*v16[6]) + 32'sd87*v16[7])));
    assign m16_out[7] = (((32'sd9 *v16[0] - 32'sd25*v16[1]) + (32'sd43*v16[2] - 32'sd57*v16[3])) + ((32'sd70*v16[4] - 32'sd80*v16[5]) + (32'sd87*v16[6] - 32'sd90*v16[7])));

    // 16-point Odd Core (M32) - Balanced 4-level binary adder tree
    wire signed [31:0] m32_out [0:15];
    assign m32_out[0]  = ((((32'sd90*v32[0] + 32'sd90*v32[1]) + (32'sd88*v32[2] + 32'sd85*v32[3])) + ((32'sd82*v32[4] + 32'sd78*v32[5]) + (32'sd73*v32[6] + 32'sd67*v32[7]))) + (((32'sd61*v32[8] + 32'sd54*v32[9]) + (32'sd46*v32[10] + 32'sd38*v32[11])) + ((32'sd31*v32[12] + 32'sd22*v32[13]) + (32'sd13*v32[14] + 32'sd4 *v32[15]))));
    assign m32_out[1]  = ((((32'sd90*v32[0] + 32'sd82*v32[1]) + (32'sd67*v32[2] + 32'sd46*v32[3])) + ((32'sd22*v32[4] - 32'sd4 *v32[5]) + ((-32'sd31*v32[6]) - 32'sd54*v32[7]))) + ((((-32'sd73*v32[8]) - 32'sd85*v32[9]) + ((-32'sd90*v32[10]) - 32'sd88*v32[11])) + (((-32'sd78*v32[12]) - 32'sd61*v32[13]) + ((-32'sd38*v32[14]) - 32'sd13*v32[15]))));
    assign m32_out[2]  = ((((32'sd88*v32[0] + 32'sd67*v32[1]) + (32'sd31*v32[2] - 32'sd13*v32[3])) + (((-32'sd54*v32[4]) - 32'sd82*v32[5]) + ((-32'sd90*v32[6]) - 32'sd78*v32[7]))) + ((((-32'sd46*v32[8]) - 32'sd4 *v32[9]) + (32'sd38*v32[10] + 32'sd73*v32[11])) + ((32'sd90*v32[12] + 32'sd85*v32[13]) + (32'sd61*v32[14] + 32'sd22*v32[15]))));
    assign m32_out[3]  = ((((32'sd85*v32[0] + 32'sd46*v32[1]) + ((-32'sd13*v32[2]) - 32'sd67*v32[3])) + (((-32'sd90*v32[4]) - 32'sd73*v32[5]) + ((-32'sd22*v32[6]) + 32'sd38*v32[7]))) + (((32'sd82*v32[8] + 32'sd88*v32[9]) + (32'sd54*v32[10] - 32'sd4 *v32[11])) + (((-32'sd61*v32[12]) - 32'sd90*v32[13]) + ((-32'sd78*v32[14]) - 32'sd31*v32[15]))));
    assign m32_out[4]  = ((((32'sd82*v32[0] + 32'sd22*v32[1]) + ((-32'sd54*v32[2]) - 32'sd90*v32[3])) + (((-32'sd61*v32[4]) + 32'sd13*v32[5]) + (32'sd78*v32[6] + 32'sd85*v32[7]))) + (((32'sd31*v32[8] - 32'sd46*v32[9]) + ((-32'sd90*v32[10]) - 32'sd67*v32[11])) + ((32'sd4 *v32[12] + 32'sd73*v32[13]) + (32'sd88*v32[14] + 32'sd38*v32[15]))));
    assign m32_out[5]  = ((((32'sd78*v32[0] - 32'sd4 *v32[1]) + ((-32'sd82*v32[2]) - 32'sd73*v32[3])) + ((32'sd13*v32[4] + 32'sd85*v32[5]) + (32'sd67*v32[6] - 32'sd22*v32[7]))) + ((((-32'sd88*v32[8]) - 32'sd61*v32[9]) + (32'sd31*v32[10] + 32'sd90*v32[11])) + ((32'sd54*v32[12] - 32'sd38*v32[13]) + ((-32'sd90*v32[14]) - 32'sd46*v32[15]))));
    assign m32_out[6]  = ((((32'sd73*v32[0] - 32'sd31*v32[1]) + ((-32'sd90*v32[2]) - 32'sd22*v32[3])) + ((32'sd78*v32[4] + 32'sd67*v32[5]) + ((-32'sd38*v32[6]) - 32'sd90*v32[7]))) + ((((-32'sd13*v32[8]) + 32'sd82*v32[9]) + (32'sd61*v32[10] - 32'sd46*v32[11])) + (((-32'sd88*v32[12]) - 32'sd4 *v32[13]) + (32'sd85*v32[14] + 32'sd54*v32[15]))));
    assign m32_out[7]  = ((((32'sd67*v32[0] - 32'sd54*v32[1]) + ((-32'sd78*v32[2]) + 32'sd38*v32[3])) + ((32'sd85*v32[4] - 32'sd22*v32[5]) + ((-32'sd90*v32[6]) + 32'sd4 *v32[7]))) + (((32'sd90*v32[8] + 32'sd13*v32[9]) + ((-32'sd88*v32[10]) - 32'sd31*v32[11])) + ((32'sd82*v32[12] + 32'sd46*v32[13]) + ((-32'sd73*v32[14]) - 32'sd61*v32[15]))));
    assign m32_out[8]  = ((((32'sd61*v32[0] - 32'sd73*v32[1]) + ((-32'sd46*v32[2]) + 32'sd82*v32[3])) + ((32'sd31*v32[4] - 32'sd88*v32[5]) + ((-32'sd13*v32[6]) + 32'sd90*v32[7]))) + ((((-32'sd4 *v32[8]) - 32'sd90*v32[9]) + (32'sd22*v32[10] + 32'sd85*v32[11])) + (((-32'sd38*v32[12]) - 32'sd78*v32[13]) + (32'sd54*v32[14] + 32'sd67*v32[15]))));
    assign m32_out[9]  = ((((32'sd54*v32[0] - 32'sd85*v32[1]) + ((-32'sd4 *v32[2]) + 32'sd88*v32[3])) + (((-32'sd46*v32[4]) - 32'sd61*v32[5]) + (32'sd82*v32[6] + 32'sd13*v32[7]))) + ((((-32'sd90*v32[8]) + 32'sd38*v32[9]) + (32'sd67*v32[10] - 32'sd78*v32[11])) + (((-32'sd22*v32[12]) + 32'sd90*v32[13]) + ((-32'sd31*v32[14]) - 32'sd73*v32[15]))));
    assign m32_out[10] = ((((32'sd46*v32[0] - 32'sd90*v32[1]) + (32'sd38*v32[2] + 32'sd54*v32[3])) + (((-32'sd90*v32[4]) + 32'sd31*v32[5]) + (32'sd61*v32[6] - 32'sd88*v32[7]))) + (((32'sd22*v32[8] + 32'sd67*v32[9]) + ((-32'sd85*v32[10]) + 32'sd13*v32[11])) + ((32'sd73*v32[12] - 32'sd82*v32[13]) + (32'sd4 *v32[14] + 32'sd78*v32[15]))));
    assign m32_out[11] = ((((32'sd38*v32[0] - 32'sd88*v32[1]) + (32'sd73*v32[2] - 32'sd4 *v32[3])) + (((-32'sd67*v32[4]) + 32'sd90*v32[5]) + ((-32'sd46*v32[6]) - 32'sd31*v32[7]))) + (((32'sd85*v32[8] - 32'sd78*v32[9]) + (32'sd13*v32[10] + 32'sd61*v32[11])) + (((-32'sd90*v32[12]) + 32'sd54*v32[13]) + (32'sd22*v32[14] - 32'sd82*v32[15]))));
    assign m32_out[12] = ((((32'sd31*v32[0] - 32'sd78*v32[1]) + (32'sd90*v32[2] - 32'sd61*v32[3])) + ((32'sd4 *v32[4] + 32'sd54*v32[5]) + ((-32'sd88*v32[6]) + 32'sd82*v32[7]))) + ((((-32'sd38*v32[8]) - 32'sd22*v32[9]) + (32'sd73*v32[10] - 32'sd90*v32[11])) + ((32'sd67*v32[12] - 32'sd13*v32[13]) + ((-32'sd46*v32[14]) + 32'sd85*v32[15]))));
    assign m32_out[13] = ((((32'sd22*v32[0] - 32'sd61*v32[1]) + (32'sd85*v32[2] - 32'sd90*v32[3])) + ((32'sd73*v32[4] - 32'sd38*v32[5]) + ((-32'sd4 *v32[6]) + 32'sd46*v32[7]))) + ((((-32'sd78*v32[8]) + 32'sd90*v32[9]) + ((-32'sd82*v32[10]) + 32'sd54*v32[11])) + (((-32'sd13*v32[12]) - 32'sd31*v32[13]) + (32'sd67*v32[14] - 32'sd88*v32[15]))));
    assign m32_out[14] = ((((32'sd13*v32[0] - 32'sd38*v32[1]) + (32'sd61*v32[2] - 32'sd78*v32[3])) + ((32'sd88*v32[4] - 32'sd90*v32[5]) + (32'sd85*v32[6] - 32'sd73*v32[7]))) + (((32'sd54*v32[8] - 32'sd31*v32[9]) + (32'sd4 *v32[10] + 32'sd22*v32[11])) + (((-32'sd46*v32[12]) + 32'sd67*v32[13]) + ((-32'sd82*v32[14]) + 32'sd90*v32[15]))));
    assign m32_out[15] = ((((32'sd4 *v32[0] - 32'sd13*v32[1]) + (32'sd22*v32[2] - 32'sd31*v32[3])) + ((32'sd38*v32[4] - 32'sd46*v32[5]) + (32'sd54*v32[6] - 32'sd61*v32[7]))) + (((32'sd67*v32[8] - 32'sd73*v32[9]) + (32'sd78*v32[10] - 32'sd82*v32[11])) + ((32'sd85*v32[12] - 32'sd88*v32[13]) + (32'sd90*v32[14] - 32'sd90*v32[15]))));

    // 4-point DST-VII Core
    wire signed [31:0] c0_dst = fwd_inv_n ? (s[0] + s[3]) : (s[0] + s[2]);
    wire signed [31:0] c1_dst = fwd_inv_n ? (s[1] + s[3]) : (s[2] + s[3]);
    wire signed [31:0] c2_dst = fwd_inv_n ? (s[0] - s[1]) : (s[0] - s[3]);
    wire signed [31:0] c3_dst = 32'sd74 * (fwd_inv_n ? s[2] : s[1]);
    wire signed [31:0] c4_dst = 32'sd74 * (fwd_inv_n ? (s[0] + s[1] - s[3]) : (s[0] - s[2] + s[3]));

    wire signed [31:0] x_dst = (32'sd29 * c0_dst + 32'sd55 * c1_dst) + c3_dst;
    wire signed [31:0] y_dst = (32'sd55 * c2_dst - 32'sd29 * c1_dst) + c3_dst;
    wire signed [31:0] z_dst = (32'sd55 * c0_dst + 32'sd29 * c2_dst) - c3_dst;

    //=========================================================================
    // Inverse Reconstruction Butterflies
    //=========================================================================
    wire signed [31:0] e8_inv [0:3];
    assign e8_inv[0] = e4_out[0] + m4_out[0];
    assign e8_inv[1] = e4_out[1] + m4_out[1];
    assign e8_inv[2] = e4_out[1] - m4_out[1];
    assign e8_inv[3] = e4_out[0] - m4_out[0];

    wire signed [31:0] e16_inv [0:7];
    assign e16_inv[0] = e8_inv[0] + m8_out[0];
    assign e16_inv[1] = e8_inv[1] + m8_out[1];
    assign e16_inv[2] = e8_inv[2] + m8_out[2];
    assign e16_inv[3] = e8_inv[3] + m8_out[3];
    assign e16_inv[4] = e8_inv[3] - m8_out[3];
    assign e16_inv[5] = e8_inv[2] - m8_out[2];
    assign e16_inv[6] = e8_inv[1] - m8_out[1];
    assign e16_inv[7] = e8_inv[0] - m8_out[0];

    wire signed [31:0] e32_inv [0:15];
    genvar kinv16;
    generate
        for (kinv16 = 0; kinv16 < 8; kinv16 = kinv16 + 1) begin : gen_e32_inv
            assign e32_inv[kinv16]      = e16_inv[kinv16] + m16_out[kinv16];
            assign e32_inv[15 - kinv16] = e16_inv[kinv16] - m16_out[kinv16];
        end
    endgenerate

    wire signed [31:0] dst_inv32 [0:31];
    genvar kinv32;
    generate
        for (kinv32 = 0; kinv32 < 16; kinv32 = kinv32 + 1) begin : gen_dst_inv32
            assign dst_inv32[kinv32]      = e32_inv[kinv32] + m32_out[kinv32];
            assign dst_inv32[31 - kinv32] = e32_inv[kinv32] - m32_out[kinv32];
        end
    endgenerate

    //=========================================================================
    // Output Multiplexing & Assembly
    //=========================================================================
    reg signed [31:0] dst_out [0:31];
    integer idx;
    integer i;
    always @(*) begin
        for (idx = 0; idx < 32; idx = idx + 1) begin
            dst_out[idx] = 32'sd0;
        end

        if (is_dst7 && tu_size_log2 == 3'd2) begin
            dst_out[0] = x_dst;
            dst_out[1] = fwd_inv_n ? c4_dst : y_dst;
            dst_out[2] = fwd_inv_n ? z_dst  : c4_dst;
            dst_out[3] = fwd_inv_n ? y_dst  : z_dst;
        end else if (!fwd_inv_n) begin
            // Inverse DCT-II
            case (tu_size_log2)
                3'd2: begin
                    for (idx = 0; idx < 4; idx = idx + 1)
                        dst_out[idx] = e8_inv[idx];
                end
                3'd3: begin
                    for (idx = 0; idx < 8; idx = idx + 1)
                        dst_out[idx] = e16_inv[idx];
                end
                3'd4: begin
                    for (idx = 0; idx < 16; idx = idx + 1)
                        dst_out[idx] = e32_inv[idx];
                end
                3'd5: begin
                    for (idx = 0; idx < 32; idx = idx + 1)
                        dst_out[idx] = dst_inv32[idx];
                end
                default: begin
                    // synthesis translate_off
                    if (rst_n && in_valid) begin
                        $error("ERROR [transform_1d_core] Unsupported tu_size_log2=%0d at time=%0t", tu_size_log2, $time);
                    end
                    // synthesis translate_on
                end
            endcase
        end else begin
            // Forward DCT-II
            case (tu_size_log2)
                3'd2: begin
                    dst_out[0] = e4_out[0];
                    dst_out[1] = m4_out[0];
                    dst_out[2] = e4_out[1];
                    dst_out[3] = m4_out[1];
                end
                3'd3: begin
                    dst_out[0] = e4_out[0];
                    dst_out[1] = m8_out[0];
                    dst_out[2] = m4_out[0];
                    dst_out[3] = m8_out[1];
                    dst_out[4] = e4_out[1];
                    dst_out[5] = m8_out[2];
                    dst_out[6] = m4_out[1];
                    dst_out[7] = m8_out[3];
                end
                3'd4: begin
                    dst_out[0]  = e4_out[0];
                    dst_out[1]  = m16_out[0];
                    dst_out[2]  = m8_out[0];
                    dst_out[3]  = m16_out[1];
                    dst_out[4]  = m4_out[0];
                    dst_out[5]  = m16_out[2];
                    dst_out[6]  = m8_out[1];
                    dst_out[7]  = m16_out[3];
                    dst_out[8]  = e4_out[1];
                    dst_out[9]  = m16_out[4];
                    dst_out[10] = m8_out[2];
                    dst_out[11] = m16_out[5];
                    dst_out[12] = m4_out[1];
                    dst_out[13] = m16_out[6];
                    dst_out[14] = m8_out[3];
                    dst_out[15] = m16_out[7];
                end
                3'd5: begin
                    dst_out[0]  = e4_out[0];
                    dst_out[1]  = m32_out[0];
                    dst_out[2]  = m16_out[0];
                    dst_out[3]  = m32_out[1];
                    dst_out[4]  = m8_out[0];
                    dst_out[5]  = m32_out[2];
                    dst_out[6]  = m16_out[1];
                    dst_out[7]  = m32_out[3];
                    dst_out[8]  = m4_out[0];
                    dst_out[9]  = m32_out[4];
                    dst_out[10] = m16_out[2];
                    dst_out[11] = m32_out[5];
                    dst_out[12] = m8_out[1];
                    dst_out[13] = m32_out[6];
                    dst_out[14] = m16_out[3];
                    dst_out[15] = m32_out[7];
                    dst_out[16] = e4_out[1];
                    dst_out[17] = m32_out[8];
                    dst_out[18] = m16_out[4];
                    dst_out[19] = m32_out[9];
                    dst_out[20] = m8_out[2];
                    dst_out[21] = m32_out[10];
                    dst_out[22] = m16_out[5];
                    dst_out[23] = m32_out[11];
                    dst_out[24] = m4_out[1];
                    dst_out[25] = m32_out[12];
                    dst_out[26] = m16_out[6];
                    dst_out[27] = m32_out[13];
                    dst_out[28] = m8_out[3];
                    dst_out[29] = m32_out[14];
                    dst_out[30] = m16_out[7];
                    dst_out[31] = m32_out[15];
                end
                default: begin
                    // synthesis translate_off
                    if (rst_n && in_valid) begin
                        $error("ERROR [transform_1d_core] Unsupported tu_size_log2=%0d at time=%0t", tu_size_log2, $time);
                    end
                    // synthesis translate_on
                end
            endcase
        end
    end

    // Apply Rounding and Shift
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            out_vec   <= 512'd0;
        end else if (in_valid && in_ready) begin
            out_valid <= 1'b1;
            for (i = 0; i < 32; i = i + 1) begin
                out_vec[i*16 +: 16] <= clip_s16((dst_out[i] + (32'sd1 << (shift_val - 1))) >>> shift_val);
            end
        end else if (out_ready) begin
            out_valid <= 1'b0;
        end
    end

endmodule
