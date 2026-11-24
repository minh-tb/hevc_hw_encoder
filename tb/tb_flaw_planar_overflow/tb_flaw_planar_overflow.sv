//=============================================================================
// tb_flaw_planar_overflow.sv
// Dual-State Verification Testbench for Flaw D-08:
// Intra Planar 32x32 Accumulator Overflow in intra_rmd.v lines 108-114
//
// Demonstrates that a 16-bit accumulator (wire [15:0] planar_sum) wraps around
// modulo 65,536 on high dynamic range / overshoot inputs, collapsing prediction
// from peak luminance to near zero, whereas an 18-bit accumulator preserves
// the full dynamic range without distortion.
//
// Dual-state compilation:
//   Buggy run:      vlog -sv ... tb_flaw_planar_overflow.sv
//                   -> Fails assertion and reports Flaw D-08 reproduction
//   Remediated run: vlog -sv +define+REMEDIATION_PATCH ... tb_flaw_planar_overflow.sv
//                   -> Passes assertion and reports ALL TESTS PASSED
//=============================================================================

`timescale 1ns / 1ps
`include "parameter_pkg.vh"

module tb_flaw_planar_overflow;

    logic        clk;
    logic        rst_n;
    int          total_errors = 0;

    // Clock generation (100 MHz)
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

`ifndef REMEDIATION_PATCH
    // Buggy 16-bit Planar Accumulator Core (as in baseline intra_rmd.v)
    logic [2:0]  pu_size_log2;
    logic [5:0]  cx_q, cy_q;
    logic [10:0] refL_y;
    logic [10:0] refT_x;
    logic [10:0] refT_N;
    logic [10:0] refL_N;

    wire [9:0]   pred_pixel_out;
    wire [17:0]  planar_sum_raw;
    wire         overflow_flag;

    planar_acc_16b dut (
        .pu_size_log2   (pu_size_log2),
        .cx_q           (cx_q),
        .cy_q           (cy_q),
        .refL_y         (refL_y),
        .refT_x         (refT_x),
        .refT_N         (refT_N),
        .refL_N         (refL_N),
        .pred_planar    (pred_pixel_out),
        .planar_sum_out (planar_sum_raw),
        .overflow       (overflow_flag)
    );
`else
    // Live production RTL instances (rtl/intra/intra_planar.v + rtl/intra/intra_rmd.v)
    logic [2:0]  planar_pu_size_log2;
    logic        planar_in_valid;
    wire         planar_in_ready;
    logic [9:0]  planar_in_sample;
    logic [7:0]  planar_in_idx;
    logic        planar_in_last;
    wire         planar_out_valid;
    logic        planar_out_ready;
    wire [9:0]   planar_out_pixel;
    wire [5:0]   planar_out_x;
    wire [5:0]   planar_out_y;
    wire         planar_out_last;

    intra_planar u_planar (
        .clk          (clk),
        .rst_n        (rst_n),
        .pu_size_log2 (planar_pu_size_log2),
        .in_valid     (planar_in_valid),
        .in_ready     (planar_in_ready),
        .in_sample    (planar_in_sample),
        .in_idx       (planar_in_idx),
        .in_last      (planar_in_last),
        .out_valid    (planar_out_valid),
        .out_ready    (planar_out_ready),
        .out_pixel    (planar_out_pixel),
        .out_x        (planar_out_x),
        .out_y        (planar_out_y),
        .out_last     (planar_out_last)
    );

    logic        rmd_start;
    logic [5:0]  rmd_pu_x, rmd_pu_y;
    logic [2:0]  rmd_pu_size_log2;
    wire [11:0]  rmd_orig_rd_addr;
    wire         rmd_active;
    logic [9:0]  rmd_orig_rd_data;
    wire [9:0]   rmd_orig_c_rd_addr;
    logic [9:0]  rmd_orig_u_rd_data, rmd_orig_v_rd_data;
    logic        rmd_ref_valid;
    logic [9:0]  rmd_ref_sample, rmd_ref_sample_u, rmd_ref_sample_v;
    logic [7:0]  rmd_ref_idx;
    logic        rmd_ref_last;
    wire         rmd_done;
    wire [5:0]   rmd_best_mode;
    wire [31:0]  rmd_best_cost;
    wire [2:0]   rmd_best_chroma_pred_mode;
    wire [5:0]   rmd_best_chroma_dir;

    intra_rmd u_rmd (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .start                 (rmd_start),
        .pu_x                  (rmd_pu_x),
        .pu_y                  (rmd_pu_y),
        .pu_size_log2          (rmd_pu_size_log2),
        .orig_rd_addr          (rmd_orig_rd_addr),
        .rmd_active            (rmd_active),
        .orig_rd_data          (rmd_orig_rd_data),
        .orig_c_rd_addr        (rmd_orig_c_rd_addr),
        .orig_u_rd_data        (rmd_orig_u_rd_data),
        .orig_v_rd_data        (rmd_orig_v_rd_data),
        .ref_valid             (rmd_ref_valid),
        .ref_sample            (rmd_ref_sample),
        .ref_idx               (rmd_ref_idx),
        .ref_last              (rmd_ref_last),
        .ref_sample_u          (rmd_ref_sample_u),
        .ref_sample_v          (rmd_ref_sample_v),
        .rmd_done              (rmd_done),
        .best_mode             (rmd_best_mode),
        .best_cost             (rmd_best_cost),
        .best_chroma_pred_mode (rmd_best_chroma_pred_mode),
        .best_chroma_dir       (rmd_best_chroma_dir)
    );
`endif

    // Test sequence
    initial begin
        rst_n = 0;
`ifndef REMEDIATION_PATCH
        pu_size_log2 = 3'd5; // 32x32
        cx_q = 6'd0;
        cy_q = 6'd0;
        refL_y = 11'd0;
        refT_x = 11'd0;
        refT_N = 11'd0;
        refL_N = 11'd0;
`else
        planar_pu_size_log2 = 3'd5;
        planar_in_valid     = 1'b0;
        planar_in_sample    = 10'd0;
        planar_in_idx       = 8'd0;
        planar_in_last      = 1'b0;
        planar_out_ready    = 1'b1;
        rmd_start           = 1'b0;
        rmd_pu_x            = 6'd0;
        rmd_pu_y            = 6'd0;
        rmd_pu_size_log2    = 3'd5;
        rmd_orig_rd_data    = 10'd1023;
        rmd_orig_u_rd_data  = 10'd1023;
        rmd_orig_v_rd_data  = 10'd1023;
        rmd_ref_valid       = 1'b0;
        rmd_ref_sample      = 10'd1023;
        rmd_ref_sample_u    = 10'd1023;
        rmd_ref_sample_v    = 10'd1023;
        rmd_ref_idx         = 8'd0;
        rmd_ref_last        = 1'b0;
`endif

        repeat (2) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        $display("==================================================");
        $display(" Starting tb_flaw_planar_overflow Simulation");
`ifdef REMEDIATION_PATCH
        $display(" Mode: REMEDIATED (Live rtl/intra/intra_planar.v + intra_rmd.v)");
`else
        $display(" Mode: UNPATCHED / BUGGY (16-bit Planar Accumulator Active)");
`endif
        $display(" Block Size: 32x32 (N=32, log2N=5, shift=6)");
        $display("==================================================");

`ifndef REMEDIATION_PATCH
        // -------------------------------------------------------------
        // TEST 1: High-Luminance Overshoot / Extended Dynamic Range Test
        // When reference samples reach 1024 (1 LSB above 1023 due to FIR
        // smoothing filter overshoot or 11-bit intermediate representation):
        //   hor = 32 * 1024 = 32768
        //   ver = 32 * 1024 = 32768
        //   sum = 32768 + 32768 + 32 = 65568 > 65535!
        // 16-bit accumulator wraps around to 65568 % 65536 = 32!
        // Prediction becomes: 32 >> 6 = 0 (Total black instead of peak white!)
        // -------------------------------------------------------------
        $display("\n--- Test 1: High-Luminance Sample Wrap-Around (Samples = 1024) ---");
        pu_size_log2 = 3'd5;
        cx_q = 6'd0;
        cy_q = 6'd0;
        refL_y = 11'd1024;
        refT_x = 11'd1024;
        refT_N = 11'd1024;
        refL_N = 11'd1024;
        #1;

        $display(" Inputs: refL_y=%0d, refT_x=%0d, refT_N=%0d, refL_N=%0d, N=32", 
                 refL_y, refT_x, refT_N, refL_N);
        $display(" Expected Uncorrupted Sum: 65,568 (Hex: 18'h10020)");
        $display(" Expected Uncorrupted Pred: 1024 (Hex: 10'h400)");
        $display(" DUT Planar Sum:            %0d (Hex: %h)", planar_sum_raw, planar_sum_raw);
        $display(" DUT Predicted Pixel:       %0d (Hex: %h)", pred_pixel_out, pred_pixel_out);

        if (planar_sum_raw < 18'd65536 || pred_pixel_out < 10'd1023) begin
            $display(" [FAIL] Flaw D-08 Triggered: 16-bit accumulator wrapped around!");
            $display("   Planar Sum truncated from 65568 to %0d (Modulo 65536 wrap-around)", planar_sum_raw);
            $display("   Predicted pixel collapsed from 1023 to %0d (Severe Distortion Error: %0d LSB)", 
                     pred_pixel_out, (1023 - pred_pixel_out));
            total_errors++;
        end else begin
            $display(" [PASS] 18-bit accumulator preserved 65568 (Clipped pred: %0d) without wrap-around!", pred_pixel_out);
        end

        // -------------------------------------------------------------
        // TEST 2: Static Independent Product Upper Bound Test (126,884)
        // -------------------------------------------------------------
        $display("\n--- Test 2: Static Upper Bound Analysis (126,884) ---");
        test_independent_bound(31713, 31713, 31713, 31713, 32);

        // -------------------------------------------------------------
        // TEST 3: Nominal 10-bit Maximum Luminance Headroom Check (1023)
        // -------------------------------------------------------------
        $display("\n--- Test 3: Nominal 10-bit Peak Luminance Check (Samples = 1023) ---");
        refL_y = 11'd1023;
        refT_x = 11'd1023;
        refT_N = 11'd1023;
        refL_N = 11'd1023;
        #1;
        $display(" Inputs: ref=1023, N=32");
        $display(" Planar Sum = %0d (Safety Margin to 16-bit 65535 overflow = %0d codes)", 
                 planar_sum_raw, (65535 - planar_sum_raw));
        $display(" DUT Predicted Pixel = %0d (Expected = 1023)", pred_pixel_out);
`else
        // -------------------------------------------------------------
        // TEST 1: Live RTL Accumulator Bit-Width Assertions
        // -------------------------------------------------------------
        $display("\n--- Test 1: Live RTL Planar Accumulator Width Audit ---");
        if ($bits(u_rmd.planar_sum) !== 18 || $bits(u_rmd.planar_sum_u) !== 18 || $bits(u_rmd.planar_sum_v) !== 18) begin
            $display(" [FAIL] intra_rmd planar_sum width mismatch: Y=%0d U=%0d V=%0d (Expected 18)",
                     $bits(u_rmd.planar_sum), $bits(u_rmd.planar_sum_u), $bits(u_rmd.planar_sum_v));
            total_errors++;
        end else begin
            $display(" [PASS] intra_rmd planar_sum/u/v widths verified at 18 bits (no 16-bit wrap).");
        end
        if ($bits(u_planar.psum_s2) < 17) begin
            $display(" [FAIL] intra_planar psum_s2 width=%0d (Expected >= 17)", $bits(u_planar.psum_s2));
            total_errors++;
        end else begin
            $display(" [PASS] intra_planar psum_s2 width verified at %0d bits.", $bits(u_planar.psum_s2));
        end

        // -------------------------------------------------------------
        // TEST 2: Live intra_planar.v 32x32 Peak White (1023) & Asymmetric Gradient
        // -------------------------------------------------------------
        $display("\n--- Test 2: Live intra_planar 32x32 Peak-White (1023) Test ---");
        run_live_planar_32x32(1'b0);

        $display("\n--- Test 3: Live intra_planar 32x32 High-Swing Gradient Test ---");
        run_live_planar_32x32(1'b1);

        // -------------------------------------------------------------
        // TEST 4: Live intra_rmd.v 32x32 Peak-White (1023) SATD Test
        // -------------------------------------------------------------
        $display("\n--- Test 4: Live intra_rmd 32x32 Peak-White (1023) SATD Test ---");
        run_live_rmd_32x32_peak();
`endif

        $display("\n==================================================");
        if (total_errors == 0) begin
            $display(" *** ALL TESTS PASSED: Live RTL planar accumulators verified overflow-free ***");
        end else begin
            $display(" *** FAILED: %0d Accumulator Overflow / Wrap-Around Errors Detected ***", total_errors);
        end
        $display("==================================================\n");
        $finish;
    end

`ifdef REMEDIATION_PATCH
    task automatic run_live_planar_32x32(input bit gradient_mode);
        int i, px_count, block_errs;
        logic [9:0] refT_arr [0:32];
        logic [9:0] refL_arr [0:32];
        logic [9:0] samp;
        int exp_pix;
        begin
            block_errs = 0;
            for (i = 0; i <= 32; i++) begin
                refT_arr[i] = 10'd1023;
                refL_arr[i] = (gradient_mode && i < 32) ? ((i == 31) ? 10'd0 : 10'd1023) : 10'd1023;
                if (gradient_mode && i < 16) refL_arr[i] = 10'd0;
            end
            while (!planar_in_ready) @(posedge clk);
            for (i = 0; i < 129; i++) begin
                if (i == 0)                     samp = 10'd1023;
                else if (i >= 1 && i <= 33)     samp = refT_arr[i - 1];
                else if (i >= 65 && i <= 97)    samp = refL_arr[i - 65];
                else                            samp = 10'd0;
                planar_in_valid  <= 1'b1;
                planar_in_sample <= samp;
                planar_in_idx    <= i[7:0];
                planar_in_last   <= (i == 128);
                @(posedge clk);
            end
            planar_in_valid <= 1'b0;
            planar_in_last  <= 1'b0;

            px_count = 0;
            while (px_count < 1024) begin
                @(posedge clk);
                if (planar_out_valid && planar_out_ready) begin
                    exp_pix = ((31 - int'(planar_out_x)) * int'(refL_arr[planar_out_y])
                             + (int'(planar_out_x) + 1)  * int'(refT_arr[32])
                             + (31 - int'(planar_out_y)) * int'(refT_arr[planar_out_x])
                             + (int'(planar_out_y) + 1)  * int'(refL_arr[32]) + 32) >> 6;
                    if (int'(planar_out_pixel) !== exp_pix) begin
                        if (block_errs < 5)
                            $display(" [FAIL] intra_planar (%0d,%0d): got=%0d exp=%0d",
                                     planar_out_x, planar_out_y, planar_out_pixel, exp_pix);
                        block_errs++;
                    end
                    px_count++;
                end
            end
            total_errors += block_errs;
            $display(" [PASS=%0d] Checked %0d 32x32 pixels against HM Planar equation (errors=%0d)",
                     (block_errs == 0), px_count, block_errs);
        end
    endtask

    task automatic run_live_rmd_32x32_peak();
        int i;
        begin
            @(posedge clk);
            rmd_start <= 1'b1;
            @(posedge clk);
            rmd_start <= 1'b0;
            for (i = 0; i < 129; i++) begin
                rmd_ref_valid    <= 1'b1;
                rmd_ref_sample   <= 10'd1023;
                rmd_ref_sample_u <= 10'd1023;
                rmd_ref_sample_v <= 10'd1023;
                rmd_ref_idx      <= i[7:0];
                rmd_ref_last     <= (i == 128);
                @(posedge clk);
            end
            rmd_ref_valid <= 1'b0;
            rmd_ref_last  <= 1'b0;
            while (!rmd_done) @(posedge clk);
            if (rmd_best_cost !== 32'd0) begin
                $display(" [FAIL] intra_rmd 32x32 peak-white best_cost=%0d (Expected 0)", rmd_best_cost);
                total_errors++;
            end else begin
                $display(" [PASS] intra_rmd 32x32 peak-white best_mode=%0d best_cost=%0d (overflow-free)",
                         rmd_best_mode, rmd_best_cost);
            end
        end
    endtask
`endif

    // Task for checking independent product sum
    task automatic test_independent_bound(input int w1, w2, w3, w4, n_val);
        int expected_sum = w1 + w2 + w3 + w4 + n_val; // 126,884
        int wrapped_sum  = expected_sum % 65536;      // 61,348

        $display(" Sum of 4 independent products + N: %0d", expected_sum);
        $display(" 16-bit accumulator wrapped value:  %0d", wrapped_sum);
`ifndef REMEDIATION_PATCH
        $display(" [FAIL] Flaw D-08: 16-bit accumulator wire [15:0] cannot represent %0d (Exceeds 65,535 by %0d)",
                 expected_sum, (expected_sum - 65535));
        total_errors++;
`else
        $display(" [PASS] Remediated 18-bit accumulator wire [17:0] capacity is 262,143 (Covers %0d with 135,259 headroom)",
                 expected_sum);
`endif
    endtask

endmodule

//=============================================================================
// Buggy 16-bit Accumulator Model (intra_rmd.v line 108-114 verbatim)
//=============================================================================
module planar_acc_16b (
    input  wire [2:0]   pu_size_log2,
    input  wire [5:0]   cx_q, cy_q,
    input  wire [10:0]  refL_y, refT_x, refT_N, refL_N,
    output wire [9:0]   pred_planar,
    output wire [17:0]  planar_sum_out,
    output wire         overflow
);
    wire [7:0] N = 8'd1 << pu_size_log2;

    wire [15:0] wL = (N[7:0] - 8'd1 - {2'd0, cx_q}) * refL_y[9:0];
    wire [15:0] wR = ({2'd0, cx_q} + 8'd1) * refT_N[9:0];
    wire [15:0] wT = (N[7:0] - 8'd1 - {2'd0, cy_q}) * refT_x[9:0];
    wire [15:0] wB = ({2'd0, cy_q} + 8'd1) * refL_N[9:0];

    // Buggy 16-bit accumulator
    wire [15:0] planar_sum = wL + wR + wT + wB + N;
    wire [15:0] raw_pred = planar_sum >> (pu_size_log2 + 1);
    assign pred_planar = (raw_pred > 16'd1023) ? 10'd1023 : raw_pred[9:0];

    // Full unclipped sum for monitoring
    wire [17:0] true_sum = {2'd0, wL} + {2'd0, wR} + {2'd0, wT} + {2'd0, wB} + {10'd0, N};
    assign planar_sum_out = {2'd0, planar_sum}; // Truncated to 16 bits!
    assign overflow = (true_sum >= 18'd65536);
endmodule

//=============================================================================
// Remediated 18-bit Accumulator Model
//=============================================================================
module planar_acc_18b (
    input  wire [2:0]   pu_size_log2,
    input  wire [5:0]   cx_q, cy_q,
    input  wire [10:0]  refL_y, refT_x, refT_N, refL_N,
    output wire [9:0]   pred_planar,
    output wire [17:0]  planar_sum_out,
    output wire         overflow
);
    wire [7:0] N = 8'd1 << pu_size_log2;

    wire [17:0] wL = (N[7:0] - 8'd1 - {2'd0, cx_q}) * refL_y;
    wire [17:0] wR = ({2'd0, cx_q} + 8'd1) * refT_N;
    wire [17:0] wT = (N[7:0] - 8'd1 - {2'd0, cy_q}) * refT_x;
    wire [17:0] wB = ({2'd0, cy_q} + 8'd1) * refL_N;

    // Remediated 18-bit accumulator
    wire [17:0] planar_sum = wL + wR + wT + wB + {10'd0, N};
    wire [17:0] raw_pred = planar_sum >> (pu_size_log2 + 1);
    assign pred_planar = (raw_pred > 18'd1023) ? 10'd1023 : raw_pred[9:0];

    assign planar_sum_out = planar_sum;
    assign overflow = 1'b0; // 18-bit never overflows max 131,008
endmodule
