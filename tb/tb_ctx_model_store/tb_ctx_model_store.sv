//=============================================================================
// tb_ctx_model_store.sv
// Testbench for HEVC CABAC Context Model Store
//=============================================================================

`timescale 1ns/1ps

module tb_ctx_model_store;

    // Parameters
    parameter N_CTX    = 154;
    parameter CTX_W    = 7;
    parameter CTX_ID_W = 8;

    // DUT Signals
    logic                  clk;
    logic                  rst_n;
    
    logic                  slice_init;
    logic [1:0]            slice_type;
    logic [6:0]            qp_in;
    
    logic [CTX_ID_W-1:0]   rd_ctx_id;
    logic [CTX_W-1:0]      rd_state;
    
    logic                  upd_valid;
    logic [CTX_ID_W-1:0]   upd_ctx_id;
    logic                  upd_bin;
    
    logic                  init_busy;

    // Instantiate the DUT
    ctx_model_store #(
        .N_CTX(N_CTX),
        .CTX_W(CTX_W),
        .CTX_ID_W(CTX_ID_W)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .slice_init(slice_init),
        .slice_type(slice_type),
        .qp_in(qp_in),
        .rd_ctx_id(rd_ctx_id),
        .rd_state(rd_state),
        .upd_valid(upd_valid),
        .upd_ctx_id(upd_ctx_id),
        .upd_bin(upd_bin),
        .init_busy(init_busy)
    );

    // Clock Generation
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // Test Sequence
    initial begin
        // 1. Apply Reset
        rst_n = 0;
        slice_init = 0;
        slice_type = 0;
        qp_in = 0;
        rd_ctx_id = 0;
        upd_valid = 0;
        upd_ctx_id = 0;
        upd_bin = 0;
        
        repeat(5) @(posedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);

        // 2. Trigger Slice Initialization (I-Slice, QP = 32)
        $display("=== Starting Context Initialization (I-Slice, QP=32) ===");
        slice_init = 1;
        slice_type = 2'd0; // 0 = I-Slice
        qp_in      = 7'd32;
        @(posedge clk);
        slice_init = 0;

        // Wait for initialization to complete (should take 154 cycles)
        @(posedge clk); // Advance one cycle so init_busy propagates to 1
        while (init_busy) @(posedge clk); // Wait for it to return to 0
        $display("=== Initialization Complete ===");

        // 3. Test Read: Context 0 (SPLIT_CODING_UNIT_FLAG)
        // Mathematical Expected Initial State for I-Slice, Ctx=0, QP=32:
        // iv = 107. slope = (6*5)-45 = -15. offs = (11<<3)-16 = 72.
        // tmp = ((-15 * 32) >> 4) + 72 = -30 + 72 = 42.
        // State = (63 - 42) << 1 | 0 = 21 << 1 | 0 = 42.
        rd_ctx_id = 8'd0;
        #1; // wait for combinational read
        $display("Read Ctx 0 State: Expected=42, Got=%0d", rd_state);
        if (rd_state !== 7'd42) $display("ERROR: Initialization mismatch!");

        // 4. Test Update: Code an MPS (Most Probable Symbol)
        // Since valMPS (bit 0) is 0, coding a 0 is the MPS path.
        // Expected transition: pStateIdx 21 -> 22. New state = (22 << 1) | 0 = 44.
        @(posedge clk);
        upd_valid  = 1;
        upd_ctx_id = 8'd0;
        upd_bin    = 1'b0; // MPS
        @(posedge clk);
        upd_valid  = 0;
        #1;
        $display("After MPS Update: Expected=44, Got=%0d", rd_state);
        if (rd_state !== 7'd44) $display("ERROR: MPS transition mismatch!");

        // 5. Finish Test
        repeat(5) @(posedge clk);
        $display("=== CABAC Context Store Testbench Finished ===");
        $finish;
    end
endmodule