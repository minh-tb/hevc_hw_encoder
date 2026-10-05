//=============================================================================
// tb_flaw_syntax_coeff_cg.sv
// Adversarial Algorithmic Verification Testbench for HEVC Encoder Subsystem
//
// Target Flaw: D-03 (CRITICAL): 8x8 TU Coefficient Group (CG) coordinate aliasing
// Module: rtl/entropy/syntax_coeff.v
// Normative Reference: ITU-T H.265 Clause 7.4.9.11, Table 7-40, HM getCoefScanIdx
//
// Verification Objective:
//   - Assert and FAIL on buggy RTL behavior (CG 3 coordinates aliasing onto CG 0)
//   - Assert and PASS when remediated code is active (CG 3 coordinates (1,1))
//=============================================================================

`timescale 1ns/1ps
`include "parameter_pkg.vh"

module tb_flaw_syntax_coeff_cg;

    // Clock and reset
    logic        clk;
    logic        rst_n;

    // DUT Interface Signals
    logic        coeff_valid;
    logic        cu_valid;
    logic [1:0]  cu_depth;
    logic        coeff_done;

    logic [1:0]  comp_id;
    logic        is_intra;
    logic        is_merge;
    logic [2:0]  tu_size_log2;
    logic        tu_cbf;
    logic [9:0]  last_sig_pos;

    logic        coeff_rd_en;
    logic [11:0] coeff_rd_addr;
    logic signed [15:0] coeff_rd_data;

    logic        bin_valid;
    logic        bin_value;
    logic [7:0]  bin_ctx_id;
    logic        bin_is_ep;
    logic        bin_rdy;

    // DUT Instantiation
    syntax_coeff #(
        .CTX_ID_W(8),
        .COEFF_W(16),
        .MAX_RICE(4)
    ) dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .coeff_valid   (coeff_valid),
        .cu_valid      (cu_valid),
        .cu_depth      (cu_depth),
        .coeff_done    (coeff_done),
        .comp_id       (comp_id),
        .is_intra      (is_intra),
        .is_merge      (is_merge),
        .tu_size_log2  (tu_size_log2),
        .tu_cbf        (tu_cbf),
        .last_sig_pos  (last_sig_pos),
        .coeff_rd_en   (coeff_rd_en),
        .coeff_rd_addr (coeff_rd_addr),
        .coeff_rd_data (coeff_rd_data),
        .bin_valid     (bin_valid),
        .bin_value     (bin_value),
        .bin_ctx_id    (bin_ctx_id),
        .bin_is_ep     (bin_is_ep),
        .bin_rdy       (bin_rdy)
    );

    // Clock Generation: 100 MHz (10ns period)
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // Timeout Watchdog Guard
    initial begin
        #500000; // 500 us limit
        $display("\n[FATAL TIMEOUT] Simulation exceeded cycle limit. Deadlock detected!");
        $finish(2);
    end

    // Mock coeff_buffer memory for 8x8 TU
    logic signed [15:0] tu_coeffs [0:63];

    always_comb begin
        if (coeff_rd_en && coeff_rd_addr < 12'd64)
            coeff_rd_data = tu_coeffs[coeff_rd_addr];
        else
            coeff_rd_data = 16'd0;
    end

    // Normative HEVC Scan Reference functions
    function automatic [1:0] ref_diag_4_row(input [3:0] pos);
        reg [1:0] lut [0:15];
        begin
            lut[ 0]=2'd0; lut[ 1]=2'd1; lut[ 2]=2'd0; lut[ 3]=2'd2;
            lut[ 4]=2'd1; lut[ 5]=2'd0; lut[ 6]=2'd3; lut[ 7]=2'd2;
            lut[ 8]=2'd1; lut[ 9]=2'd0; lut[10]=2'd3; lut[11]=2'd2;
            lut[12]=2'd1; lut[13]=2'd3; lut[14]=2'd2; lut[15]=2'd3;
            ref_diag_4_row = lut[pos];
        end
    endfunction

    function automatic [1:0] ref_diag_4_col(input [3:0] pos);
        reg [1:0] lut [0:15];
        begin
            lut[ 0]=2'd0; lut[ 1]=2'd0; lut[ 2]=2'd1; lut[ 3]=2'd0;
            lut[ 4]=2'd1; lut[ 5]=2'd2; lut[ 6]=2'd0; lut[ 7]=2'd1;
            lut[ 8]=2'd2; lut[ 9]=2'd3; lut[10]=2'd1; lut[11]=2'd2;
            lut[12]=2'd3; lut[13]=2'd2; lut[14]=2'd3; lut[15]=2'd3;
            ref_diag_4_col = lut[pos];
        end
    endfunction

    // Normative 8x8 TU coordinate calculation per Clause 7.4.9.11 / Table 7-40
    // CG grid is 2x2: scanCG order is (0,0)->(0,1)->(1,0)->(1,1)
    function automatic [4:0] norm_8x8_x(input [9:0] scan);
        reg [1:0] cg_idx;
        reg [1:0] cg_x;
        reg [1:0] sub_x;
        begin
            cg_idx = scan[5:4];
            cg_x   = cg_idx[1]; // bit 1 of 2x2 scan index is x
            sub_x  = ref_diag_4_col(scan[3:0]);
            norm_8x8_x = {2'd0, cg_x, sub_x};
        end
    endfunction

    function automatic [4:0] norm_8x8_y(input [9:0] scan);
        reg [1:0] cg_idx;
        reg [1:0] cg_y;
        reg [1:0] sub_y;
        begin
            cg_idx = scan[5:4];
            cg_y   = cg_idx[0]; // bit 0 of 2x2 scan index is y
            sub_y  = ref_diag_4_row(scan[3:0]);
            norm_8x8_y = {2'd0, cg_y, sub_y};
        end
    endfunction

    // Verification counters
    int total_tests = 0;
    int error_count = 0;
    int cg3_tested  = 0;
    int cg3_failed  = 0;

    // Test execution task
    task automatic test_8x8_last_pos(
        input [9:0] test_scan_pos,
        input string desc
    );
        logic [4:0] exp_x, exp_y;
        logic [4:0] got_x, got_y;
        logic [1:0] cg_idx;
        int timeout;

        total_tests++;
        cg_idx = test_scan_pos[5:4];
        exp_x = norm_8x8_x(test_scan_pos);
        exp_y = norm_8x8_y(test_scan_pos);

        // Populate mock memory with zero except last_sig_pos
        for (int i = 0; i < 64; i++) tu_coeffs[i] = 16'd0;
        tu_coeffs[test_scan_pos] = 16'sd1;

        // Drive TU encode request
        @(posedge clk);
        cu_valid     <= 1'b1;
        cu_depth     <= 2'd3; // 8x8 CU
        @(posedge clk);
        cu_valid     <= 1'b0;

        coeff_valid  <= 1'b1;
        comp_id      <= 2'd0; // Luma
        is_intra     <= 1'b1;
        is_merge     <= 1'b0;
        tu_size_log2 <= 3'd3; // 8x8 TU
        tu_cbf       <= 1'b1;
        last_sig_pos <= test_scan_pos;
        @(posedge clk);
        coeff_valid  <= 1'b0;

        // Latch coordinates from DUT internal registers
        @(posedge clk);
        got_x = dut.last_sig_x_r;
        got_y = dut.last_sig_y_r;

        if (cg_idx == 2'd3) begin
            cg3_tested++;
        end

        // Check against normative expectation
        if (got_x !== exp_x || got_y !== exp_y) begin
            error_count++;
            if (cg_idx == 2'd3) cg3_failed++;
            $display("[SPEC DEVIATION DETECTED] %s", desc);
            $display("  ScanPos=%0d (CG %0d, sub-pos %0d): Expected=(x=%0d, y=%0d), Got=(x=%0d, y=%0d)",
                     test_scan_pos, cg_idx, test_scan_pos[3:0], exp_x, exp_y, got_x, got_y);
            if (cg_idx == 2'd3 && got_x < 4 && got_y < 4) begin
                $display("  --> FLAW D-03 ALIASING CONFIRMED: CG 3 mapped to CG 0 coordinates (cx[0]=0, cy[0]=0)!");
            end
        end else begin
            $display("[PASS] %s: ScanPos=%0d -> (x=%0d, y=%0d) matches ITU-T H.265 Clause 7.4.9.11",
                     desc, test_scan_pos, got_x, got_y);
        end

        // Wait for TU completion or small cycle count
        timeout = 0;
        while (!coeff_done && timeout < 200) begin
            @(posedge clk);
            timeout++;
        end
        repeat(2) @(posedge clk);
    endtask

    // Main Test Stimulus
    initial begin
        // Reset sequence
        rst_n        <= 1'b0;
        coeff_valid  <= 1'b0;
        cu_valid     <= 1'b0;
        cu_depth     <= 2'd0;
        comp_id      <= 2'd0;
        is_intra     <= 1'b0;
        is_merge     <= 1'b0;
        tu_size_log2 <= 3'd3;
        tu_cbf       <= 1'b0;
        last_sig_pos <= 10'd0;
        bin_rdy      <= 1'b1;

        repeat(5) @(posedge clk);
        rst_n <= 1'b1;
        repeat(2) @(posedge clk);

        $display("==================================================================");
        $display(" Running Flaw Verification: D-03 (8x8 TU CG Coordinate Aliasing)");
        $display(" Target Module: rtl/entropy/syntax_coeff.v");
        $display(" Normative Spec: ITU-T H.265 Clause 7.4.9.11, Table 7-40");
        $display("==================================================================");

        // Test CG 0 (Top-Left 4x4, scan 0..15): Expected coordinates in [0..3, 0..3]
        test_8x8_last_pos(10'd0,  "CG 0 DC (0,0)");
        test_8x8_last_pos(10'd15, "CG 0 last sub-pos (3,3)");

        // Test CG 1 (Bottom-Left 4x4, scan 16..31): Expected coordinates in [0..3, 4..7]
        test_8x8_last_pos(10'd16, "CG 1 first pos (0,4)");
        test_8x8_last_pos(10'd31, "CG 1 last sub-pos (3,7)");

        // Test CG 2 (Top-Right 4x4, scan 32..47): Expected coordinates in [4..7, 0..3]
        test_8x8_last_pos(10'd32, "CG 2 first pos (4,0)");
        test_8x8_last_pos(10'd47, "CG 2 last sub-pos (7,3)");

        // Test CG 3 (Bottom-Right 4x4, scan 48..63): MUST BE in [4..7, 4..7]
        // BUGGY RTL will map these to [0..3, 0..3] (aliasing onto CG 0)!
        test_8x8_last_pos(10'd48, "CG 3 first pos (4,4)");
        test_8x8_last_pos(10'd55, "CG 3 mid pos (6,5)");
        test_8x8_last_pos(10'd63, "CG 3 last pos (7,7)");

        $display("\n==================================================================");
        $display(" VERIFICATION SUMMARY");
        $display(" Total Tests: %0d | Failures: %0d", total_tests, error_count);
        $display(" CG 3 Tests:  %0d | CG 3 Failures: %0d", cg3_tested, cg3_failed);
        $display("==================================================================");

        if (error_count == 0) begin
            $display(" *** ALL %0d TESTS PASSED SPECIFICATION *** ", total_tests);
            $display("==================================================================");
            $finish(0);
        end else begin
            $display(" *** FLAW D-03 CONFIRMED: %0d ERRORS OUT OF %0d TESTS *** ",
                     error_count, total_tests);
            $display(" 8x8 TU CG 3 coordinates aliased onto CG 0 due to 1-bit slicing bug!");
            $display("==================================================================");
            $finish(1);
        end
    end

endmodule
