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
    
    // 16 signed 11-bit residual differences (Orig - Pred, range [-1023, +1023])
    input  wire signed [10:0]       diff_0,  diff_1,  diff_2,  diff_3,
    input  wire signed [10:0]       diff_4,  diff_5,  diff_6,  diff_7,
    input  wire signed [10:0]       diff_8,  diff_9,  diff_10, diff_11,
    input  wire signed [10:0]       diff_12, diff_13, diff_14, diff_15,
    
    output reg                      done,
    output reg  [15:0]              satd_out
);

    // =========================================================================
    // Stage-1 1D Hadamard Function: 11-bit signed inputs -> 13-bit signed outputs
    // Max magnitude: 4 * 1023 = 4092 (fits signed [12:0], [-4096, +4095])
    // =========================================================================
    function automatic [51:0] hadamard_1d_s1;
        input signed [10:0] a, b, c, d;
        reg   signed [12:0] ax, bx, cx, dx;
        reg   signed [12:0] s0, d0, s1, d1;
        reg   signed [12:0] y0, y1, y2, y3;
        begin
            ax = a;
            bx = b;
            cx = c;
            dx = d;
            s0 = ax + dx;
            d0 = ax - dx;
            s1 = bx + cx;
            d1 = bx - cx;
            y0 = s0 + s1;
            y1 = d0 + d1;
            y2 = d0 - d1;
            y3 = s0 - s1;
            hadamard_1d_s1 = {y3, y2, y1, y0};
        end
    endfunction

    // =========================================================================
    // Stage-2 1D Hadamard Function: 13-bit signed inputs -> 15-bit signed outputs
    // Max magnitude: 16 * 1023 = 16368 (fits signed [14:0], [-16384, +16383])
    // =========================================================================
    function automatic [59:0] hadamard_1d_s2;
        input signed [12:0] a, b, c, d;
        reg   signed [14:0] ax, bx, cx, dx;
        reg   signed [14:0] s0, d0, s1, d1;
        reg   signed [14:0] y0, y1, y2, y3;
        begin
            ax = a;
            bx = b;
            cx = c;
            dx = d;
            s0 = ax + dx;
            d0 = ax - dx;
            s1 = bx + cx;
            d1 = bx - cx;
            y0 = s0 + s1;
            y1 = d0 + d1;
            y2 = d0 - d1;
            y3 = s0 - s1;
            hadamard_1d_s2 = {y3, y2, y1, y0};
        end
    endfunction

    // Stage 1: Row Transform (latches all 16 diff_0..15 on start clock edge)
    reg signed [12:0] row_t [0:15];
    reg               stg1_valid;

    wire [51:0] r0_out = hadamard_1d_s1(diff_0,  diff_1,  diff_2,  diff_3);
    wire [51:0] r1_out = hadamard_1d_s1(diff_4,  diff_5,  diff_6,  diff_7);
    wire [51:0] r2_out = hadamard_1d_s1(diff_8,  diff_9,  diff_10, diff_11);
    wire [51:0] r3_out = hadamard_1d_s1(diff_12, diff_13, diff_14, diff_15);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stg1_valid <= 1'b0;
        end else begin
            stg1_valid <= start;
            if (start) begin
                row_t[0]  <= r0_out[12:0];  row_t[1]  <= r0_out[25:13]; row_t[2]  <= r0_out[38:26]; row_t[3]  <= r0_out[51:39];
                row_t[4]  <= r1_out[12:0];  row_t[5]  <= r1_out[25:13]; row_t[6]  <= r1_out[38:26]; row_t[7]  <= r1_out[51:39];
                row_t[8]  <= r2_out[12:0];  row_t[9]  <= r2_out[25:13]; row_t[10] <= r2_out[38:26]; row_t[11] <= r2_out[51:39];
                row_t[12] <= r3_out[12:0];  row_t[13] <= r3_out[25:13]; row_t[14] <= r3_out[38:26]; row_t[15] <= r3_out[51:39];
            end
        end
    end

    // Stage 2: Column Transform & Absolute Sum (reads only registered row_t)
    wire [59:0] c0_out = hadamard_1d_s2(row_t[0], row_t[4], row_t[8],  row_t[12]);
    wire [59:0] c1_out = hadamard_1d_s2(row_t[1], row_t[5], row_t[9],  row_t[13]);
    wire [59:0] c2_out = hadamard_1d_s2(row_t[2], row_t[6], row_t[10], row_t[14]);
    wire [59:0] c3_out = hadamard_1d_s2(row_t[3], row_t[7], row_t[11], row_t[15]);

    reg signed [14:0] col_t [0:15];
    integer i;
    reg        [16:0] abs_sum;
    reg        [16:0] satd_norm;
    reg signed [14:0] sample;
    reg        [14:0] abs_val;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            done     <= 1'b0;
            satd_out <= 16'd0;
        end else begin
            done <= stg1_valid;
            if (stg1_valid) begin
                col_t[0]  = c0_out[14:0];  col_t[4]  = c0_out[29:15]; col_t[8]  = c0_out[44:30]; col_t[12] = c0_out[59:45];
                col_t[1]  = c1_out[14:0];  col_t[5]  = c1_out[29:15]; col_t[9]  = c1_out[44:30]; col_t[13] = c1_out[59:45];
                col_t[2]  = c2_out[14:0];  col_t[6]  = c2_out[29:15]; col_t[10] = c2_out[44:30]; col_t[14] = c2_out[59:45];
                col_t[3]  = c3_out[14:0];  col_t[7]  = c3_out[29:15]; col_t[11] = c3_out[44:30]; col_t[15] = c3_out[59:45];

                abs_sum = 17'd0;
                for (i = 0; i < 16; i = i + 1) begin
                    sample  = col_t[i];
                    abs_val = sample[14] ? (~sample[14:0] + 15'd1) : sample[14:0];
                    abs_sum = abs_sum + {2'b00, abs_val};
                end

                // Normalization: (abs_sum + 1) >> 1 (max 32,736)
                satd_norm = (abs_sum + 17'd1) >> 1;
                satd_out <= satd_norm[15:0];
            end
        end
    end

endmodule
