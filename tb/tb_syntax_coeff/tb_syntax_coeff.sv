`timescale 1ns/1ps

module tb_syntax_coeff;

    // =========================================================================
    // Parameters & Signals
    // =========================================================================
    parameter int CTX_ID_W = 8;
    parameter int COEFF_W  = 16;
    parameter int BLK_SIZE = 4;
    parameter int N_COEFF  = 16;

    logic                          clk;
    logic                          rst_n;

    logic                          coeff_valid;
    logic                          coeff_done;

    logic [1:0]                    comp_id;
    logic                          is_intra;
    logic [COEFF_W*N_COEFF-1:0]    coeff_flat;

    logic                          bin_valid;
    logic                          bin_value;
    logic [CTX_ID_W-1:0]           bin_ctx_id;
    logic                          bin_is_ep;
    logic                          bin_rdy;

    // =========================================================================
    // Device Under Test (DUT)
    // =========================================================================
    // Notice the SystemVerilog implicit connection (.*) 
    // This connects all ports to local signals of the exact same name!
    syntax_coeff #(
        .CTX_ID_W (CTX_ID_W),
        .COEFF_W  (COEFF_W),
        .BLK_SIZE (BLK_SIZE),
        .N_COEFF  (N_COEFF)
    ) dut (.*);

    // =========================================================================
    // Clock & Reset Generation
    // =========================================================================
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk; // 100 MHz
    end

    initial begin
        rst_n = 1'b0;
        #20 rst_n = 1'b1;
    end

    // =========================================================================
    // Random Ready Signal (Stall simulation)
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bin_rdy <= 1'b1;
        end else begin
            // Assert ready ~70% of the time using SV RNG
            bin_rdy <= ($urandom_range(0, 99) < 70);
        end
    end

    // =========================================================================
    // Bin Monitor
    // =========================================================================
    int bin_count;
    always_ff @(posedge clk) begin
        if (rst_n && bin_valid && bin_rdy) begin
            bin_count++;
            $display("    Bin %0d: val=%b | ctx=%0d | ep=%b", 
                     bin_count, bin_value, bin_ctx_id, bin_is_ep);
        end
    end

    // =========================================================================
    // Test Stimulus
    // =========================================================================
    logic signed [COEFF_W-1:0] test_blk [N_COEFF];

    // SV 'automatic' task ensures independent internal variables
    task automatic encode_block(input logic [1:0] t_comp, input logic t_intra);
        // Flatten the array into the wide bus
        foreach (test_blk[i]) begin
            coeff_flat[i*COEFF_W +: COEFF_W] = test_blk[i];
        end

        @(posedge clk);
        coeff_valid <= 1'b1;
        comp_id     <= t_comp;
        is_intra    <= t_intra;
        
        @(posedge clk);
        coeff_valid <= 1'b0;

        // Wait for completion
        wait(coeff_done);
        @(posedge clk);
        $display("[INFO] Block Encoding Complete. Total Bins = %0d\n", bin_count);
    endtask

    // Helper task to clear the block using SV foreach
    task automatic clear_block();
        foreach (test_blk[i]) test_blk[i] = '0;
    endtask

    // Main sequence
    initial begin
        coeff_valid = 1'b0;
        comp_id     = 2'd0;
        is_intra    = 1'b0;
        coeff_flat  = '0;
        bin_count   = 0;

        wait(rst_n);
        @(posedge clk);
        @(posedge clk);

        // -----------------------------------------------------------
        $display("==================================================");
        $display("TEST 1: DC-Only Block (Luma, Intra)");
        $display("==================================================");
        bin_count = 0;
        clear_block();
        test_blk[0] = 16'd15; // Only DC is non-zero
        encode_block(2'd0, 1'b1);

        // -----------------------------------------------------------
        $display("==================================================");
        $display("TEST 2: Sparse Block (Chroma, Inter)");
        $display("==================================================");
        bin_count = 0;
        clear_block();
        test_blk[0] = 16'd5;
        test_blk[1] = -16'd2;
        test_blk[4] = 16'd1;  // Note: indices represent diagonal scan order
        encode_block(2'd1, 1'b0);

        // -----------------------------------------------------------
        $display("==================================================");
        $display("TEST 3: High Amplitude Block (Triggers Exp-Golomb)");
        $display("==================================================");
        bin_count = 0;
        clear_block();
        test_blk[0] = 16'd105;
        test_blk[1] = -16'd50;
        test_blk[2] = 16'd12;
        test_blk[3] = -16'd3;
        test_blk[5] = 16'd1;
        encode_block(2'd0, 1'b1);

        $display("\n>>> ALL TESTS FINISHED <<<");
        $stop;
    end

endmodule