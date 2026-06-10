//=============================================================================
// tb_fifo_sync.sv
// Testbench for Synchronous FIFO
//=============================================================================

`timescale 1ns/1ps

module tb_fifo_sync;

    //-------------------------------------------------------------------------
    // Parameters
    //-------------------------------------------------------------------------
    localparam DATA_W = 16;
    localparam DEPTH  = 8;  // Small depth to easily test wrap-around & full
    localparam P_FULL = 6;  // Programmable full threshold
    localparam P_EMPTY= 2;  // Programmable empty threshold
    localparam ADDR_W = $clog2(DEPTH);

    //-------------------------------------------------------------------------
    // Signals
    //-------------------------------------------------------------------------
    logic clk;
    logic rst_n;

    int total_errors;

    // Signals for Standard FIFO (FWFT = 0)
    logic              wr_en_std;
    logic [DATA_W-1:0] din_std;
    logic              full_std;
    logic              prog_full_std;
    
    logic              rd_en_std;
    logic [DATA_W-1:0] dout_std;
    logic              empty_std;
    logic              prog_empty_std;
    logic [ADDR_W:0]   count_std;

    // Signals for FWFT FIFO (FWFT = 1)
    logic              wr_en_fwft;
    logic [DATA_W-1:0] din_fwft;
    logic              full_fwft;
    logic              prog_full_fwft;
    
    logic              rd_en_fwft;
    logic [DATA_W-1:0] dout_fwft;
    logic              empty_fwft;
    logic              prog_empty_fwft;
    logic [ADDR_W:0]   count_fwft;

    //-------------------------------------------------------------------------
    // Device Under Test (DUT) - Standard Mode
    //-------------------------------------------------------------------------
    fifo_sync #(
        .DATA_WIDTH(DATA_W),
        .DEPTH(DEPTH),
        .FWFT(0),
        .PROG_FULL_THRESH(P_FULL),
        .PROG_EMPTY_THRESH(P_EMPTY)
    ) dut_std (
        .clk       (clk),
        .rst_n     (rst_n),
        .wr_en     (wr_en_std),
        .din       (din_std),
        .full      (full_std),
        .prog_full (prog_full_std),
        .rd_en     (rd_en_std),
        .dout      (dout_std),
        .empty     (empty_std),
        .prog_empty(prog_empty_std),
        .count     (count_std)
    );

    //-------------------------------------------------------------------------
    // Device Under Test (DUT) - FWFT Mode
    //-------------------------------------------------------------------------
    fifo_sync #(
        .DATA_WIDTH(DATA_W),
        .DEPTH(DEPTH),
        .FWFT(1),
        .PROG_FULL_THRESH(P_FULL),
        .PROG_EMPTY_THRESH(P_EMPTY)
    ) dut_fwft (
        .clk       (clk),
        .rst_n     (rst_n),
        .wr_en     (wr_en_fwft),
        .din       (din_fwft),
        .full      (full_fwft),
        .prog_full (prog_full_fwft),
        .rd_en     (rd_en_fwft),
        .dout      (dout_fwft),
        .empty     (empty_fwft),
        .prog_empty(prog_empty_fwft),
        .count     (count_fwft)
    );

    //-------------------------------------------------------------------------
    // Clock Generation
    //-------------------------------------------------------------------------
    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100 MHz
    end

    //-------------------------------------------------------------------------
    // Helpers
    //-------------------------------------------------------------------------
    task automatic check_flags(string name, int expected_count, int actual_count, logic empty, logic full, logic p_empty, logic p_full);
        if (actual_count !== expected_count) begin
            $display("[FAIL] %s Count mismatch. Exp: %0d, Got: %0d", name, expected_count, actual_count);
            total_errors++;
        end
        if (empty !== (expected_count == 0)) begin
            $display("[FAIL] %s Empty flag incorrect. Count: %0d, Empty: %b", name, expected_count, empty);
            total_errors++;
        end
        if (full !== (expected_count == DEPTH)) begin
            $display("[FAIL] %s Full flag incorrect. Count: %0d, Full: %b", name, expected_count, full);
            total_errors++;
        end
        if (p_empty !== (expected_count <= P_EMPTY)) begin
            $display("[FAIL] %s Prog Empty flag incorrect. Count: %0d", name, expected_count);
            total_errors++;
        end
        if (p_full !== (expected_count >= P_FULL)) begin
            $display("[FAIL] %s Prog Full flag incorrect. Count: %0d", name, expected_count);
            total_errors++;
        end
    endtask

    //-------------------------------------------------------------------------
    // Main Test Stimulus
    //-------------------------------------------------------------------------
    initial begin
        int i;
        total_errors = 0;

        wr_en_std = 0; rd_en_std = 0; din_std = 0;
        wr_en_fwft= 0; rd_en_fwft= 0; din_fwft= 0;

        rst_n = 0;
        @(negedge clk);
        rst_n = 1;

        $display("\n==================================================");
        $display(" Starting FIFO Verification (DEPTH=%0d)", DEPTH);
        $display("==================================================");

        //---------------------------------------------------------------------
        // TEST 1: Fill to FULL boundary & check programmable thresholds
        //---------------------------------------------------------------------
        $display("--- TEST 1: Fill to FULL ---");
        for (i = 1; i <= DEPTH; i++) begin
            @(negedge clk);
            wr_en_std = 1; din_std = i;
            wr_en_fwft= 1; din_fwft= i;
        end
        @(negedge clk);
        wr_en_std = 0; wr_en_fwft = 0;
        
        check_flags("STD_FIFO ", DEPTH, count_std, empty_std, full_std, prog_empty_std, prog_full_std);
        check_flags("FWFT_FIFO", DEPTH, count_fwft, empty_fwft, full_fwft, prog_empty_fwft, prog_full_fwft);

        //---------------------------------------------------------------------
        // TEST 2: Read to EMPTY & check sequential data integrity
        //---------------------------------------------------------------------
        $display("--- TEST 2: Read to EMPTY ---");
        for (i = 1; i <= DEPTH; i++) begin
            @(negedge clk);
            // In FWFT, data is already combinatorially present before read
            if (dout_fwft !== i) begin
                $display("[FAIL] FWFT Data mismatch. Exp: %0d, Got: %0d", i, dout_fwft);
                total_errors++;
            end
            rd_en_std = 1;
            rd_en_fwft= 1;
            
            @(posedge clk); // sample standard out on next posedge equivalent (simulated by waiting for standard read latency)
            #1; 
            if (dout_std !== i) begin
                $display("[FAIL] STD Data mismatch. Exp: %0d, Got: %0d", i, dout_std);
                total_errors++;
            end
        end
        @(negedge clk);
        rd_en_std = 0; rd_en_fwft = 0;

        check_flags("STD_FIFO ", 0, count_std, empty_std, full_std, prog_empty_std, prog_full_std);
        check_flags("FWFT_FIFO", 0, count_fwft, empty_fwft, full_fwft, prog_empty_fwft, prog_full_fwft);

        //---------------------------------------------------------------------
        // TEST 3: Simultaneous Read / Write (Streaming) & Pointer Wrap-around
        //---------------------------------------------------------------------
        $display("--- TEST 3: Streaming & Pointer Wrap-around ---");
        // Half fill the FIFOs
        for (i = 1; i <= DEPTH/2; i++) begin
            @(negedge clk);
            wr_en_std = 1; din_std = 100+i;
            wr_en_fwft= 1; din_fwft= 100+i;
        end
        
        // Stream simultaneously for 3x DEPTH to force pointer wrapping multiple times
        for (i = 1; i <= DEPTH*3; i++) begin
            @(negedge clk);
            wr_en_std = 1; rd_en_std = 1; din_std = 200+i;
            wr_en_fwft= 1; rd_en_fwft= 1; din_fwft= 200+i;
            
            // Verify count stays perfectly stable while streaming
            if (count_std !== DEPTH/2) begin
                $display("[FAIL] STD Stream Count drift. Exp: %0d, Got: %0d", DEPTH/2, count_std);
                total_errors++;
            end
        end
        @(negedge clk);
        wr_en_std = 0; rd_en_std = 0;
        wr_en_fwft= 0; rd_en_fwft= 0;

        // Drain remainder
        for (i = 1; i <= DEPTH/2; i++) begin
            @(negedge clk);
            rd_en_std = 1; rd_en_fwft = 1;
        end
        @(negedge clk);
        rd_en_std = 0; rd_en_fwft = 0;
        
        check_flags("STD_FIFO ", 0, count_std, empty_std, full_std, prog_empty_std, prog_full_std);

        $display("==================================================");
        if (total_errors == 0) $display(" === ALL TESTS PASSED ===");
        else                   $display(" === TESTS FAILED: %0d Errors ===", total_errors);
        $display("==================================================\n");
        $finish;
    end

endmodule