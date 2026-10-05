//=============================================================================
// tb_flaw_amvp.sv
// Dual-State Algorithmic Verification Testbench for Flaw D-01: AMVP Zero Tie-off
//
// Normative Reference:
//   - ITU-T H.265 (Main10 Profile) Clause 8.5.3.1 (Derivation process for
//     motion vector predictor candidates)
//   - HM 18.0 Reference Software: TComDataCU.cpp :: fillMvpCand()
//
// Target Bug:
//   In rtl/top/hevc_encoder_top.v lines 229-230, 1592-1596, 2818-2823:
//     wire [19:0] amvp_mv_x_flat = 20'd0;
//     wire [19:0] amvp_mv_y_flat = 20'd0;
//     mvp_x_qp = amvp_mv_x_flat[9:0]; // hardwired to 0
//     mvd_l0_x = latched_cu_mv_x - mvp_x_qp; // encodes MVD = MV_enc - 0
//
// Dual-State Protocol:
//   - Default (Buggy State): Simulates hardware zero tie-off. Compares encoder
//     MVD and resulting decoder reconstructed MV against ITU-T H.265 / HM 18.0.
//     Asserts non-zero decoder reconstruction drift, demonstrates failure,
//     and exits with error code.
//   - Remediated State (+define+REMEDIATION): Connects compliant mvp_predictor
//     module. Confirms bit-exact MVP derivation and zero decoder drift.
//     Emits '*** ALL TESTS PASSED ***' with exit code 0.
//=============================================================================

`timescale 1ns/1ps
`include "parameter_pkg.vh"

module tb_flaw_amvp;

    parameter MV_W    = `MV_TOTAL_BITS - `MV_FRAC_BITS; // 10 bits integer-pel
    parameter RIF_W   = 4;                              // 4-bit reference index
    parameter N_MERGE = 5;
    parameter N_NBR   = 5;

    // Spatial Neighbor Index Mapping per HEVC Clause 8.5.3.1
    localparam NBR_A1 = 0; // directly left
    localparam NBR_A0 = 1; // bottom-left
    localparam NBR_B1 = 2; // directly above
    localparam NBR_B0 = 3; // above-right
    localparam NBR_B2 = 4; // above-left

    logic clk;
    logic rst_n;
    logic valid_in;

    // Target reference index
    logic [RIF_W-1:0]       target_ref_idx;

    // Spatial Neighbor inputs (5 neighbors)
    logic [4:0]             nbr_inter;
    logic [MV_W*N_NBR-1:0]  nbr_mv_x_flat;
    logic [MV_W*N_NBR-1:0]  nbr_mv_y_flat;
    logic [RIF_W*N_NBR-1:0] nbr_ref_flat;

    // Wire interfaces for candidate logic
    wire                    dut_valid_out;
    wire [MV_W*2-1:0]       dut_amvp_mv_x_flat;
    wire [MV_W*2-1:0]       dut_amvp_mv_y_flat;
    wire [N_MERGE-1:0]      dut_merge_valid;
    wire [MV_W*N_MERGE-1:0] dut_merge_mv_x_flat;
    wire [MV_W*N_MERGE-1:0] dut_merge_mv_y_flat;
    wire [RIF_W*N_MERGE-1:0] dut_merge_ref_flat;

    // Real mvp_predictor module instance
    mvp_predictor #(
        .MV_W      (MV_W),
        .RIF_W     (RIF_W),
        .N_MERGE   (N_MERGE),
        .N_NBR     (N_NBR)
    ) u_mvp_predictor (
        .clk             (clk),
        .rst_n           (rst_n),
        .valid_in        (valid_in),
        .target_ref_idx  (target_ref_idx),
        .nbr_inter       (nbr_inter),
        .nbr_mv_x_flat   (nbr_mv_x_flat),
        .nbr_mv_y_flat   (nbr_mv_y_flat),
        .nbr_ref_flat    (nbr_ref_flat),
        .valid_out       (dut_valid_out),
        .amvp_mv_x_flat  (dut_amvp_mv_x_flat),
        .amvp_mv_y_flat  (dut_amvp_mv_y_flat),
        .merge_valid     (dut_merge_valid),
        .merge_mv_x_flat (dut_merge_mv_x_flat),
        .merge_mv_y_flat (dut_merge_mv_y_flat),
        .merge_ref_flat  (dut_merge_ref_flat)
    );

    // Simulated Top-Level Integration Bus
    wire [19:0] top_amvp_mv_x_flat;
    wire [19:0] top_amvp_mv_y_flat;

`ifdef REMEDIATION
    // REMEDIATED STATE: Connects genuine mvp_predictor outputs to top datapath
    assign top_amvp_mv_x_flat = dut_amvp_mv_x_flat;
    assign top_amvp_mv_y_flat = dut_amvp_mv_y_flat;
    localparam IS_REMEDIATED = 1;
`else
    // BUGGY STATE: Reproduces rtl/top/hevc_encoder_top.v lines 229-230 hardcoded tie-offs
    assign top_amvp_mv_x_flat = 20'd0;
    assign top_amvp_mv_y_flat = 20'd0;
    localparam IS_REMEDIATED = 0;
`endif

    // Candidate 0 extraction from top-level bus (matches lines 1592-1596)
    wire signed [9:0] enc_mvp_x_qp = top_amvp_mv_x_flat[9:0];
    wire signed [9:0] enc_mvp_y_qp = top_amvp_mv_y_flat[9:0];

    // Clock generator: 100 MHz
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // Watchdog guard to prevent hangs
    initial begin
        #500000;
        $display("\n[FATAL TIMEOUT] Simulation exceeded 500us limit.");
        $finish(2);
    end

    // Helper task: Set neighbor attributes
    task automatic set_neighbor(
        input int idx,
        input logic is_inter,
        input int mvx_val,
        input int mvy_val,
        input int ref_idx
    );
        nbr_inter[idx] = is_inter;
        nbr_mv_x_flat[MV_W*idx +: MV_W] = mvx_val[MV_W-1:0];
        nbr_mv_y_flat[MV_W*idx +: MV_W] = mvy_val[MV_W-1:0];
        nbr_ref_flat[RIF_W*idx +: RIF_W] = ref_idx[RIF_W-1:0];
    endtask

    task automatic clear_neighbors();
        nbr_inter     = 5'b00000;
        nbr_mv_x_flat = '0;
        nbr_mv_y_flat = '0;
        nbr_ref_flat  = '0;
    endtask

    // Golden Model: HM 18.0 fillMvpCand() compliant logic
    task automatic calc_golden_amvp(
        input int ref_target,
        output int exp_mvp_x0,
        output int exp_mvp_y0,
        output int exp_mvp_x1,
        output int exp_mvp_y1
    );
        int c0_found, c1_found;
        int c0_x, c0_y, c1_x, c1_y;
        
        c0_found = 0; c0_x = 0; c0_y = 0;
        c1_found = 0; c1_x = 0; c1_y = 0;

        // Left Group: Priority A0 -> A1
        if (nbr_inter[NBR_A0] && (nbr_ref_flat[RIF_W*NBR_A0 +: RIF_W] == ref_target)) begin
            c0_x = $signed(nbr_mv_x_flat[MV_W*NBR_A0 +: MV_W]);
            c0_y = $signed(nbr_mv_y_flat[MV_W*NBR_A0 +: MV_W]);
            c0_found = 1;
        end else if (nbr_inter[NBR_A1] && (nbr_ref_flat[RIF_W*NBR_A1 +: RIF_W] == ref_target)) begin
            c0_x = $signed(nbr_mv_x_flat[MV_W*NBR_A1 +: MV_W]);
            c0_y = $signed(nbr_mv_y_flat[MV_W*NBR_A1 +: MV_W]);
            c0_found = 1;
        end

        // Above Group: Priority B0 -> B1 -> B2
        if (nbr_inter[NBR_B0] && (nbr_ref_flat[RIF_W*NBR_B0 +: RIF_W] == ref_target)) begin
            c1_x = $signed(nbr_mv_x_flat[MV_W*NBR_B0 +: MV_W]);
            c1_y = $signed(nbr_mv_y_flat[MV_W*NBR_B0 +: MV_W]);
            c1_found = 1;
        end else if (nbr_inter[NBR_B1] && (nbr_ref_flat[RIF_W*NBR_B1 +: RIF_W] == ref_target)) begin
            c1_x = $signed(nbr_mv_x_flat[MV_W*NBR_B1 +: MV_W]);
            c1_y = $signed(nbr_mv_y_flat[MV_W*NBR_B1 +: MV_W]);
            c1_found = 1;
        end else if (nbr_inter[NBR_B2] && (nbr_ref_flat[RIF_W*NBR_B2 +: RIF_W] == ref_target)) begin
            c1_x = $signed(nbr_mv_x_flat[MV_W*NBR_B2 +: MV_W]);
            c1_y = $signed(nbr_mv_y_flat[MV_W*NBR_B2 +: MV_W]);
            c1_found = 1;
        end

        // De-duplication check: if both found and equal, candidate 1 cleared to 0
        if (c0_found && c1_found && (c0_x == c1_x) && (c0_y == c1_y)) begin
            c1_found = 0;
            c1_x = 0;
            c1_y = 0;
        end

        // Candidate output packing with zero padding
        if (c0_found) begin
            exp_mvp_x0 = c0_x;
            exp_mvp_y0 = c0_y;
            if (c1_found) begin
                exp_mvp_x1 = c1_x;
                exp_mvp_y1 = c1_y;
            end else begin
                exp_mvp_x1 = 0;
                exp_mvp_y1 = 0;
            end
        end else if (c1_found) begin
            exp_mvp_x0 = c1_x;
            exp_mvp_y0 = c1_y;
            exp_mvp_x1 = 0;
            exp_mvp_y1 = 0;
        end else begin
            exp_mvp_x0 = 0;
            exp_mvp_y0 = 0;
            exp_mvp_x1 = 0;
            exp_mvp_y1 = 0;
        end
    endtask

    int total_tests = 0;
    int flaw_failure_count = 0;
    int pass_count = 0;

    // Test Verification Task
    task automatic evaluate_amvp_case(
        input string test_name,
        input int cu_mv_x,
        input int cu_mv_y,
        input int ref_idx
    );
        int gold_x0, gold_y0, gold_x1, gold_y1;
        int enc_mvd_x, enc_mvd_y;
        int dec_recon_x, dec_recon_y;
        int drift_x, drift_y;

        total_tests++;
        target_ref_idx = ref_idx[RIF_W-1:0];
        valid_in = 1;
        @(posedge clk);
        valid_in = 0;
        @(posedge clk); // Allow 1-cycle pipeline register update

        // 1. Calculate golden normative MVP from neighbors
        calc_golden_amvp(ref_idx, gold_x0, gold_y0, gold_x1, gold_y1);

        // 2. Hardware Encoder MVD calculation (matches hevc_encoder_top.v line 2818)
        // Encoder signals mvp_flag_l0 = 0, so candidate 0 is chosen
        enc_mvd_x = cu_mv_x - enc_mvp_x_qp;
        enc_mvd_y = cu_mv_y - enc_mvp_y_qp;

        // 3. Compliant Decoder Reconstructed MV calculation:
        // Compliant decoder receives mvp_flag_l0 = 0, independently builds candidate list,
        // obtains gold_x0/gold_y0, and computes: MV_recon = MVP_gold + MVD_signaled
        dec_recon_x = gold_x0 + enc_mvd_x;
        dec_recon_y = gold_y0 + enc_mvd_y;

        // 4. Mathematical Drift between intended encoder MV and decoded MV:
        // Drift = MV_dec - MV_enc = (gold + enc_mvd) - cu_mv
        //       = gold + (cu_mv - enc_mvp) - cu_mv = gold - enc_mvp
        drift_x = dec_recon_x - cu_mv_x;
        drift_y = dec_recon_y - cu_mv_y;

        $display("----------------------------------------------------------------");
        $display("[Case %0d] %s", total_tests, test_name);
        $display("  Intended CU MV     : (%0d, %0d)", cu_mv_x, cu_mv_y);
        $display("  Normative Gold MVP : Cand0=(%0d, %0d), Cand1=(%0d, %0d)", 
                 gold_x0, gold_y0, gold_x1, gold_y1);
        $display("  HW Datapath MVP    : Cand0=(%0d, %0d)", enc_mvp_x_qp, enc_mvp_y_qp);
        $display("  Signaled MVD       : (%0d, %0d)", enc_mvd_x, enc_mvd_y);
        $display("  Decoder Reconstructed MV : (%0d, %0d)", dec_recon_x, dec_recon_y);
        $display("  Decoder Drift (ΔMV): (%0d, %0d)", drift_x, drift_y);

        if (drift_x != 0 || drift_y != 0 || enc_mvp_x_qp != gold_x0 || enc_mvp_y_qp != gold_y0) begin
            $display("  >>> DEVIATION DETECTED! Non-zero drift violates HEVC Clause 8.5.3.1");
            flaw_failure_count++;
        end else begin
            $display("  >>> PASS: Zero drift bit-exact match with normative specification.");
            pass_count++;
        end
    endtask

    // Main Test Stimulus Sequence
    initial begin
        valid_in = 0;
        target_ref_idx = 0;
        clear_neighbors();
        rst_n = 0;
        #20 rst_n = 1;
        #10;

        $display("================================================================");
        $display(" HEVC DUAL-STATE VERIFICATION: Flaw D-01 (AMVP Zero Tie-off)");
        $display(" Target Spec: ITU-T H.265 Clause 8.5.3.1 / HM fillMvpCand()");
        $display(" Configuration: %s State", IS_REMEDIATED ? "REMEDIATED" : "BUGGY (UNMODIFIED)");
        $display("================================================================");

        //---------------------------------------------------------------------
        // TEST 1: Spatial Neighbor A0 Available (Non-zero MV)
        //---------------------------------------------------------------------
        clear_neighbors();
        set_neighbor(NBR_A0, 1'b1, 16, -8, 0); // Bottom-left neighbor has MV (16, -8)
        evaluate_amvp_case("Single Spatial Neighbor A0 Active", 20, -10, 0);

        //---------------------------------------------------------------------
        // TEST 2: Left Group Priority: A0 Wins Over A1
        //---------------------------------------------------------------------
        clear_neighbors();
        set_neighbor(NBR_A1, 1'b1,  8,   8, 0); // A1 valid
        set_neighbor(NBR_A0, 1'b1, 24, -12, 0); // A0 valid (higher priority)
        evaluate_amvp_case("Left Group Priority: A0 over A1", 30, -15, 0);

        //---------------------------------------------------------------------
        // TEST 3: Above Group Active: B0 over B1 over B2 (Left Unavailable)
        //---------------------------------------------------------------------
        clear_neighbors();
        // Left boundary: A0, A1 unavailable
        set_neighbor(NBR_B2, 1'b1,  4,   4, 0);
        set_neighbor(NBR_B1, 1'b1, 12,  12, 0);
        set_neighbor(NBR_B0, 1'b1, -16, 20, 0); // B0 highest priority in above group
        evaluate_amvp_case("Above Group Priority: B0 over B1, B2", -10, 25, 0);

        //---------------------------------------------------------------------
        // TEST 4: Both Left and Above Groups Active (Two Distinct Candidates)
        //---------------------------------------------------------------------
        clear_neighbors();
        set_neighbor(NBR_A0, 1'b1, 14, -6, 0);  // Left candidate
        set_neighbor(NBR_B0, 1'b1, -18, 10, 0); // Above candidate
        evaluate_amvp_case("Dual Group Active: Distinct Candidates", 15, -5, 0);

        //---------------------------------------------------------------------
        // TEST 5: De-duplication: Candidate 0 equals Candidate 1
        //---------------------------------------------------------------------
        clear_neighbors();
        set_neighbor(NBR_A0, 1'b1, 32, 16, 0);
        set_neighbor(NBR_B1, 1'b1, 32, 16, 0); // Exact duplicate
        evaluate_amvp_case("De-duplication: Redundant Above Candidate", 40, 20, 0);

        //---------------------------------------------------------------------
        // TEST 6: Reference Index Filtering
        //---------------------------------------------------------------------
        clear_neighbors();
        set_neighbor(NBR_A0, 1'b1, 50, 50, 1); // Belongs to RefPic 1 (mismatch)
        set_neighbor(NBR_A1, 1'b1, 18, 22, 0); // Belongs to RefPic 0 (match)
        evaluate_amvp_case("Reference Index Filtering (Target RefIdx 0)", 20, 25, 0);

        //---------------------------------------------------------------------
        // TEST 7: Corner Case: All Neighbors Unavailable (Zero Fallback)
        //---------------------------------------------------------------------
        clear_neighbors();
        // All intra or picture boundary
        evaluate_amvp_case("All Neighbors Unavailable: Fallback to (0, 0)", 10, 10, 0);

        //---------------------------------------------------------------------
        // Summary & Dual-State Verification Assertions
        //---------------------------------------------------------------------
        $display("\n================================================================");
        $display(" VERIFICATION RESULTS SUMMARY:");
        $display("   Total Test Scenarios  : %0d", total_tests);
        $display("   Passed Scenarios      : %0d", pass_count);
        $display("   Failed Scenarios      : %0d", flaw_failure_count);
        $display("================================================================");

        if (IS_REMEDIATED) begin
            if (flaw_failure_count == 0) begin
                $display("\n [PASS] *** ALL TESTS PASSED: AMVP CONFORMANCE VERIFIED WITH ZERO DRIFT ***\n");
                $finish(0);
            end else begin
                $display("\n [FAIL] Remediated RTL encountered unexpected errors!\n");
                $finish(1);
            end
        end else begin
            // In Buggy State, we expect failures on non-zero neighbor cases
            if (flaw_failure_count > 0) begin
                $display("\n [CONFIRMED FLAW] *** FLAW D-01 CONFIRMED: HARDCODED ZERO TIE-OFF PRODUCES DECODER DRIFT ***");
                $display(" Failure mechanism: Bitstream MVD carries full MV, but compliant decoder adds non-zero MVP, corrupting decoded frames.");
                $display(" Status: Assert and FAIL verified on unmodified RTL.\n");
                $finish(1); // Non-zero exit code documents bug failure
            end else begin
                $display("\n [UNEXPECTED] Buggy mode did not fail as expected!\n");
                $finish(2);
            end
        end
    end

endmodule
