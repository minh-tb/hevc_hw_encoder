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
        .intra_cost_valid(intra_cost_valid),
        .intra_rd_cost(intra_rd_cost),
        .intra_best_mode(intra_best_mode),
        .inter_cost_valid(inter_cost_valid),
        .inter_rd_cost(inter_rd_cost),
        .inter_best_mv_x(inter_best_mv_x),
        .inter_best_mv_y(inter_best_mv_y),
        .rate_cost_valid(rate_cost_valid),
        .est_bit_rate(est_bit_rate),
        .eval_intra_start(eval_intra_start),
        .eval_inter_start(eval_inter_start),
        .mode_valid(mode_valid),
        .best_rd_cost(best_rd_cost),
        .best_is_intra(best_is_intra),
        .best_intra_mode(best_intra_mode),
        .best_inter_mv_x(best_inter_mv_x),
        .best_inter_mv_y(best_inter_mv_y)
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
        intra_rd_cost = 0;
        intra_best_mode = 0;
        inter_rd_cost = 0;
        inter_best_mv_x = 0;
        inter_best_mv_y = 0;
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
        $display("All tests completed.");
        $finish;
    end

endmodule
