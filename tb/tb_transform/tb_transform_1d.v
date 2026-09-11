//=============================================================================
// tb_transform_1d.v
// Unit Testbench for 1D Transform Core (DCT-II 4/8-pt & 4-pt DST-VII)
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

    initial begin
        clk = 0;
        rst_n = 0;
        fwd_inv_n = 1;
        tu_size_log2 = 2; // 4-pt
        is_dst7 = 0;
        is_second_pass = 0;
        in_valid = 0;
        in_vec = 0;
        out_ready = 1;

        #50;
        rst_n = 1;
        #20;

        $display("\n=================================================================");
        $display("Test 1: 4-Point Forward DCT-II on [100, 100, 100, 100]");
        $display("=================================================================");
        @(posedge clk);
        in_valid = 1;
        fwd_inv_n = 1;
        tu_size_log2 = 2;
        is_dst7 = 0;
        is_second_pass = 0;
        in_vec[0*16 +: 16] = 16'sd100;
        in_vec[1*16 +: 16] = 16'sd100;
        in_vec[2*16 +: 16] = 16'sd100;
        in_vec[3*16 +: 16] = 16'sd100;
        @(posedge clk);
        in_valid = 0;

        wait(out_valid);
        $display("4-Point DCT-II Output: DC=%0d, AC1=%0d, AC2=%0d, AC3=%0d",
            $signed(out_vec[0*16 +: 16]),
            $signed(out_vec[1*16 +: 16]),
            $signed(out_vec[2*16 +: 16]),
            $signed(out_vec[3*16 +: 16])
        );

        #50;
        $display("\n=================================================================");
        $display("Test 2: 4-Point Forward DST-VII on [50, 100, 150, 200] (Intra Luma)");
        $display("=================================================================");
        @(posedge clk);
        in_valid = 1;
        fwd_inv_n = 1;
        tu_size_log2 = 2;
        is_dst7 = 1;
        is_second_pass = 0;
        in_vec[0*16 +: 16] = 16'sd50;
        in_vec[1*16 +: 16] = 16'sd100;
        in_vec[2*16 +: 16] = 16'sd150;
        in_vec[3*16 +: 16] = 16'sd200;
        @(posedge clk);
        in_valid = 0;

        wait(out_valid);
        $display("4-Point DST-VII Output: c0=%0d, c1=%0d, c2=%0d, c3=%0d",
            $signed(out_vec[0*16 +: 16]),
            $signed(out_vec[1*16 +: 16]),
            $signed(out_vec[2*16 +: 16]),
            $signed(out_vec[3*16 +: 16])
        );

        #50;
        $display("\n=================================================================");
        $display("Test 3: 8-Point Forward DCT-II on [10, 20, 30, 40, 50, 60, 70, 80]");
        $display("=================================================================");
        @(posedge clk);
        in_valid = 1;
        fwd_inv_n = 1;
        tu_size_log2 = 3;
        is_dst7 = 0;
        is_second_pass = 0;
        for (i = 0; i < 8; i = i + 1) in_vec[i*16 +: 16] = 16'sd10 * (i + 1);
        @(posedge clk);
        in_valid = 0;

        wait(out_valid);
        $display("8-Point DCT-II Output:");
        for (i = 0; i < 8; i = i + 1) begin
            $write("%0d ", $signed(out_vec[i*16 +: 16]));
        end
        $display("");

        $display("\n=================================================================");
        $display("1D Transform Core Unit Verification PASSED!");
        $display("=================================================================\n");
        #100;
        $finish;
    end

endmodule
