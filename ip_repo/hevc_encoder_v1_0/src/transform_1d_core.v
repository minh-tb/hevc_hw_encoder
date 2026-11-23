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

    reg s1_valid;
    reg s2_valid;
    wire s3_ready = out_ready | ~out_valid;
    wire s2_ready = s3_ready  | ~s2_valid;
    assign in_ready = s2_ready | ~s1_valid;

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
    // Stage 1 Registers: Capture Input Butterflies, Odd Vectors & Control
    //=========================================================================
    reg                    s1_fwd_inv_n;
    reg [2:0]              s1_tu_size_log2;
    reg                    s1_is_dst7;
    reg [4:0]              s1_shift_val;
    reg signed [31:0]      s1_v32   [0:15];
    reg signed [31:0]      s1_v16   [0:7];
    reg signed [31:0]      s1_v8    [0:3];
    reg signed [31:0]      s1_v4    [0:1];
    reg signed [31:0]      s1_ev4   [0:1];
    reg signed [31:0]      s1_c0_dst, s1_c1_dst, s1_c2_dst, s1_c3_dst, s1_c4_dst;

    // 4-point DST-VII Pre-Butterfly Terms (Stage 1)
    wire signed [31:0] c0_dst = fwd_inv_n ? (s[0] + s[3]) : (s[0] + s[2]);
    wire signed [31:0] c1_dst = fwd_inv_n ? (s[1] + s[3]) : (s[2] + s[3]);
    wire signed [31:0] c2_dst = fwd_inv_n ? (s[0] - s[1]) : (s[0] - s[3]);
    wire signed [31:0] c3_dst = 32'sd74 * (fwd_inv_n ? s[2] : s[1]);
    wire signed [31:0] c4_dst = 32'sd74 * (fwd_inv_n ? (s[0] + s[1] - s[3]) : (s[0] - s[2] + s[3]));

    integer st1_i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid        <= 1'b0;
            s1_fwd_inv_n    <= 1'b1;
            s1_tu_size_log2 <= 3'd2;
            s1_is_dst7      <= 1'b0;
            s1_shift_val    <= 5'd4;
            for (st1_i = 0; st1_i < 16; st1_i = st1_i + 1) s1_v32[st1_i] <= 32'sd0;
            for (st1_i = 0; st1_i < 8;  st1_i = st1_i + 1) s1_v16[st1_i] <= 32'sd0;
            for (st1_i = 0; st1_i < 4;  st1_i = st1_i + 1) s1_v8[st1_i]  <= 32'sd0;
            for (st1_i = 0; st1_i < 2;  st1_i = st1_i + 1) begin
                s1_v4[st1_i]  <= 32'sd0;
                s1_ev4[st1_i] <= 32'sd0;
            end
            s1_c0_dst <= 32'sd0; s1_c1_dst <= 32'sd0; s1_c2_dst <= 32'sd0;
            s1_c3_dst <= 32'sd0; s1_c4_dst <= 32'sd0;
        end else if (in_ready) begin
            s1_valid <= in_valid;
            if (in_valid) begin
                s1_fwd_inv_n    <= fwd_inv_n;
                s1_tu_size_log2 <= tu_size_log2;
                s1_is_dst7      <= is_dst7;
                s1_shift_val    <= shift_val;
                for (st1_i = 0; st1_i < 16; st1_i = st1_i + 1) s1_v32[st1_i] <= v32[st1_i];
                for (st1_i = 0; st1_i < 8;  st1_i = st1_i + 1) s1_v16[st1_i] <= v16[st1_i];
                for (st1_i = 0; st1_i < 4;  st1_i = st1_i + 1) s1_v8[st1_i]  <= v8[st1_i];
                for (st1_i = 0; st1_i < 2;  st1_i = st1_i + 1) begin
                    s1_v4[st1_i]  <= v4[st1_i];
                    s1_ev4[st1_i] <= ev4[st1_i];
                end
                s1_c0_dst <= c0_dst;
                s1_c1_dst <= c1_dst;
                s1_c2_dst <= c2_dst;
                s1_c3_dst <= c3_dst;
                s1_c4_dst <= c4_dst;
            end
        end
    end

    //=========================================================================
    // Stage 2: Basis Multiplier Engines (from Stage 1 Registers)
    //=========================================================================

    // 2-point Even Core (e4)
    wire signed [31:0] e4_out [0:1];
    assign e4_out[0] = 32'sd64 * (s1_ev4[0] + s1_ev4[1]);
    assign e4_out[1] = 32'sd64 * (s1_ev4[0] - s1_ev4[1]);

    // 2-point Odd Core (M4)
    wire signed [31:0] m4_out [0:1];
    assign m4_out[0] = 32'sd83 * s1_v4[0] + 32'sd36 * s1_v4[1];
    assign m4_out[1] = 32'sd36 * s1_v4[0] - 32'sd83 * s1_v4[1];

    // 4-point Odd Core (M8) - Balanced 2-level binary adder tree
    wire signed [31:0] m8_out [0:3];
    assign m8_out[0] = ((32'sd89 * s1_v8[0] + 32'sd75 * s1_v8[1]) + (32'sd50 * s1_v8[2] + 32'sd18 * s1_v8[3]));
    assign m8_out[1] = ((32'sd75 * s1_v8[0] - 32'sd18 * s1_v8[1]) - (32'sd89 * s1_v8[2] + 32'sd50 * s1_v8[3]));
    assign m8_out[2] = ((32'sd50 * s1_v8[0] - 32'sd89 * s1_v8[1]) + (32'sd18 * s1_v8[2] + 32'sd75 * s1_v8[3]));
    assign m8_out[3] = ((32'sd18 * s1_v8[0] - 32'sd50 * s1_v8[1]) + (32'sd75 * s1_v8[2] - 32'sd89 * s1_v8[3]));

    // 8-point Odd Core (M16) - Balanced 3-level binary adder tree
    wire signed [31:0] m16_out [0:7];
    assign m16_out[0] = (((32'sd90*s1_v16[0] + 32'sd87*s1_v16[1]) + (32'sd80*s1_v16[2] + 32'sd70*s1_v16[3])) + ((32'sd57*s1_v16[4] + 32'sd43*s1_v16[5]) + (32'sd25*s1_v16[6] + 32'sd9 *s1_v16[7])));
    assign m16_out[1] = (((32'sd87*s1_v16[0] + 32'sd57*s1_v16[1]) + (32'sd9 *s1_v16[2] - 32'sd43*s1_v16[3])) + (((-32'sd80*s1_v16[4]) - 32'sd90*s1_v16[5]) + ((-32'sd70*s1_v16[6]) - 32'sd25*s1_v16[7])));
    assign m16_out[2] = (((32'sd80*s1_v16[0] + 32'sd9 *s1_v16[1]) + ((-32'sd70*s1_v16[2]) - 32'sd87*s1_v16[3])) + (((-32'sd25*s1_v16[4]) + 32'sd57*s1_v16[5]) + (32'sd90*s1_v16[6] + 32'sd43*s1_v16[7])));
    assign m16_out[3] = (((32'sd70*s1_v16[0] - 32'sd43*s1_v16[1]) + ((-32'sd87*s1_v16[2]) + 32'sd9 *s1_v16[3])) + ((32'sd90*s1_v16[4] + 32'sd25*s1_v16[5]) + ((-32'sd80*s1_v16[6]) - 32'sd57*s1_v16[7])));
    assign m16_out[4] = (((32'sd57*s1_v16[0] - 32'sd80*s1_v16[1]) + ((-32'sd25*s1_v16[2]) + 32'sd90*s1_v16[3])) + (((-32'sd9 *s1_v16[4]) - 32'sd87*s1_v16[5]) + (32'sd43*s1_v16[6] + 32'sd70*s1_v16[7])));
    assign m16_out[5] = (((32'sd43*s1_v16[0] - 32'sd90*s1_v16[1]) + (32'sd57*s1_v16[2] + 32'sd25*s1_v16[3])) + (((-32'sd87*s1_v16[4]) + 32'sd70*s1_v16[5]) + (32'sd9 *s1_v16[6] - 32'sd80*s1_v16[7])));
    assign m16_out[6] = (((32'sd25*s1_v16[0] - 32'sd70*s1_v16[1]) + (32'sd90*s1_v16[2] - 32'sd80*s1_v16[3])) + ((32'sd43*s1_v16[4] + 32'sd9 *s1_v16[5]) + ((-32'sd57*s1_v16[6]) + 32'sd87*s1_v16[7])));
    assign m16_out[7] = (((32'sd9 *s1_v16[0] - 32'sd25*s1_v16[1]) + (32'sd43*s1_v16[2] - 32'sd57*s1_v16[3])) + ((32'sd70*s1_v16[4] - 32'sd80*s1_v16[5]) + (32'sd87*s1_v16[6] - 32'sd90*s1_v16[7])));

    // 16-point Odd Core (M32) - Balanced 4-level binary adder tree
    wire signed [31:0] m32_out [0:15];
    assign m32_out[0]  = ((((32'sd90*s1_v32[0] + 32'sd90*s1_v32[1]) + (32'sd88*s1_v32[2] + 32'sd85*s1_v32[3])) + ((32'sd82*s1_v32[4] + 32'sd78*s1_v32[5]) + (32'sd73*s1_v32[6] + 32'sd67*s1_v32[7]))) + (((32'sd61*s1_v32[8] + 32'sd54*s1_v32[9]) + (32'sd46*s1_v32[10] + 32'sd38*s1_v32[11])) + ((32'sd31*s1_v32[12] + 32'sd22*s1_v32[13]) + (32'sd13*s1_v32[14] + 32'sd4 *s1_v32[15]))));
    assign m32_out[1]  = ((((32'sd90*s1_v32[0] + 32'sd82*s1_v32[1]) + (32'sd67*s1_v32[2] + 32'sd46*s1_v32[3])) + ((32'sd22*s1_v32[4] - 32'sd4 *s1_v32[5]) + ((-32'sd31*s1_v32[6]) - 32'sd54*s1_v32[7]))) + ((((-32'sd73*s1_v32[8]) - 32'sd85*s1_v32[9]) + ((-32'sd90*s1_v32[10]) - 32'sd88*s1_v32[11])) + (((-32'sd78*s1_v32[12]) - 32'sd61*s1_v32[13]) + ((-32'sd38*s1_v32[14]) - 32'sd13*s1_v32[15]))));
    assign m32_out[2]  = ((((32'sd88*s1_v32[0] + 32'sd67*s1_v32[1]) + (32'sd31*s1_v32[2] - 32'sd13*s1_v32[3])) + (((-32'sd54*s1_v32[4]) - 32'sd82*s1_v32[5]) + ((-32'sd90*s1_v32[6]) - 32'sd78*s1_v32[7]))) + ((((-32'sd46*s1_v32[8]) - 32'sd4 *s1_v32[9]) + (32'sd38*s1_v32[10] + 32'sd73*s1_v32[11])) + ((32'sd90*s1_v32[12] + 32'sd85*s1_v32[13]) + (32'sd61*s1_v32[14] + 32'sd22*s1_v32[15]))));
    assign m32_out[3]  = ((((32'sd85*s1_v32[0] + 32'sd46*s1_v32[1]) + ((-32'sd13*s1_v32[2]) - 32'sd67*s1_v32[3])) + (((-32'sd90*s1_v32[4]) - 32'sd73*s1_v32[5]) + ((-32'sd22*s1_v32[6]) + 32'sd38*s1_v32[7]))) + (((32'sd82*s1_v32[8] + 32'sd88*s1_v32[9]) + (32'sd54*s1_v32[10] - 32'sd4 *s1_v32[11])) + (((-32'sd61*s1_v32[12]) - 32'sd90*s1_v32[13]) + ((-32'sd78*s1_v32[14]) - 32'sd31*s1_v32[15]))));
    assign m32_out[4]  = ((((32'sd82*s1_v32[0] + 32'sd22*s1_v32[1]) + ((-32'sd54*s1_v32[2]) - 32'sd90*s1_v32[3])) + (((-32'sd61*s1_v32[4]) + 32'sd13*s1_v32[5]) + (32'sd78*s1_v32[6] + 32'sd85*s1_v32[7]))) + (((32'sd31*s1_v32[8] - 32'sd46*s1_v32[9]) + ((-32'sd90*s1_v32[10]) - 32'sd67*s1_v32[11])) + ((32'sd4 *s1_v32[12] + 32'sd73*s1_v32[13]) + (32'sd88*s1_v32[14] + 32'sd38*s1_v32[15]))));
    assign m32_out[5]  = ((((32'sd78*s1_v32[0] - 32'sd4 *s1_v32[1]) + ((-32'sd82*s1_v32[2]) - 32'sd73*s1_v32[3])) + ((32'sd13*s1_v32[4] + 32'sd85*s1_v32[5]) + (32'sd67*s1_v32[6] - 32'sd22*s1_v32[7]))) + ((((-32'sd88*s1_v32[8]) - 32'sd61*s1_v32[9]) + (32'sd31*s1_v32[10] + 32'sd90*s1_v32[11])) + ((32'sd54*s1_v32[12] - 32'sd38*s1_v32[13]) + ((-32'sd90*s1_v32[14]) - 32'sd46*s1_v32[15]))));
    assign m32_out[6]  = ((((32'sd73*s1_v32[0] - 32'sd31*s1_v32[1]) + ((-32'sd90*s1_v32[2]) - 32'sd22*s1_v32[3])) + ((32'sd78*s1_v32[4] + 32'sd67*s1_v32[5]) + ((-32'sd38*s1_v32[6]) - 32'sd90*s1_v32[7]))) + ((((-32'sd13*s1_v32[8]) + 32'sd82*s1_v32[9]) + (32'sd61*s1_v32[10] - 32'sd46*s1_v32[11])) + (((-32'sd88*s1_v32[12]) - 32'sd4 *s1_v32[13]) + (32'sd85*s1_v32[14] + 32'sd54*s1_v32[15]))));
    assign m32_out[7]  = ((((32'sd67*s1_v32[0] - 32'sd54*s1_v32[1]) + ((-32'sd78*s1_v32[2]) + 32'sd38*s1_v32[3])) + ((32'sd85*s1_v32[4] - 32'sd22*s1_v32[5]) + ((-32'sd90*s1_v32[6]) + 32'sd4 *s1_v32[7]))) + (((32'sd90*s1_v32[8] + 32'sd13*s1_v32[9]) + ((-32'sd88*s1_v32[10]) - 32'sd31*s1_v32[11])) + ((32'sd82*s1_v32[12] + 32'sd46*s1_v32[13]) + ((-32'sd73*s1_v32[14]) - 32'sd61*s1_v32[15]))));
    assign m32_out[8]  = ((((32'sd61*s1_v32[0] - 32'sd73*s1_v32[1]) + ((-32'sd46*s1_v32[2]) + 32'sd82*s1_v32[3])) + ((32'sd31*s1_v32[4] - 32'sd88*s1_v32[5]) + ((-32'sd13*s1_v32[6]) + 32'sd90*s1_v32[7]))) + ((((-32'sd4 *s1_v32[8]) - 32'sd90*s1_v32[9]) + (32'sd22*s1_v32[10] + 32'sd85*s1_v32[11])) + (((-32'sd38*s1_v32[12]) - 32'sd78*s1_v32[13]) + (32'sd54*s1_v32[14] + 32'sd67*s1_v32[15]))));
    assign m32_out[9]  = ((((32'sd54*s1_v32[0] - 32'sd85*s1_v32[1]) + ((-32'sd4 *s1_v32[2]) + 32'sd88*s1_v32[3])) + (((-32'sd46*s1_v32[4]) - 32'sd61*s1_v32[5]) + (32'sd82*s1_v32[6] + 32'sd13*s1_v32[7]))) + ((((-32'sd90*s1_v32[8]) + 32'sd38*s1_v32[9]) + (32'sd67*s1_v32[10] - 32'sd78*s1_v32[11])) + (((-32'sd22*s1_v32[12]) + 32'sd90*s1_v32[13]) + ((-32'sd31*s1_v32[14]) - 32'sd73*s1_v32[15]))));
    assign m32_out[10] = ((((32'sd46*s1_v32[0] - 32'sd90*s1_v32[1]) + (32'sd38*s1_v32[2] + 32'sd54*s1_v32[3])) + (((-32'sd90*s1_v32[4]) + 32'sd31*s1_v32[5]) + (32'sd61*s1_v32[6] - 32'sd88*s1_v32[7]))) + (((32'sd22*s1_v32[8] + 32'sd67*s1_v32[9]) + ((-32'sd85*s1_v32[10]) + 32'sd13*s1_v32[11])) + ((32'sd73*s1_v32[12] - 32'sd82*s1_v32[13]) + (32'sd4 *s1_v32[14] + 32'sd78*s1_v32[15]))));
    assign m32_out[11] = ((((32'sd38*s1_v32[0] - 32'sd88*s1_v32[1]) + (32'sd73*s1_v32[2] - 32'sd4 *s1_v32[3])) + (((-32'sd67*s1_v32[4]) + 32'sd90*s1_v32[5]) + ((-32'sd46*s1_v32[6]) - 32'sd31*s1_v32[7]))) + (((32'sd85*s1_v32[8] - 32'sd78*s1_v32[9]) + (32'sd13*s1_v32[10] + 32'sd61*s1_v32[11])) + (((-32'sd90*s1_v32[12]) + 32'sd54*s1_v32[13]) + (32'sd22*s1_v32[14] - 32'sd82*s1_v32[15]))));
    assign m32_out[12] = ((((32'sd31*s1_v32[0] - 32'sd78*s1_v32[1]) + (32'sd90*s1_v32[2] - 32'sd61*s1_v32[3])) + ((32'sd4 *s1_v32[4] + 32'sd54*s1_v32[5]) + ((-32'sd88*s1_v32[6]) + 32'sd82*s1_v32[7]))) + ((((-32'sd38*s1_v32[8]) - 32'sd22*s1_v32[9]) + (32'sd73*s1_v32[10] - 32'sd90*s1_v32[11])) + ((32'sd67*s1_v32[12] - 32'sd13*s1_v32[13]) + ((-32'sd46*s1_v32[14]) + 32'sd85*s1_v32[15]))));
    assign m32_out[13] = ((((32'sd22*s1_v32[0] - 32'sd61*s1_v32[1]) + (32'sd85*s1_v32[2] - 32'sd90*s1_v32[3])) + ((32'sd73*s1_v32[4] - 32'sd38*s1_v32[5]) + ((-32'sd4 *s1_v32[6]) + 32'sd46*s1_v32[7]))) + ((((-32'sd78*s1_v32[8]) + 32'sd90*s1_v32[9]) + ((-32'sd82*s1_v32[10]) + 32'sd54*s1_v32[11])) + (((-32'sd13*s1_v32[12]) - 32'sd31*s1_v32[13]) + (32'sd67*s1_v32[14] - 32'sd88*s1_v32[15]))));
    assign m32_out[14] = ((((32'sd13*s1_v32[0] - 32'sd38*s1_v32[1]) + (32'sd61*s1_v32[2] - 32'sd78*s1_v32[3])) + ((32'sd88*s1_v32[4] - 32'sd90*s1_v32[5]) + (32'sd85*s1_v32[6] - 32'sd73*s1_v32[7]))) + (((32'sd54*s1_v32[8] - 32'sd31*s1_v32[9]) + (32'sd4 *s1_v32[10] + 32'sd22*s1_v32[11])) + (((-32'sd46*s1_v32[12]) + 32'sd67*s1_v32[13]) + ((-32'sd82*s1_v32[14]) + 32'sd90*s1_v32[15]))));
    assign m32_out[15] = ((((32'sd4 *s1_v32[0] - 32'sd13*s1_v32[1]) + (32'sd22*s1_v32[2] - 32'sd31*s1_v32[3])) + ((32'sd38*s1_v32[4] - 32'sd46*s1_v32[5]) + (32'sd54*s1_v32[6] - 32'sd61*s1_v32[7]))) + (((32'sd67*s1_v32[8] - 32'sd73*s1_v32[9]) + (32'sd78*s1_v32[10] - 32'sd82*s1_v32[11])) + ((32'sd85*s1_v32[12] - 32'sd88*s1_v32[13]) + (32'sd90*s1_v32[14] - 32'sd90*s1_v32[15]))));

    // 4-point DST-VII Core
    wire signed [31:0] x_dst = (32'sd29 * s1_c0_dst + 32'sd55 * s1_c1_dst) + s1_c3_dst;
    wire signed [31:0] y_dst = (32'sd55 * s1_c2_dst - 32'sd29 * s1_c1_dst) + s1_c3_dst;
    wire signed [31:0] z_dst = (32'sd55 * s1_c0_dst + 32'sd29 * s1_c2_dst) - s1_c3_dst;

    //=========================================================================
    // Stage 2 Registers: Capture Basis Products & Pipeline Control
    //=========================================================================
    reg                    s2_fwd_inv_n;
    reg [2:0]              s2_tu_size_log2;
    reg                    s2_is_dst7;
    reg [4:0]              s2_shift_val;
    reg signed [31:0]      s2_e4_out  [0:1];
    reg signed [31:0]      s2_m4_out  [0:1];
    reg signed [31:0]      s2_m8_out  [0:3];
    reg signed [31:0]      s2_m16_out [0:7];
    reg signed [31:0]      s2_m32_out [0:15];
    reg signed [31:0]      s2_x_dst, s2_y_dst, s2_z_dst, s2_c4_dst;

    integer st2_i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_valid        <= 1'b0;
            s2_fwd_inv_n    <= 1'b1;
            s2_tu_size_log2 <= 3'd2;
            s2_is_dst7      <= 1'b0;
            s2_shift_val    <= 5'd4;
            for (st2_i = 0; st2_i < 2;  st2_i = st2_i + 1) begin
                s2_e4_out[st2_i] <= 32'sd0;
                s2_m4_out[st2_i] <= 32'sd0;
            end
            for (st2_i = 0; st2_i < 4;  st2_i = st2_i + 1) s2_m8_out[st2_i]  <= 32'sd0;
            for (st2_i = 0; st2_i < 8;  st2_i = st2_i + 1) s2_m16_out[st2_i] <= 32'sd0;
            for (st2_i = 0; st2_i < 16; st2_i = st2_i + 1) s2_m32_out[st2_i] <= 32'sd0;
            s2_x_dst <= 32'sd0; s2_y_dst <= 32'sd0; s2_z_dst <= 32'sd0; s2_c4_dst <= 32'sd0;
        end else if (s2_ready) begin
            s2_valid <= s1_valid;
            if (s1_valid) begin
                s2_fwd_inv_n    <= s1_fwd_inv_n;
                s2_tu_size_log2 <= s1_tu_size_log2;
                s2_is_dst7      <= s1_is_dst7;
                s2_shift_val    <= s1_shift_val;
                for (st2_i = 0; st2_i < 2;  st2_i = st2_i + 1) begin
                    s2_e4_out[st2_i] <= e4_out[st2_i];
                    s2_m4_out[st2_i] <= m4_out[st2_i];
                end
                for (st2_i = 0; st2_i < 4;  st2_i = st2_i + 1) s2_m8_out[st2_i]  <= m8_out[st2_i];
                for (st2_i = 0; st2_i < 8;  st2_i = st2_i + 1) s2_m16_out[st2_i] <= m16_out[st2_i];
                for (st2_i = 0; st2_i < 16; st2_i = st2_i + 1) s2_m32_out[st2_i] <= m32_out[st2_i];
                s2_x_dst  <= x_dst;
                s2_y_dst  <= y_dst;
                s2_z_dst  <= z_dst;
                s2_c4_dst <= s1_c4_dst;
            end
        end
    end

    //=========================================================================
    // Stage 3: Inverse Reconstruction Butterflies, Output Mux, Shift & Clip
    //=========================================================================
    wire signed [31:0] e8_inv [0:3];
    assign e8_inv[0] = s2_e4_out[0] + s2_m4_out[0];
    assign e8_inv[1] = s2_e4_out[1] + s2_m4_out[1];
    assign e8_inv[2] = s2_e4_out[1] - s2_m4_out[1];
    assign e8_inv[3] = s2_e4_out[0] - s2_m4_out[0];

    wire signed [31:0] e16_inv [0:7];
    assign e16_inv[0] = e8_inv[0] + s2_m8_out[0];
    assign e16_inv[1] = e8_inv[1] + s2_m8_out[1];
    assign e16_inv[2] = e8_inv[2] + s2_m8_out[2];
    assign e16_inv[3] = e8_inv[3] + s2_m8_out[3];
    assign e16_inv[4] = e8_inv[3] - s2_m8_out[3];
    assign e16_inv[5] = e8_inv[2] - s2_m8_out[2];
    assign e16_inv[6] = e8_inv[1] - s2_m8_out[1];
    assign e16_inv[7] = e8_inv[0] - s2_m8_out[0];

    wire signed [31:0] e32_inv [0:15];
    genvar kinv16;
    generate
        for (kinv16 = 0; kinv16 < 8; kinv16 = kinv16 + 1) begin : gen_e32_inv
            assign e32_inv[kinv16]      = e16_inv[kinv16] + s2_m16_out[kinv16];
            assign e32_inv[15 - kinv16] = e16_inv[kinv16] - s2_m16_out[kinv16];
        end
    endgenerate

    wire signed [31:0] dst_inv32 [0:31];
    genvar kinv32;
    generate
        for (kinv32 = 0; kinv32 < 16; kinv32 = kinv32 + 1) begin : gen_dst_inv32
            assign dst_inv32[kinv32]      = e32_inv[kinv32] + s2_m32_out[kinv32];
            assign dst_inv32[31 - kinv32] = e32_inv[kinv32] - s2_m32_out[kinv32];
        end
    endgenerate

    // Output Multiplexing & Assembly
    reg signed [31:0] dst_out [0:31];
    integer idx;
    integer i;
    always @(*) begin
        for (idx = 0; idx < 32; idx = idx + 1) begin
            dst_out[idx] = 32'sd0;
        end

        if (s2_is_dst7 && s2_tu_size_log2 == 3'd2) begin
            dst_out[0] = s2_x_dst;
            dst_out[1] = s2_fwd_inv_n ? s2_c4_dst : s2_y_dst;
            dst_out[2] = s2_fwd_inv_n ? s2_z_dst  : s2_c4_dst;
            dst_out[3] = s2_fwd_inv_n ? s2_y_dst  : s2_z_dst;
        end else if (!s2_fwd_inv_n) begin
            // Inverse DCT-II
            case (s2_tu_size_log2)
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
                    if (rst_n && s2_valid) begin
                        $error("ERROR [transform_1d_core] Unsupported tu_size_log2=%0d at time=%0t", s2_tu_size_log2, $time);
                    end
                    // synthesis translate_on
                end
            endcase
        end else begin
            // Forward DCT-II
            case (s2_tu_size_log2)
                3'd2: begin
                    dst_out[0] = s2_e4_out[0];
                    dst_out[1] = s2_m4_out[0];
                    dst_out[2] = s2_e4_out[1];
                    dst_out[3] = s2_m4_out[1];
                end
                3'd3: begin
                    dst_out[0] = s2_e4_out[0];
                    dst_out[1] = s2_m8_out[0];
                    dst_out[2] = s2_m4_out[0];
                    dst_out[3] = s2_m8_out[1];
                    dst_out[4] = s2_e4_out[1];
                    dst_out[5] = s2_m8_out[2];
                    dst_out[6] = s2_m4_out[1];
                    dst_out[7] = s2_m8_out[3];
                end
                3'd4: begin
                    dst_out[0]  = s2_e4_out[0];
                    dst_out[1]  = s2_m16_out[0];
                    dst_out[2]  = s2_m8_out[0];
                    dst_out[3]  = s2_m16_out[1];
                    dst_out[4]  = s2_m4_out[0];
                    dst_out[5]  = s2_m16_out[2];
                    dst_out[6]  = s2_m8_out[1];
                    dst_out[7]  = s2_m16_out[3];
                    dst_out[8]  = s2_e4_out[1];
                    dst_out[9]  = s2_m16_out[4];
                    dst_out[10] = s2_m8_out[2];
                    dst_out[11] = s2_m16_out[5];
                    dst_out[12] = s2_m4_out[1];
                    dst_out[13] = s2_m16_out[6];
                    dst_out[14] = s2_m8_out[3];
                    dst_out[15] = s2_m16_out[7];
                end
                3'd5: begin
                    dst_out[0]  = s2_e4_out[0];
                    dst_out[1]  = s2_m32_out[0];
                    dst_out[2]  = s2_m16_out[0];
                    dst_out[3]  = s2_m32_out[1];
                    dst_out[4]  = s2_m8_out[0];
                    dst_out[5]  = s2_m32_out[2];
                    dst_out[6]  = s2_m16_out[1];
                    dst_out[7]  = s2_m32_out[3];
                    dst_out[8]  = s2_m4_out[0];
                    dst_out[9]  = s2_m32_out[4];
                    dst_out[10] = s2_m16_out[2];
                    dst_out[11] = s2_m32_out[5];
                    dst_out[12] = s2_m8_out[1];
                    dst_out[13] = s2_m32_out[6];
                    dst_out[14] = s2_m16_out[3];
                    dst_out[15] = s2_m32_out[7];
                    dst_out[16] = s2_e4_out[1];
                    dst_out[17] = s2_m32_out[8];
                    dst_out[18] = s2_m16_out[4];
                    dst_out[19] = s2_m32_out[9];
                    dst_out[20] = s2_m8_out[2];
                    dst_out[21] = s2_m32_out[10];
                    dst_out[22] = s2_m16_out[5];
                    dst_out[23] = s2_m32_out[11];
                    dst_out[24] = s2_m4_out[1];
                    dst_out[25] = s2_m32_out[12];
                    dst_out[26] = s2_m16_out[6];
                    dst_out[27] = s2_m32_out[13];
                    dst_out[28] = s2_m8_out[3];
                    dst_out[29] = s2_m32_out[14];
                    dst_out[30] = s2_m16_out[7];
                    dst_out[31] = s2_m32_out[15];
                end
                default: begin
                    // synthesis translate_off
                    if (rst_n && s2_valid) begin
                        $error("ERROR [transform_1d_core] Unsupported tu_size_log2=%0d at time=%0t", s2_tu_size_log2, $time);
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
        end else if (s3_ready) begin
            out_valid <= s2_valid;
            if (s2_valid) begin
                for (i = 0; i < 32; i = i + 1) begin
                    out_vec[i*16 +: 16] <= clip_s16((dst_out[i] + (32'sd1 << (s2_shift_val - 5'd1))) >>> s2_shift_val);
                end
            end
        end
    end

endmodule
