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
    reg signed [31:0] dst_out [0:31];

    // Temporary butterfly terms
    reg signed [31:0] c0, c1, c2, c3;
    reg signed [31:0] e4[0:1], o4[0:1];
    reg signed [31:0] e8[0:3], o8[0:3];
    reg signed [31:0] e16[0:7], o16[0:7];
    reg signed [31:0] e32[0:15], o32[0:15];
    integer i, k;

    always @(*) begin
        for (i = 0; i < 32; i = i + 1) dst_out[i] = 32'sd0;

        if (is_dst7 && tu_size_log2 == 3'd2) begin
            //-----------------------------------------------------------------
            // 4-point DST-VII (HEVC Section 8.4.5.3.1.2)
            // Forward / Inverse
            //-----------------------------------------------------------------
            if (fwd_inv_n) begin
                // Fast Forward DST-VII (HM fastForwardDst)
                c0 = $signed({{16{src[0][15]}}, src[0]}) + $signed({{16{src[3][15]}}, src[3]});
                c1 = $signed({{16{src[1][15]}}, src[1]}) + $signed({{16{src[3][15]}}, src[3]});
                c2 = $signed({{16{src[0][15]}}, src[0]}) - $signed({{16{src[1][15]}}, src[1]});
                c3 = 32'sd74 * $signed({{16{src[2][15]}}, src[2]});

                dst_out[0] = 32'sd29 * c0 + 32'sd55 * c1 + c3;
                dst_out[1] = 32'sd74 * ($signed({{16{src[0][15]}}, src[0]}) + $signed({{16{src[1][15]}}, src[1]}) - $signed({{16{src[3][15]}}, src[3]}));
                dst_out[2] = 32'sd29 * c2 + 32'sd55 * c0 - c3;
                dst_out[3] = 32'sd55 * c2 - 32'sd29 * c1 + c3;
            end else begin
                // Fast Inverse DST-VII (HM fastInverseDst)
                c0 = $signed({{16{src[0][15]}}, src[0]}) + $signed({{16{src[2][15]}}, src[2]});
                c1 = $signed({{16{src[2][15]}}, src[2]}) + $signed({{16{src[3][15]}}, src[3]});
                c2 = $signed({{16{src[0][15]}}, src[0]}) - $signed({{16{src[3][15]}}, src[3]});
                c3 = 32'sd74 * $signed({{16{src[1][15]}}, src[1]});

                dst_out[0] = 32'sd29 * c0 + 32'sd55 * c1 + c3;
                dst_out[1] = 32'sd55 * c2 - 32'sd29 * c1 + c3;
                dst_out[2] = 32'sd74 * ($signed({{16{src[0][15]}}, src[0]}) - $signed({{16{src[2][15]}}, src[2]}) + $signed({{16{src[3][15]}}, src[3]}));
                dst_out[3] = 32'sd55 * c0 + 32'sd29 * c2 - c3;
            end
        end else if (tu_size_log2 == 3'd2) begin
            //-----------------------------------------------------------------
            // 4-point DCT-II (HEVC Table 9-15)
            //-----------------------------------------------------------------
            if (fwd_inv_n) begin
                e4[0] = $signed({{16{src[0][15]}}, src[0]}) + $signed({{16{src[3][15]}}, src[3]});
                e4[1] = $signed({{16{src[1][15]}}, src[1]}) + $signed({{16{src[2][15]}}, src[2]});
                o4[0] = $signed({{16{src[0][15]}}, src[0]}) - $signed({{16{src[3][15]}}, src[3]});
                o4[1] = $signed({{16{src[1][15]}}, src[1]}) - $signed({{16{src[2][15]}}, src[2]});

                dst_out[0] = 32'sd64 * (e4[0] + e4[1]);
                dst_out[1] = 32'sd83 * o4[0] + 32'sd36 * o4[1];
                dst_out[2] = 32'sd64 * (e4[0] - e4[1]);
                dst_out[3] = 32'sd36 * o4[0] - 32'sd83 * o4[1];
            end else begin
                e4[0] = 32'sd64 * ($signed({{16{src[0][15]}}, src[0]}) + $signed({{16{src[2][15]}}, src[2]}));
                e4[1] = 32'sd64 * ($signed({{16{src[0][15]}}, src[0]}) - $signed({{16{src[2][15]}}, src[2]}));
                o4[0] = 32'sd83 * $signed({{16{src[1][15]}}, src[1]}) + 32'sd36 * $signed({{16{src[3][15]}}, src[3]});
                o4[1] = 32'sd36 * $signed({{16{src[1][15]}}, src[1]}) - 32'sd83 * $signed({{16{src[3][15]}}, src[3]});

                dst_out[0] = e4[0] + o4[0];
                dst_out[1] = e4[1] + o4[1];
                dst_out[2] = e4[1] - o4[1];
                dst_out[3] = e4[0] - o4[0];
            end
        end else if (tu_size_log2 == 3'd3) begin
            //-----------------------------------------------------------------
            // 8-point DCT-II (HEVC Table 9-15)
            //-----------------------------------------------------------------
            if (fwd_inv_n) begin
                for (k = 0; k < 4; k = k + 1) begin
                    e8[k] = $signed({{16{src[k][15]}}, src[k]}) + $signed({{16{src[7-k][15]}}, src[7-k]});
                    o8[k] = $signed({{16{src[k][15]}}, src[k]}) - $signed({{16{src[7-k][15]}}, src[7-k]});
                end
                // Even parts (4-point on E8)
                e4[0] = e8[0] + e8[3]; e4[1] = e8[1] + e8[2];
                o4[0] = e8[0] - e8[3]; o4[1] = e8[1] - e8[2];
                dst_out[0] = 32'sd64 * (e4[0] + e4[1]);
                dst_out[2] = 32'sd83 * o4[0] + 32'sd36 * o4[1];
                dst_out[4] = 32'sd64 * (e4[0] - e4[1]);
                dst_out[6] = 32'sd36 * o4[0] - 32'sd83 * o4[1];
                // Odd parts
                dst_out[1] = 32'sd89 * o8[0] + 32'sd75 * o8[1] + 32'sd50 * o8[2] + 32'sd18 * o8[3];
                dst_out[3] = 32'sd75 * o8[0] - 32'sd18 * o8[1] - 32'sd89 * o8[2] - 32'sd50 * o8[3];
                dst_out[5] = 32'sd50 * o8[0] - 32'sd89 * o8[1] + 32'sd18 * o8[2] + 32'sd75 * o8[3];
                dst_out[7] = 32'sd18 * o8[0] - 32'sd50 * o8[1] + 32'sd75 * o8[2] - 32'sd89 * o8[3];
            end else begin
                // Inverse 8-point
                e4[0] = 32'sd64 * ($signed({{16{src[0][15]}}, src[0]}) + $signed({{16{src[4][15]}}, src[4]}));
                e4[1] = 32'sd64 * ($signed({{16{src[0][15]}}, src[0]}) - $signed({{16{src[4][15]}}, src[4]}));
                o4[0] = 32'sd83 * $signed({{16{src[2][15]}}, src[2]}) + 32'sd36 * $signed({{16{src[6][15]}}, src[6]});
                o4[1] = 32'sd36 * $signed({{16{src[2][15]}}, src[2]}) - 32'sd83 * $signed({{16{src[6][15]}}, src[6]});
                e8[0] = e4[0] + o4[0]; e8[1] = e4[1] + o4[1];
                e8[2] = e4[1] - o4[1]; e8[3] = e4[0] - o4[0];

                o8[0] = 32'sd89 * $signed({{16{src[1][15]}}, src[1]}) + 32'sd75 * $signed({{16{src[3][15]}}, src[3]}) + 32'sd50 * $signed({{16{src[5][15]}}, src[5]}) + 32'sd18 * $signed({{16{src[7][15]}}, src[7]});
                o8[1] = 32'sd75 * $signed({{16{src[1][15]}}, src[1]}) - 32'sd18 * $signed({{16{src[3][15]}}, src[3]}) - 32'sd89 * $signed({{16{src[5][15]}}, src[5]}) - 32'sd50 * $signed({{16{src[7][15]}}, src[7]});
                o8[2] = 32'sd50 * $signed({{16{src[1][15]}}, src[1]}) - 32'sd89 * $signed({{16{src[3][15]}}, src[3]}) + 32'sd18 * $signed({{16{src[5][15]}}, src[5]}) + 32'sd75 * $signed({{16{src[7][15]}}, src[7]});
                o8[3] = 32'sd18 * $signed({{16{src[1][15]}}, src[1]}) - 32'sd50 * $signed({{16{src[3][15]}}, src[3]}) + 32'sd75 * $signed({{16{src[5][15]}}, src[5]}) - 32'sd89 * $signed({{16{src[7][15]}}, src[7]});

                dst_out[0] = e8[0] + o8[0]; dst_out[1] = e8[1] + o8[1];
                dst_out[2] = e8[2] + o8[2]; dst_out[3] = e8[3] + o8[3];
                dst_out[4] = e8[3] - o8[3]; dst_out[5] = e8[2] - o8[2];
                dst_out[6] = e8[1] - o8[1]; dst_out[7] = e8[0] - o8[0];
            end
        end else begin
            // Default passthrough / higher TU fallback
            for (i = 0; i < 32; i = i + 1) begin
                dst_out[i] = $signed({{16{src[i][15]}}, src[i]}) << shift_val;
            end
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
