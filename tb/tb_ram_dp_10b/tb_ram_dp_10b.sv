//=============================================================================
// tb_ram_dp_10b.sv
// Testbench for Dual-Port 10-bit SRAM
//=============================================================================

`timescale 1ns/1ps

module tb_ram_dp_10b;

    //-------------------------------------------------------------------------
    // Parameters
    //-------------------------------------------------------------------------
    localparam DATA_W = 10;
    localparam ADDR_W = 4;
    localparam DEPTH  = 16;

    //-------------------------------------------------------------------------
    // Signals
    //-------------------------------------------------------------------------
    logic clk;

    // Port A
    logic              en_a, we_a;
    logic [ADDR_W-1:0] addr_a;
    logic [DATA_W-1:0] din_a;
    logic [DATA_W-1:0] dout_a;

    // Port B
    logic              en_b, we_b;
    logic [ADDR_W-1:0] addr_b;
    logic [DATA_W-1:0] din_b;
    logic [DATA_W-1:0] dout_b;

    int total_errors;

    //-------------------------------------------------------------------------
    // Device Under Test (DUT)
    //-------------------------------------------------------------------------
    ram_dp_10b #(
        .DATA_WIDTH(DATA_W),
        .ADDR_WIDTH(ADDR_W),
        .DEPTH(DEPTH)
    ) dut (
        .clk_a (clk), .en_a(en_a), .we_a(we_a), .addr_a(addr_a), .din_a(din_a), .dout_a(dout_a),
        .clk_b (clk), .en_b(en_b), .we_b(we_b), .addr_b(addr_b), .din_b(din_b), .dout_b(dout_b)
    );

    //-------------------------------------------------------------------------
    // Clock Generation
    //-------------------------------------------------------------------------
    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100 MHz
    end

    //-------------------------------------------------------------------------
    // Main Test Stimulus
    //-------------------------------------------------------------------------
    initial begin
        total_errors = 0;
        en_a = 0; we_a = 0; addr_a = 0; din_a = 0;
        en_b = 0; we_b = 0; addr_b = 0; din_b = 0;

        @(negedge clk);

        $display("\n==================================================");
        $display(" Starting RAM_DP_10B Verification");
        $display("==================================================");

        //---------------------------------------------------------------------
        // TEST 1: Port A Write-First Behavior
        //---------------------------------------------------------------------
        $display("--- TEST 1: Port A Write-First Behavior ---");
        en_a = 1; we_a = 1; addr_a = 4'h5; din_a = 10'h155;
        @(negedge clk);
        we_a = 0; // stop writing
        if (dout_a !== 10'h155) begin
            $display("[FAIL] Port A write-first mismatch. Exp: 155, Got: %0h", dout_a);
            total_errors++;
        end

        //---------------------------------------------------------------------
        // TEST 2: Port B Read-First Behavior
        //---------------------------------------------------------------------
        $display("--- TEST 2: Port B Read-First Behavior ---");
        // Overwrite the same address on Port B. We expect the OLD data (155) first!
        en_b = 1; we_b = 1; addr_b = 4'h5; din_b = 10'h2AA;
        @(negedge clk);
        we_b = 0;
        if (dout_b !== 10'h155) begin 
            $display("[FAIL] Port B read-first mismatch (old data). Exp: 155, Got: %0h", dout_b);
            total_errors++;
        end
        @(negedge clk);
        if (dout_b !== 10'h2AA) begin // Should see new data on the NEXT read
            $display("[FAIL] Port B read-first mismatch (new data). Exp: 2AA, Got: %0h", dout_b);
            total_errors++;
        end

        //---------------------------------------------------------------------
        // TEST 3: Collision Warning Generation
        //---------------------------------------------------------------------
        $display("--- TEST 3: Collision Warning Generation (Check Console) ---");
        en_a = 1; we_a = 1; addr_a = 4'h7; din_a = 10'h333;
        en_b = 1; we_b = 1; addr_b = 4'h7; din_b = 10'h444; // Simultaneous write to same address!
        @(negedge clk);
        en_a = 0; we_a = 0; en_b = 0; we_b = 0;

        $display("==================================================");
        if (total_errors == 0) $display(" === ALL TESTS PASSED ===");
        else                   $display(" === TESTS FAILED: %0d Errors ===", total_errors);
        $display("==================================================\n");
        $finish;
    end
endmodule