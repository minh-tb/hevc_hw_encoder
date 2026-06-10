//=============================================================================
// tb_range_coder.sv
// Testbench for HEVC CABAC M-Coder Arithmetic Range Engine
//=============================================================================

`timescale 1ns/1ps

module tb_range_coder;

    // DUT Signals
    logic        clk;
    logic        rst_n;
    
    logic        coder_init;
    logic        bin_valid;
    logic        bin_value;
    logic [5:0]  bin_pstate;
    logic        bin_valmps;
    logic        bin_ready;
    logic        ep_valid;
    
    logic        trm_valid;
    logic        flush_valid;
    logic        flush_done;
    
    logic        byte_valid;
    logic [7:0]  byte_out;
    logic        byte_ready;
    logic        coder_busy;

    // Byte collection queue for verification
    logic [7:0]  out_bytes[$];

    // Instantiate the DUT
    range_coder dut (
        .clk(clk),
        .rst_n(rst_n),
        .coder_init(coder_init),
        .bin_valid(bin_valid),
        .bin_value(bin_value),
        .bin_pstate(bin_pstate),
        .bin_valmps(bin_valmps),
        .bin_ready(bin_ready),
        .ep_valid(ep_valid),
        .trm_valid(trm_valid),
        .flush_valid(flush_valid),
        .flush_done(flush_done),
        .byte_valid(byte_valid),
        .byte_out(byte_out),
        .byte_ready(byte_ready),
        .coder_busy(coder_busy)
    );

    // Clock Generation
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // Always accept output bytes and store them
    assign byte_ready = 1'b1;
    always_ff @(posedge clk) begin
        if (byte_valid && byte_ready) begin
            out_bytes.push_back(byte_out);
            $display("Time %0t: Emitted Byte 0x%02X", $time, byte_out);
        end
    end

    // Task to encode a regular bin
    task encode_bin(input logic val, input logic [5:0] ps, input logic mps);
        @(posedge clk iff bin_ready == 1'b1);
        bin_valid  <= 1'b1;
        bin_value  <= val;
        bin_pstate <= ps;
        bin_valmps <= mps;
        @(posedge clk);
        bin_valid  <= 1'b0;
    endtask

    // Task to encode an Equi-Probable (Bypass) bin
    task encode_ep(input logic val);
        @(posedge clk iff bin_ready == 1'b1);
        ep_valid <= 1'b1;
        bin_value <= val;
        @(posedge clk);
        ep_valid <= 1'b0;
    endtask

    // Task to encode a terminating bin
    task encode_trm(input logic val);
        @(posedge clk iff bin_ready == 1'b1);
        trm_valid <= 1'b1;
        bin_value <= val;
        @(posedge clk);
        trm_valid <= 1'b0;
    endtask

    // Test Sequence
    initial begin
        int fin, fout;
        int mode, bval, pstate, vmps, r;
        int exp_byte, got_byte;
        int match = 0, mismatch = 0;
        
        // 1. Reset
        rst_n <= 0; coder_init <= 0; bin_valid <= 0; ep_valid <= 0; trm_valid <= 0; flush_valid <= 0;
        repeat(5) @(posedge clk);
        rst_n <= 1;
        repeat(2) @(posedge clk);

        // 2. Initialize slice
        $display("=== Starting Range Coder FSM Test ===");
        coder_init <= 1; @(posedge clk); coder_init <= 0;

        // 3. Stream inputs from HM Golden Vectors
        fin = $fopen("cabac_in.dat", "r");
        if (!fin) begin $display("ERROR: Cannot open cabac_in.dat"); $finish; end
        
        while (!$feof(fin)) begin
            r = $fscanf(fin, "%d %d %d %d\n", mode, bval, pstate, vmps);
            if (r == 4) begin
                if (mode == 0) encode_bin(bval[0], pstate[5:0], vmps[0]);
                else if (mode == 1) encode_trm(bval[0]);
                else if (mode == 2) begin
                    @(posedge clk iff bin_ready == 1'b1);
                    flush_valid <= 1; @(posedge clk); flush_valid <= 0;
                    wait (flush_done);
                    repeat(2) @(posedge clk);
                end
                else if (mode == 3) encode_ep(bval[0]);
            end
        end
        $fclose(fin);

        // 4. Verify outputs against HM Golden Vectors
        fout = $fopen("cabac_out.dat", "r");
        if (!fout) begin $display("ERROR: Cannot open cabac_out.dat"); $finish; end
        
        $display("=== Verifying %0d Output Bytes ===", out_bytes.size());
        while (!$feof(fout)) begin
            r = $fscanf(fout, "%x\n", exp_byte);
            if (r == 1) begin
                if (out_bytes.size() == 0) begin
                    $display("ERROR: Missing byte. Expected 0x%02X", exp_byte);
                    mismatch++;
                end else begin
                    got_byte = out_bytes.pop_front();
                    if (got_byte !== exp_byte) begin
                        if (mismatch < 20) $display("Mismatch: Exp=0x%02X, Got=0x%02X", exp_byte, got_byte);
                        mismatch++;
                    end else begin
                        match++;
                    end
                end
            end
        end
        $fclose(fout);

        if (out_bytes.size() > 0) begin
            $display("ERROR: Extra %0d bytes emitted by RTL", out_bytes.size());
            mismatch += out_bytes.size();
        end

        if (mismatch == 0) $display("[PASS] Range Coder matches HM exactly! (%0d matches)", match);
        else               $display("[FAIL] %0d mismatches found.", mismatch);
        $finish;
    end
endmodule