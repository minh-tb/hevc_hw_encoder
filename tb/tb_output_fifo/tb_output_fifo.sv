//=============================================================================
// tb_output_fifo.sv
// Testbench for Bitstream Output FIFO
//=============================================================================

`timescale 1ns/1ps

module tb_output_fifo;

    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
    logic         clk;
    logic         rst_n;

    logic         wr_valid;
    logic         wr_ready;
    logic [7:0]   wr_byte;
    logic         wr_last_in_au;

    logic         rd_valid;
    logic         rd_ready;
    logic [7:0]   rd_byte;
    logic         rd_last_in_au;

    logic         empty;
    logic         full;
    logic [12:0]  count;
    logic         wr_overflow;
    logic [31:0]  total_bytes;

    // -------------------------------------------------------------------------
    // DUT Instantiation
    // -------------------------------------------------------------------------
    output_fifo dut (
        .clk(clk),
        .rst_n(rst_n),
        .wr_valid(wr_valid),
        .wr_ready(wr_ready),
        .wr_byte(wr_byte),
        .wr_last_in_au(wr_last_in_au),
        .rd_valid(rd_valid),
        .rd_ready(rd_ready),
        .rd_byte(rd_byte),
        .rd_last_in_au(rd_last_in_au),
        .empty(empty),
        .full(full),
        .count(count),
        .wr_overflow(wr_overflow),
        .total_bytes(total_bytes)
    );

    // -------------------------------------------------------------------------
    // Clock Generation
    // -------------------------------------------------------------------------
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // -------------------------------------------------------------------------
    // Tasks
    // -------------------------------------------------------------------------
    task write_byte(input bit [7:0] b, input bit last);
        #1;
        wr_valid      = 1'b1;
        wr_byte       = b;
        wr_last_in_au = last;
        wait(wr_valid && wr_ready);
        @(posedge clk);
        #1;
        wr_valid      = 1'b0;
        wr_last_in_au = 1'b0;
    endtask

    task read_byte(output logic [7:0] b, output logic last);
        #1;
        rd_ready = 1'b1;
        wait(rd_valid && rd_ready);
        b    = rd_byte;
        last = rd_last_in_au;
        @(posedge clk);
        #1;
        rd_ready = 1'b0;
    endtask

    // -------------------------------------------------------------------------
    // Test Sequence
    // -------------------------------------------------------------------------
    int errors = 0;

    initial begin
        // Initialization
        rst_n = 0;
        wr_valid = 0;
        wr_byte = 0;
        wr_last_in_au = 0;
        rd_ready = 0;

        #20;
        rst_n = 1;
        @(posedge clk);

        $display("=== Starting output_fifo Testbench ===");

        // 1. Basic FWFT & Flag verification
        $display("--- Test 1: Single Write/Read (FWFT Check) ---");
        write_byte(8'hAB, 1'b1);
        
        #1;
        if (empty || !rd_valid || count !== 1) begin $display("ERROR: DUT should not be empty. count=%0d", count); errors++; end
        
        begin
            logic [7:0] r_b; logic r_l;
            read_byte(r_b, r_l);
            if (r_b !== 8'hAB || r_l !== 1'b1) begin $display("ERROR: Read mismatch. Exp: AB,1. Got: %02x,%b", r_b, r_l); errors++; end
        end

        // 2. Saturation and Backpressure logic 
        $display("--- Test 2: Fill FIFO (4096 bytes) ---");
        for (int i = 0; i < 4096; i++) write_byte(i[7:0], (i == 4095)); // Only last byte gets the AU flag

        #1;
        if (!full || wr_ready) begin $display("ERROR: FIFO should be fully saturated! count=%0d", count); errors++; end

        // 3. Overflow assertion 
        $display("--- Test 3: Trigger Overflow (Expect 1 ERROR print below from DUT) ---");
        #1; wr_valid = 1'b1; wr_byte = 8'hFF;
        @(posedge clk); #1; wr_valid = 1'b0; // Clock it in (it should be rejected)
        
        if (!wr_overflow) begin $display("ERROR: wr_overflow should be asserted!"); errors++; end
        if (total_bytes !== 4097) begin $display("ERROR: total_bytes counted dropped payload!"); errors++; end

        // 4. Data integrity verification 
        $display("--- Test 4: Drain FIFO and Verify Constraints ---");
        for (int i = 0; i < 4096; i++) begin
            logic [7:0] r_b; logic r_l;
            read_byte(r_b, r_l);
            if (r_b !== i[7:0]) begin $display("ERROR: Drain mismatch at index %0d", i); errors++; break; end
            if (i == 4095 && !r_l) begin $display("ERROR: Expected last_in_au flag at index 4095!"); errors++; end
        end

        if (errors == 0) $display("=== [PASS] All output_fifo tests passed! ===");
        else             $display("=== [FAIL] %0d errors found ===", errors);
        $finish;
    end
endmodule