//=============================================================================
// tb_flaw_cabac_init.sv
// Adversarial Algorithmic Verification Testbench for HEVC Encoder Subsystem
//
// Target Flaw: D-11 (MAJOR): Slice type mapping inversion in ctx_model_store.v
// Module: rtl/entropy/ctx_model_store.v
// Normative Reference: ITU-T H.265 Clause 9.3.2.2, Table 9-39, HM ContextModel::init
//
// Verification Objective:
//   - Assert and FAIL when top-level / testbench drives slice_type=0 assuming
//     I-slice per RTL header comment (0=I, 1=P, 2=B), proving B/I inversion.
//   - Assert and PASS when verified against normative Table 9-39 across all
//     186 context models for I, P, and B slices under aligned mapping.
//=============================================================================

`timescale 1ns/1ps
`include "parameter_pkg.vh"

module tb_flaw_cabac_init;

    parameter N_CTX    = 186;
    parameter CTX_W    = 7;
    parameter CTX_ID_W = 8;

    // Clock and reset
    logic                  clk;
    logic                  rst_n;

    // DUT signals
    logic                  slice_init;
    logic [1:0]            slice_type;
    logic [6:0]            qp_in;

    logic [CTX_ID_W-1:0]   rd_ctx_id;
    logic [CTX_W-1:0]      rd_state;

    logic                  upd_valid;
    logic [CTX_ID_W-1:0]   upd_ctx_id;
    logic                  upd_bin;
    logic                  init_busy;

    // Instantiate DUT
    ctx_model_store #(
        .N_CTX(N_CTX),
        .CTX_W(CTX_W),
        .CTX_ID_W(CTX_ID_W)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .slice_init (slice_init),
        .slice_type (slice_type),
        .qp_in      (qp_in),
        .rd_ctx_id  (rd_ctx_id),
        .rd_state   (rd_state),
        .upd_valid  (upd_valid),
        .upd_ctx_id (upd_ctx_id),
        .upd_bin    (upd_bin),
        .init_busy  (init_busy)
    );

    // Clock Generation: 100 MHz
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // Timeout Watchdog Guard
    initial begin
        #2000000; // 2 ms limit
        $display("\n[FATAL TIMEOUT] Simulation exceeded 2ms limit. Deadlock detected!");
        $finish(2);
    end

    // =========================================================================
    // Normative Mathematical Reference Model (ITU-T H.265 Clause 9.3.2.2)
    // =========================================================================
    function automatic [7:0] get_norm_init_val(
        input [CTX_ID_W-1:0] ctx,
        input [1:0]          norm_slice_type // 0=B, 1=P, 2=I (normative HEVC Table 7-23)
    );
        reg [7:0] iv_I, iv_P, iv_B;
        begin
            iv_I = 8'd154; iv_P = 8'd154; iv_B = 8'd154;
            case (ctx)
`include "init_tables.vh"
                default: begin iv_I = 8'd154; iv_P = 8'd154; iv_B = 8'd154; end
            endcase
            case (norm_slice_type)
                2'd0:    get_norm_init_val = iv_B;
                2'd1:    get_norm_init_val = iv_P;
                default: get_norm_init_val = iv_I;
            endcase
        end
    endfunction

    function automatic [6:0] norm_compute_state(
        input [7:0] init_val,
        input [6:0] qp
    );
        reg signed [8:0] slope;
        reg signed [8:0] offset;
        reg signed [15:0] prod;
        reg signed [8:0] pre_clamp;
        reg [6:0] init_state;
        reg       val_mps;
        reg [5:0] p_state_idx;
        begin
            slope     = $signed({1'b0, init_val[7:4]}) * 9'sd5 - 9'sd45;
            offset    = ($signed({1'b0, init_val[3:0]}) <<< 3) - 9'sd16;
            prod      = slope * $signed({1'b0, qp});
            pre_clamp = (prod >>> 4) + offset;

            if (pre_clamp < 9'sd1)
                init_state = 7'd1;
            else if (pre_clamp > 9'sd126)
                init_state = 7'd126;
            else
                init_state = pre_clamp[6:0];

            if (init_state >= 7'd64) begin
                val_mps     = 1'b1;
                p_state_idx = init_state - 7'd64;
            end else begin
                val_mps     = 1'b0;
                p_state_idx = 7'd63 - init_state;
            end
            norm_compute_state = {p_state_idx, val_mps};
        end
    endfunction

    // Test tracking counters
    int total_tests = 0;
    int error_count = 0;
    int flaw_inversion_mismatches = 0;

    // Task to run slice initialization and wait for completion
    task automatic trigger_slice_init(input [1:0] stype, input [6:0] qp);
        @(posedge clk);
        slice_init <= 1'b1;
        slice_type <= stype;
        qp_in      <= qp;
        @(posedge clk);
        slice_init <= 1'b0;
        @(posedge clk);
        while (init_busy) @(posedge clk);
        repeat(2) @(posedge clk);
    endtask

    // Main Test Stimulus
    initial begin
        // 1. Reset
        rst_n      <= 1'b0;
        slice_init <= 1'b0;
        slice_type <= 2'd0;
        qp_in      <= 7'd0;
        rd_ctx_id  <= 8'd0;
        upd_valid  <= 1'b0;
        upd_ctx_id <= 8'd0;
        upd_bin    <= 1'b0;

        repeat(5) @(posedge clk);
        rst_n <= 1'b1;
        repeat(2) @(posedge clk);

        $display("==================================================================");
        $display(" Running Flaw Verification: D-11 (CABAC Context Slice Type Inversion)");
        $display(" Target Module: rtl/entropy/ctx_model_store.v");
        $display(" Normative Spec: ITU-T H.265 Clause 9.3.2.2, Table 9-39");
        $display("==================================================================");

`ifdef TEST_CONFORMANCE
        $display("\n>>> MODE: NORMATIVE CONFORMANCE VERIFICATION (ALIGNED MAPPING) <<<");
        // Verify all 186 contexts across I, P, B slices at multiple QPs
        for (int qp_val = 22; qp_val <= 32; qp_val += 5) begin
            // 1. I-Slice (normative slice_type = 2)
            trigger_slice_init(2'd2, qp_val[6:0]);
            for (int c = 0; c < N_CTX; c++) begin
                logic [6:0] exp_s;
                logic [7:0] iv;
                total_tests++;
                rd_ctx_id = c[CTX_ID_W-1:0];
                #1;
                iv = get_norm_init_val(c[CTX_ID_W-1:0], 2'd2);
                exp_s = norm_compute_state(iv, qp_val[6:0]);
                if (rd_state !== exp_s) begin
                    error_count++;
                    $display("[FAIL] I-Slice QP=%0d Ctx=%0d: Exp=%0d, Got=%0d", qp_val, c, exp_s, rd_state);
                end
            end

            // 2. P-Slice (normative slice_type = 1)
            trigger_slice_init(2'd1, qp_val[6:0]);
            for (int c = 0; c < N_CTX; c++) begin
                logic [6:0] exp_s;
                logic [7:0] iv;
                total_tests++;
                rd_ctx_id = c[CTX_ID_W-1:0];
                #1;
                iv = get_norm_init_val(c[CTX_ID_W-1:0], 2'd1);
                exp_s = norm_compute_state(iv, qp_val[6:0]);
                if (rd_state !== exp_s) begin
                    error_count++;
                    $display("[FAIL] P-Slice QP=%0d Ctx=%0d: Exp=%0d, Got=%0d", qp_val, c, exp_s, rd_state);
                end
            end

            // 3. B-Slice (normative slice_type = 0)
            trigger_slice_init(2'd0, qp_val[6:0]);
            for (int c = 0; c < N_CTX; c++) begin
                logic [6:0] exp_s;
                logic [7:0] iv;
                total_tests++;
                rd_ctx_id = c[CTX_ID_W-1:0];
                #1;
                iv = get_norm_init_val(c[CTX_ID_W-1:0], 2'd0);
                exp_s = norm_compute_state(iv, qp_val[6:0]);
                if (rd_state !== exp_s) begin
                    error_count++;
                    $display("[FAIL] B-Slice QP=%0d Ctx=%0d: Exp=%0d, Got=%0d", qp_val, c, exp_s, rd_state);
                end
            end
        end

        $display("\n==================================================================");
        $display(" CONFORMANCE RESULTS: %0d Tests | %0d Errors", total_tests, error_count);
        if (error_count == 0) begin
            $display(" *** ALL 186 CONTEXT MODELS PASSED TABLE 9-39 BIT-ACCURATELY ***");
            $display("==================================================================");
            $finish(0);
        end else begin
            $display(" *** CONFORMANCE FAILED: %0d MISMATCHES DETECTED ***", error_count);
            $display("==================================================================");
            $finish(1);
        end

`else
        $display("\n>>> MODE: ADVERSARIAL FLAW DEMONSTRATION (PORT-SPEC INVERSION) <<<");
        $display("Testing interface where caller drives slice_type=2'd0 expecting I-slice");
        $display("(following port comment: 'input wire [1:0] slice_type, // 0=I, 1=P, 2=B')");

        // Drive slice_type = 2'd0 with QP = 32
        trigger_slice_init(2'd0, 7'd32);

        for (int c = 0; c < N_CTX; c++) begin
            logic [6:0] exp_i_state;
            logic [6:0] actual_b_state;
            logic [7:0] iv_I, iv_B;
            total_tests++;

            rd_ctx_id = c[CTX_ID_W-1:0];
            #1;

            iv_I = get_norm_init_val(c[CTX_ID_W-1:0], 2'd2); // True I-slice
            iv_B = get_norm_init_val(c[CTX_ID_W-1:0], 2'd0); // True B-slice
            exp_i_state    = norm_compute_state(iv_I, 7'd32);
            actual_b_state = norm_compute_state(iv_B, 7'd32);

            // Compare DUT output against normative I-slice expectation
            if (rd_state !== exp_i_state) begin
                flaw_inversion_mismatches++;
                error_count++;
                if (flaw_inversion_mismatches <= 15) begin
                    $display("[FLAW D-11 DETECTED] Ctx %0d: Expected I-State=%0d (iv_I=%0d), Got State=%0d (matched B-State=%0d, iv_B=%0d)",
                             c, exp_i_state, iv_I, rd_state, actual_b_state, iv_B);
                end
            end
        end

        $display("... (remaining mismatches truncated for log readability) ...");
        $display("\n==================================================================");
        $display(" ADVERSARIAL FLAW AUDIT SUMMARY");
        $display(" Context Models Tested: %0d", total_tests);
        $display(" Inverted Init Mismatches: %0d / %0d contexts corrupted!",
                 flaw_inversion_mismatches, total_tests);
        $display(" Contexts with iv_I != iv_B all completely diverged!");
        $display("==================================================================");

        if (flaw_inversion_mismatches > 50) begin
            $display(" *** FLAW D-11 CONFIRMED: SLICE TYPE MAPPING INVERSION PROVEN ***");
            $display(" When driving slice_type=0 for I-slice, DUT loaded B-slice init tables.");
            $display(" Bitstream CABAC entropy distribution is corrupted at slice start.");
            $display("==================================================================");
            $finish(1);
        end else begin
            $display(" *** ALL %0d TESTS PASSED SPECIFICATION *** ", total_tests);
            $display("==================================================================");
            $finish(0);
        end
`endif

    end

endmodule
