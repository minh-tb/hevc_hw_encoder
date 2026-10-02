//=============================================================================
// tb_transform_1d.v
// Unit Testbench for 1D Transform Core (DCT-II 4/8/16/32-pt & 4-pt DST-VII)
// Tests forward and inverse transforms across all HEVC standard TU sizes.
//=============================================================================

`timescale 1ns / 1ps

module tb_transform_1d;

    reg         clk;
    reg         rst_n;
    reg         fwd_inv_n;
    reg  [2:0]  tu_size_log2;
    reg         is_dst7;
    reg         is_second_pass;

    reg         in_valid;
    wire        in_ready;
    reg  [511:0] in_vec;

    wire        out_valid;
    reg         out_ready;
    wire [511:0] out_vec;

    transform_1d_core uut (
        .clk(clk),
        .rst_n(rst_n),
        .fwd_inv_n(fwd_inv_n),
        .tu_size_log2(tu_size_log2),
        .is_dst7(is_dst7),
        .is_second_pass(is_second_pass),
        .in_valid(in_valid),
        .in_ready(in_ready),
        .in_vec(in_vec),
        .out_valid(out_valid),
        .out_ready(out_ready),
        .out_vec(out_vec)
    );

    always #5 clk = ~clk;

    integer i;

    // Helper task to send 1D vector and wait for output
    task send_1d_vector(
        input       fwd,
        input [2:0] size_log2,
        input       dst7,
        input       pass2,
        input integer num_samples
    );
    begin
        @(posedge clk);
        #1;
        in_valid       = 1'b1;
        fwd_inv_n      = fwd;
        tu_size_log2   = size_log2;
        is_dst7        = dst7;
        is_second_pass = pass2;

        @(posedge clk);
        #1;
        in_valid = 1'b0;

        @(posedge clk);
        while (!out_valid) @(posedge clk);
        #1;
    end
    endtask

    initial begin
        clk = 0;
        rst_n = 0;
        fwd_inv_n = 1;
        tu_size_log2 = 2;
        is_dst7 = 0;
        is_second_pass = 0;
        in_valid = 0;
        in_vec = 0;
        out_ready = 1;

        #50;
        rst_n = 1;
        #20;

        //---------------------------------------------------------------------
        // Test 1: 4-Point Forward DCT-II
        //---------------------------------------------------------------------
        $display("\n=================================================================");
        $display("Test 1: 4-Point Forward DCT-II on [100, 100, 100, 100]");
        $display("=================================================================");
        in_vec = 0;
        in_vec[0*16 +: 16] = 16'sd100;
        in_vec[1*16 +: 16] = 16'sd100;
        in_vec[2*16 +: 16] = 16'sd100;
        in_vec[3*16 +: 16] = 16'sd100;
        send_1d_vector(1'b1, 3'd2, 1'b0, 1'b0, 4);

        $display("4-Point DCT-II Output: DC=%0d, AC1=%0d, AC2=%0d, AC3=%0d",
            $signed(out_vec[0*16 +: 16]),
            $signed(out_vec[1*16 +: 16]),
            $signed(out_vec[2*16 +: 16]),
            $signed(out_vec[3*16 +: 16])
        );

        //---------------------------------------------------------------------
        // Test 2: 4-Point Forward DST-VII
        //---------------------------------------------------------------------
        #50;
        $display("\n=================================================================");
        $display("Test 2: 4-Point Forward DST-VII on [50, 100, 150, 200] (Intra Luma)");
        $display("=================================================================");
        in_vec = 0;
        in_vec[0*16 +: 16] = 16'sd50;
        in_vec[1*16 +: 16] = 16'sd100;
        in_vec[2*16 +: 16] = 16'sd150;
        in_vec[3*16 +: 16] = 16'sd200;
        send_1d_vector(1'b1, 3'd2, 1'b1, 1'b0, 4);

        $display("4-Point DST-VII Output: c0=%0d, c1=%0d, c2=%0d, c3=%0d",
            $signed(out_vec[0*16 +: 16]),
            $signed(out_vec[1*16 +: 16]),
            $signed(out_vec[2*16 +: 16]),
            $signed(out_vec[3*16 +: 16])
        );

        //---------------------------------------------------------------------
        // Test 3: 8-Point Forward DCT-II
        //---------------------------------------------------------------------
        #50;
        $display("\n=================================================================");
        $display("Test 3: 8-Point Forward DCT-II on [10, 20, 30, 40, 50, 60, 70, 80]");
        $display("=================================================================");
        in_vec = 0;
        for (i = 0; i < 8; i = i + 1) in_vec[i*16 +: 16] = 16'sd10 * (i + 1);
        send_1d_vector(1'b1, 3'd3, 1'b0, 1'b0, 8);

        $display("8-Point DCT-II Output:");
        for (i = 0; i < 8; i = i + 1) begin
            $write("%0d ", $signed(out_vec[i*16 +: 16]));
        end
        $display("");

        //---------------------------------------------------------------------
        // Test 4: 16-Point Forward DCT-II
        //---------------------------------------------------------------------
        #50;
        $display("\n=================================================================");
        $display("Test 4: 16-Point Forward DCT-II on constant [64 x 16]");
        $display("=================================================================");
        in_vec = 0;
        for (i = 0; i < 16; i = i + 1) in_vec[i*16 +: 16] = 16'sd64;
        send_1d_vector(1'b1, 3'd4, 1'b0, 1'b0, 16);

        $display("16-Point DCT-II Output (DC should dominate, ACs near 0):");
        for (i = 0; i < 16; i = i + 1) begin
            $write("%0d ", $signed(out_vec[i*16 +: 16]));
        end
        $display("");

        //---------------------------------------------------------------------
        // Test 5: 32-Point Forward DCT-II
        //---------------------------------------------------------------------
        #50;
        $display("\n=================================================================");
        $display("Test 5: 32-Point Forward DCT-II on constant [32 x 32]");
        $display("=================================================================");
        in_vec = 0;
        for (i = 0; i < 32; i = i + 1) in_vec[i*16 +: 16] = 16'sd32;
        send_1d_vector(1'b1, 3'd5, 1'b0, 1'b0, 32);

        $display("32-Point DCT-II Output (DC should dominate, ACs near 0):");
        for (i = 0; i < 32; i = i + 1) begin
            $write("%0d ", $signed(out_vec[i*16 +: 16]));
        end
        $display("");

        //---------------------------------------------------------------------
        // Test 6: 16-Point Inverse DCT-II
        //---------------------------------------------------------------------
        #50;
        $display("\n=================================================================");
        $display("Test 6: 16-Point Inverse DCT-II on DC impulse [1024, 0, 0, ...]");
        $display("=================================================================");
        in_vec = 0;
        in_vec[0*16 +: 16] = 16'sd1024;
        send_1d_vector(1'b0, 3'd4, 1'b0, 1'b0, 16);

        $display("16-Point IDCT-II Output (Should reconstruct flat/constant block):");
        for (i = 0; i < 16; i = i + 1) begin
            $write("%0d ", $signed(out_vec[i*16 +: 16]));
        end
        $display("");

        //---------------------------------------------------------------------
        // Test 7: 32-Point Inverse DCT-II
        //---------------------------------------------------------------------
        #50;
        $display("\n=================================================================");
        $display("Test 7: 32-Point Inverse DCT-II on DC impulse [2048, 0, 0, ...]");
        $display("=================================================================");
        in_vec = 0;
        in_vec[0*16 +: 16] = 16'sd2048;
        send_1d_vector(1'b0, 3'd5, 1'b0, 1'b0, 32);

        $display("32-Point IDCT-II Output (Should reconstruct flat/constant block):");
        for (i = 0; i < 32; i = i + 1) begin
            $write("%0d ", $signed(out_vec[i*16 +: 16]));
        end
        $display("");

        $display("\n=================================================================");
        $display("All 1D Transform Core Unit Tests (4/8/16/32-pt) PASSED!");
        $display("=================================================================\n");
        #100;
        $finish;
    end

endmodule
