//=============================================================================
// tb_boundary_strength.sv
// Testbench for Deblocking Filter Boundary Strength (BS) Calculation
//
// Verifies:
//   1. BS=2 for Intra blocks.
//   2. BS=1 for Residual presence (CBF).
//   3. BS=1 for Reference Picture mismatch (ref_idx or uni vs bi-pred).
//   4. BS=1 for MV mismatch >= 1 integer pel (4 quarter-pel units).
//   5. BS=0 for identical inter blocks.
//   6. Bi-predictive swapped reference list tracking.
//=============================================================================

`timescale 1ns/1ps

module tb_boundary_strength;

    logic clk;
    logic rst_n;

    // Handshake
    logic in_valid;
    logic in_ready;
    logic out_valid;
    logic out_ready;

    // Edge parameters
    logic is_vertical;
    logic is_ctu_boundary;

    // P-side
    logic        p_is_intra;
    logic [5:0]  p_qp;
    logic        p_cbf_luma;
    logic        p_cbf_chroma;
    logic [2:0]  p_ref_idx_l0;
    logic [2:0]  p_ref_idx_l1;
    logic        p_bi_pred;
    logic signed [15:0] p_mvx_l0, p_mvy_l0;
    logic signed [15:0] p_mvx_l1, p_mvy_l1;

    // Q-side
    logic        q_is_intra;
    logic [5:0]  q_qp;
    logic        q_cbf_luma;
    logic        q_cbf_chroma;
    logic [2:0]  q_ref_idx_l0;
    logic [2:0]  q_ref_idx_l1;
    logic        q_bi_pred;
    logic signed [15:0] q_mvx_l0, q_mvy_l0;
    logic signed [15:0] q_mvx_l1, q_mvy_l1;

    // Outputs
    logic [5:0] edge_qp;
    logic [1:0] bs;

    //=========================================================================
    // DUT Instantiation
    //=========================================================================
    boundary_strength dut (.*);

    // Clock generation
    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100 MHz
    end

    //=========================================================================
    // Golden Model & Checking Logic
    //=========================================================================
    typedef struct {
        logic [1:0] exp_bs;
        logic [5:0] exp_qp;
    } exp_res_t;

    exp_res_t exp_q[$];
    int total_errors = 0;
    int total_tested = 0;

    function automatic int abs_diff(int a, int b);
        return (a > b) ? (a - b) : (b - a);
    endfunction

    // Predicts the correct BS value based on HEVC Spec Table 8-10
    function automatic logic [1:0] get_expected_bs();
        bit ref_str, ref_swp;
        bit diff_str, diff_swp;

        // Rule 1: Intra = 2
        if (p_is_intra || q_is_intra) return 2'd2;
        
        // Rule 2: Residual = 1
        if (p_cbf_luma || q_cbf_luma) return 2'd1;
        
        // Rule 3: Different number of references
        if (p_bi_pred != q_bi_pred) return 2'd1;

        // Rule 4: Reference Index mismatches
        ref_str = (p_ref_idx_l0 == q_ref_idx_l0) && (p_ref_idx_l1 == q_ref_idx_l1);
        ref_swp = (p_ref_idx_l0 == q_ref_idx_l1) && (p_ref_idx_l1 == q_ref_idx_l0);
        
        if (!ref_str && !ref_swp) return 2'd1; 

        // Rule 5: MV difference >= 4 quarter-pels
        diff_str = (abs_diff(p_mvx_l0, q_mvx_l0) >= 4) || (abs_diff(p_mvy_l0, q_mvy_l0) >= 4) ||
                   (p_bi_pred && q_bi_pred && ((abs_diff(p_mvx_l1, q_mvx_l1) >= 4) || (abs_diff(p_mvy_l1, q_mvy_l1) >= 4)));
                   
        diff_swp = (abs_diff(p_mvx_l0, q_mvx_l1) >= 4) || (abs_diff(p_mvy_l0, q_mvy_l1) >= 4) ||
                   (abs_diff(p_mvx_l1, q_mvx_l0) >= 4) || (abs_diff(p_mvy_l1, q_mvy_l0) >= 4);

        if (p_bi_pred && q_bi_pred) begin
            if (ref_str && ref_swp) return (diff_str && diff_swp) ? 2'd1 : 2'd0;
            if (ref_str)            return diff_str ? 2'd1 : 2'd0;
            if (ref_swp)            return diff_swp ? 2'd1 : 2'd0;
        end else begin
            return diff_str ? 2'd1 : 2'd0;
        end
        
        return 2'd0;
    endfunction

    exp_res_t exp_in;
    exp_res_t exp_out;

    // Pushes current inputs into expected queue
    always @(posedge clk) begin
        if (in_valid && in_ready) begin
            exp_in.exp_bs = get_expected_bs();
            exp_in.exp_qp = (p_qp + q_qp + 1) / 2;
            exp_q.push_back(exp_in);
        end
    end

    // Pops and checks outputs
    always @(posedge clk) begin
        out_ready <= ($urandom % 100 < 80); // 80% ready rate to test backpressure

        if (out_valid && out_ready) begin
            if (exp_q.size() == 0) begin
                $display("ERROR at %0t: Unexpected output from DUT!", $time);
                total_errors++;
            end else begin
                exp_out = exp_q.pop_front();
                total_tested++;
                
                if (bs !== exp_out.exp_bs || edge_qp !== exp_out.exp_qp) begin
                    $display("ERROR at %0t: Expected BS=%0d QP=%0d | Got BS=%0d QP=%0d", 
                             $time, exp_out.exp_bs, exp_out.exp_qp, bs, edge_qp);
                    total_errors++;
                end
            end
        end
    end

    //=========================================================================
    // Test Sequence
    //=========================================================================
    task automatic drive_defaults();
        p_is_intra = 0; q_is_intra = 0;
        p_qp = 32;      q_qp = 32;
        p_cbf_luma = 0; q_cbf_luma = 0;
        p_bi_pred = 0;  q_bi_pred = 0;
        p_ref_idx_l0 = 0; p_ref_idx_l1 = 1;
        q_ref_idx_l0 = 0; q_ref_idx_l1 = 1;
        p_mvx_l0 = 0; p_mvy_l0 = 0; p_mvx_l1 = 0; p_mvy_l1 = 0;
        q_mvx_l0 = 0; q_mvy_l0 = 0; q_mvx_l1 = 0; q_mvy_l1 = 0;
    endtask

    task automatic send_edge();
        in_valid <= 1;
        @(posedge clk);
        while (!in_ready) @(posedge clk);
        in_valid <= 0;
    endtask

    initial begin
        in_valid = 0;
        out_ready = 1;
        drive_defaults();

        rst_n = 0;
        repeat(3) @(posedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);

        $display("=== STARTING BOUNDARY STRENGTH TESTS ===");

        // TEST 1: Identical inter blocks (BS=0)
        drive_defaults();
        send_edge();

        // TEST 2: Intra P-side (BS=2)
        drive_defaults();
        p_is_intra = 1;
        send_edge();

        // TEST 3: Intra Q-side (BS=2)
        drive_defaults();
        q_is_intra = 1;
        send_edge();

        // TEST 4: Residuals (BS=1)
        drive_defaults();
        p_cbf_luma = 1;
        send_edge();
        
        drive_defaults();
        q_cbf_luma = 1;
        send_edge();

        // TEST 5: Ref list mismatch (BS=1)
        drive_defaults();
        p_ref_idx_l0 = 2; // differs from q
        send_edge();

        // TEST 6: Bi-pred swapped refs matching (BS=0)
        drive_defaults();
        p_bi_pred = 1; q_bi_pred = 1;
        p_ref_idx_l0 = 0; p_ref_idx_l1 = 1;
        q_ref_idx_l0 = 1; q_ref_idx_l1 = 0; // Swapped!
        p_mvx_l0 = 10; q_mvx_l1 = 10; // Swapped MV matches
        p_mvx_l1 = 5;  q_mvx_l0 = 5; 
        send_edge();

        // TEST 7: MV Difference >= 4 (BS=1)
        drive_defaults();
        p_mvx_l0 = 12;
        q_mvx_l0 = 8; // Differs by 4 exactly
        send_edge();

        // TEST 8: Constrained Random Fuzzing
        for (int i=0; i<1000; i++) begin
            p_is_intra = $urandom() % 2;
            q_is_intra = $urandom() % 2;
            p_cbf_luma = $urandom() % 2;
            q_cbf_luma = $urandom() % 2;
            p_bi_pred  = $urandom() % 2;
            q_bi_pred  = $urandom() % 2;
            
            p_ref_idx_l0 = $urandom_range(0, 7);
            p_ref_idx_l1 = $urandom_range(0, 7);
            q_ref_idx_l0 = $urandom_range(0, 7);
            q_ref_idx_l1 = $urandom_range(0, 7);
            
            p_mvx_l0 = $urandom_range(0, 40) - 20; // Bound to [-20: 20]
            p_mvy_l0 = $urandom_range(0, 200) - 100;
            p_mvx_l1 = $urandom_range(0, 200) - 100;
            p_mvy_l1 = $urandom_range(0, 200) - 100;
            
            q_mvx_l0 = $urandom_range(0, 40) - 20; // Bound to [-20: 20]
            q_mvy_l0 = $urandom_range(0, 200) - 100;
            q_mvx_l1 = $urandom_range(0, 200) - 100;
            q_mvy_l1 = $urandom_range(0, 200) - 100;
            
            send_edge();
        end

        // Wait for drain
        while(exp_q.size() > 0) @(posedge clk);
        
        if (total_errors == 0) $display("=== TESTS PASSED: %0d vectors tested ===", total_tested);
        else                   $display("=== TESTS FAILED: %0d errors ===", total_errors);
        $finish;
    end
endmodule