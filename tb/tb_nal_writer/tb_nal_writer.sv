//=============================================================================
// tb_nal_writer.sv
// Testbench for NAL Unit Framer
//=============================================================================
//
`timescale 1ns/1ps

module tb_nal_writer;

    logic        clk;
    logic        rst_n;
    logic        nal_start;
    logic [5:0]  nal_type;
    logic [2:0]  temporal_id;
    logic        nal_end;

    logic        rbsp_valid;
    logic        rbsp_ready;
    logic [7:0]  rbsp_byte;
    logic        rbsp_last;

    logic        out_valid;
    logic        out_ready;
    logic [7:0]  out_byte;
    logic        out_last_in_nal;

    logic [31:0] nal_byte_count;
    logic [31:0] total_nal_count;

    nal_writer dut(.*);

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // Queue to capture output stream
    logic [7:0] out_stream [$];

    always @(posedge clk) begin
        if (out_valid && out_ready) begin
            out_stream.push_back(out_byte);
        end
    end

    task write_rbsp(input logic [7:0] data [], input logic [5:0] ntype, input logic [2:0] tid);
        out_stream.delete();
       
        @(posedge clk); #1;
        nal_start   = 1'b1;
        nal_type    = ntype;
        temporal_id = tid;
        @(posedge clk); #1;
        nal_start   = 1'b0;
        
        for (int i = 0; i < data.size(); i++) begin
            rbsp_valid = 1'b1;
            rbsp_byte  = data[i];
            rbsp_last  = (i == data.size() - 1);
            wait(rbsp_ready);
            @(posedge clk); #1;
        end
        rbsp_valid = 1'b0;
        rbsp_last  = 1'b0;
        
        // Wait for FSM to complete
        while (dut.state !== 0) @(posedge clk);
        #10;
    endtask

    int errors = 0;

    initial begin
        rst_n = 0; nal_start = 0; nal_type = 0; temporal_id = 0; nal_end = 0;
        rbsp_valid = 0; rbsp_byte = 0; rbsp_last = 0; out_ready = 1;

        #20 rst_n = 1;
        $display("=== Starting nal_writer Testbench ===");

        // Test 1: Simple payload, check header and start code
        $display("--- Test 1: Header Check (VPS) ---");
        // nal_type = 32 (VPS), tid = 0
        // Header should be: {1'b0, 6'd32, 6'd0, 3'd1} = {0, 100000, 000000, 001} = 0x4001
        write_rbsp('{8'hAA, 8'hBB, 8'hCC}, 6'd32, 3'd0);
        
        if (out_stream.size() != 9) begin $display("ERROR: Test 1 output size mismatch."); errors++; end 
        else begin
            if ({out_stream[0], out_stream[1], out_stream[2], out_stream[3]} !== 32'h00000001) begin $display("ERROR: Start code wrong."); errors++; end
            if ({out_stream[4], out_stream[5]} !== 16'h4001) begin $display("ERROR: NAL header wrong. Expected 4001, got %02x%02x", out_stream[4], out_stream[5]); errors++; end
        end

        // Test 2: Emulation Prevention Insertion
        $display("--- Test 2: Emulation Prevention (Expect 0x03 insertion) ---");
         write_rbsp('{8'h00, 8'h00, 8'h00, 8'h01, 8'h02, 8'h03}, 6'd1, 3'd0);
        if (out_stream[8] !== 8'h03) begin $display("ERROR: EPB 03 not inserted correctly."); errors++; end

        if (errors == 0) $display("=== [PASS] All nal_writer tests passed! ===");
        else             $display("=== [FAIL] %0d errors found ===", errors);
        $finish;
    end
endmodule
