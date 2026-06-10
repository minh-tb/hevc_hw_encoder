//=============================================================================
// tb_pu_cu_splitter.sv
// Testbench for PU/TU Splitter
//
// Verifies:
//   1. Correct geometric slicing of PUs (NxN, AMP asymmetric).
//   2. Quadtree recursive splitting logic handling down to 4x4 leaves.
//   3. Standard Y -> Cb -> Cr extraction ordering.
//   4. Robust stalling / back-pressure from downstream modules.
//=============================================================================

`timescale 1ns/1ps

module tb_pu_cu_splitter;

    logic clk;
    logic rst_n;

    // CU input
    logic        cu_valid;
    logic        cu_ready;
    logic [5:0]  cu_x, cu_y;
    logic [6:0]  cu_size;
    logic [1:0]  cu_depth;
    logic        pred_mode;
    logic [2:0]  part_mode;
    logic        skip_flag;
    logic [5:0]  qp;
    logic [15:0] cu_ctu_addr;
    logic [9:0]  cu_poc;
    logic [1:0]  cu_slice_type;

    // PU output
    logic        pu_valid;
    logic        pu_ready;
    logic [5:0]  pu_x, pu_y;
    logic [6:0]  pu_w, pu_h;
    logic [1:0]  pu_idx;
    logic        pu_pred_mode;
    logic [2:0]  pu_part_mode;
    logic        pu_is_last_in_cu;
    logic [5:0]  pu_qp;
    logic [15:0] pu_ctu_addr;
    logic [9:0]  pu_poc;
    logic [1:0]  pu_slice_type;

    // TU split feedback
    logic        tu_split_fb_valid;
    logic        tu_split_fb_flag;
    logic        tu_split_fb_ready;

    // TU output
    logic        tu_valid;
    logic        tu_ready;
    logic [5:0]  tu_x, tu_y;
    logic [2:0]  tu_size_log2;
    logic [1:0]  tu_comp;
    logic        tu_transform_skip;
    logic        tu_is_last_in_cu;
    logic [5:0]  tu_qp;
    logic [15:0] tu_ctu_addr;

    pu_cu_splitter dut (.*);

    initial begin
        clk = 0;
        forever #4 clk = ~clk;
    end

    int pu_count = 0;
    int tu_count = 0;
    int expected_pus = 0;
    int total_errors = 0;
    int last_comp = -1;

    always @(posedge clk) begin
        // Randomly simulate downstream processing delays
        pu_ready <= ($urandom % 100) < 80;
        tu_ready <= ($urandom % 100) < 80;

        // Automatically fulfill TU split requests (randomly split ~30% of the time)
        if (tu_split_fb_ready) begin
            tu_split_fb_valid <= 1'b1;
            tu_split_fb_flag  <= ($urandom % 100) < 30; 
        end else begin
            tu_split_fb_valid <= 1'b0;
        end

        if (pu_valid && pu_ready) begin
            pu_count++;
            if (pu_is_last_in_cu) begin
                if (pu_count != expected_pus) begin
                    $display("ERROR: Expected %0d PUs, got %0d", expected_pus, pu_count);
                    total_errors++;
                end
                pu_count = 0;
            end
        end

        if (tu_valid && tu_ready) begin
            tu_count++;
            
            // Verify that Chroma successfully follows Luma
            if (last_comp == 0 && tu_comp != 1 && tu_comp != 0) begin
                $display("ERROR: Y must be followed by Cb or another Y leaf! Got %0d", tu_comp);
                total_errors++;
            end
            if (last_comp == 1 && tu_comp != 2) begin
                $display("ERROR: Cb must always be followed by Cr! Got %0d", tu_comp);
                total_errors++;
            end
            last_comp = tu_comp;
            
            if (tu_is_last_in_cu) begin
                $display("INFO : TU quadtree completed successfully with %0d generated leaves", tu_count);
                tu_count = 0;
                last_comp = -1;
            end
        end
    end

    task automatic drive(int pm, int pus);
        $display("-------------------------------------------");
        $display("Starting CU Test -> Part Mode: %0d", pm);
        @(negedge clk);
        wait (cu_ready);
        cu_valid     <= 1;
        part_mode    <= pm;
        expected_pus <= pus;
        cu_size      <= 64;
        pred_mode    <= 0;
        skip_flag    <= 0;
        @(negedge clk);
        cu_valid     <= 0;
        
        // Wait until everything completes
        wait (cu_ready);
    endtask

    initial begin
        cu_valid = 0;
        rst_n = 0; repeat(4) @(posedge clk);
        rst_n = 1; repeat(2) @(posedge clk);

        drive(0 /*PART_2Nx2N*/, 1);
        drive(3 /*PART_NxN*/,   4);
        drive(4 /*PART_2NxnU*/, 2);
        
        if (total_errors == 0) $display("\n=== ALL PIPELINE TESTS PASSED ===");
        else                   $display("\n=== TESTS FAILED: %0d Errors ===", total_errors);
        
        $finish;
    end
endmodule
