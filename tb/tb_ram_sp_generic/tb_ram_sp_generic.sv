//=============================================================================
// tb_ram_sp_generic.sv
// Testbench for Single-Port SRAM Generic Wrapper
//=============================================================================

`timescale 1ns/1ps

module tb_ram_sp_generic;

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    parameter DATA_WIDTH = 32;
    parameter DEPTH      = 16;
    parameter ADDR_WIDTH = 4;
    parameter INIT_VAL   = 32'hDEADBEEF;

    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
    logic clk;
    
    // Signals for DUT 0 (Combinational Read, Latency = 0)
    logic                  en0, we0;
    logic [ADDR_WIDTH-1:0] addr0;
    logic [DATA_WIDTH-1:0] din0;
    logic [DATA_WIDTH-1:0] dout0;

    // Signals for DUT 1 (Registered Read, Latency = 1)
    logic                  en1, we1;
    logic [ADDR_WIDTH-1:0] addr1;
    logic [DATA_WIDTH-1:0] din1;
    logic [DATA_WIDTH-1:0] dout1;

    // -------------------------------------------------------------------------
    // Instantiations
    // -------------------------------------------------------------------------
    // DUT 0: Combinational Read
    ram_sp_generic #(
        .DATA_WIDTH(DATA_WIDTH), 
        .DEPTH(DEPTH), 
        .ADDR_WIDTH(ADDR_WIDTH),
        .READ_LATENCY(0), 
        .INIT_VAL(INIT_VAL)
    ) dut_comb (
        .clk(clk), .en(en0), .we(we0), .addr(addr0), .din(din0), .dout(dout0)
    );

    // DUT 1: Registered Read (Typical BRAM behavior)
    ram_sp_generic #(
        .DATA_WIDTH(DATA_WIDTH), 
        .DEPTH(DEPTH), 
        .ADDR_WIDTH(ADDR_WIDTH),
        .READ_LATENCY(1), 
        .INIT_VAL(INIT_VAL)
    ) dut_reg (
        .clk(clk), .en(en1), .we(we1), .addr(addr1), .din(din1), .dout(dout1)
    );

    // -------------------------------------------------------------------------
    // Clock Generation
    // -------------------------------------------------------------------------
    initial begin 
        clk = 0; 
        forever #5 clk = ~clk; 
    end

    // -------------------------------------------------------------------------
    // Test Sequence
    // -------------------------------------------------------------------------
    int errors = 0;

    initial begin
        // Setup initial states
        en0 = 0; we0 = 0; addr0 = 0; din0 = 0;
        en1 = 0; we1 = 0; addr1 = 0; din1 = 0;
        
        repeat(2) @(posedge clk);
        $display("=== Starting ram_sp_generic Testbench ===");

        // 1. Check Initialization
        $display("--- Test 1: Check Initialization Values ---");
        addr0 = 2; en0 = 1; we0 = 0;
        addr1 = 2; en1 = 1; we1 = 0;
        #1; // Combinational read (DUT0) resolves immediately after address changes
        if (dout0 !== INIT_VAL) begin $display("FAIL: DUT0 Init val %x != %x", dout0, INIT_VAL); errors++; end
        
        @(posedge clk); #1; // Registered read (DUT1) resolves after clock edge
        if (dout1 !== INIT_VAL) begin $display("FAIL: DUT1 Init val %x != %x", dout1, INIT_VAL); errors++; end

        // 2. Write Data to entire depth
        $display("--- Test 2: Write Data ---");
        for (int i = 0; i < DEPTH; i++) begin
            addr0 = i; din0 = 32'h1000 + i; en0 = 1; we0 = 1;
            addr1 = i; din1 = 32'h2000 + i; en1 = 1; we1 = 1;
            @(posedge clk);
        end
        en0 = 0; we0 = 0; en1 = 0; we1 = 0;
        @(posedge clk);

        // 3. Read Data back and verify
        $display("--- Test 3: Read and Verify Data ---");
        for (int i = 0; i < DEPTH; i++) begin
            addr0 = i; en0 = 1; we0 = 0;
            addr1 = i; en1 = 1; we1 = 0;
            #1; 
            if (dout0 !== (32'h1000 + i)) begin $display("FAIL: DUT0 Read addr %0d: %x", i, dout0); errors++; end
            @(posedge clk); #1; 
            if (dout1 !== (32'h2000 + i)) begin $display("FAIL: DUT1 Read addr %0d: %x", i, dout1); errors++; end
        end

        // 4. Simultaneous Read/Write (Verify Read-First behavior on Registered SRAM)
        $display("--- Test 4: Simultaneous Read/Write (Read-First Check) ---");
        addr1 = 5; din1 = 32'h9999_9999; en1 = 1; we1 = 1;
        @(posedge clk); #1;
        // On a read-first memory, writing while reading the same address gives the OLD data out
        if (dout1 !== (32'h2000 + 5)) begin $display("FAIL: DUT1 Read-First behavior mismatch. Got %x", dout1); errors++; end
        
        addr1 = 5; en1 = 1; we1 = 0; // Turn off write to verify the memory actually updated
        @(posedge clk); #1;
        if (dout1 !== 32'h9999_9999) begin $display("FAIL: DUT1 Data not updated correctly. Got %x", dout1); errors++; end

        // 5. Out of bounds check (Verify the translation-off error $displays)
        $display("--- Test 5: Out of Bounds Check (Expect 2 ERROR prints below) ---");
        addr0 = DEPTH + 1; en0 = 1; we0 = 0;
        addr1 = DEPTH + 2; en1 = 1; we1 = 1;
        @(posedge clk);
        $display("---------------------------------------------------------------");

        if (errors == 0) $display("=== [PASS] All ram_sp_generic tests passed! ===");
        else             $display("=== [FAIL] %0d errors found ===", errors);
        $finish;
    end
endmodule