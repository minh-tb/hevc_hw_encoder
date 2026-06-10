//=============================================================================
// tb_db_filter_luma.sv
// Testbench for Deblocking Filter — Luma Edge Filter
//
// Reads test vectors generated from the HEVC HM Reference Software.
// File format (space separated decimal integers):
// BS EDGE_QP P3 P2 P1 P0 Q0 Q1 Q2 Q3 EXP_P2 EXP_P1 EXP_P0 EXP_Q0 EXP_Q1 EXP_Q2
//=============================================================================

`timescale 1ns/1ps
`include "parameter_pkg.vh"

module tb_db_filter_luma;

    logic clk;
    logic rst_n;

    // Input Handshake
    logic in_valid;
    logic in_ready;

    // Inputs
    logic [1:0]  bs;
    logic [5:0]  edge_qp;
    logic [`PIXEL_WIDTH-1:0] p0, p1, p2, p3;
    logic [`PIXEL_WIDTH-1:0] q0, q1, q2, q3;

    // Output Handshake
    logic out_valid;
    logic out_ready;

    // Outputs
    logic [`PIXEL_WIDTH-1:0] p0_f, p1_f, p2_f;
    logic [`PIXEL_WIDTH-1:0] q0_f, q1_f, q2_f;
    logic modified_p, modified_q;

    //=========================================================================
    // DUT Instantiation
    //=========================================================================
    db_filter_luma dut (.*);

    // Clock generation
    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100 MHz
    end

    //=========================================================================
    // Expected Results Queue (to handle pipeline latency)
    //=========================================================================
    typedef struct {
        logic [`PIXEL_WIDTH-1:0] exp_p2, exp_p1, exp_p0;
        logic [`PIXEL_WIDTH-1:0] exp_q0, exp_q1, exp_q2;
    } exp_res_t;

    exp_res_t exp_q[$];
    exp_res_t current_exp;
    exp_res_t exp_out;
    
    int total_tested = 0;
    int total_errors = 0;

    //=========================================================================
    // File I/O and Stimulus Driver
    //=========================================================================
    int fd;
    int scan_ret;
    
    // Temporary variables for file reading
    int f_bs, f_qp;
    int f_p3, f_p2, f_p1, f_p0;
    int f_q0, f_q1, f_q2, f_q3;
    int f_ep2, f_ep1, f_ep0;
    int f_eq0, f_eq1, f_eq2;

    initial begin
        in_valid = 0;
        rst_n = 0;
        
        // Open golden vectors file (generated from HM)
        fd = $fopen("db_luma_tv.txt", "r");
        if (fd == 0) begin
            $display("ERROR: Could not open db_luma_tv.txt");
            $display("Please generate this file from HM TComLoopFilter.cpp");
            $finish;
        end

        repeat(4) @(posedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);

        $display("=== STARTING LUMA DEBLOCKING FILTER TESTS ===");

        while (!$feof(fd)) begin
            // Read 16 values per line
            scan_ret = $fscanf(fd, "%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d", 
                               f_bs, f_qp, 
                               f_p3, f_p2, f_p1, f_p0, f_q0, f_q1, f_q2, f_q3,
                               f_ep2, f_ep1, f_ep0, f_eq0, f_eq1, f_eq2);
            
            if (scan_ret == 16) begin
                // Wait for DUT to be ready
                in_valid <= 1;
                bs <= f_bs;
                edge_qp <= f_qp;
                p3 <= f_p3; p2 <= f_p2; p1 <= f_p1; p0 <= f_p0;
                q0 <= f_q0; q1 <= f_q1; q2 <= f_q2; q3 <= f_q3;

                // Push expected results into queue
                current_exp.exp_p2 = f_ep2;
                current_exp.exp_p1 = f_ep1;
                current_exp.exp_p0 = f_ep0;
                current_exp.exp_q0 = f_eq0;
                current_exp.exp_q1 = f_eq1;
                current_exp.exp_q2 = f_eq2;
                exp_q.push_back(current_exp);

                @(posedge clk);
                while (!in_ready) @(posedge clk);
                
                // Randomly drop valid to test pipeline stalls
                if ($urandom() % 100 < 30) begin
                    in_valid <= 0;
                    @(posedge clk);
                end
            end
        end
        
        in_valid <= 0;
        
        // Wait for pipeline to drain
        while (exp_q.size() > 0) @(posedge clk);
        
        if (total_errors == 0) $display("=== ALL %0d TESTS PASSED ===", total_tested);
        else                   $display("=== TESTS FAILED: %0d Errors ===", total_errors);
        
        $fclose(fd);
        $finish;
    end

    //=========================================================================
    // Output Checker
    //=========================================================================
    always @(posedge clk) begin
        out_ready <= ($urandom() % 100 < 80); // Random backpressure

        if (out_valid && out_ready) begin
            if (exp_q.size() == 0) begin
                $display("ERROR at %0t: Unexpected output from DUT!", $time);
                total_errors++;
            end else begin
                exp_out = exp_q.pop_front();
                total_tested++;
                
                if (p2_f !== exp_out.exp_p2 || p1_f !== exp_out.exp_p1 || p0_f !== exp_out.exp_p0 ||
                    q0_f !== exp_out.exp_q0 || q1_f !== exp_out.exp_q1 || q2_f !== exp_out.exp_q2) begin
                    $display("ERROR at %0t: Mismatch! Expected P[2..0]=%0d,%0d,%0d Q[0..2]=%0d,%0d,%0d | Got P=%0d,%0d,%0d Q=%0d,%0d,%0d", 
                             $time, exp_out.exp_p2, exp_out.exp_p1, exp_out.exp_p0, exp_out.exp_q0, exp_out.exp_q1, exp_out.exp_q2, p2_f, p1_f, p0_f, q0_f, q1_f, q2_f);
                    total_errors++;
                end
            end
        end
    end
endmodule