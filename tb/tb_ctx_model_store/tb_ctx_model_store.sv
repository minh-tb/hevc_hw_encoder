//=============================================================================
// tb_ctx_model_store.sv
// Testbench for HEVC CABAC Context Model Store
//=============================================================================

`timescale 1ns/1ps

module tb_ctx_model_store;

    // Parameters
    parameter N_CTX    = 186;
    parameter CTX_W    = 7;
    parameter CTX_ID_W = 8;

    // Test tracking
    integer init_cycles;
    integer fail_cnt;

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
        fail_cnt   = 0;
        init_cycles = 0;
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

        // 2. Trigger Slice Initialization (Normative I-Slice = 2'd2 per Table 7-23, QP = 32)
        $display("=== Starting Context Initialization (I-Slice=2, QP=32) ===");
        slice_init = 1;
        slice_type = 2'd2; // 2 = I-Slice (normative HEVC Table 7-23: 0=B, 1=P, 2=I)
        qp_in      = 7'd32;
        @(posedge clk);
        slice_init = 0;

        // Count init_busy cycles (must equal N_CTX = 186)
        init_cycles = 0;
        #1;
        while (init_busy && init_cycles < 500) begin
            init_cycles = init_cycles + 1;
            @(posedge clk);
            #1;
        end
        $display("I-Slice Init Cycles: Expected=%0d, Got=%0d", N_CTX, init_cycles);
        if (init_cycles !== N_CTX) begin
            $display("ERROR: init_busy cycle count mismatch! Expected %0d, Got %0d", N_CTX, init_cycles);
            fail_cnt = fail_cnt + 1;
        end
        $display("=== Initialization Complete ===");

        // 3. Test Read & Update: Context 0 (SPLIT_CODING_UNIT_FLAG, iv_I = 139)
        // slope = (8*5)-45 = -5. offs = (11<<3)-16 = 72.
        // tmp = ((-5 * 32) >>> 4) + 72 = -10 + 72 = 62 -> state = (63-62)<<1 | 0 = 2.
        rd_ctx_id = 8'd0;
        #1;
        $display("Read I-Slice Ctx 0: Expected=2, Got=%0d", rd_state);
        if (rd_state !== 7'd2) begin
            $display("ERROR: I-Slice Ctx 0 init mismatch!");
            fail_cnt = fail_cnt + 1;
        end
        @(posedge clk);
        upd_valid  = 1;
        upd_ctx_id = 8'd0;
        upd_bin    = 1'b0; // MPS (pStateIdx 1 -> 2, valMPS=0 => 4)
        @(posedge clk);
        upd_valid  = 0;
        #1;
        $display("After I-Slice Ctx 0 MPS Update: Expected=4, Got=%0d", rd_state);
        if (rd_state !== 7'd4) begin
            $display("ERROR: I-Slice Ctx 0 MPS transition mismatch!");
            fail_cnt = fail_cnt + 1;
        end

        // 4. Test Read & Update: Context 181 (SAO_MERGE_FLAG, iv_I = 153)
        // slope = (9*5)-45 = 0. offs = (9<<3)-16 = 56.
        // tmp = 56 -> state = (63-56)<<1 | 0 = 14 (pStateIdx=7, valMPS=0).
        rd_ctx_id = 8'd181;
        #1;
        $display("Read I-Slice Ctx 181 (SAO_MERGE): Expected=14, Got=%0d", rd_state);
        if (rd_state !== 7'd14) begin
            $display("ERROR: Ctx 181 init mismatch!");
            fail_cnt = fail_cnt + 1;
        end
        @(posedge clk);
        upd_valid  = 1;
        upd_ctx_id = 8'd181;
        upd_bin    = 1'b0; // MPS (pStateIdx 7 -> 8, valMPS=0 => 16)
        @(posedge clk);
        upd_valid  = 0;
        #1;
        $display("After Ctx 181 MPS Update: Expected=16, Got=%0d", rd_state);
        if (rd_state !== 7'd16) begin
            $display("ERROR: Ctx 181 MPS transition mismatch!");
            fail_cnt = fail_cnt + 1;
        end

        // 5. Test Read & Update: Context 182 (SAO_TYPE_IDX, iv_I = 200)
        // slope = (12*5)-45 = 15. offs = (8<<3)-16 = 48.
        // tmp = ((15*32) >>> 4) + 48 = 30 + 48 = 78 -> state = (78-64)<<1 | 1 = 29 (pStateIdx=14, valMPS=1).
        rd_ctx_id = 8'd182;
        #1;
        $display("Read I-Slice Ctx 182 (SAO_TYPE_IDX): Expected=29, Got=%0d", rd_state);
        if (rd_state !== 7'd29) begin
            $display("ERROR: Ctx 182 init mismatch!");
            fail_cnt = fail_cnt + 1;
        end
        @(posedge clk);
        upd_valid  = 1;
        upd_ctx_id = 8'd182;
        upd_bin    = 1'b1; // MPS (pStateIdx 14 -> 15, valMPS=1 => 31)
        @(posedge clk);
        upd_valid  = 0;
        #1;
        $display("After Ctx 182 MPS Update: Expected=31, Got=%0d", rd_state);
        if (rd_state !== 7'd31) begin
            $display("ERROR: Ctx 182 MPS transition mismatch!");
            fail_cnt = fail_cnt + 1;
        end
        @(posedge clk);
        upd_valid  = 1;
        upd_ctx_id = 8'd182;
        upd_bin    = 1'b0; // LPS (trans_lps(15)=12, valMPS=1 => 25)
        @(posedge clk);
        upd_valid  = 0;
        #1;
        $display("After Ctx 182 LPS Update: Expected=25, Got=%0d", rd_state);
        if (rd_state !== 7'd25) begin
            $display("ERROR: Ctx 182 LPS transition mismatch!");
            fail_cnt = fail_cnt + 1;
        end

        // 6. Test Read & Update: Context 185 (CU_TRANSQUANT_BYPASS / CNU = 154)
        // slope = (9*5)-45 = 0. offs = (10<<3)-16 = 64.
        // tmp = 64 -> state = (64-64)<<1 | 1 = 1 (pStateIdx=0, valMPS=1).
        rd_ctx_id = 8'd185;
        #1;
        $display("Read I-Slice Ctx 185 (CNU=154): Expected=1, Got=%0d", rd_state);
        if (rd_state !== 7'd1) begin
            $display("ERROR: Ctx 185 init mismatch!");
            fail_cnt = fail_cnt + 1;
        end
        @(posedge clk);
        upd_valid  = 1;
        upd_ctx_id = 8'd185;
        upd_bin    = 1'b0; // LPS at pStateIdx=0 flips valMPS 1->0, trans_lps(0)=0 => 0
        @(posedge clk);
        upd_valid  = 0;
        #1;
        $display("After Ctx 185 LPS Update (MPS flip): Expected=0, Got=%0d", rd_state);
        if (rd_state !== 7'd0) begin
            $display("ERROR: Ctx 185 LPS transition mismatch!");
            fail_cnt = fail_cnt + 1;
        end

        // 7. Trigger B-Slice Initialization (slice_type = 2'd0, QP = 32)
        $display("=== Starting Context Initialization (B-Slice=0, QP=32) ===");
        @(posedge clk);
        slice_init = 1;
        slice_type = 2'd0; // 0 = B-Slice
        qp_in      = 7'd32;
        @(posedge clk);
        slice_init = 0;

        init_cycles = 0;
        #1;
        while (init_busy && init_cycles < 500) begin
            init_cycles = init_cycles + 1;
            @(posedge clk);
            #1;
        end
        $display("B-Slice Init Cycles: Expected=%0d, Got=%0d", N_CTX, init_cycles);
        if (init_cycles !== N_CTX) begin
            $display("ERROR: B-Slice init_busy cycle count mismatch!");
            fail_cnt = fail_cnt + 1;
        end

        // B-Slice Ctx 0 (iv_B = 107 -> state = 42 -> MPS -> 44) & Ctx 182 (iv_B = 160 -> state = 124)
        rd_ctx_id = 8'd0;
        #1;
        $display("Read B-Slice Ctx 0: Expected=42, Got=%0d", rd_state);
        if (rd_state !== 7'd42) begin
            $display("ERROR: B-Slice Ctx 0 init mismatch!");
            fail_cnt = fail_cnt + 1;
        end
        @(posedge clk);
        upd_valid  = 1;
        upd_ctx_id = 8'd0;
        upd_bin    = 1'b0; // MPS -> 44
        @(posedge clk);
        upd_valid  = 0;
        #1;
        $display("After B-Slice Ctx 0 MPS Update: Expected=44, Got=%0d", rd_state);
        if (rd_state !== 7'd44) begin
            $display("ERROR: B-Slice Ctx 0 MPS transition mismatch!");
            fail_cnt = fail_cnt + 1;
        end

        rd_ctx_id = 8'd182;
        #1;
        $display("Read B-Slice Ctx 182: Expected=124, Got=%0d", rd_state);
        if (rd_state !== 7'd124) begin
            $display("ERROR: B-Slice Ctx 182 init mismatch!");
            fail_cnt = fail_cnt + 1;
        end

        // 8. Finish Test
        repeat(5) @(posedge clk);
        if (fail_cnt == 0) begin
            $display("=== CABAC Context Store Testbench Finished: ALL TESTS PASSED (N_CTX=%0d) ===", N_CTX);
            $finish(0);
        end else begin
            $display("=== CABAC Context Store Testbench FAILED: %0d errors ===", fail_cnt);
            $finish(1);
        end
    end
endmodule