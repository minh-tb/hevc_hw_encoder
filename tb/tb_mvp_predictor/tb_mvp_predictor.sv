//=============================================================================
// tb_mvp_predictor.sv
// Testbench for AMVP and Merge Candidate List Builder
// 
// Verifies:
// 1. AMVP Left Group priority (A0 -> A1)
// 2. AMVP Above Group priority (B0 -> B1 -> B2)
// 3. AMVP De-duplication and zero padding
// 4. Merge Priority (A1 -> B1 -> B0 -> A0 -> B2)
// 5. HEVC Strict Merge Pruning:
//    - B1 != A1
//    - B0 != B1
//    - A0 != A1
//    - B2 != A1 && B2 != B1
//=============================================================================

`timescale 1ns/1ps

module tb_mvp_predictor;

    // TB Parameters
    parameter MV_W      = 10;
    parameter RIF_W     = 4;
    parameter N_MERGE   = 5;
    parameter N_NBR     = 5;

    parameter NBR_A1    = 0;
    parameter NBR_A0    = 1;
    parameter NBR_B1    = 2;
    parameter NBR_B0    = 3;
    parameter NBR_B2    = 4;

    logic clk;
    logic rst_n;
    logic valid_in;

    // DUT Inputs
    logic [RIF_W-1:0]       target_ref_idx;
    logic [4:0]             nbr_inter;
    logic [MV_W*N_NBR-1:0]  nbr_mv_x_flat;
    logic [MV_W*N_NBR-1:0]  nbr_mv_y_flat;
    logic [RIF_W*N_NBR-1:0] nbr_ref_flat;

    // DUT Outputs
    logic                     valid_out;
    logic [MV_W*2-1:0]        amvp_mv_x_flat;
    logic [MV_W*2-1:0]        amvp_mv_y_flat;
    logic [N_MERGE-1:0]       merge_valid;
    logic [MV_W*N_MERGE-1:0]  merge_mv_x_flat;
    logic [MV_W*N_MERGE-1:0]  merge_mv_y_flat;
    logic [RIF_W*N_MERGE-1:0] merge_ref_flat;

    // DUT Instantiation
    mvp_predictor #(
        .MV_W(MV_W),
        .RIF_W(RIF_W),
        .N_MERGE(N_MERGE),
        .N_NBR(N_NBR)
    ) dut (.*);

    // Clock Generation
    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100 MHz
    end

    //-------------------------------------------------------------------------
    // Helper Tasks
    //-------------------------------------------------------------------------
    task set_neighbor(input int idx, input logic inter, input int mvx, input int mvy, input int ref_idx);
        nbr_inter[idx] = inter;
        nbr_mv_x_flat[MV_W*idx +: MV_W] = mvx[MV_W-1:0];
        nbr_mv_y_flat[MV_W*idx +: MV_W] = mvy[MV_W-1:0];
        nbr_ref_flat[RIF_W*idx +: RIF_W] = ref_idx[RIF_W-1:0];
    endtask

    task clear_all_neighbors();
        nbr_inter     = 0;
        nbr_mv_x_flat = 0;
        nbr_mv_y_flat = 0;
        nbr_ref_flat  = 0;
    endtask

    int total_errors = 0;

    task check_amvp(input int exp_x0, input int exp_y0, input int exp_x1, input int exp_y1);
        logic signed [MV_W-1:0] got_x0, got_y0, got_x1, got_y1;
        got_x0 = amvp_mv_x_flat[MV_W*0 +: MV_W];
        got_y0 = amvp_mv_y_flat[MV_W*0 +: MV_W];
        got_x1 = amvp_mv_x_flat[MV_W*1 +: MV_W];
        got_y1 = amvp_mv_y_flat[MV_W*1 +: MV_W];

        if (got_x0 !== exp_x0 || got_y0 !== exp_y0 || got_x1 !== exp_x1 || got_y1 !== exp_y1) begin
            $display("ERROR [AMVP] Expected: (0: %0d,%0d), (1: %0d,%0d) | Got: (0: %0d,%0d), (1: %0d,%0d)",
                     exp_x0, exp_y0, exp_x1, exp_y1, got_x0, got_y0, got_x1, got_y1);
            total_errors++;
        end else begin
            $display("PASS  [AMVP] Got expected: (0: %0d,%0d), (1: %0d,%0d)", got_x0, got_y0, got_x1, got_y1);
        end
    endtask

    task check_merge(input int idx, input int exp_v, input int exp_x, input int exp_y, input int exp_r);
        logic got_v;
        logic signed [MV_W-1:0] got_x, got_y;
        logic [RIF_W-1:0] got_r;
        
        got_v = merge_valid[idx];
        got_x = merge_mv_x_flat[MV_W*idx +: MV_W];
        got_y = merge_mv_y_flat[MV_W*idx +: MV_W];
        got_r = merge_ref_flat[RIF_W*idx +: RIF_W];

        if (got_v !== exp_v || got_x !== exp_x || got_y !== exp_y || got_r !== exp_r) begin
            $display("ERROR [Merge %0d] Expected: v=%0d, mv=(%0d,%0d), r=%0d | Got: v=%0d, mv=(%0d,%0d), r=%0d",
                     idx, exp_v, exp_x, exp_y, exp_r, got_v, got_x, got_y, got_r);
            total_errors++;
        end else begin
            $display("PASS  [Merge %0d] Got expected: v=%0d, mv=(%0d,%0d), r=%0d", idx, got_v, got_x, got_y, got_r);
        end
    endtask

    //-------------------------------------------------------------------------
    // Main Stimulus
    //-------------------------------------------------------------------------
    initial begin
        valid_in = 0;
        rst_n = 0;
        target_ref_idx = 0;
        clear_all_neighbors();
        
        #20 rst_n = 1;
        #10;
        
        $display("=============================================================");
        $display("=== TEST 1: All Unavailable (Zero Padding)                 ===");
        $display("=============================================================");
        valid_in = 1;
        clear_all_neighbors();
        @(posedge clk); valid_in = 0; @(posedge clk);
        check_amvp(0,0, 0,0);
        check_merge(0, 0, 0,0,0);
        check_merge(1, 0, 0,0,0);
        check_merge(4, 0, 0,0,0);


        $display("\n=============================================================");
        $display("=== TEST 2: AMVP Priority (A0 over A1, B0 over B1 over B2) ===");
        $display("=============================================================");
        valid_in = 1;
        target_ref_idx = 2; // Searching for reference index 2
        
        // Left Group
        set_neighbor(NBR_A1, 1, 11, 11, 2); // A1 valid match
        set_neighbor(NBR_A0, 1, 10, 10, 2); // A0 valid match (Should win over A1)
        
        // Above Group
        set_neighbor(NBR_B2, 1, 22, 22, 2); // B2 match
        set_neighbor(NBR_B1, 1, 21, 21, 2); // B1 match
        set_neighbor(NBR_B0, 1, 20, 20, 2); // B0 match (Should win over B1 and B2)
        
        @(posedge clk); valid_in = 0; @(posedge clk);
        check_amvp(10, 10, 20, 20);


        $display("\n=============================================================");
        $display("=== TEST 3: AMVP De-duplication                            ===");
        $display("=============================================================");
        valid_in = 1;
        clear_all_neighbors();
        target_ref_idx = 1;
        
        // Left Group winner (A0)
        set_neighbor(NBR_A0, 1, 55, 66, 1);
        // Above Group winner (B1)
        set_neighbor(NBR_B1, 1, 55, 66, 1); // Same as Left Group
        
        @(posedge clk); valid_in = 0; @(posedge clk);
        // Second candidate should be zeroed out
        check_amvp(55, 66, 0, 0); 


        $display("\n=============================================================");
        $display("=== TEST 4: Merge Base Order (A1->B1->B0->A0->B2)          ===");
        $display("=============================================================");
        valid_in = 1;
        clear_all_neighbors();
        
        set_neighbor(NBR_A1, 1,  1,  1, 1); // 1st
        set_neighbor(NBR_B1, 1,  2,  2, 2); // 2nd
        set_neighbor(NBR_B0, 1,  3,  3, 3); // 3rd
        set_neighbor(NBR_A0, 1,  4,  4, 4); // 4th
        set_neighbor(NBR_B2, 1,  5,  5, 5); // 5th (Should be dropped)
        
        @(posedge clk); valid_in = 0; @(posedge clk);
        check_merge(0, 1,  1, 1, 1); // A1
        check_merge(1, 1,  2, 2, 2); // B1
        check_merge(2, 1,  3, 3, 3); // B0
        check_merge(3, 1,  4, 4, 4); // A0
        check_merge(4, 0,  0, 0, 0); // B2 dropped (HEVC specifies max 4 spatial candidates)


        $display("\n=============================================================");
        $display("=== TEST 4b: Merge B2 Added if < 4 Spatial Candidates      ===");
        $display("=============================================================");
        valid_in = 1;
        clear_all_neighbors();
        
        set_neighbor(NBR_A1, 1,  1,  1, 1); // 1st
        set_neighbor(NBR_B1, 1,  2,  2, 2); // 2nd
        set_neighbor(NBR_B0, 1,  3,  3, 3); // 3rd
        // A0 intentionally left unavailable
        set_neighbor(NBR_B2, 1,  5,  5, 5); // 4th
        
        @(posedge clk); valid_in = 0; @(posedge clk);
        check_merge(0, 1,  1, 1, 1); // A1
        check_merge(1, 1,  2, 2, 2); // B1
        check_merge(2, 1,  3, 3, 3); // B0
        check_merge(3, 1,  5, 5, 5); // B2 takes 4th slot
        check_merge(4, 0,  0, 0, 0); // Padded zero


        $display("\n=============================================================");
        $display("=== TEST 5: Merge Strict Pruning - Rule 1 (B1 != A1)       ===");
        $display("=============================================================");
        valid_in = 1;
        clear_all_neighbors();
        set_neighbor(NBR_A1, 1, 10, 10, 1);
        set_neighbor(NBR_B1, 1, 10, 10, 1); // Duplicate of A1 -> PRUNE
        set_neighbor(NBR_B0, 1, 30, 30, 3); 
        
        @(posedge clk); valid_in = 0; @(posedge clk);
        check_merge(0, 1, 10, 10, 1); // A1
        check_merge(1, 1, 30, 30, 3); // B0 jumps up
        check_merge(2, 0,  0,  0, 0); // padded


        $display("\n=============================================================");
        $display("=== TEST 6: Merge Strict Pruning - Rule 2 (B0 != B1)       ===");
        $display("=============================================================");
        valid_in = 1;
        clear_all_neighbors();
        set_neighbor(NBR_A1, 1, 10, 10, 1);
        set_neighbor(NBR_B1, 1, 20, 20, 2);
        set_neighbor(NBR_B0, 1, 20, 20, 2); // Duplicate of B1 -> PRUNE
        set_neighbor(NBR_A0, 1, 40, 40, 4);
        
        @(posedge clk); valid_in = 0; @(posedge clk);
        check_merge(0, 1, 10, 10, 1); // A1
        check_merge(1, 1, 20, 20, 2); // B1
        check_merge(2, 1, 40, 40, 4); // A0 jumps up


        $display("\n=============================================================");
        $display("=== TEST 7: Merge Strict Pruning - Rule 3 (A0 != A1)       ===");
        $display("=============================================================");
        valid_in = 1;
        clear_all_neighbors();
        set_neighbor(NBR_A1, 1, 10, 10, 1);
        set_neighbor(NBR_B1, 1, 20, 20, 2);
        set_neighbor(NBR_B0, 1, 30, 30, 3);
        set_neighbor(NBR_A0, 1, 10, 10, 1); // Duplicate of A1 -> PRUNE
        set_neighbor(NBR_B2, 1, 50, 50, 5);
        
        @(posedge clk); valid_in = 0; @(posedge clk);
        check_merge(0, 1, 10, 10, 1); // A1
        check_merge(1, 1, 20, 20, 2); // B1
        check_merge(2, 1, 30, 30, 3); // B0
        check_merge(3, 1, 50, 50, 5); // B2 jumps up


        $display("\n=============================================================");
        $display("=== TEST 8: Merge Strict Pruning - Rule 4 (B2!=A1, B2!=B1) ===");
        $display("=============================================================");
        valid_in = 1;
        clear_all_neighbors();
        set_neighbor(NBR_A1, 1, 10, 10, 1);
        set_neighbor(NBR_B1, 1, 20, 20, 2);
        set_neighbor(NBR_B2, 1, 20, 20, 2); // Duplicate of B1 -> PRUNE
        
        @(posedge clk); valid_in = 0; @(posedge clk);
        check_merge(0, 1, 10, 10, 1); // A1
        check_merge(1, 1, 20, 20, 2); // B1
        check_merge(2, 0,  0,  0, 0); // B2 was pruned, padded zero


        $display("\n=============================================================");
        if (total_errors == 0)
            $display("=== ALL MVP/MERGE TESTS PASSED SUCCESSFULLY! ===");
        else
            $display("=== TESTS FAILED: %0d Errors ===", total_errors);
        $display("=============================================================");
        
        $finish;
    end

endmodule