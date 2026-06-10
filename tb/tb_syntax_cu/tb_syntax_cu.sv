//=============================================================================
// tb_syntax_cu.sv
// Testbench for CU-Level CABAC Syntax Element Encoder
//=============================================================================

`timescale 1ns/1ps

module tb_syntax_cu;

    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
    logic        clk;
    logic        rst_n;

    logic        cu_valid;
    logic        cu_done;

    logic [1:0]  cu_depth;
    logic        cu_is_split;
    logic        slice_is_intra;
    logic        cu_skip;
    logic        cu_merge;
    logic [2:0]  cu_merge_idx;
    logic        cu_pred_intra;
    logic [1:0]  cu_part_mode;
    logic        cu_cbf;
    logic [1:0]  cu_skip_ctx;

    logic        bin_valid;
    logic        bin_value;
    logic [7:0]  bin_ctx_id;
    logic        bin_is_ep;
    logic        bin_rdy;

    // -------------------------------------------------------------------------
    // DUT Instantiation
    // -------------------------------------------------------------------------
    syntax_cu #(
        .CTX_ID_W(8)
    ) dut (
        .*
    );

    // -------------------------------------------------------------------------
    // Clock Generation
    // -------------------------------------------------------------------------
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // -------------------------------------------------------------------------
    // Output Bin Capture Queue
    // -------------------------------------------------------------------------
    typedef struct packed {
        logic       val;
        logic [7:0] ctx;
        logic       ep;
    } bin_t;

    bin_t bin_q[$];

    always_ff @(posedge clk) begin
        if (bin_valid && bin_rdy) begin
            bin_t b;
            b.val = bin_value;
            b.ctx = bin_ctx_id;
            b.ep  = bin_is_ep;
            bin_q.push_back(b);
        end
    end

    // Helper to generate expected bins
    function automatic bin_t make_bin(logic v, logic [7:0] c, logic e);
        bin_t b; b.val = v; b.ctx = c; b.ep = e; return b;
    endfunction

    // -------------------------------------------------------------------------
    // Test Task
    // -------------------------------------------------------------------------
    int errors = 0;

    task test_cu(
        input logic [1:0] t_depth,
        input logic       t_split,
        input logic       t_intra_slice,
        input logic       t_skip,
        input logic       t_merge,
        input logic [2:0] t_merge_idx,
        input logic       t_pred_intra,
        input logic [1:0] t_part_mode,
        input logic       t_cbf,
        input logic [1:0] t_skip_ctx,
        input bin_t       expected_bins[]
    );
        #1;
        cu_depth       = t_depth;
        cu_is_split    = t_split;
        slice_is_intra = t_intra_slice;
        cu_skip        = t_skip;
        cu_merge       = t_merge;
        cu_merge_idx   = t_merge_idx;
        cu_pred_intra  = t_pred_intra;
        cu_part_mode   = t_part_mode;
        cu_cbf         = t_cbf;
        cu_skip_ctx    = t_skip_ctx;
        
        cu_valid = 1'b1;
        @(posedge clk); #1;
        cu_valid = 1'b0;

        // Wait for FSM to complete the CU encoding
        while (!cu_done) @(posedge clk);
        #1;

        // Check lengths
        if (bin_q.size() != expected_bins.size()) begin
            $display("ERROR: Bin count mismatch! Expected %0d bins, got %0d bins.", expected_bins.size(), bin_q.size());
            errors++;
        end else begin
            // Check contents
            for (int i = 0; i < expected_bins.size(); i++) begin
                if (bin_q[i] !== expected_bins[i]) begin
                    $display("ERROR: Bin %0d mismatch. Exp: {val=%b, ctx=%0d, ep=%b}, Got: {val=%b, ctx=%0d, ep=%b}",
                        i, expected_bins[i].val, expected_bins[i].ctx, expected_bins[i].ep,
                        bin_q[i].val, bin_q[i].ctx, bin_q[i].ep);
                    errors++;
                end
            end
        end
        
        // Clear the queue for the next test
        bin_q.delete();
        @(posedge clk);
    endtask

    // -------------------------------------------------------------------------
    // Main Test Sequence
    // -------------------------------------------------------------------------
    initial begin
        // Initialization
        rst_n = 0; cu_valid = 0; bin_rdy = 0;
        cu_depth = 0; cu_is_split = 0; slice_is_intra = 0; cu_skip = 0;
        cu_merge = 0; cu_merge_idx = 0; cu_pred_intra = 0; cu_part_mode = 0;
        cu_cbf = 0; cu_skip_ctx = 0;

        #20 rst_n = 1; bin_rdy = 1; // Assert bin_rdy to allow continuous streaming
        @(posedge clk);
        $display("=== Starting syntax_cu Testbench ===");

        $display("--- Test 1: Split CU ---");
        // Expecting: split_flag=1 (ctx = CTX_SPLIT_0 + depth=0)
        test_cu(0, 1, 0, 0, 0, 0, 0, 0, 0, 0, '{ make_bin(1, 0, 0) });

        $display("--- Test 2: I-Slice Intra CU (Depth 3, 2Nx2N) ---");
        // Expecting: split_flag=0(ctx=3), part_mode_0=1(ctx=10) -> DONE
        test_cu(3, 0, 1, 0, 0, 0, 1, 0, 1, 0, '{ make_bin(0, 3, 0), make_bin(1, 10, 0) });

        $display("--- Test 3: Inter Skip CU (merge_idx = 2, skip_ctx = 1) ---");
        // Expecting: split_flag=0(ctx=1), skip_flag=1(ctx=5), merge_idx0=1(ctx=8), merge_idx1=1(ep=1), merge_idx2=0(ep=1)
        test_cu(1, 0, 0, 1, 0, 2, 0, 0, 0, 1, '{
            make_bin(0, 1, 0), make_bin(1, 5, 0), make_bin(1, 8, 0), make_bin(1, 0, 1), make_bin(0, 0, 1)
        });

        $display("--- Test 4: Inter Standard CU (Nx2N, cbf=0) ---");
        // Expecting: split_flag=0(ctx=2), skip_flag=0(ctx=4), merge_flag=0(ctx=7), pred_mode=0(ctx=9), 
        // part0=0(ctx=10), part1=0(ctx=11), part2=1(ctx=12), cbf=0(ctx=14)
        test_cu(2, 0, 0, 0, 0, 0, 0, 2, 0, 0, '{
            make_bin(0, 2, 0), make_bin(0, 4, 0), make_bin(0, 7, 0), make_bin(0, 9, 0),
            make_bin(0, 10, 0), make_bin(0, 11, 0), make_bin(1, 12, 0), make_bin(0, 14, 0)
        });

        if (errors == 0) $display("=== [PASS] All syntax_cu tests passed! ===");
        else             $display("=== [FAIL] %0d errors found ===", errors);
        $finish;
    end
endmodule