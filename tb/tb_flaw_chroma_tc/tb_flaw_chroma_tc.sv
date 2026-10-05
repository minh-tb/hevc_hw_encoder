//=============================================================================
// tb_flaw_chroma_tc.sv
// Dual-State Self-Checking Verification Testbench for Chroma t_C Table & High-QP Collapse
// Target Module: rtl/inloop_filters/db_filter_chroma.v
// Associated Flaw: Flaw D-06 (Chroma t_C table mapping collapse at high QPs vs Table 8-19)
//
// Specification Reference:
//   - ITU-T H.265 (HEVC) Clause 8.7.2.5.3, Table 8-19 (t_C' derivation)
//   - ITU-T H.265 (HEVC) Clause 8.7.2.5.5: Chroma filtering process
//   - HM 18.0 reference software: TComLoopFilter::xEdgeFilterChroma
//     (lines 804-805: Clip3(0, 53, ...) and sm_tcTable[53] = 24 * iBitdepthScale)
//
// Dual-State Behavior:
//   - Buggy RTL: db_filter_chroma.v lines 136-137 has default: tc_table = 7'd0,
//     and lines 103-104 has default: chroma_qp_table = 6'd0.
//     At high QPs (edge_qp >= 52 or tc_idx >= 54), t_C collapses to 0 instead of
//     saturating to 24 per Table 8-19 (96 in Main10).
//     The testbench asserts on t_C zero-collapse, FAILING with exit code 1.
//   - Remediated RTL: tc_table saturates to 24 for idx >= 53 per Table 8-19,
//     chroma_qp_table saturates at 45 (or Table 8-21), and Main10 scale is 4.
//     The testbench verifies full QP range 0..51 + high QP saturation, PASSING with zero errors.
//=============================================================================

`timescale 1ns/1ps
`include "parameter_pkg.vh"

`ifndef PIXEL_WIDTH
`define PIXEL_WIDTH 10
`endif

module tb_flaw_chroma_tc;

    // Clock and Reset
    logic clk;
    logic rst_n;

    // DUT Ports
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

    // DUT Instantiation
    db_filter_chroma dut (
        .clk(clk),
        .rst_n(rst_n),
        .in_valid(in_valid),
        .in_ready(in_ready),
        .bs(bs),
        .edge_qp(edge_qp),
        .comp(comp),
        .p0(p0),
        .p1(p1),
        .q0(q0),
        .q1(q1),
        .out_valid(out_valid),
        .out_ready(out_ready),
        .p0_f(p0_f),
        .q0_f(q0_f),
        .p1_pass(p1_pass),
        .q1_pass(q1_pass),
        .modified(modified)
    );

    // Clock Generation (100 MHz)
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    //-------------------------------------------------------------------------
    // Normative Reference Model per ITU-T H.265 Clause 8.7.2.5 & HM 18.0
    //-------------------------------------------------------------------------
    function automatic logic [5:0] golden_chroma_qp(input logic [5:0] qpy);
        // HEVC Table 8-21 (Table 8-15) for 4:2:0 format
        logic [5:0] tbl [0:51] = '{
            0,  1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14, 15, 16, 17, 18, 19,
            20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 29, 30, 31, 32, 33, 33, 34, 34, 35, 35,
            36, 36, 37, 37, 38, 39, 40, 41, 42, 43, 44, 45
        };
        if (qpy > 51) return 6'd45; // Saturation for 4:2:0
        return tbl[qpy];
    endfunction

    // Normative Table 8-19 (54 entries: 0..53, with saturation at 24)
    function automatic logic [6:0] golden_tc_table(input int idx);
        logic [6:0] tbl [0:53] = '{
            0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
            1,1,1,1,1,1,1,1,1,
            2,2,2,2,
            3,3,3,3,
            4,4,4,
            5,5,
            6,6,
            7,8,9,10,11,13,14,16,18,20,22,24
        };
        if (idx < 0) return 7'd0;
        if (idx >= 53) return 7'd24; // Normative saturation per Table 8-19 & HM Clip3(0, 53)
        return tbl[idx];
    endfunction

    function automatic int clip1(input int val);
        int max_val = (1 << `BIT_DEPTH) - 1; // 1023
        if (val < 0) return 0;
        if (val > max_val) return max_val;
        return val;
    endfunction

    typedef struct {
        logic [`PIXEL_WIDTH-1:0] p0_f, q0_f, p1_pass, q1_pass;
        logic modified;
        int tc_val;
        int qpc;
        int tc_idx;
        int qp_tested;
    } golden_result_t;

    function automatic golden_result_t compute_golden(
        input logic [1:0] i_bs,
        input logic [5:0] i_qp,
        input logic [`PIXEL_WIDTH-1:0] i_p0, i_p1, i_q0, i_q1
    );
        golden_result_t res;
        int qpc, tc_idx, tc_val, raw_sum, raw_delta, delta;

        res.p1_pass = i_p1;
        res.q1_pass = i_q1;
        res.qp_tested = i_qp;

        if (i_bs == 2) begin
            qpc = golden_chroma_qp(i_qp);
            tc_idx = qpc + 2;
            // Main10 scaling factor: 1 << (10 - 8) = 4
            tc_val = int'(golden_tc_table(tc_idx)) << (`BIT_DEPTH - 8);

            raw_sum = ((int'(i_q0) - int'(i_p0)) * 4) + int'(i_p1) - int'(i_q1) + 4;
            raw_delta = raw_sum >>> 3;

            // Clip3(-tc, tc, delta)
            if (raw_delta < -tc_val) delta = -tc_val;
            else if (raw_delta > tc_val) delta = tc_val;
            else delta = raw_delta;

            res.p0_f = clip1(int'(i_p0) + delta);
            res.q0_f = clip1(int'(i_q0) - delta);
            res.modified = (tc_val != 0) ? 1'b1 : 1'b0;
            res.tc_val = tc_val;
            res.qpc = qpc;
            res.tc_idx = tc_idx;
        end else begin
            // BS < 2: chroma filtering completely bypassed
            res.p0_f = i_p0;
            res.q0_f = i_q0;
            res.modified = 1'b0;
            res.tc_val = 0;
            res.qpc = 0;
            res.tc_idx = 0;
        end

        return res;
    endfunction

    // Transaction Queue
    golden_result_t exp_q[$];
    int error_count = 0;
    int test_count = 0;
    int zero_collapse_errors = 0;

    // Response Scoreboard
    always @(posedge clk) begin
        if (rst_n && out_valid && out_ready) begin
            golden_result_t exp;
            if (exp_q.size() == 0) begin
                $display("FATAL: Unexpected out_valid!");
                $finish(1);
            end
            exp = exp_q.pop_front();
            test_count++;

            // Check for Flaw D-06: Zero-collapse detection at high QPs
            if (exp.modified == 1'b1 && modified == 1'b0 && exp.tc_val > 0) begin
                $display("ERROR [Flaw D-06 Detected]: QP=%0d QpC=%0d tc_idx=%0d | Golden Tc=%0d (mod=1), DUT Tc=0 (mod=0, zero-collapse!)",
                         exp.qp_tested, exp.qpc, exp.tc_idx, exp.tc_val);
                zero_collapse_errors++;
                error_count++;
            end else if ((p0_f !== exp.p0_f) || (q0_f !== exp.q0_f) || (modified !== exp.modified)) begin
                $display("ERROR mismatch: Test #%0d QP=%0d | Expected p0=%0d q0=%0d mod=%b | Got p0=%0d q0=%0d mod=%b",
                         test_count, exp.qp_tested, exp.p0_f, exp.q0_f, exp.modified, p0_f, q0_f, modified);
                error_count++;
            end
        end
    end

    // Stimulus Task
    task automatic drive_sample(
        input logic [1:0] i_bs,
        input logic [5:0] i_qp,
        input logic [`PIXEL_WIDTH-1:0] i_p0, i_p1, i_q0, i_q1
    );
        exp_q.push_back(compute_golden(i_bs, i_qp, i_p0, i_p1, i_q0, i_q1));
        in_valid <= 1'b1;
        bs       <= i_bs;
        edge_qp  <= i_qp;
        comp     <= 2'd1; // Cb
        p0       <= i_p0;
        p1       <= i_p1;
        q0       <= i_q0;
        q1       <= i_q1;
        @(posedge clk);
        while (!in_ready) @(posedge clk);
        in_valid <= 1'b0;
    endtask

    // Main Test Sequence
    initial begin
        $display("==================================================================");
        $display(" Starting tb_flaw_chroma_tc: Chroma t_C Table & High-QP Audit");
        $display(" ITU-T H.265 Clause 8.7.2.5.3, Table 8-19 & Main10 Scaling Verification");
        $display("==================================================================");

        in_valid  = 1'b0;
        out_ready = 1'b1;
        bs        = 2'd0;
        edge_qp   = 6'd0;
        comp      = 2'd1;
        p0 = 10'd0; p1 = 10'd0; q0 = 10'd0; q1 = 10'd0;
        rst_n     = 1'b0;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // Section 1: Verify Bypass on BS=0 and BS=1 across diverse QPs
        $display("--- Test Section 1: BS=0 and BS=1 Chroma Bypass Conformance ---");
        drive_sample(2'd0, 6'd30, 10'd400, 10'd410, 10'd550, 10'd560);
        drive_sample(2'd1, 6'd30, 10'd400, 10'd410, 10'd550, 10'd560);
        drive_sample(2'd1, 6'd45, 10'd300, 10'd300, 10'd700, 10'd700);

        // Section 2: Full QP Sweep (0..51) for BS=2 with distinct step edge
        $display("--- Test Section 2: Full QP Sweep (0..51) with Main10 Scale Factor (1<<(B-8)=4) ---");
        for (int q = 0; q <= 51; q++) begin
            drive_sample(2'd2, 6'(q), 10'd500, 10'd500, 10'd650, 10'd650);
        end

        // Section 3: High-QP / Extended Range Audit (edge_qp >= 52)
        // In HEVC, for high/extended QPs (52..63), chroma QP saturates to 45 (or Table 8-21),
        // requiring active filtering with maximum t_C.
        // Under buggy RTL, default: chroma_qp_table = 6'd0 returns 0, collapsing filtering completely!
        $display("--- Test Section 3: High-QP / Extended Range Audit (QP >= 52) ---");
        for (int q = 52; q <= 63; q++) begin
            drive_sample(2'd2, 6'(q), 10'd400, 10'd400, 10'd800, 10'd800);
        end

        // Section 4: Direct Table 8-19 Function Saturation Audit
        // In HEVC Table 8-19, for any index >= 53, tc_table must saturate to 24.
        // Under buggy RTL, default: tc_table = 7'd0 returns 0 for index >= 54!
        $display("--- Test Section 4: Table 8-19 Function Saturation Audit (idx >= 53) ---");
        for (int idx = 50; idx <= 63; idx++) begin
            automatic logic [6:0] rtl_tc = dut.tc_table(7'(idx));
            automatic logic [6:0] exp_tc = golden_tc_table(idx);
            if (rtl_tc !== exp_tc) begin
                $display("ERROR [Table 8-19 Saturation Defect]: idx=%0d | Expected tc=%0d, Got tc=%0d (zero-collapse at idx>=54)",
                         idx, exp_tc, rtl_tc);
                zero_collapse_errors++;
                error_count++;
            end
        end

        // Section 5: Pipeline Stress Randomization
        $display("--- Test Section 5: Pipeline Stress Randomization ---");
        for (int i = 0; i < 100; i++) begin
            drive_sample(
                2'd2,
                6'($urandom_range(16, 51)),
                10'($urandom_range(100, 900)),
                10'($urandom_range(100, 900)),
                10'($urandom_range(100, 900)),
                10'($urandom_range(100, 900))
            );
        end

        // Drain pipeline
        repeat (20) @(posedge clk);

        $display("\n==================================================================");
        $display(" Final Verification Summary: %0d transactions evaluated", test_count);
        $display(" Total Errors: %0d (Zero-collapse errors: %0d)", error_count, zero_collapse_errors);
        $display("==================================================================");

        if (zero_collapse_errors > 0 || error_count > 0) begin
            $display("\n==================================================================");
            $display("*** FAILED: Chroma t_C table mapping flaw detected! (Flaw D-06) ***");
            $display("Failure Details: default: tc_table = 7'd0 in db_filter_chroma.v lines 136-137");
            $display("and default: chroma_qp_table = 6'd0 collapse filtering to zero at high QPs");
            $display("instead of saturating to 24 per Table 8-19!");
            $display("==================================================================\n");
            $finish(1);
        end else begin
            $display("\n==================================================================");
            $display("*** ALL TESTS PASSED: Full Table 8-19 and Main10 scaling verified ***");
            $display("==================================================================\n");
            $finish(0);
        end
    end

endmodule
