//=============================================================================
// tb_ctu_partitioner.sv
// Testbench for CTU Quadtree CU Split Decision
//
// Verifies:
//   1. Exact HM Z-scan order (Morton code) generation (Child 0 -> Child 3).
//   2. Stack push/pop bounds and coordinate mathematics.
//   3. Accurate `cu_is_last_in_ctu` flagging on the final leaf.
//   4. Handshake stall tolerance (randomized cu_ready and split_valid).
//=============================================================================

`timescale 1ns/1ps

module tb_ctu_partitioner;

    logic clk;
    logic rst_n;

    // CTU input
    logic        ctu_valid;
    logic        ctu_ready;
    logic [15:0] ctu_addr;
    logic [9:0]  ctu_x, ctu_y, poc;
    logic [1:0]  slice_type;
    logic [5:0]  qp;

    // CU output
    logic        cu_valid;
    logic        cu_ready;
    logic [5:0]  cu_x_out, cu_y_out;
    logic [6:0]  cu_size;
    logic [1:0]  cu_depth;
    logic [15:0] cu_ctu_addr;
    logic [9:0]  cu_ctu_x, cu_ctu_y, cu_poc;
    logic [1:0]  cu_slice_type;
    logic [5:0]  cu_qp;
    logic        cu_is_last_in_ctu;

    // Split feedback
    logic        split_valid;
    logic        split_flag;
    logic        split_ready;

    //=========================================================================
    // DUT Instantiation
    //=========================================================================
    ctu_partitioner dut (
        .clk(clk), .rst_n(rst_n),
        .ctu_valid(ctu_valid), .ctu_ready(ctu_ready),
        .cu_valid(cu_valid), .cu_ready(cu_ready),
        .cu_x(cu_x_out), .cu_y(cu_y_out), .cu_size(cu_size), .cu_depth(cu_depth),
        .cu_is_last_in_ctu(cu_is_last_in_ctu),
        .split_valid(split_valid), .split_flag(split_flag), .split_ready(split_ready)
    );

    initial begin
        clk = 0;
        forever #4 clk = ~clk; // 125 MHz
    end

    //=========================================================================
    // Recursive Golden Model (Z-Scan Equivalent)
    //=========================================================================
    typedef struct {
        int x, y, size, depth;
        bit split;     // Decision TB will make
    } eval_t;
    
    eval_t exp_q[$];

    // Recursively generates the expected CU sequence
    function automatic void gen_tree(int x, int y, int size, int depth, int target_depth);
        eval_t cur;
        int h;
        cur.x = x; cur.y = y; cur.size = size; cur.depth = depth;
        
        // Force leaf at target_depth or at min CU size (8x8)
        if (depth == target_depth || size <= 8) begin
            cur.split = 0;
            exp_q.push_back(cur);
        end else begin
            cur.split = 1;
            exp_q.push_back(cur);
            h = size / 2;
            gen_tree(x,   y,   h, depth+1, target_depth); // Child 0 (TL)
            gen_tree(x+h, y,   h, depth+1, target_depth); // Child 1 (TR)
            gen_tree(x,   y+h, h, depth+1, target_depth); // Child 2 (BL)
            gen_tree(x+h, y+h, h, depth+1, target_depth); // Child 3 (BR)
        end
    endfunction

    //=========================================================================
    // Monitor & Check Process
    //=========================================================================
    int total_errors = 0;
    eval_t exp;
    bit ctu_done_pulse = 0;

    bit decision_q[$];

    reg in_eval;
    reg new_cu_presented_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_eval <= 0;
            new_cu_presented_r <= 0;
        end else begin
            in_eval <= (dut.state == 2'd2);
            new_cu_presented_r <= (dut.state == 2'd2) && !in_eval;
        end
    end

    always @(posedge clk) begin
        // Randomize the CU ready signal to test pipeline back-pressure
        cu_ready <= ($urandom() % 100 < 80); 

        if (cu_is_last_in_ctu) begin
            ctu_done_pulse = 1;
            if (exp_q.size() != 0) begin
                $display("ERROR: cu_is_last_in_ctu pulsed but queue has %0d pending CUs!", exp_q.size());
                total_errors++;
            end
        end

        if (new_cu_presented_r && cu_valid) begin
            if (exp_q.size() == 0) begin
                $display("ERROR: Unexpected CU output from DUT at t=%0t", $time);
                total_errors++;
            end else begin
                exp = exp_q.pop_front();
                $display("Time=%0t | Monitor: Pop CU (%0d,%0d) size=%0d depth=%0d, split=%0d. exp_q left=%0d", 
                         $time, exp.x, exp.y, exp.size, exp.depth, exp.split, exp_q.size());
                decision_q.push_back(exp.split);
                
                // Check coordinates
                if (cu_x_out !== exp.x || cu_y_out !== exp.y || cu_size !== exp.size || cu_depth !== exp.depth) begin
                    $display("ERROR: CU mismatch. Exp=(%0d,%0d) size=%0d depth=%0d | Got=(%0d,%0d) size=%0d depth=%0d",
                             exp.x, exp.y, exp.size, exp.depth, cu_x_out, cu_y_out, cu_size, cu_depth);
                    total_errors++;
                end
            end
        end
    end

    // Separate non-blocking thread to handle split decision feedback
    initial begin
        split_valid = 0;
        split_flag  = 0;
        forever begin
            wait(decision_q.size() > 0);
            $display("Time=%0t | MD Thread: Found decision pending. Delaying...", $time);
            repeat($urandom_range(1, 4)) @(posedge clk);
            @(negedge clk);
            split_valid <= 1'b1;
            split_flag  <= decision_q.pop_front();
            $display("Time=%0t | MD Thread: Asserting split_valid=%0d, split_flag=%0d", $time, 1'b1, split_flag);
            @(posedge clk);
            wait(split_ready);
            $display("Time=%0t | MD Thread: split_ready asserted. Waiting for exit...", $time);
            wait(!split_ready);
            $display("Time=%0t | MD Thread: S_SPLIT exited. Deasserting split_valid.", $time);
            @(negedge clk);
            split_valid <= 1'b0;
        end
    end

    //=========================================================================
    // Test Sequence
    //=========================================================================
    task automatic test_depth(int target_depth);
        $display("Time=%0t | Test Sequence: Starting test_depth(%0d)", $time, target_depth);
        @(negedge clk);
        gen_tree(0, 0, 64, 0, target_depth);
        ctu_done_pulse = 0;
        
        ctu_valid <= 1'b1;
        ctu_addr  <= target_depth; // Just a dummy ID
        @(negedge clk);
        $display("Time=%0t | Test Sequence: Waiting for ctu_ready...", $time);
        wait(ctu_ready);
        ctu_valid <= 1'b0;
        $display("Time=%0t | Test Sequence: ctu_ready seen. Waiting for exp_q empty and ctu_done...", $time);
        
        // Wait until queue is completely drained and completion pulse is seen
        wait(exp_q.size() == 0 && ctu_done_pulse == 1);
        $display("Time=%0t | Test Sequence: test_depth(%0d) finished!", $time, target_depth);
        repeat(10) @(posedge clk);
    endtask

    initial begin
        ctu_valid = 0; cu_ready = 0; split_valid = 0; split_flag = 0;
        rst_n = 0; repeat(4) @(posedge clk);
        rst_n = 1; repeat(2) @(posedge clk);

        test_depth(0); // Test NO SPLIT (single 64x64 CU)
        test_depth(1); // Test DEPTH 1 (four 32x32 CUs)
        test_depth(3); // Test FULL SPLIT (sixty-four 8x8 CUs)

        if (total_errors == 0) $display("=== ALL CTU PARTITION TESTS PASSED ===");
        else                   $display("=== TESTS FAILED: %0d Errors ===", total_errors);
        $finish;
    end
endmodule