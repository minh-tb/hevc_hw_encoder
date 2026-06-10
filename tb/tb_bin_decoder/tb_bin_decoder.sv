//=============================================================================
// tb_bin_decoder.sv
// Testbench for HEVC CABAC Arithmetic Range Decoder
//=============================================================================

`timescale 1ns/1ps

module tb_bin_decoder;

    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
    logic        clk;
    logic        rst_n;

    logic        coder_init;
    logic [7:0]  rd_ctx_id;
    logic [6:0]  rd_state;

    logic        upd_valid;
    logic [7:0]  upd_ctx_id;
    logic        upd_bin;

    logic        byte_valid;
    logic [7:0]  byte_in;
    logic        byte_ready;

    logic        dec_req;
    logic [7:0]  dec_ctx_id;
    logic        is_ep;
    logic        is_trm;
    logic        dec_ready;

    logic        dec_valid;
    logic        dec_bin;

    // -------------------------------------------------------------------------
    // DUT Instantiation
    // -------------------------------------------------------------------------
    bin_decoder #(
        .CTX_ID_W(8),
        .BIT_BUF_W(16)
    ) dut (
        .*
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
    task send_byte(input logic [7:0] b);
        #1;
        byte_valid = 1'b1;
        byte_in    = b;
        wait(byte_ready);
        @(posedge clk);
        #1;
        byte_valid = 1'b0;
    endtask

    task decode_ep(output logic bin_out);
        is_ep      = 1'b1;
        is_trm     = 1'b0;
        dec_ctx_id = 0;
        
        // Align to clock and wait for DUT to be ready
        while (!dec_ready) @(posedge clk);
        
        #1;
        dec_req    = 1'b1;
        
        // Pulse request for exactly 1 cycle to prevent multi-cycle decode
        @(posedge clk);
        #1;
        dec_req = 1'b0;
        is_ep   = 1'b0;
        
        // Wait for DUT to assert valid response
        while (!dec_valid) @(posedge clk);
        bin_out = dec_bin;
    endtask

    // -------------------------------------------------------------------------
    // Main Test Sequence
    // -------------------------------------------------------------------------
    int errors = 0;

    initial begin
        // Initialization
        rst_n = 0; coder_init = 0; rd_state = 0;
        byte_valid = 0; byte_in = 0;
        dec_req = 0; is_ep = 0; is_trm = 0; dec_ctx_id = 0;

        #20 rst_n = 1;
        @(posedge clk);

        $display("=== Starting bin_decoder Testbench ===");

        // 1. Send test byte stream in the background
        // HEVC streams are MSB first. 
        // 0xAB = 10101011, 0xCD = 11001101, 0xEF = 11101111
        fork
            begin
                send_byte(8'hAB);
                send_byte(8'hCD);
                send_byte(8'hEF);
            end
        join_none

        // 2. Trigger Decoder CABAC Initialization
        $display("--- Test 1: CABAC Initialization ---");
        #1; coder_init = 1'b1;
        @(posedge clk);
        #1; coder_init = 1'b0;

        // Wait for the 9-bit codIValue init to complete
        wait(dec_ready);
        $display("INFO: Decoder Initialized. 9-bit value populated successfully.");

        // 3. Request EP Bins (Bypass mode)
        $display("--- Test 2: EP Bin Decoding ---");
        begin
            logic b;
            
            // Expected bits based on the bitstream mathematical extraction
            decode_ep(b); if (b !== 1'b1) begin $display("ERROR: Bin 1 Exp: 1, Got: %b", b); errors++; end
            decode_ep(b); if (b !== 1'b0) begin $display("ERROR: Bin 2 Exp: 0, Got: %b", b); errors++; end
            decode_ep(b); if (b !== 1'b1) begin $display("ERROR: Bin 3 Exp: 1, Got: %b", b); errors++; end
            decode_ep(b); if (b !== 1'b0) begin $display("ERROR: Bin 4 Exp: 0, Got: %b", b); errors++; end
        end

        if (errors == 0) $display("=== [PASS] All bin_decoder tests passed! ===");
        else             $display("=== [FAIL] %0d errors found ===", errors);
        
        $finish;
    end

endmodule