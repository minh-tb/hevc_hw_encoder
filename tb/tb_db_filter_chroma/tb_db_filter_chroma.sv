//=============================================================================
// tb_db_filter_chroma.sv
// Self-checking testbench for HEVC Chroma Deblocking Filter
//=============================================================================

`timescale 1ns/1ps


`include "parameter_pkg.vh"
module tb_db_filter_chroma;

    // DUT Ports
    logic                     clk;
    logic                     rst_n;
    logic                     in_valid;
    logic                     in_ready;
    logic [1:0]               bs;
    logic [5:0]               edge_qp;
    logic [1:0]               comp;
    logic [`PIXEL_WIDTH-1:0]  p0, p1, q0, q1;
    
    logic                     out_valid;
    logic                     out_ready;
    logic [`PIXEL_WIDTH-1:0]  p0_f, q0_f, p1_pass, q1_pass;
    logic                     modified;

    // Instantiation
    db_filter_chroma dut (.*);

    // Clock Generation (100 MHz)
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    //-------------------------------------------------------------------------
    // SystemVerilog Golden Reference Model
    //-------------------------------------------------------------------------
    function automatic logic [5:0] get_chroma_qp(input logic [5:0] qpy);
        // HEVC Table 8-15
        logic [5:0] tbl [0:51] = '{
            0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 
            20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 29, 30, 31, 32, 33, 33, 34, 34, 
            35, 35, 36, 36, 37, 37, 38, 39, 40, 41, 42, 43, 44, 45
        };
        if (qpy > 51) return 0;
        return tbl[qpy];
    endfunction

    function automatic logic [6:0] get_tc(input logic [6:0] idx);
        // HEVC Table 8-11
        logic [6:0] tbl [0:53] = '{
            0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
            1,1,1,1,1,1,1,1,1,2,2,2,2,3,3,3,4,4,4,4,4,5,5,
            6,6,7,7,8,9,10,11
        };
        if (idx > 53) return 0;
        return tbl[idx];
    endfunction

    function automatic int clip1(input int val);
        int max_val = (1 << `BIT_DEPTH) - 1;
        if (val < 0) return 0;
        if (val > max_val) return max_val;
        return val;
    endfunction

    typedef struct {
        logic [`PIXEL_WIDTH-1:0] p0_f, q0_f, p1_pass, q1_pass;
        logic modified;
    } expected_t;

    expected_t exp_queue[$];

    // Compute expected output matching HEVC section 8.7.2.5
    function automatic expected_t compute_golden(
        input logic [1:0] bs, input logic [5:0] edge_qp, 
        input logic [`PIXEL_WIDTH-1:0] p0, p1, q0, q1
    );
        expected_t exp;
        int tc, qpc, delta_raw, delta;
        
        exp.p1_pass = p1;
        exp.q1_pass = q1;

        if (bs == 2) begin
            qpc = get_chroma_qp(edge_qp);
            tc = get_tc(qpc + 2);
            
            delta_raw = ( (int'(q0) - int'(p0)) * 4 + int'(p1) - int'(q1) + 4 ) >>> 3;
            
            // Clip3(-tc, tc, delta_raw)
            if (delta_raw < -tc) delta = -tc;
            else if (delta_raw > tc) delta = tc;
            else delta = delta_raw;

            exp.p0_f = clip1(int'(p0) + delta);
            exp.q0_f = clip1(int'(q0) - delta);
            exp.modified = (tc != 0) ? 1'b1 : 1'b0;
        end else begin
            // BS=0 or BS=1 -> bypass filtering for chroma
            exp.p0_f = p0;
            exp.q0_f = q0;
            exp.modified = 1'b0;
        end
        
        return exp;
    endfunction

    //-------------------------------------------------------------------------
    // Scoreboard & Checkers
    //-------------------------------------------------------------------------
    int total_tested = 0;
    int total_errors = 0;

    always @(posedge clk) begin
        if (rst_n) begin
            // Randomize out_ready to aggressively test pipeline backpressure
            out_ready <= $urandom_range(0, 100) > 30; // 70% ready rate
            
            if (out_valid && out_ready) begin
                automatic expected_t exp;
                if (exp_queue.size() == 0) begin
                    $display("ERROR: out_valid asserted but no data expected!");
                    $finish;
                end
                exp = exp_queue.pop_front();
                
                total_tested++;
                
                if (p0_f !== exp.p0_f || q0_f !== exp.q0_f || 
                    p1_pass !== exp.p1_pass || q1_pass !== exp.q1_pass || 
                    modified !== exp.modified) begin
                    
                    $display("ERROR %0d: Expected p0=%0d q0=%0d mod=%0b | Got p0=%0d q0=%0d mod=%0b", 
                             total_tested, exp.p0_f, exp.q0_f, exp.modified, p0_f, q0_f, modified);
                    total_errors++;
                end
            end
        end
    end

    //-------------------------------------------------------------------------
    // Driver Task
    //-------------------------------------------------------------------------
    task automatic drive_edge(
        input logic [1:0] i_bs, input logic [5:0] i_qp, 
        input logic [`PIXEL_WIDTH-1:0] i_p0, i_p1, i_q0, i_q1
    );
        // Compute and queue expected response FIRST to avoid simulation race conditions
        exp_queue.push_back(compute_golden(i_bs, i_qp, i_p0, i_p1, i_q0, i_q1));

        // Drive inputs
        in_valid <= 1'b1;
        bs <= i_bs;
        edge_qp <= i_qp;
        p0 <= i_p0; p1 <= i_p1;
        q0 <= i_q0; q1 <= i_q1;
        comp <= 2'd1; // Cb or Cr doesn't matter for this unit
        
        // Wait for DUT to accept the transaction
        @(posedge clk);
        while (!in_ready) @(posedge clk);
        
        in_valid <= 1'b0;
    endtask

    //-------------------------------------------------------------------------
    // Test Sequence
    //-------------------------------------------------------------------------
    initial begin
        // Init
        in_valid = 0; out_ready = 1;
        bs = 0; edge_qp = 0; comp = 0;
        p0 = 0; p1 = 0; q0 = 0; q1 = 0;
        rst_n = 0;
        
        repeat(5) @(posedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);

        $display("=== Starting db_filter_chroma unit tests ===");

        // Test 1: BS=0 (No filtering)
        drive_edge(0, 30, 100, 110, 150, 140);
        
        // Test 2: BS=1 (No filtering for Chroma)
        drive_edge(1, 30, 100, 110, 150, 140);
        
        // Test 3: BS=2 (Filtering, small difference)
        drive_edge(2, 35, 500, 502, 504, 501);
        
        // Test 4: BS=2 (Filtering, high QP, large difference clipping to TC)
        drive_edge(2, 45, 500, 500, 600, 600);

        // Test 5: Back-to-Back Random Stimulus Pipeline Stress Test
        for (int i = 0; i < 5000; i++) begin
            // Optionally insert idle cycles
            if ($urandom_range(0, 100) > 80) begin
                in_valid <= 1'b0;
                @(posedge clk);
            end
            drive_edge(
                $urandom_range(0, 2),        // bs
                $urandom_range(0, 51),       // qp
                $urandom_range(0, 1023),     // p0
                $urandom_range(0, 1023),     // p1
                $urandom_range(0, 1023),     // q0
                $urandom_range(0, 1023)      // q1
            );
        end


        // Drain pipeline
        in_valid <= 1'b0;
        
        repeat(20) @(posedge clk); // wait for pipeline to flush
        
        if (total_errors == 0)
            $display("\n=== ALL DB_FILTER_CHROMA TESTS PASSED (%0d tests) ===", total_tested);
        else
            $display("\n=== DB_FILTER_CHROMA TESTS FAILED: %0d errors out of %0d tests ===", total_errors, total_tested);
            
        $finish;
    end

endmodule
