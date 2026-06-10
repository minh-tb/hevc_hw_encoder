//=============================================================================
// tb_clk_gate.sv
// Testbench for Clock Gating Cell Wrapper
//=============================================================================

`timescale 1ns/1ps

module tb_clk_gate;

    // DUT Signals
    logic clk_in;
    logic enable;
    logic test_en;
    logic clk_out;

    // Instantiate the DUT
    clk_gate dut (
        .clk_in(clk_in),
        .enable(enable),
        .test_en(test_en),
        .clk_out(clk_out)
    );

    // Clock Generation
    initial begin
        clk_in = 0;
        forever #5 clk_in = ~clk_in;
    end

    int errors = 0;

    // Test Sequence
    initial begin
        // Initialize
        enable  = 0;
        test_en = 0;

        $display("=== Starting clk_gate Testbench ===");
        
        // 1. Test Clock Disabled
        $display("--- Test 1: Clock Disabled ---");
        @(negedge clk_in);
        #1;
        if (clk_out !== 1'b0) begin $display("ERROR: clk_out should be 0"); errors++; end
        @(posedge clk_in);
        #1;
        if (clk_out !== 1'b0) begin $display("ERROR: clk_out should be 0"); errors++; end

        // 2. Test Clock Enabled
        $display("--- Test 2: Clock Enabled ---");
        @(negedge clk_in);
        enable = 1;
        @(posedge clk_in);
        #1;
        if (clk_out !== 1'b1) begin $display("ERROR: clk_out should be 1"); errors++; end

        // 3. Test Test-Enable Override
        $display("--- Test 3: Test Enable Override ---");
        @(negedge clk_in);
        enable = 0;
        test_en = 1;
        @(posedge clk_in);
        #1;
        if (clk_out !== 1'b1) begin $display("ERROR: clk_out should be 1 due to test_en"); errors++; end

        // 4. Test Glitch Detection Warning
        $display("--- Test 4: Glitch Detection (Expect 1 WARN print below) ---");
        @(posedge clk_in);
        #2;
        enable = 1; // Toggle enable while clock is HIGH (should trigger warning in DUT)
        #5;

        if (errors == 0) $display("=== [PASS] All clk_gate tests passed! ===");
        else             $display("=== [FAIL] %0d errors found ===", errors);
        
        $finish;
    end
endmodule