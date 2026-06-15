//=============================================================================
// tb_fwd_quant.sv
// Testbench for Forward Quantization Unit
//=============================================================================

`timescale 1ns/1ps

`define COEFF_W 16
`define BIT_DEPTH 10

module tb_fwd_quant;

    //-------------------------------------------------------------------------
    // Signals
    //-------------------------------------------------------------------------
    logic                 clk;
    logic                 rst_n;

    logic [5:0]           qp;
    logic [2:0]           tu_size_log2;
    logic                 is_intra;
    logic                 transform_skip;

    logic                 in_valid;
    logic                 in_ready;
    logic signed [15:0]   in_coeff;
    logic [9:0]           in_scan_idx;
    logic                 in_last;

    logic                 out_valid;
    logic                 out_ready;
    logic signed [15:0]   out_level;
    logic [9:0]           out_scan_idx;
    logic                 out_last;
    logic                 out_cbf;

    int total_errors;

    //-------------------------------------------------------------------------
    // Device Under Test (DUT)
    //-------------------------------------------------------------------------
    fwd_quant dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .qp             (qp),
        .tu_size_log2   (tu_size_log2),
        .is_intra       (is_intra),
        .in_valid       (in_valid),
        .in_ready       (in_ready),
        .in_coeff       (in_coeff),
        .in_scan_idx    (in_scan_idx),
        .in_last        (in_last),
        .out_valid      (out_valid),
        .out_ready      (out_ready),
        .out_level      (out_level),
        .out_scan_idx   (out_scan_idx),
        .out_last       (out_last),
        .out_cbf        (out_cbf)
    );

    //-------------------------------------------------------------------------
    // Clock Generation
    //-------------------------------------------------------------------------
    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100 MHz clock
    end

    //-------------------------------------------------------------------------
    // HM File I/O Verification Task
    //-------------------------------------------------------------------------
    task automatic test_from_files(
        string in_file,
        string ref_file,
        int N,
        logic [5:0] test_qp,
        logic test_intra,
        logic test_ts
    );
        int fd_in, fd_ref, scan_r;
        int num_coeffs = N * N;
        logic [2:0] test_tu_size_log2 = $clog2(N);
        logic signed [15:0] coeffs [];
        logic signed [15:0] expected_levels [];
        int err_count = 0;
        int correct_blocks = 0;
        logic expected_cbf;

        fd_in  = $fopen(in_file, "r");
        fd_ref = $fopen(ref_file, "r");

        if (!fd_in || !fd_ref) begin
            $display("WARNING: Could not open HM test vectors %s or %s. Skipping file test.", in_file, ref_file);
            if (fd_in) $fclose(fd_in);
            if (fd_ref) $fclose(fd_ref);
            return;
        end

        $display("--------------------------------------------------");
        $display("Running HM File Test: %0dx%0d (QP=%0d, Intra=%0b, TS=%0b)", N, N, test_qp, test_intra, test_ts);

        coeffs = new[num_coeffs];
        expected_levels = new[num_coeffs];

        while (!$feof(fd_in) && !$feof(fd_ref)) begin
            expected_cbf = 1'b0;

            // Read 1 block of inputs
            for (int i = 0; i < num_coeffs; i++) begin
                scan_r = $fscanf(fd_in, "%h", coeffs[i]);
                if (scan_r != 1) begin
                    if (i == 0) break; // Clean EOF at block boundary
                    $display("ERROR: bad read from %s at idx %0d", in_file, i);
                    $fclose(fd_in); $fclose(fd_ref); return;
                end
            end
            if (scan_r != 1) break;

            // Read 1 block of references
            for (int i = 0; i < num_coeffs; i++) begin
                scan_r = $fscanf(fd_ref, "%h", expected_levels[i]);
                if (scan_r != 1) begin
                    $display("ERROR: bad read from %s at idx %0d", ref_file, i);
                    $fclose(fd_in); $fclose(fd_ref); return;
                end
                if (expected_levels[i] != 0) expected_cbf = 1'b1;
            end

            fork
                // Thread 1: Driver
                begin
                    qp = test_qp;
                    tu_size_log2 = test_tu_size_log2;
                    is_intra = test_intra;
                    transform_skip = test_ts;

                    in_valid    <= 1'b1;
                    in_coeff    <= coeffs[0];
                    in_scan_idx <= 0;
                    in_last     <= (0 == num_coeffs - 1);

                    for (int i = 0; i < num_coeffs; i++) begin
                        logic accepted;
                        do begin
                            @(posedge clk);
                            accepted = in_ready;
                        end while (!accepted);
                        
                        if (i + 1 < num_coeffs) begin
                            in_valid    <= 1'b1;
                            in_coeff    <= coeffs[i+1];
                            in_scan_idx <= i+1;
                            in_last     <= ((i+1) == num_coeffs - 1);
                        end else begin
                            in_valid    <= 1'b0;
                        end
                    end
                end

                // Thread 2: Monitor
                begin
                    int i = 0;
                int timeout = 0;
                    while (i < num_coeffs) begin
                        @(posedge clk);
                    timeout++;
                    if (timeout > num_coeffs * 200) begin
                        $display("ERROR [tb_fwd_quant] TIMEOUT waiting for output %0d", i);
                        $finish;
                    end

                        if (out_valid && out_ready) begin
                        timeout = 0;
                            if (out_level !== expected_levels[i]) 
                            begin                        
                                err_count++;
                                $display("ERROR: Mismatch at idx %0d: got %0d, expected %0d", i, out_level, expected_levels[i]);
                            end
                                
                            else begin
                                correct_blocks++;
                                //$display("Match at idx %0d: got %0d, expected %0d", i, out_level, expected_levels[i]);    
                            end                                
                            
                            if (out_scan_idx !== i) err_count++;
                            if (out_last !== (i == num_coeffs - 1)) err_count++;
                            if ((i == num_coeffs - 1) && (out_cbf !== expected_cbf)) err_count++;
                            i++;
                        end
                        
                        // Randomly throttle out_ready to test pipeline stalling
                        out_ready <= ($random % 100 < 80); 
                    end
                    out_ready <= 1'b0;
                end
            join
        end
        
        if (err_count == 0) $display("[PASS] HM File Vectors Verified! (Correct elements: %0d)", correct_blocks);
        else                $display("[FAIL] HM File Vectors Failed with %0d errors.", err_count);
        
        total_errors += err_count;
        $fclose(fd_in);
        $fclose(fd_ref);
    endtask

    //-------------------------------------------------------------------------
    // Main Test Stimulus
    //-------------------------------------------------------------------------
    initial begin
        in_valid  = 0;
        out_ready = 0;
        total_errors = 0;

        rst_n = 0;
        @(negedge clk);
        rst_n = 1;
        @(negedge clk);

        $display("\n==================================================");
        $display(" Starting FWD_QUANT Verification");
        $display("==================================================");

        // The HEVC HM configuration uses IntraQPOffset = -3.
        // Base QP is 32, so Intra blocks are coded with QP = 32 - 3 = 29.
        test_from_files("hm_quant_in_4.dat",  "hm_quant_out_4.dat",   4, 29, 1'b1, 1'b0);
        test_from_files("hm_quant_in_8.dat",  "hm_quant_out_8.dat",   8, 29, 1'b1, 1'b0);
        test_from_files("hm_quant_in_16.dat", "hm_quant_out_16.dat", 16, 29, 1'b1, 1'b0);
        test_from_files("hm_quant_in_32.dat", "hm_quant_out_32.dat", 32, 29, 1'b1, 1'b0);

        $display("==================================================");
        if (total_errors == 0) $display(" === ALL TESTS PASSED ===");
        else                   $display(" === TESTS FAILED: %0d Errors ===", total_errors);
        $display("==================================================\n");
        $finish;
    end

endmodule