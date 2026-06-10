//=============================================================================
// tb_dct_top.sv
// Testbench for DCT/IDCT Dispatcher Top
//=============================================================================

`timescale 1ns/1ps

`define COEFF_W 16

module tb_dct_top;

    //-------------------------------------------------------------------------
    // Signals
    //-------------------------------------------------------------------------
    logic                       clk;
    logic                       rst_n;
    logic                       fwd_inv_n;
    logic [2:0]                 tu_size_log2;
    
    logic                       in_valid;
    logic                       in_ready;
    logic signed [`COEFF_W-1:0] in_data [0:31][0:31];
    
    logic                       out_valid;
    logic                       out_ready;
    logic signed [`COEFF_W-1:0] out_data [0:31][0:31];
    
    logic [2:0]                 out_tu_size_log2;
    logic                       out_fwd_inv_n;

    int total_errors;

    //-------------------------------------------------------------------------
    // Device Under Test (DUT)
    //-------------------------------------------------------------------------
    dct_top dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .fwd_inv_n        (fwd_inv_n),
        .tu_size_log2     (tu_size_log2),
        .in_valid         (in_valid),
        .in_ready         (in_ready),
        .in_data          (in_data),
        .out_valid        (out_valid),
        .out_ready        (out_ready),
        .out_data         (out_data),
        .out_tu_size_log2 (out_tu_size_log2),
        .out_fwd_inv_n    (out_fwd_inv_n)
    );

    //-------------------------------------------------------------------------
    // Clock Generation
    //-------------------------------------------------------------------------
    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100 MHz clock
    end

    //-------------------------------------------------------------------------
    // Handshake Tasks
    //-------------------------------------------------------------------------
    task automatic send_block(input logic signed [`COEFF_W-1:0] blk[0:31][0:31], input logic mode_fwd, input logic [2:0] size_log2);
        @(negedge clk);
        fwd_inv_n    = mode_fwd;
        tu_size_log2 = size_log2;
        in_data      = blk;
        in_valid     = 1'b1;
        
        @(negedge clk);
        while (!in_ready) @(negedge clk);
        
        in_valid = 1'b0;
    endtask

    task automatic receive_block(output logic signed [`COEFF_W-1:0] blk[0:31][0:31], output logic [2:0] rec_size_log2, output logic rec_fwd);
        int timeout;
        timeout = 0;
        @(negedge clk);
        out_ready = 1'b1;
        
        @(negedge clk);
        while (!out_valid) begin
            if (++timeout > 100) begin
                $display("ERROR [receive_block] TIMEOUT — out_valid never asserted");
                $finish;
            end
            @(negedge clk);
        end
        
        blk           = out_data;
        rec_size_log2 = out_tu_size_log2;
        rec_fwd       = out_fwd_inv_n;
        out_ready     = 1'b0;
    endtask

    //-------------------------------------------------------------------------
    // Unified Size Sweep Roundtrip Task
    //-------------------------------------------------------------------------
    task automatic test_roundtrip(input logic [2:0] size_log2);
        logic signed [`COEFF_W-1:0] test_in  [0:31][0:31];
        logic signed [`COEFF_W-1:0] fwd_out  [0:31][0:31];
        logic signed [`COEFF_W-1:0] inv_out  [0:31][0:31];
        logic [2:0] rec_size_log2;
        logic       rec_fwd;
        int N, r, c, max_err, diff, orig;
        
        N = 1 << size_log2;
        $display("--- Testing TU Size %0dx%0d (tu_size_log2=%0d) ---", N, N, size_log2);

        // Init Array
        for(r=0; r<32; r++) for(c=0; c<32; c++) test_in[r][c] = 0;
        test_in[0][0] = 100; // Hardcoded Impulse

        // FWD DCT
        fork
            send_block(test_in, 1'b1, size_log2);
            receive_block(fwd_out, rec_size_log2, rec_fwd);
        join

        // Check FWD Metadata
        if (rec_size_log2 !== size_log2 || rec_fwd !== 1'b1) begin
            $display("[FAIL] FWD Metadata mismatch. Exp size:%0d fwd:1, Got size:%0d fwd:%0b", size_log2, rec_size_log2, rec_fwd);
            total_errors++;
        end

        // INV DCT
        fork
            send_block(fwd_out, 1'b0, size_log2);
            receive_block(inv_out, rec_size_log2, rec_fwd);
        join

        // Check INV Metadata
        if (rec_size_log2 !== size_log2 || rec_fwd !== 1'b0) begin
            $display("[FAIL] INV Metadata mismatch. Exp size:%0d fwd:0, Got size:%0d fwd:%0b", size_log2, rec_size_log2, rec_fwd);
            total_errors++;
        end

        // Check Reconstruction Data & Padding constraints
        max_err = 0;
        for (r=0; r<32; r++) begin
            for (c=0; c<32; c++) begin
                if (r < N && c < N) begin
                    orig = (r==0 && c==0) ? 100 : 0;
                    diff = inv_out[r][c] - orig;
                    if (diff < 0) diff = -diff;
                    if (diff > max_err) max_err = diff;
                end else begin
                    // Area outside active TU must be driven to exact 0
                    if (inv_out[r][c] !== 0) begin
                        $display("[FAIL] Non-zero output outside active %0dx%0d bounds at [%0d][%0d] = %0d", N, N, r, c, inv_out[r][c]);
                        total_errors++;
                    end
                end
            end
        end

        if (max_err <= 2) $display("[PASS] %0dx%0d Roundtrip Reconstructed & Masked (max err=%0d)", N, N, max_err);
        else begin        $display("[FAIL] %0dx%0d Roundtrip reconstruction failed (max err=%0d)", N, N, max_err); total_errors++; end
    endtask

    //-------------------------------------------------------------------------
    // HM File I/O Verification Task (Dynamic Size)
    //-------------------------------------------------------------------------
    task automatic test_from_files(string in_file, string ref_file, logic is_fwd, logic [2:0] size_log2);
        int fd_in, fd_ref, scan_r;
        logic signed [`COEFF_W-1:0] blk_in [0:31][0:31];
        logic signed [`COEFF_W-1:0] blk_ref [0:31][0:31];
        logic signed [`COEFF_W-1:0] blk_out [0:31][0:31];
        logic [2:0] rec_size_log2;
        logic       rec_fwd;
        int N, r, c, err_count, correct_blocks;

        N = 1 << size_log2;
        fd_in  = $fopen(in_file, "r");
        fd_ref = $fopen(ref_file, "r");
        
        if (!fd_in || !fd_ref) begin
            $display("WARNING: Could not open HM test vectors %s or %s. Skipping file test.", in_file, ref_file);
            if (fd_in) $fclose(fd_in);
            if (fd_ref) $fclose(fd_ref);
            return;
        end

        $display("--------------------------------------------------");
        $display("Running HM File Test: %s %0dx%0d", is_fwd ? "FORWARD DCT" : "INVERSE DCT", N, N);
        
        err_count = 0;
        correct_blocks = 0;
        while (!$feof(fd_in) && !$feof(fd_ref)) begin
            // Clear arrays
            for(r=0; r<32; r++) for(c=0; c<32; c++) begin blk_in[r][c] = 0; blk_ref[r][c] = 0; end

            for(r=0; r<N; r++) begin
                for(c=0; c<N; c++) begin
                    scan_r = $fscanf(fd_in, "%h", blk_in[r][c]);
                    if ($feof(fd_in) && r==0 && c==0) break;
                    if (scan_r != 1) begin
                        $display("ERROR: bad read from %s at [%0d][%0d]", in_file, r, c);
                        $fclose(fd_in); $fclose(fd_ref); return;
                    end
                end
                if ($feof(fd_in)) break;
            end
            
            if ($feof(fd_in)) break;

            for(r=0; r<N; r++) for(c=0; c<N; c++) begin
                scan_r = $fscanf(fd_ref, "%h", blk_ref[r][c]);
                if (scan_r != 1) begin
                    $display("ERROR: bad read from %s at [%0d][%0d]", ref_file, r, c);
                    $fclose(fd_in); $fclose(fd_ref); return;
                end
            end

            fork
                send_block(blk_in, is_fwd, size_log2);
                receive_block(blk_out, rec_size_log2, rec_fwd);
            join

            // Metadata check
            if (rec_size_log2 !== size_log2 || rec_fwd !== is_fwd) begin
                $display("[FAIL] Metadata mismatch. Exp size:%0d fwd:%0b, Got size:%0d fwd:%0b", size_log2, is_fwd, rec_size_log2, rec_fwd);
                err_count++;
            end

            // Data & Masking Check
            for(r=0; r<32; r++) begin
                for(c=0; c<32; c++) begin
                    if (r < N && c < N) begin
                        if (blk_out[r][c] !== blk_ref[r][c]) err_count++;
                        else                                 correct_blocks++;
                    end else begin
                        if (blk_out[r][c] !== 0) begin
                            $display("[FAIL] Non-zero padding at [%0d][%0d]: %0d", r, c, blk_out[r][c]);
                            err_count++;
                        end
                    end
                end
            end
        end
        
        if (err_count == 0) $display("[PASS] HM File Vectors Verified!");
        else                $display("[FAIL] HM File Vectors Failed with %0d errors.", err_count);
        $display("[INFO] Correct elements: %0d", correct_blocks);
        
        total_errors += err_count;
        $fclose(fd_in);
        $fclose(fd_ref);
    endtask

    //-------------------------------------------------------------------------
    // Main Test Stimulus
    //-------------------------------------------------------------------------
    initial begin
        in_valid  = 0; out_ready = 0; fwd_inv_n = 1; tu_size_log2 = 2; total_errors = 0;
        rst_n = 0; #20 rst_n = 1; #10;

        $display("\n==================================================");
        $display(" Starting DCT_TOP Dispatcher Verification");
        $display("==================================================");

        test_roundtrip(3'd2); // 4x4
        test_roundtrip(3'd3); // 8x8
        test_roundtrip(3'd4); // 16x16
        test_roundtrip(3'd5); // 32x32

        $display("\n==================================================");
        $display(" Running File Vectors Across All Tu_Sizes");
        $display("==================================================");
        test_from_files("hm_fwd_in_4.dat",  "hm_fwd_out_4.dat",  1'b1, 3'd2);
        test_from_files("hm_inv_in_4.dat",  "hm_inv_out_4.dat",  1'b0, 3'd2);
        test_from_files("hm_fwd_in_8.dat",  "hm_fwd_out_8.dat",  1'b1, 3'd3);
        test_from_files("hm_inv_in_8.dat",  "hm_inv_out_8.dat",  1'b0, 3'd3);
        test_from_files("hm_fwd_in_16.dat", "hm_fwd_out_16.dat", 1'b1, 3'd4);
        test_from_files("hm_inv_in_16.dat", "hm_inv_out_16.dat", 1'b0, 3'd4);
        test_from_files("hm_fwd_in_32.dat", "hm_fwd_out_32.dat", 1'b1, 3'd5);
        test_from_files("hm_inv_in_32.dat", "hm_inv_out_32.dat", 1'b0, 3'd5);

        $display("==================================================");
        if (total_errors == 0) $display(" === ALL TESTS PASSED ===");
        else                   $display(" === TESTS FAILED: %0d Errors ===", total_errors);
        $display("==================================================\n");
        $finish;
    end
endmodule