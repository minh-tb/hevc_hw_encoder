//=============================================================================
// tb_pipeline_reg.sv
// Testbench for Generic Pipeline Register Stage
//=============================================================================

`timescale 1ns/1ps

module tb_pipeline_reg;

    parameter WIDTH = 8;

    logic clk;
    logic rst_n;
    logic en;
    logic [WIDTH-1:0] din;

    // DUT outputs for different configurations
    logic [WIDTH-1:0] dout_0; // STAGES = 0
    logic [WIDTH-1:0] dout_1; // STAGES = 1
    logic [WIDTH-1:0] dout_3; // STAGES = 3

    // Instantiate DUTs
    pipeline_reg #(.WIDTH(WIDTH), .STAGES(0)) dut0 (
        .clk(clk), .rst_n(rst_n), .en(en), .din(din), .dout(dout_0)
    );

    pipeline_reg #(.WIDTH(WIDTH), .STAGES(1)) dut1 (
        .clk(clk), .rst_n(rst_n), .en(en), .din(din), .dout(dout_1)
    );

    pipeline_reg #(.WIDTH(WIDTH), .STAGES(3)) dut3 (
        .clk(clk), .rst_n(rst_n), .en(en), .din(din), .dout(dout_3)
    );

    // Clock Generation
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    int errors = 0;

    initial begin
        // Initialize
        en = 0;
        din = 8'h00;
        rst_n = 0;

        repeat(2) @(posedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);

        $display("=== Starting pipeline_reg Testbench ===");

        // 1. Test STAGES = 0 (Combinational pass-through)
        din = 8'hAA;
        #1; // Combinational delay
        if (dout_0 !== 8'hAA) begin $display("ERROR: STAGES=0 failed pass-through. Expected AA, got %h", dout_0); errors++; end

        // 2. Test STAGES = 1
        en = 1;
        din = 8'hBB;
        @(posedge clk); #1;
        if (dout_1 !== 8'hBB) begin $display("ERROR: STAGES=1 failed to register data. Expected BB, got %h", dout_1); errors++; end

        // 3. Test STAGES = 3 (Shift register chain)
        en = 1;
        din = 8'h11; @(posedge clk);
        din = 8'h22; @(posedge clk);
        din = 8'h33; @(posedge clk);
        #1;
        if (dout_3 !== 8'h11) begin $display("ERROR: STAGES=3 failed to shift correctly. Expected 11, got %h", dout_3); errors++; end

        // 4. Test Stall (en = 0)
        en = 0;
        din = 8'h99; // Change input, pipeline should ignore it and hold state
        @(posedge clk); #1;
        if (dout_1 !== 8'h33) begin $display("ERROR: STAGES=1 failed stall. Expected 33, got %h", dout_1); errors++; end
        if (dout_3 !== 8'h11) begin $display("ERROR: STAGES=3 failed stall. Expected 11, got %h", dout_3); errors++; end

        // 5. Test Reset
        rst_n = 0;
        @(posedge clk); #1;
        if (dout_1 !== 8'h00 || dout_3 !== 8'h00) begin $display("ERROR: Reset failed."); errors++; end

        if (errors == 0) $display("=== [PASS] All pipeline_reg tests passed! ===");
        else             $display("=== [FAIL] %0d errors found ===", errors);
        $finish;
    end
endmodule
