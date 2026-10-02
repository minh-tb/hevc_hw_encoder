//=============================================================================
// tb_cross_verify.v
// Bit-exact Cross-Verification: transform_1d_core vs dct16 & dct32
//=============================================================================

`timescale 1ns / 1ps
`include "parameter_pkg.vh"

module tb_cross_verify;

    reg clk;
    reg rst_n;

    // 1D core signals
    reg         fwd_inv_n;
    reg  [2:0]  tu_size_log2;
    reg         in_valid_1d;
    wire        in_ready_1d;
    reg  [511:0] in_vec_1d;
    wire        out_valid_1d;
    reg         out_ready_1d;
    wire [511:0] out_vec_1d;

    transform_1d_core u_1d (
        .clk(clk),
        .rst_n(rst_n),
        .fwd_inv_n(fwd_inv_n),
        .tu_size_log2(tu_size_log2),
        .is_dst7(1'b0),
        .is_second_pass(1'b0),
        .in_valid(in_valid_1d),
        .in_ready(in_ready_1d),
        .in_vec(in_vec_1d),
        .out_valid(out_valid_1d),
        .out_ready(out_ready_1d),
        .out_vec(out_vec_1d)
    );

    // Parallel dct16 instance
    reg         in_valid_16;
    wire        in_ready_16;
    reg  [4095:0] in_data_16;
    wire        out_valid_16;
    wire [4095:0] out_data_16;

    dct16 u_dct16 (
        .clk(clk),
        .rst_n(rst_n),
        .fwd_inv_n(fwd_inv_n),
        .in_valid(in_valid_16),
        .in_ready(in_ready_16),
        .in_data(in_data_16),
        .out_valid(out_valid_16),
        .out_ready(1'b1),
        .out_data(out_data_16)
    );

    // Parallel dct32 instance
    reg          in_valid_32;
    wire         in_ready_32;
    reg  [16383:0] in_data_32;
    wire         out_valid_32;
    wire [16383:0] out_data_32;

    dct32 u_dct32 (
        .clk(clk),
        .rst_n(rst_n),
        .fwd_inv_n(fwd_inv_n),
        .in_valid(in_valid_32),
        .in_ready(in_ready_32),
        .in_data(in_data_32),
        .out_valid(out_valid_32),
        .out_ready(1'b1),
        .out_data(out_data_32)
    );

    always #5 clk = ~clk;

    integer r, c, err_cnt;

    initial begin
        clk = 0;
        rst_n = 0;
        fwd_inv_n = 1;
        tu_size_log2 = 4;
        in_valid_1d = 0;
        in_valid_16 = 0;
        in_vec_1d = 0;
        in_data_16 = 0;
        out_ready_1d = 1;
        err_cnt = 0;

        #50;
        rst_n = 1;
        #20;

        $display("\n=================================================================");
        $display("Cross-Verification: 16-point Forward 1D Pass vs dct16.v stage1");
        $display("=================================================================");

        // Prepare test data: pseudo-random ramp pattern
        for (r = 0; r < 16; r = r + 1) begin
            for (c = 0; c < 16; c = c + 1) begin
                in_data_16[(r*16+c)*16 +: 16] = 16'sd15 * (r + 1) + 16'sd7 * (c + 1);
            end
        end
        // Feed row 0 to 1D core
        for (c = 0; c < 16; c = c + 1) begin
            in_vec_1d[c*16 +: 16] = in_data_16[(0*16+c)*16 +: 16];
        end

        @(posedge clk);
        #1;
        in_valid_1d = 1'b1;
        in_valid_16 = 1'b1;
        fwd_inv_n   = 1'b1;
        tu_size_log2= 3'd4;

        @(posedge clk);
        #1;
        in_valid_1d = 1'b0;
        in_valid_16 = 1'b0;

        // Wait 1 cycle for stage1 to register
        @(posedge clk);
        #1;

        // Compare 1D core output with dct16 stage1 (row 0)
        for (c = 0; c < 16; c = c + 1) begin
            if ($signed(out_vec_1d[c*16 +: 16]) !== $signed(u_dct16.stage1[0][c])) begin
                $display("MISMATCH at coeff %0d: 1D_core=%0d, dct16_stage1=%0d",
                         c, $signed(out_vec_1d[c*16 +: 16]), $signed(u_dct16.stage1[0][c]));
                err_cnt = err_cnt + 1;
            end else begin
                $display("Match coeff %0d: %0d == %0d",
                         c, $signed(out_vec_1d[c*16 +: 16]), $signed(u_dct16.stage1[0][c]));
            end
        end

        if (err_cnt == 0) begin
            $display("\n=================================================================");
            $display("16-point 1D Core vs dct16.v BIT-EXACT MATCH PASSED (0 errors)!");
            $display("=================================================================\n");
        end else begin
            $display("\nFAILED with %0d errors!\n", err_cnt);
        end

        //---------------------------------------------------------------------
        // 32-point Cross-Verification
        //---------------------------------------------------------------------
        #50;
        $display("\n=================================================================");
        $display("Cross-Verification: 32-point Forward 1D Pass vs dct32.v stage1");
        $display("=================================================================");
        err_cnt = 0;
        in_vec_1d = 0;
        in_data_32 = 0;

        for (r = 0; r < 32; r = r + 1) begin
            for (c = 0; c < 32; c = c + 1) begin
                in_data_32[(r*32+c)*16 +: 16] = 16'sd11 * (r + 1) + 16'sd3 * (c + 1);
            end
        end
        for (c = 0; c < 32; c = c + 1) begin
            in_vec_1d[c*16 +: 16] = in_data_32[(0*32+c)*16 +: 16];
        end

        @(posedge clk);
        #1;
        in_valid_1d = 1'b1;
        in_valid_32 = 1'b1;
        fwd_inv_n   = 1'b1;
        tu_size_log2= 3'd5;

        @(posedge clk);
        #1;
        in_valid_1d = 1'b0;
        in_valid_32 = 1'b0;

        @(posedge clk);
        #1;

        for (c = 0; c < 32; c = c + 1) begin
            if ($signed(out_vec_1d[c*16 +: 16]) !== $signed(u_dct32.stage1[0][c])) begin
                $display("MISMATCH at coeff %0d: 1D_core=%0d, dct32_stage1=%0d",
                         c, $signed(out_vec_1d[c*16 +: 16]), $signed(u_dct32.stage1[0][c]));
                err_cnt = err_cnt + 1;
            end else begin
                $display("Match coeff %0d: %0d == %0d",
                         c, $signed(out_vec_1d[c*16 +: 16]), $signed(u_dct32.stage1[0][c]));
            end
        end

        if (err_cnt == 0) begin
            $display("\n=================================================================");
            $display("32-point 1D Core vs dct32.v BIT-EXACT MATCH PASSED (0 errors)!");
            $display("=================================================================\n");
        end else begin
            $display("\n32-point FAILED with %0d errors!\n", err_cnt);
        end

        #50;
        $finish;
    end

endmodule
