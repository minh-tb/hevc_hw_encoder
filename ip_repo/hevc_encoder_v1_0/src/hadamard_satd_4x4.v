//=============================================================================
// hadamard_satd_4x4.v
// Pipelined 2D 4x4 Hadamard Transform Engine for Perceptual Distortion (SATD)
//
// Computes:
//   Y_2D = H4 * Diff_4x4 * H4^T
//   SATD = (sum(|Y_2D(i,j)|) + 1) >> 1
//=============================================================================

`timescale 1ns / 1ps

module hadamard_satd_4x4 (
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     start,
    
    // 16 signed 11-bit residual differences (Orig - Pred)
    input  wire signed [10:0]       diff_0,  diff_1,  diff_2,  diff_3,
    input  wire signed [10:0]       diff_4,  diff_5,  diff_6,  diff_7,
    input  wire signed [10:0]       diff_8,  diff_9,  diff_10, diff_11,
    input  wire signed [10:0]       diff_12, diff_13, diff_14, diff_15,
    
    output reg                      done,
    output reg  [15:0]              satd_out
);

    // =========================================================================
    // 1D Hadamard Function
    // =========================================================================
    function automatic [47:0] hadamard_1d;
        input signed [11:0] a, b, c, d;
        reg signed [11:0] s0, d0, s1, d1;
        reg signed [11:0] y0, y1, y2, y3;
        begin
            s0 = a + d;
            d0 = a - d;
            s1 = b + c;
            d1 = b - c;
            y0 = s0 + s1;
            y1 = d0 + d1;
            y2 = d0 - d1;
            y3 = s0 - s1;
            hadamard_1d = {y3, y2, y1, y0};
        end
    endfunction

    // Stage 1: Row Transform
    reg signed [11:0] row_t [0:15];
    reg               stg1_valid;
    
    reg [47:0] r0_out, r1_out, r2_out, r3_out;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stg1_valid <= 1'b0;
        end else begin
            stg1_valid <= start;
            if (start) begin
                r0_out = hadamard_1d(diff_0,  diff_1,  diff_2,  diff_3);
                r1_out = hadamard_1d(diff_4,  diff_5,  diff_6,  diff_7);
                r2_out = hadamard_1d(diff_8,  diff_9,  diff_10, diff_11);
                r3_out = hadamard_1d(diff_12, diff_13, diff_14, diff_15);

                row_t[0]  <= r0_out[11:0];  row_t[1]  <= r0_out[23:12]; row_t[2]  <= r0_out[35:24]; row_t[3]  <= r0_out[47:36];
                row_t[4]  <= r1_out[11:0];  row_t[5]  <= r1_out[23:12]; row_t[6]  <= r1_out[35:24]; row_t[7]  <= r1_out[47:36];
                row_t[8]  <= r2_out[11:0];  row_t[9]  <= r2_out[23:12]; row_t[10] <= r2_out[35:24]; row_t[11] <= r2_out[47:36];
                row_t[12] <= r3_out[11:0];  row_t[13] <= r3_out[23:12]; row_t[14] <= r3_out[35:24]; row_t[15] <= r3_out[47:36];
            end
        end
    end

    // Stage 2: Column Transform & Absolute Sum
    reg [47:0] c0_out, c1_out, c2_out, c3_out;
    reg signed [11:0] col_t [0:15];
    integer i;
    reg [16:0] abs_sum;
    reg signed [11:0] sample;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            done     <= 1'b0;
            satd_out <= 16'd0;
        end else begin
            done <= stg1_valid;
            if (stg1_valid) begin
                c0_out = hadamard_1d(row_t[0], row_t[4], row_t[8],  row_t[12]);
                c1_out = hadamard_1d(row_t[1], row_t[5], row_t[9],  row_t[13]);
                c2_out = hadamard_1d(row_t[2], row_t[6], row_t[10], row_t[14]);
                c3_out = hadamard_1d(row_t[3], row_t[7], row_t[11], row_t[15]);

                col_t[0]  = c0_out[11:0];  col_t[4]  = c0_out[23:12]; col_t[8]  = c0_out[35:24]; col_t[12] = c0_out[47:36];
                col_t[1]  = c1_out[11:0];  col_t[5]  = c1_out[23:12]; col_t[9]  = c1_out[35:24]; col_t[13] = c1_out[47:36];
                col_t[2]  = c2_out[11:0];  col_t[6]  = c2_out[23:12]; col_t[10] = c2_out[35:24]; col_t[14] = c2_out[47:36];
                col_t[3]  = c3_out[11:0];  col_t[7]  = c3_out[23:12]; col_t[11] = c3_out[35:24]; col_t[15] = c3_out[47:36];

                abs_sum = 17'd0;
                for (i = 0; i < 16; i = i + 1) begin
                    sample = col_t[i];
                    abs_sum = abs_sum + ((sample < 0) ? -sample : sample);
                end

                // Normalization: (abs_sum + 1) >> 1
                satd_out <= (abs_sum + 17'd1) >> 1;
            end
        end
    end

endmodule
