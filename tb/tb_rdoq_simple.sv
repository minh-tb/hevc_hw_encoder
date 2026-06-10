//=============================================================================
// tb_rdoq_simple.sv
// Testbench for Simplified Rate-Distortion Optimized Quantization
//=============================================================================

`timescale 1ns/1ps

`define COEFF_WIDTH 16

module tb_rdoq_simple;

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
    logic signed [15:0]   in_level;
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
    rdoq_simple dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .qp             (qp),
        .tu_size_log2   (tu_size_log2),
        .is_intra       (is_intra),
        .transform_skip (transform_skip),
        .in_valid       (in_valid),
        .in_ready       (in_ready),
        .in_level       (in_level),
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
    // Algorithmic Verification Task
    //-------------------------------------------------------------------------
    task automatic test_random_groups(int num_groups);
        int err_count = 0;
        
        $display("--------------------------------------------------");
        $display("Running Algorithmic Test: %0d Coefficient Groups", num_groups);

        fork
            // Thread 1: Driver
            begin
                qp = 32;
                tu_size_log2 = 2; // 4x4
                is_intra = 1'b0;
                transform_skip = 1'b0;
                
                for (int g = 0; g < num_groups; g++) begin
                    for (int i = 0; i < 16; i++) begin
                        logic accepted;
                        
                        in_valid    <= 1'b1;
                        // Generate random level biased towards small numbers (-3 to 3)
                        in_level    <= $signed($random % 4); 
                        in_scan_idx <= g * 16 + i;
                        in_last     <= (i == 15);
                        
                        do begin
                            @(posedge clk);
                            accepted = in_ready;
                        end while (!accepted);
                    end
                end
                in_valid <= 1'b0;
            end

            // Thread 2: Monitor
            begin
                int groups_received = 0;
                logic signed [15:0] out_buf [16];
                int out_idx = 0;
                
                while (groups_received < num_groups) begin
                    @(posedge clk);
                    
                    if (out_valid && out_ready) begin
                        out_buf[out_idx] = out_level;
                        out_idx++;
                        
                        if (out_idx == 16) begin
                            // Verify SDH property for this group!
                            int first_nz = -1;
                            int last_nz = -1;
                            int abs_sum = 0;
                            int sign_first = 0;
                            
                            // Find properties
                            for (int k = 0; k < 16; k++) begin
                                if (out_buf[k] != 0) begin
                                    if (first_nz == -1) begin
                                        first_nz = k;
                                        sign_first = (out_buf[k] < 0) ? 1 : 0;
                                    end
                                    last_nz = k;
                                    abs_sum += (out_buf[k] < 0) ? -out_buf[k] : out_buf[k];
                                end
                            end
                            
                            if (first_nz != -1 && (last_nz - first_nz >= 4)) begin
                                int parity = abs_sum & 1;
                                if (parity != sign_first) begin
                                    $display("ERROR: SDH Parity violation in group %0d! sum=%0d, sign_first=%0d", groups_received, abs_sum, sign_first);
                                    err_count++;
                                end
                            end
                            
                            groups_received++;
                            out_idx = 0;
                        end
                    end
                    
                    out_ready <= ($random % 100 < 80); // Random stalls
                end
            end
        join
        
        if (err_count == 0) $display("[PASS] All %0d coefficient groups verified successfully!", num_groups);
        else                $display("[FAIL] Verification failed with %0d errors.", err_count);
        
        total_errors += err_count;
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
        $display(" Starting RDOQ_SIMPLE Verification");
        $display("==================================================");

        test_random_groups(100);

        $display("==================================================");
        if (total_errors == 0) $display(" === ALL TESTS PASSED ===");
        else                   $display(" === TESTS FAILED: %0d Errors ===", total_errors);
        $display("==================================================\n");
        $finish;
    end

endmodule
