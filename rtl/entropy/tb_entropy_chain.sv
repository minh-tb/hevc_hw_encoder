`timescale 1ns/1ps

module tb_entropy_chain;

    // =========================================================================
    // Parameters
    // =========================================================================
    parameter int CTX_ID_W  = 8;
    parameter int COEFF_W   = 16;
    parameter int MVD_W     = 12;
    parameter int N_COEFF   = 16; // 4x4 block

    // =========================================================================
    // Signals
    // =========================================================================
    logic clk;
    logic rst_n;

    // Slice Init
    logic       slice_init;
    logic [1:0] slice_type;
    logic [6:0] qp_in;

    // CU Req
    logic       cu_req, cu_done;
    logic [1:0] cu_depth;
    logic       cu_is_split;
    logic       slice_is_intra;
    logic       cu_skip, cu_merge;
    logic [2:0] cu_merge_idx;
    logic       cu_pred_intra;
    logic [1:0] cu_part_mode;
    logic       cu_cbf;
    logic [1:0] cu_skip_ctx;

    // Pred Req
    logic       pred_req, pred_done;
    logic       slice_is_b;
    logic [1:0] inter_dir;
    logic [2:0] ref_idx_l0;
    logic       mvp_flag_l0;
    logic signed [MVD_W-1:0] mvd_l0_x, mvd_l0_y;
    logic [2:0] ref_idx_l1;
    logic       mvp_flag_l1;
    logic signed [MVD_W-1:0] mvd_l1_x, mvd_l1_y;

    // Coeff Req
    logic       coeff_req, coeff_done;
    logic [1:0] coeff_comp;
    logic       coeff_is_intra;
    logic [COEFF_W*N_COEFF-1:0] coeff_flat;

    // End of Slice / Flush
    logic       trm_req;
    logic       flush_req, flush_done;

    // Outputs
    logic       byte_valid;
    logic [7:0] byte_out;
    logic       byte_ready;
    
    logic       enc_busy;
    logic       ctx_init_busy;

    // =========================================================================
    // DUT Instantiation
    // =========================================================================
    cabac_enc_top #(
        .CTX_ID_W (CTX_ID_W),
        .COEFF_W  (COEFF_W),
        .MVD_W    (MVD_W),
        .N_COEFF  (N_COEFF)
    ) dut (.*);

    // =========================================================================
    // Clock & Reset
    // =========================================================================
    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100 MHz
    end

    initial begin
        rst_n = 0;
        #20 rst_n = 1;
    end

    // =========================================================================
    // Random Backpressure (Stall byte output randomly)
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) byte_ready <= 1'b1;
        else        byte_ready <= ($urandom_range(0, 99) < 80); // Ready 80% of time
    end

    // =========================================================================
    // File Verification Monitor (Compares to HM Golden Bitstream)
    // =========================================================================
    int output_file;
    int byte_count;
    string expected_bin_path = "d:/UIT_Doc/hevc_hw_encoder/verif/expected/flat_field_qp32.bin";
    
    initial begin
        // Try to open a golden reference file if one exists
        output_file = $fopen(expected_bin_path, "rb");
        if (output_file) $display("[TESTBENCH] Golden reference file loaded: %s", expected_bin_path);
        else             $display("[TESTBENCH] No golden reference file found. Running in standalone mode.");
        byte_count = 0;
    end

    always_ff @(posedge clk) begin
        if (rst_n && byte_valid && byte_ready) begin
            byte_count++;
            $display("[CABAC OUT] Byte %0d: 0x%02X", byte_count, byte_out);
            
            // If we have a file, read one byte and check it!
            if (output_file) begin
                int expected_char;
                expected_char = $fgetc(output_file);
                if (expected_char == -1) begin
                    $error("[FAIL] Bitstream generated MORE bytes than the HM reference file!");
                    $stop;
                end
                
                if (byte_out !== expected_char[7:0]) begin
                    $error("[FAIL] Byte %0d Mismatch! Expected: 0x%02X, Got: 0x%02X", byte_count, expected_char[7:0], byte_out);
                    $stop;
                end
            end
        end
    end

    // =========================================================================
    // High-Level Driver Tasks
    // =========================================================================
    task automatic init_slice(logic [1:0] stype, logic [6:0] qp);
        @(posedge clk);
        slice_init <= 1'b1;
        slice_type <= stype;
        qp_in      <= qp;
        @(posedge clk);
        slice_init <= 1'b0;
        wait(!ctx_init_busy);
        @(posedge clk);
    endtask

    task automatic encode_cu(logic intra, logic split, logic skip, logic cbf);
        @(posedge clk);
        cu_req <= 1'b1;
        cu_depth <= 2'd0;
        cu_is_split <= split;
        slice_is_intra <= intra;
        cu_pred_intra <= intra;
        cu_skip <= skip;
        cu_merge <= 0;
        cu_merge_idx <= 0;
        cu_part_mode <= 0;
        cu_cbf <= cbf;
        cu_skip_ctx <= 0;
        @(posedge clk);
        cu_req <= 1'b0;
        wait(cu_done);
        @(posedge clk);
    endtask

    task automatic encode_coeff(logic [1:0] comp, logic intra, logic signed [COEFF_W-1:0] blk [N_COEFF]);
        @(posedge clk);
        coeff_req <= 1'b1;
        coeff_comp <= comp;
        coeff_is_intra <= intra;
        foreach (blk[i]) coeff_flat[i*COEFF_W +: COEFF_W] <= blk[i];
        @(posedge clk);
        coeff_req <= 1'b0;
        wait(coeff_done);
        @(posedge clk);
    endtask

    task automatic finish_slice();
        @(posedge clk);
        trm_req <= 1'b1; // Send the end_of_slice_flag (1)
        @(posedge clk);
        trm_req <= 1'b0;
        
        @(posedge clk);
        flush_req <= 1'b1; // Flush range coder internal buffers
        @(posedge clk);
        flush_req <= 1'b0;
        wait(flush_done);
        @(posedge clk);
    endtask

    // =========================================================================
    // Main Stimulus
    // =========================================================================
    logic signed [COEFF_W-1:0] test_blk [N_COEFF];
    
    initial begin
        // Init all inputs
        slice_init = 0; slice_type = 0; qp_in = 0;
        cu_req = 0; cu_depth = 0; cu_is_split = 0; slice_is_intra = 0;
        cu_skip = 0; cu_merge = 0; cu_merge_idx = 0; cu_pred_intra = 0;
        cu_part_mode = 0; cu_cbf = 0; cu_skip_ctx = 0;
        pred_req = 0; slice_is_b = 0; inter_dir = 0; ref_idx_l0 = 0;
        mvp_flag_l0 = 0; mvd_l0_x = 0; mvd_l0_y = 0; ref_idx_l1 = 0;
        mvp_flag_l1 = 0; mvd_l1_x = 0; mvd_l1_y = 0;
        coeff_req = 0; coeff_comp = 0; coeff_is_intra = 0; coeff_flat = 0;
        trm_req = 0; flush_req = 0;

        foreach(test_blk[i]) test_blk[i] = 0;

        // Wait for reset
        wait(rst_n);
        @(posedge clk);
        
        $display("\n==================================================");
        $display("   STARTING FULL ENTROPY CHAIN INTEGRATION TEST");
        $display("==================================================\n");

        // 1. Initialize Contexts (I-Slice, QP=32)
        $display("[SEQ] 1. Initializing Slice Contexts...");
        init_slice(2'd0, 7'd32);
        
        // 2. Encode a CU Header
        $display("[SEQ] 2. Encoding Intra CU Syntax...");
        encode_cu(.intra(1'b1), .split(1'b0), .skip(1'b0), .cbf(1'b1));
        
        // 3. Encode Coefficients for a 4x4 block
        $display("[SEQ] 3. Encoding Transform Coefficients...");
        test_blk[0] = 16'd45; test_blk[1] = -16'd3; test_blk[2] = 16'd1;
        encode_coeff(.comp(2'd0), .intra(1'b1), .blk(test_blk));

        // 4. Terminate and Flush Slice
        $display("[SEQ] 4. Flushing Range Coder...");
        finish_slice();

        $display("\n>>> TEST COMPLETE. Wrote %0d bytes. <<<", byte_count);
        $stop;
    end

endmodule