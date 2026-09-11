`timescale 1ns / 1ps

module tb_mode_decision();

    //-------------------------------------------------------------------------
    // Signals
    //-------------------------------------------------------------------------
    reg         clk;
    reg         rst_n;

    // Interface with CTU Partitioner
    wire        split_valid;
    wire        split_flag;
    reg         split_ready;
    
    // Inputs from PU/CU Splitter
    reg         pu_valid;
    reg  [6:0]  pu_size;
    reg  [1:0]  pu_depth;
    reg  [1:0]  slice_type;
    reg  [5:0]  qp;
    
    // Cost inputs from Intra Prediction
    reg         intra_cost_valid;
    reg  [31:0] intra_rd_cost;
    reg  [5:0]  intra_best_mode;

    // Cost inputs from Inter Prediction
    reg         inter_cost_valid;
    reg  [31:0] inter_rd_cost;
    reg  [11:0] inter_best_mv_x;
    reg  [11:0] inter_best_mv_y;
    
    reg  [9:0]  poc;
    
    // Merge Candidates
    reg  [4:0]  merge_cand_valid;
    reg  [49:0] merge_cand_mv_x_flat;
    reg  [49:0] merge_cand_mv_y_flat;

    // Cost inputs from CABAC
    reg         rate_cost_valid;
    reg  [31:0] est_bit_rate;

    // Control to trigger engines
    wire        eval_intra_start;
    wire        eval_inter_start;
    
    // Final Decision Outputs
    wire        mode_valid;
    wire [31:0] best_rd_cost;
    wire        best_is_intra;
    wire [5:0]  best_intra_mode;
    wire [11:0] best_inter_mv_x;
    wire [11:0] best_inter_mv_y;
    wire        best_merge_flag;
    wire [2:0]  best_merge_idx;
    wire        best_skip_flag;

    //-------------------------------------------------------------------------
    // Device Under Test (DUT)
    //-------------------------------------------------------------------------
    mode_decision uut (
        .clk(clk),
        .rst_n(rst_n),
        .split_valid(split_valid),
        .split_flag(split_flag),
        .split_ready(split_ready),
        .pu_valid(pu_valid),
        .pu_size(pu_size),
        .pu_depth(pu_depth),
        .slice_type(slice_type),
        .qp(qp),
        .poc(poc),
        .intra_cost_valid(intra_cost_valid),
        .intra_rd_cost(intra_rd_cost),
        .intra_best_mode(intra_best_mode),
        .inter_cost_valid(inter_cost_valid),
        .inter_rd_cost(inter_rd_cost),
        .inter_best_mv_x(inter_best_mv_x),
        .inter_best_mv_y(inter_best_mv_y),
        .merge_cand_valid(merge_cand_valid),
        .merge_cand_mv_x_flat(merge_cand_mv_x_flat),
        .merge_cand_mv_y_flat(merge_cand_mv_y_flat),
        .rate_cost_valid(rate_cost_valid),
        .est_bit_rate(est_bit_rate),
        .eval_intra_start(eval_intra_start),
        .eval_inter_start(eval_inter_start),
        .mode_valid(mode_valid),
        .best_rd_cost(best_rd_cost),
        .best_is_intra(best_is_intra),
        .best_intra_mode(best_intra_mode),
        .best_inter_mv_x(best_inter_mv_x),
        .best_inter_mv_y(best_inter_mv_y),
        .best_merge_flag(best_merge_flag),
        .best_merge_idx(best_merge_idx),
        .best_skip_flag(best_skip_flag)
    );

    //-------------------------------------------------------------------------
    // Clock Generation
    //-------------------------------------------------------------------------
    always #5 clk = ~clk; // 100MHz clock

    //-------------------------------------------------------------------------
    // Mock Engines (Simulate Intra and Inter evaluation delays)
    //-------------------------------------------------------------------------
    reg [4:0] intra_delay_pipe = 0;
    reg [7:0] inter_delay_pipe = 0;

    always @(posedge clk) begin
        // Shift registers to simulate 5-cycle intra delay and 8-cycle inter delay
        intra_delay_pipe <= {intra_delay_pipe[3:0], eval_intra_start};
        intra_cost_valid <= intra_delay_pipe[4];
        
        inter_delay_pipe <= {inter_delay_pipe[6:0], eval_inter_start};
        inter_cost_valid <= inter_delay_pipe[7];
    end

    //-------------------------------------------------------------------------
    // Test Sequence
    //-------------------------------------------------------------------------
    initial begin
        // Initialize Inputs
        clk = 0;
        rst_n = 0;
        split_ready = 1'b1;
        pu_valid = 0;
        pu_size = 0;
        pu_depth = 0;
        slice_type = 0;
        qp = 32;
        poc = 0;
        intra_rd_cost = 0;
        intra_best_mode = 0;
        inter_rd_cost = 0;
        inter_best_mv_x = 0;
        inter_best_mv_y = 0;
        merge_cand_valid = 5'b00000;
        merge_cand_mv_x_flat = 50'd0;
        merge_cand_mv_y_flat = 50'd0;
        rate_cost_valid = 0;
        est_bit_rate = 0;

        // Reset
        #20 rst_n = 1;
        #10;

        $display("=== TEST 1: I-Slice 64x64 (Should Force Split due to High Cost) ===");
        // P-Slice = 1, B-Slice = 0, I-Slice = 2
        slice_type = 2; // I-Slice
        pu_size = 64;
        pu_depth = 0;   // 64x64 depth = 0
        
        // Mock a high RD cost
        intra_rd_cost = 300000; // Threshold is 250,000 for 64x64
        intra_best_mode = 6'd26; // Vertical
        
        @(posedge clk);
        pu_valid = 1;
        @(posedge clk);
        pu_valid = 0;

        // Wait for split decision
        wait(split_valid);
        @(posedge clk);
        if (split_flag == 1'b1)
            $display("PASS: I-Slice 64x64 Split successfully triggered. Cost: %0d", best_rd_cost);
        else
            $display("FAIL: I-Slice 64x64 did not split! Cost: %0d", best_rd_cost);

        #50;

        $display("=== TEST 2: P-Slice 32x32 (Inter cheaper than Intra, No Split) ===");
        slice_type = 1; // P-Slice
        pu_size = 32;
        pu_depth = 1;   // 32x32 depth = 1
        
        // Mock costs (Threshold is 60,000 for 32x32)
        intra_rd_cost = 70000;
        inter_rd_cost = 45000; // Inter wins, and is below threshold (No split)
        
        @(posedge clk);
        pu_valid = 1;
        @(posedge clk);
        pu_valid = 0;

        wait(split_valid);
        @(posedge clk);
        if (best_is_intra == 1'b0 && split_flag == 1'b0)
            $display("PASS: P-Slice 32x32 Inter won and early terminated (No split). Cost: %0d", best_rd_cost);
        else
            $display("FAIL: P-Slice 32x32 logic failed. Intra: %b, Split: %b", best_is_intra, split_flag);

        #50;
        
        $display("=== TEST 3: B-Slice 8x8 (Max depth MUST force leaf) ===");
        slice_type = 0; // B-Slice
        pu_size = 8;
        pu_depth = 3;   // 8x8 depth = 3
        
        // Mock costs (Extremely high cost)
        intra_rd_cost = 999999;
        inter_rd_cost = 888888;
        
        @(posedge clk);
        pu_valid = 1;
        @(posedge clk);
        pu_valid = 0;

        wait(split_valid);
        @(posedge clk);
        if (split_flag == 1'b0)
            $display("PASS: B-Slice 8x8 correctly forced leaf (split_flag=0) despite high cost.");
        else
            $display("FAIL: B-Slice 8x8 tried to split deeper than max depth!");

        #50;
        
        $display("=== TEST 4: P-Slice 16x16 (Merge Mode Wins, Skip Mode Triggered) ===");
        slice_type = 1; // P-Slice
        pu_size = 16;
        pu_depth = 2;   // 16x16 depth = 2
        qp = 32;
        
        // Mock AMVP costs (Threshold is 15,000 for 16x16)
        intra_rd_cost = 30000;
        inter_rd_cost = 25000; 
        inter_best_mv_x = 12'd40;
        inter_best_mv_y = 12'd20;

        // Mock Merge candidate: candidate 0 is valid and has MV very close to inter_best_mv
        // Candidate 0: mv_x = 10 (which is 10 << 2 = 40 qpel), mv_y = 5 (5 << 2 = 20 qpel)
        merge_cand_valid = 5'b00001;
        merge_cand_mv_x_flat = {40'd0, 10'sd10}; // index 0: 10
        merge_cand_mv_y_flat = {40'd0, 10'sd5};  // index 0: 5
        
        @(posedge clk);
        pu_valid = 1;
        @(posedge clk);
        pu_valid = 0;

        wait(split_valid);
        @(posedge clk);
        // Best cost with Merge = Inter Cost (25000) - rate delta (saving 9 bits * lambda)
        // With lambda=86 (QP=32), saving 9 bits is 9 * 86 = 774.
        // Therefore, merge cost = 25000 - 774 = 24226. Wait! In mode_decision.v:
        // latched_inter_cost = inter_rd_cost (25000) + lambda * 12 (1032) = 26032
        // best_merge_cost    = inter_rd_cost (25000) + lambda * 3 (258)   = 25258
        // Clearly, best_merge_cost < latched_inter_cost, so Merge wins!
        // Also, skip_threshold for QP=32 is 16.
        // Wait, best_skip_flag is set if best_merge_cost < skip_threshold?
        // Let's check skip_threshold in mode_decision.v:
        // skip_threshold = (cur_qp < 40) ? 16 ...
        // Wait, best_merge_cost (25258) is way larger than skip_threshold (16).
        // Let's modify QP or make the mock cost extremely low so skip triggers.
        // Let's set QP = 16 (lambda = 2, skip_threshold = 2)
        // Or keep QP = 32, but mock inter_rd_cost = 5 (very low distortion).
        // Then best_merge_cost = 5 + 86 * 3 = 263, still > 16.
        // Oh, wait! The lambda cost estimation is included in best_merge_cost.
        // So for skip to trigger, the total rate-distortion cost (including bits) must be low.
        // Let's make QP = 10 (lambda = 0, skip_threshold = 2).
        // If QP = 10, lambda = 0.
        // inter_rd_cost = 1 (very low distortion).
        // Then best_merge_cost = 1 + 0 = 1, which is < skip_threshold (2).
        // This will trigger skip_flag!
        qp = 10;
        inter_rd_cost = 1;
        intra_rd_cost = 50;

        @(posedge clk);
        pu_valid = 1;
        @(posedge clk);
        pu_valid = 0;

        wait(split_valid);
        @(posedge clk);
        if (best_merge_flag == 1'b1 && best_skip_flag == 1'b1 && split_flag == 1'b0)
            $display("PASS: P-Slice 16x16 Merge wins and skip_flag=1 triggered successfully. Cost: %0d", best_rd_cost);
        else
            $display("FAIL: P-Slice 16x16 Merge/Skip failed. Merge: %b, Skip: %b, Split: %b, Cost: %0d", best_merge_flag, best_skip_flag, split_flag, best_rd_cost);

        #50;
        $display("All tests completed.");
        $finish;
    end

endmodule
