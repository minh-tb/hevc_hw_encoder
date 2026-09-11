`timescale 1ns/1ps

`include "parameter_pkg.vh"
`include "hevc_interfaces.vh"

module tb_intra_prediction();

    // Clock and Reset
    logic clk;
    logic rst_n;

    // Inputs
    logic [5:0]  cu_x;
    logic [5:0]  cu_y;
    logic [2:0]  pu_size_log2;
    logic        is_luma;
    logic        rmd_start;
    logic        pred_start;
    logic [5:0]  pred_intra_mode;
    logic        ref_valid;
    logic [`PIXEL_WIDTH-1:0]  ref_sample;
    logic [7:0]  ref_idx;
    logic        ref_last;
    logic [`PIXEL_WIDTH-1:0]  orig_rd_data;
    logic        pred_ready;

    // Outputs
    logic        rmd_done;
    logic [5:0]  rmd_best_mode;
    logic [31:0] rmd_best_cost;
    logic        ref_ready;
    logic [11:0] orig_rd_addr;
    logic        orig_rd_active;
    logic        pred_valid;
    logic [`PIXEL_WIDTH-1:0]  pred_pixel;
    logic [5:0]  pred_x;
    logic [5:0]  pred_y;
    logic        pred_last;

    // DUT Instantiation
    intra_prediction uut (
        .clk             (clk),
        .rst_n           (rst_n),
        .cu_x            (cu_x),
        .cu_y            (cu_y),
        .pu_size_log2    (pu_size_log2),
        .is_luma         (is_luma),
        .rmd_start       (rmd_start),
        .rmd_done        (rmd_done),
        .rmd_best_mode   (rmd_best_mode),
        .rmd_best_cost   (rmd_best_cost),
        .pred_start      (pred_start),
        .pred_intra_mode (pred_intra_mode),
        .ref_valid       (ref_valid),
        .ref_ready       (ref_ready),
        .ref_sample      (ref_sample),
        .ref_idx         (ref_idx),
        .ref_last        (ref_last),
        .orig_rd_addr    (orig_rd_addr),
        .orig_rd_active  (orig_rd_active),
        .orig_rd_data    (orig_rd_data),
        .pred_valid      (pred_valid),
        .pred_ready      (pred_ready),
        .pred_pixel      (pred_pixel),
        .pred_x          (pred_x),
        .pred_y          (pred_y),
        .pred_last       (pred_last)
    );

    // Clock generation
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // Memory arrays for simulation
    logic [`PIXEL_WIDTH-1:0] orig_mem [0:4095]; // 64x64 max CTU
    logic [`PIXEL_WIDTH-1:0] ref_mem  [0:128];  // Max 4N+1 for N=32

    // Orig memory read response (1 cycle latency)
    logic [11:0] orig_rd_addr_q;
    logic        orig_rd_active_q;
    always_ff @(posedge clk) begin
        orig_rd_addr_q   <= orig_rd_addr;
        orig_rd_active_q <= orig_rd_active;
        if (orig_rd_active_q) begin
            orig_rd_data <= orig_mem[orig_rd_addr_q];
        end else begin
            orig_rd_data <= 'x;
        end
    end

    // Task to initialize memory with some pattern
    task automatic init_mem(input int size_log2);
        int N = 1 << size_log2;
        int i, x, y;
        // Init orig_mem with a gradient
        for (y = 0; y < N; y++) begin
            for (x = 0; x < N; x++) begin
                orig_mem[(cu_y + y) * 64 + (cu_x + x)] = (x + y) * 4;
            end
        end

        // Init ref_mem (4N+1 samples)
        // ref[0] = corner, ref[1..2N] = top, ref[2N+1..4N] = left
        for (i = 0; i <= 4*N; i++) begin
            ref_mem[i] = 100 + i; // Arbitrary pattern
        end
    endtask

    // Task to send reference samples
    task automatic send_refs(input int size_log2);
        int N = 1 << size_log2;
        int i = 0;
        ref_valid = 1;
        while (i <= 4*N) begin
            ref_sample = ref_mem[i];
            ref_idx = i;
            ref_last = (i == 4*N);
            
            @(posedge clk);
            if (ref_ready) begin
                i++;
            end
        end
        ref_valid = 0;
        ref_last = 0;
        ref_sample = 0;
        ref_idx = 0;
    endtask

    // Main Test Sequence
    initial begin
        // Initialize inputs
        rst_n           = 0;
        cu_x            = 0;
        cu_y            = 0;
        pu_size_log2    = 3; // 8x8
        is_luma         = 1;
        rmd_start       = 0;
        pred_start      = 0;
        pred_intra_mode = 0;
        ref_valid       = 0;
        ref_sample      = 0;
        ref_idx         = 0;
        ref_last        = 0;
        orig_rd_data    = 0;
        pred_ready      = 1;

        // Reset
        #20 rst_n = 1;
        #10;

        $display("==================================================");
        $display("Test 1: 8x8 Block - RMD Phase");
        $display("==================================================");
        init_mem(3); // 8x8

        // Start RMD
        @(posedge clk);
        rmd_start = 1;
        @(posedge clk);
        rmd_start = 0;

        // In parallel, send reference samples (simulate reconstruction unit)
        fork
            send_refs(3);
        join_none

        // Wait for RMD to complete
        @(posedge rmd_done);
        $display("RMD Done. Best Mode: %0d, Best Cost: %0d", rmd_best_mode, rmd_best_cost);
        #20;

        $display("==================================================");
        $display("Test 2: 8x8 Block - Prediction Phase (Planar)");
        $display("==================================================");
        
        // Start Prediction with best mode (or force planar: 0)
        @(posedge clk);
        pred_start = 1;
        pred_intra_mode = 0; // Planar
        @(posedge clk);
        pred_start = 0;

        // Send reference samples again
        fork
            send_refs(3);
        join_none

        // Wait for prediction to complete
        wait(pred_last && pred_valid && pred_ready);
        @(posedge clk);
        $display("Prediction Phase (Planar) Complete.");
        #20;
        
        $display("==================================================");
        $display("Test 3: 8x8 Block - Prediction Phase (Angular Mode 26 - Vertical)");
        $display("==================================================");
        
        // Start Prediction with Vertical mode (26)
        @(posedge clk);
        pred_start = 1;
        pred_intra_mode = 26; 
        @(posedge clk);
        pred_start = 0;

        // Send reference samples again
        fork
            send_refs(3);
        join_none

        // Wait for prediction to complete
        wait(pred_last && pred_valid && pred_ready);
        @(posedge clk);
        $display("Prediction Phase (Vertical) Complete.");

        #50;
        $display("Testbench finished.");
        $finish;
    end

endmodule
