//=============================================================================
// tb_entropy_top.sv
// Testbench for Top-Level Entropy Coding Wrapper (entropy_top.v)
//
// Simulates frame-level and CTU-level encoding, driving dummy CUs and 
// coefficients, writing the output bitstream to tb_out.265.
//=============================================================================

`timescale 1ns/1ps

module tb_entropy_top;

    parameter int CTX_ID_W  = 8;
    parameter int COEFF_W   = 16;
    parameter int MVD_W     = 12;
    parameter int N_COEFF   = 16; // 4x4 block

    // Clock and Reset
    logic clk;
    logic rst_n;

    // Frame-level Control
    logic frame_start;
    logic frame_done;
    
    // CTU-level Control
    logic ctu_frame_start;
    logic ctu_frame_done;

    // CU/TU Syntax Interface
    logic       cu_req, cu_done;
    logic [1:0] cu_depth;
    logic       cu_is_split;
    logic       cu_pred_intra;
    logic       cu_cbf;

    logic       pred_req, pred_done;

    logic       coeff_req, coeff_done;
    logic [1:0] coeff_comp;
    logic [COEFF_W*N_COEFF-1:0] coeff_flat;

    // Output Annex B Bitstream
    logic       out_valid;
    logic       out_ready;
    logic [7:0] out_byte;

    //=========================================================================
    // DUT Instantiation
    //=========================================================================
    entropy_top #(
        .CTX_ID_W (CTX_ID_W),
        .COEFF_W  (COEFF_W),
        .MVD_W    (MVD_W),
        .N_COEFF  (N_COEFF)
    ) dut (.*);

    //=========================================================================
    // Clock Generator
    //=========================================================================
    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100 MHz
    end

    //=========================================================================
    // Reset Generator
    //=========================================================================
    initial begin
        rst_n = 0;
        #50 rst_n = 1;
    end

    //=========================================================================
    // Annex B Bitstream Writer
    //=========================================================================
    int fd_out;
    int byte_cnt;
    initial begin
        fd_out = $fopen("tb_out.265", "wb");
        byte_cnt = 0;
        out_ready = 1'b1; // Always ready to receive bytes
    end

    always_ff @(posedge clk) begin
        if (rst_n && out_valid && out_ready) begin
            byte_cnt++;
            $fwrite(fd_out, "%c", out_byte);
            $display("[BITSTREAM OUT] Byte %0d: 0x%02X", byte_cnt, out_byte);
        end
    end

    //=========================================================================
    // High-Level Driver Tasks
    //=========================================================================
    task automatic encode_cu_header(logic is_split, logic [1:0] depth, logic cbf);
        @(posedge clk);
        cu_req        <= 1'b1;
        cu_depth      <= depth;
        cu_is_split   <= is_split;
        cu_pred_intra <= 1'b1;
        cu_cbf        <= cbf;
        @(posedge clk);
        cu_req        <= 1'b0;
        wait(cu_done);
        @(posedge clk);
    endtask

    task automatic encode_pred();
        @(posedge clk);
        pred_req <= 1'b1;
        @(posedge clk);
        pred_req <= 1'b0;
        wait(pred_done);
        @(posedge clk);
    endtask

    task automatic encode_coeff_block(logic [1:0] comp, logic signed [COEFF_W-1:0] blk [N_COEFF]);
        @(posedge clk);
        coeff_req  <= 1'b1;
        coeff_comp <= comp;
        foreach (blk[i]) coeff_flat[i*COEFF_W +: COEFF_W] <= blk[i];
        @(posedge clk);
        coeff_req  <= 1'b0;
        wait(coeff_done);
        @(posedge clk);
    endtask

    //=========================================================================
    // Main Stimulus
    //=========================================================================
    logic signed [COEFF_W-1:0] active_blk [N_COEFF];
    logic signed [COEFF_W-1:0] zero_blk   [N_COEFF];

    always @(posedge clk) begin
        if (rst_n) begin
            $display("[MONITOR] t=%0t | entropy_state=%0d | psw_state=%0d psw_cnt=%0d | sc_state=%0d | nal_state=%0d sc_cnt=%0d | rbsp_v=%0b rbsp_r=%0b rbsp_b=0x%02X | out_v=%0b out_b=0x%02X | rc_state=%0d rc_v=%0b rc_r=%0b rc_ff=%0d rc_bits=%0d rc_flush_done=%0b rc_flush_req=%0b",
                     $time,
                     dut.state,
                     dut.u_param_set_writer.state,
                     dut.u_param_set_writer.byte_cnt,
                     dut.u_slice_controller.state,
                     dut.u_nal_writer.state,
                     dut.u_nal_writer.sc_cnt,
                     dut.rbsp_valid,
                     dut.rbsp_ready,
                     dut.rbsp_byte,
                     dut.out_valid,
                     dut.out_byte,
                     dut.u_cabac_enc_top.u_rc.state,
                     dut.u_cabac_enc_top.u_rc.byte_valid,
                     dut.u_cabac_enc_top.u_rc.byte_ready,
                     dut.u_cabac_enc_top.u_rc.num_ff,
                     dut.u_cabac_enc_top.u_rc.bits_left,
                     dut.u_cabac_enc_top.u_rc.flush_done,
                     dut.u_cabac_enc_top.u_rc.flush_valid);
        end
    end

    initial begin
        // Initialize all inputs
        frame_start    = 0;
        ctu_frame_done = 0;
        cu_req         = 0;
        cu_depth       = 0;
        cu_is_split    = 0;
        cu_pred_intra  = 0;
        cu_cbf         = 0;
        pred_req       = 0;
        coeff_req      = 0;
        coeff_comp     = 0;
        coeff_flat     = 0;

        foreach (zero_blk[i])   zero_blk[i] = 16'd0;
        foreach (active_blk[i]) active_blk[i] = 16'd0;
        
        // Let's set some non-zero coefficients for active luma block
        active_blk[0] = 16'd35;  // DC coefficient
        active_blk[1] = -16'd5;  // AC coefficient
        active_blk[4] = 16'd2;   // AC coefficient

        wait(rst_n);
        @(posedge clk);
        #20;

        $display("\n=======================================================");
        $display("   STARTING ENTROPY_TOP INTEGRATION SIMULATION");
        $display("   Resolution: 64x64, QP: 29, I-Slice Only");
        $display("=======================================================\n");

        // 1. Trigger frame start (this will write VPS, SPS, PPS, and Slice Header)
        $display("[TB_SEQ] 1. Starting Frame NAL header sequence...");
        frame_start = 1'b1;
        @(posedge clk);
        frame_start = 1'b0;

        // 2. Wait for Slice Controller to complete writing headers and start CTU scanning
        $display("[TB_SEQ] 2. Waiting for headers to finish writing...");
        wait(ctu_frame_start);
        $display("[TB_SEQ] 3. CTU Scanning Started. Coding 64 CUs (8x8)...");

        // 3. Code the hierarchical coding tree to fill the 64x64 CTU
        // Depth 0 split flag (64x64 -> four 32x32)
        $display("[TB_SEQ] Encoding depth 0 split flag...");
        encode_cu_header(.is_split(1'b1), .depth(2'd0), .cbf(1'b0));
        
        for (int q32 = 0; q32 < 4; q32++) begin
            // Depth 1 split flag (32x32 -> four 16x16)
            $display("[TB_SEQ] Encoding depth 1 split flag for quadrant %0d...", q32);
            encode_cu_header(.is_split(1'b1), .depth(2'd1), .cbf(1'b0));
            
            for (int q16 = 0; q16 < 4; q16++) begin
                // Depth 2 split flag (16x16 -> four 8x8)
                $display("[TB_SEQ] Encoding depth 2 split flag for quadrant %0d-%0d...", q32, q16);
                encode_cu_header(.is_split(1'b1), .depth(2'd2), .cbf(1'b0));
                
                for (int q8 = 0; q8 < 4; q8++) begin
                    int cu_idx;
                    cu_idx = q32*16 + q16*4 + q8;
                    $display("[TB_SEQ] Coding 8x8 CU %0d/64...", cu_idx);

                    // A. Encode CU Header (Split = 0, Depth = 3 (8x8), CBF = 1)
                    encode_cu_header(.is_split(1'b0), .depth(2'd3), .cbf(1'b1));

                    // B. Encode Intra Predictor modes (MPM list bypass)
                    encode_pred();

                    // C. Encode coefficients for four 4x4 TUs inside this 8x8 CU
                    $display("  - Coding TU 0 (non-zero coeffs)...");
                    encode_coeff_block(.comp(2'd0), .blk(active_blk));

                    $display("  - Coding TU 1 (all-zero coeffs)...");
                    encode_coeff_block(.comp(2'd0), .blk(zero_blk));

                    $display("  - Coding TU 2 (all-zero coeffs)...");
                    encode_coeff_block(.comp(2'd0), .blk(zero_blk));

                    $display("  - Coding TU 3 (all-zero coeffs)...");
                    encode_coeff_block(.comp(2'd0), .blk(zero_blk));
                end
            end
        end

        // 4. Assert ctu_frame_done to trigger the range coder termination and flush
        $display("[TB_SEQ] 4. All CTUs coded. Triggering range coder flush...");
        ctu_frame_done = 1'b1;
        @(posedge clk);
        ctu_frame_done = 1'b0;

        // 5. Wait for frame_done from the FSM
        wait(frame_done);
        $display("[TB_SEQ] 5. Frame Done! Successfully encoded whole bitstream.");

        #200;
        $fclose(fd_out);
        $display("\n=======================================================");
        $display("   SIMULATION SUCCESSFUL. Wrote %0d bytes to tb_out.265", byte_cnt);
        $display("=======================================================\n");
        $finish;
    end

endmodule
