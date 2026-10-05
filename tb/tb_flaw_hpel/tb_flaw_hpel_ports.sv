//=============================================================================
// tb_flaw_hpel_ports.sv
// Dual-State Algorithmic Verification Testbench for Flaw D-13:
// Sub-Pel Fractional Filter Port Disconnections & Integer Truncation
//
// Normative Reference:
//   - ITU-T H.265 (Main10 Profile) Clause 8.5.3.2.2 (Luma sample interpolation)
//   - ITU-T H.265 (Main10 Profile) Clause 8.5.3.2.3 (Chroma sample interpolation)
//   - HM 18.0 Reference Software:
//       TLibCommon/TComInterpolationFilter.cpp :: filter<8>() & filter<4>()
//       TLibCommon/TComRom.cpp :: g_lumaFilter, g_chromaFilter
//
// Target Bug:
//   In tb/tb_hpel_filter_luma/tb_hpel_filter_luma.sv and
//   tb/tb_hpel_filter_chroma/tb_interp_filter_chroma.sv (and sub-pel wrappers),
//   hpel_filter_luma and hpel_filter_chroma were instantiated WITHOUT connecting
//   frac_x and frac_y input ports.
//   Floating/unconnected frac inputs default to 0 (integer pel), forcing the
//   hardware FIR engine into 'default: sum = 64 * integer_pixel', completely
//   bypassing the 8-tap luma and 4-tap chroma sub-pel interpolation filters.
//
// Dual-State Protocol:
//   - Default (Buggy State): Instantiates filters with floating/disconnected
//     frac_x / frac_y ports. Exercises non-zero fractional phases against
//     normative HM 18.0 FIR reference calculations. Asserts and FAILS due to
//     integer truncation discrepancies.
//   - Remediated State (+define+REMEDIATION): Instantiates filters with frac_x
//     and frac_y explicitly driven. Asserts and PASSES with zero errors.
//=============================================================================

`timescale 1ns/1ps
`include "parameter_pkg.vh"

module tb_flaw_hpel_ports;

    localparam PIXEL_WIDTH = `PIXEL_WIDTH; // 10-bit
    localparam BLK_SIZE    = 4;            // 4x4 blocks
    localparam BLK_EXT_Y   = BLK_SIZE + 7; // 11x11 extended luma
    localparam BLK_EXT_C   = BLK_SIZE + 3; // 7x7 extended chroma

    logic clk;
    logic rst_n;
    logic valid_in;

    // Test stimulus controls
    logic [1:0] stim_frac_x;
    logic [1:0] stim_frac_y;
    logic [2:0] stim_c_frac_x;
    logic [2:0] stim_c_frac_y;

    // Input pixel buffers
    logic [PIXEL_WIDTH*BLK_EXT_Y*BLK_EXT_Y-1:0] ref_luma_ext;
    logic [PIXEL_WIDTH*BLK_EXT_C*BLK_EXT_C-1:0] ref_chroma_ext;

    // DUT output wires
    wire luma_valid_out;
    wire [PIXEL_WIDTH*BLK_SIZE*BLK_SIZE-1:0] luma_h_out;
    wire [PIXEL_WIDTH*BLK_SIZE*BLK_SIZE-1:0] luma_v_out;
    wire [PIXEL_WIDTH*BLK_SIZE*BLK_SIZE-1:0] luma_hv_out;

    wire chroma_valid_out;
    wire [PIXEL_WIDTH*BLK_SIZE*BLK_SIZE-1:0] chroma_h_out;
    wire [PIXEL_WIDTH*BLK_SIZE*BLK_SIZE-1:0] chroma_v_out;
    wire [PIXEL_WIDTH*BLK_SIZE*BLK_SIZE-1:0] chroma_hv_out;

`ifdef REMEDIATION
    // REMEDIATED STATE: frac_x and frac_y are properly connected and driven
    localparam IS_REMEDIATED = 1;

    hpel_filter_luma #(
        .PIXEL_WIDTH(PIXEL_WIDTH),
        .BLK_SIZE   (BLK_SIZE)
    ) u_luma_filter (
        .clk         (clk),
        .rst_n       (rst_n),
        .valid_in    (valid_in),
        .frac_x      (stim_frac_x),   // CONNECTED PROPERLY
        .frac_y      (stim_frac_y),   // CONNECTED PROPERLY
        .ref_ext_flat(ref_luma_ext),
        .valid_out   (luma_valid_out),
        .h_out_flat  (luma_h_out),
        .v_out_flat  (luma_v_out),
        .hv_out_flat (luma_hv_out)
    );

    hpel_filter_chroma #(
        .PIXEL_WIDTH(PIXEL_WIDTH),
        .BLK_SIZE   (BLK_SIZE)
    ) u_chroma_filter (
        .clk         (clk),
        .rst_n       (rst_n),
        .valid_in    (valid_in),
        .frac_x      (stim_c_frac_x), // CONNECTED PROPERLY
        .frac_y      (stim_c_frac_y), // CONNECTED PROPERLY
        .ref_ext_flat(ref_chroma_ext),
        .valid_out   (chroma_valid_out),
        .h_out_flat  (chroma_h_out),
        .v_out_flat  (chroma_v_out),
        .hv_out_flat (chroma_hv_out)
    );

`else
    // BUGGY STATE: frac_x and frac_y ports are omitted / floating (reproducing the bug)
    localparam IS_REMEDIATED = 0;

    hpel_filter_luma #(
        .PIXEL_WIDTH(PIXEL_WIDTH),
        .BLK_SIZE   (BLK_SIZE)
    ) u_luma_filter (
        .clk         (clk),
        .rst_n       (rst_n),
        .valid_in    (valid_in),
        // .frac_x   -- OMITTED (FLOATING / UNCONNECTED)
        // .frac_y   -- OMITTED (FLOATING / UNCONNECTED)
        .ref_ext_flat(ref_luma_ext),
        .valid_out   (luma_valid_out),
        .h_out_flat  (luma_h_out),
        .v_out_flat  (luma_v_out),
        .hv_out_flat (luma_hv_out)
    );

    hpel_filter_chroma #(
        .PIXEL_WIDTH(PIXEL_WIDTH),
        .BLK_SIZE   (BLK_SIZE)
    ) u_chroma_filter (
        .clk         (clk),
        .rst_n       (rst_n),
        .valid_in    (valid_in),
        // .frac_x   -- OMITTED (FLOATING / UNCONNECTED)
        // .frac_y   -- OMITTED (FLOATING / UNCONNECTED)
        .ref_ext_flat(ref_chroma_ext),
        .valid_out   (chroma_valid_out),
        .h_out_flat  (chroma_h_out),
        .v_out_flat  (chroma_v_out),
        .hv_out_flat (chroma_hv_out)
    );
`endif

    // Clock generator: 100 MHz
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // Watchdog
    initial begin
        #500000;
        $display("\n[FATAL TIMEOUT] Simulation watchdog tripped.");
        $finish(2);
    end

    // 10-bit clipping helper
    function automatic int clip10(input int v);
        if (v < 0) return 0;
        if (v > 1023) return 1023;
        return v;
    endfunction

    // Normative Luma 8-tap filter coefficients (Clause 8.5.3.2.2 / HM g_lumaFilter)
    function automatic int get_luma_coeff(input int phase, input int tap);
        int c[4][8];
        c[0] = '{  0,  0,   0, 64,  0,   0,  0,  0 }; // Phase 0
        c[1] = '{ -1,  4, -10, 58, 17,  -5,  1,  0 }; // Phase 1 (1/4)
        c[2] = '{ -1,  4, -11, 40, 40, -11,  4, -1 }; // Phase 2 (1/2)
        c[3] = '{  0,  1,  -5, 17, 58, -10,  4, -1 }; // Phase 3 (3/4)
        return c[phase][tap];
    endfunction

    // Normative Chroma 4-tap filter coefficients (Clause 8.5.3.2.3 / HM g_chromaFilter)
    function automatic int get_chroma_coeff(input int phase, input int tap);
        int c[8][4];
        c[0] = '{  0, 64,  0,  0 };
        c[1] = '{ -2, 58, 10, -2 };
        c[2] = '{ -4, 54, 16, -2 };
        c[3] = '{ -6, 46, 28, -4 };
        c[4] = '{ -4, 36, 36, -4 };
        c[5] = '{ -4, 28, 46, -6 };
        c[6] = '{ -2, 16, 54, -4 };
        c[7] = '{ -2, 10, 58, -2 };
        return c[phase][tap];
    endfunction

    // Golden Luma Model
    task automatic calc_golden_luma(
        input logic [PIXEL_WIDTH*BLK_EXT_Y*BLK_EXT_Y-1:0] ext_flat,
        input int fx,
        input int fy,
        output int exp_h [4][4],
        output int exp_v [4][4],
        output int exp_hv[4][4]
    );
        int px[11][11];
        int hint[11][4];
        int vsum[4][4];
        int hvsum[4][4];

        for (int r = 0; r < 11; r++) begin
            for (int c = 0; c < 11; c++) begin
                px[r][c] = int'(ext_flat[PIXEL_WIDTH*(11*r + c) +: PIXEL_WIDTH]);
            end
        end

        // Horizontal filtering: 11 rows x 4 output cols
        for (int r = 0; r < 11; r++) begin
            for (int c = 0; c < 4; c++) begin
                int sum = 0;
                for (int t = 0; t < 8; t++) sum += get_luma_coeff(fx, t) * px[r][c+t];
                hint[r][c] = sum;
            end
        end

        // Vertical filtering on integer columns: 4 rows x 4 cols (col offset 3)
        for (int r = 0; r < 4; r++) begin
            for (int c = 0; c < 4; c++) begin
                int sum = 0;
                for (int t = 0; t < 8; t++) sum += get_luma_coeff(fy, t) * px[r+t][c+3];
                vsum[r][c] = sum;
            end
        end

        // 2D HV filtering: V filter on hint
        for (int r = 0; r < 4; r++) begin
            for (int c = 0; c < 4; c++) begin
                int sum = 0;
                for (int t = 0; t < 8; t++) sum += get_luma_coeff(fy, t) * hint[r+t][c];
                hvsum[r][c] = sum;
            end
        end

        // Normalization & Clipping
        for (int r = 0; r < 4; r++) begin
            for (int c = 0; c < 4; c++) begin
                exp_h[r][c]  = clip10((hint[r+3][c] + 32) >>> 6);
                exp_v[r][c]  = clip10((vsum[r][c]   + 32) >>> 6);
                exp_hv[r][c] = clip10((hvsum[r][c]  + 2048) >>> 12);
            end
        end
    endtask

    // Golden Chroma Model
    task automatic calc_golden_chroma(
        input logic [PIXEL_WIDTH*BLK_EXT_C*BLK_EXT_C-1:0] ext_flat,
        input int fx,
        input int fy,
        output int exp_h [4][4],
        output int exp_v [4][4],
        output int exp_hv[4][4]
    );
        int px[7][7];
        int hint[7][4];
        int vsum[4][4];
        int hvsum[4][4];

        for (int r = 0; r < 7; r++) begin
            for (int c = 0; c < 7; c++) begin
                px[r][c] = int'(ext_flat[PIXEL_WIDTH*(7*r + c) +: PIXEL_WIDTH]);
            end
        end

        // Horizontal filtering: 7 rows x 4 cols
        for (int r = 0; r < 7; r++) begin
            for (int c = 0; c < 4; c++) begin
                int sum = 0;
                for (int t = 0; t < 4; t++) sum += get_chroma_coeff(fx, t) * px[r][c+t];
                hint[r][c] = sum;
            end
        end

        // Vertical filtering: 4 rows x 4 cols (col offset 1)
        for (int r = 0; r < 4; r++) begin
            for (int c = 0; c < 4; c++) begin
                int sum = 0;
                for (int t = 0; t < 4; t++) sum += get_chroma_coeff(fy, t) * px[r+t][c+1];
                vsum[r][c] = sum;
            end
        end

        // 2D HV filtering
        for (int r = 0; r < 4; r++) begin
            for (int c = 0; c < 4; c++) begin
                int sum = 0;
                for (int t = 0; t < 4; t++) sum += get_chroma_coeff(fy, t) * hint[r+t][c];
                hvsum[r][c] = sum;
            end
        end

        for (int r = 0; r < 4; r++) begin
            for (int c = 0; c < 4; c++) begin
                exp_h[r][c]  = clip10((hint[r+1][c] + 32) >>> 6);
                exp_v[r][c]  = clip10((vsum[r][c]   + 32) >>> 6);
                exp_hv[r][c] = clip10((hvsum[r][c]  + 2048) >>> 12);
            end
        end
    endtask

    int total_tests = 0;
    int error_count = 0;
    int pass_count  = 0;

    // Helper: Initialize test pattern
    task automatic generate_test_pattern(input int pattern_type);
        // Pattern 0: High-contrast sharp edge
        // Pattern 1: Diagonal ramp
        // Pattern 2: Impulse (single high-frequency point)
        for (int r = 0; r < 11; r++) begin
            for (int c = 0; c < 11; c++) begin
                int val;
                case (pattern_type)
                    0: val = (c >= 4) ? 800 : 200; // Step edge
                    1: val = clip10((r * 40) + (c * 50) + 100); // Ramp
                    2: val = (r == 3 && c == 3) ? 950 : 150; // Impulse
                    default: val = 512;
                endcase
                ref_luma_ext[PIXEL_WIDTH*(11*r + c) +: PIXEL_WIDTH] = val[PIXEL_WIDTH-1:0];
            end
        end

        for (int r = 0; r < 7; r++) begin
            for (int c = 0; c < 7; c++) begin
                int val;
                case (pattern_type)
                    0: val = (c >= 2) ? 750 : 250;
                    1: val = clip10((r * 60) + (c * 60) + 120);
                    2: val = (r == 1 && c == 1) ? 900 : 100;
                    default: val = 512;
                endcase
                ref_chroma_ext[PIXEL_WIDTH*(7*r + c) +: PIXEL_WIDTH] = val[PIXEL_WIDTH-1:0];
            end
        end
    endtask

    // Evaluation task
    task automatic test_subpel_interpolation(
        input string desc,
        input int pat,
        input int luma_fx,
        input int luma_fy,
        input int chroma_fx,
        input int chroma_fy
    );
        int exp_lh [4][4], exp_lv [4][4], exp_lhv[4][4];
        int exp_ch [4][4], exp_cv [4][4], exp_chv[4][4];
        int luma_err = 0, chroma_err = 0;

        total_tests++;
        generate_test_pattern(pat);
        stim_frac_x   = luma_fx[1:0];
        stim_frac_y   = luma_fy[1:0];
        stim_c_frac_x = chroma_fx[2:0];
        stim_c_frac_y = chroma_fy[2:0];

        // Golden calculation
        calc_golden_luma(ref_luma_ext, luma_fx, luma_fy, exp_lh, exp_lv, exp_lhv);
        calc_golden_chroma(ref_chroma_ext, chroma_fx, chroma_fy, exp_ch, exp_cv, exp_chv);

        valid_in = 1;
        @(posedge clk);
        valid_in = 0;

        // Wait for 3-stage pipeline latency
        repeat(3) @(posedge clk);

        // Check Luma outputs
        for (int r = 0; r < 4; r++) begin
            for (int c = 0; c < 4; c++) begin
                int got_h  = luma_h_out [PIXEL_WIDTH*(4*r + c) +: PIXEL_WIDTH];
                int got_v  = luma_v_out [PIXEL_WIDTH*(4*r + c) +: PIXEL_WIDTH];
                int got_hv = luma_hv_out[PIXEL_WIDTH*(4*r + c) +: PIXEL_WIDTH];

                if (got_h !== exp_lh[r][c] || got_v !== exp_lv[r][c] || got_hv !== exp_lhv[r][c]) begin
                    luma_err++;
                end
            end
        end

        // Check Chroma outputs
        for (int r = 0; r < 4; r++) begin
            for (int c = 0; c < 4; c++) begin
                int got_h  = chroma_h_out [PIXEL_WIDTH*(4*r + c) +: PIXEL_WIDTH];
                int got_v  = chroma_v_out [PIXEL_WIDTH*(4*r + c) +: PIXEL_WIDTH];
                int got_hv = chroma_hv_out[PIXEL_WIDTH*(4*r + c) +: PIXEL_WIDTH];

                if (got_h !== exp_ch[r][c] || got_v !== exp_cv[r][c] || got_hv !== exp_chv[r][c]) begin
                    chroma_err++;
                end
            end
        end

        $display("----------------------------------------------------------------");
        $display("[Case %0d] %s", total_tests, desc);
        $display("  Luma Phase   : frac_x=%0d, frac_y=%0d | Errors: %0d", luma_fx, luma_fy, luma_err);
        $display("  Chroma Phase : frac_x=%0d, frac_y=%0d | Errors: %0d", chroma_fx, chroma_fy, chroma_err);

        if (luma_err > 0 || chroma_err > 0) begin
            $display("  >>> DEVIATION: Floating ports caused integer replication mismatch!");
            error_count++;
        end else begin
            $display("  >>> PASS: Sub-pel FIR filter matched normative specification.");
            pass_count++;
        end
    endtask

    // Main Test Stimulus
    initial begin
        valid_in = 0;
        stim_frac_x = 0;
        stim_frac_y = 0;
        stim_c_frac_x = 0;
        stim_c_frac_y = 0;
        ref_luma_ext = '0;
        ref_chroma_ext = '0;

        rst_n = 0;
        #20 rst_n = 1;
        #10;

        $display("================================================================");
        $display(" HEVC DUAL-STATE VERIFICATION: Flaw D-13 (Sub-pel Port Connect)");
        $display(" Target Spec: ITU-T H.265 Clause 8.5.3.2.2 / 8.5.3.2.3");
        $display(" Configuration: %s State", IS_REMEDIATED ? "REMEDIATED" : "BUGGY (FLOATING PORTS)");
        $display("================================================================");

        // Test 1: Half-Pel Horizontal (frac_x=2, frac_y=0) on Step Edge
        test_subpel_interpolation(
            "Half-Pel Luma (fx=2, fy=0) & Chroma (cfx=4, cfy=0) on Step Edge",
            0, 2, 0, 4, 0
        );

        // Test 2: Quarter-Pel Horizontal (frac_x=1, frac_y=0) on Ramp
        test_subpel_interpolation(
            "Quarter-Pel Luma (fx=1, fy=0) & 1/8-Pel Chroma (cfx=1, cfy=0) on Ramp",
            1, 1, 0, 1, 0
        );

        // Test 3: 3/4-Pel Luma (frac_x=3, frac_y=0) & 3/8-Pel Chroma (cfx=3, cfy=0) on Impulse
        test_subpel_interpolation(
            "3/4-Pel Luma (fx=3, fy=0) & 3/8-Pel Chroma (cfx=3, cfy=0) on Impulse",
            2, 3, 0, 3, 0
        );

        // Test 4: Vertical Half-Pel (frac_x=0, frac_y=2) on Step Edge
        test_subpel_interpolation(
            "Vertical Half-Pel Luma (fx=0, fy=2) & Chroma (cfx=0, cfy=4)",
            0, 0, 2, 0, 4
        );

        // Test 5: 2D Diagonal Half-Pel (frac_x=2, frac_y=2) on Ramp
        test_subpel_interpolation(
            "2D Diagonal Half-Pel (fx=2, fy=2) & Chroma (cfx=4, cfy=4) on Ramp",
            1, 2, 2, 4, 4
        );

        // Test 6: 2D Mixed Quarter-Pel (frac_x=1, frac_y=3) on Impulse
        test_subpel_interpolation(
            "2D Mixed Sub-Pel (fx=1, fy=3) & Chroma (cfx=2, cfy=6) on Impulse",
            2, 1, 3, 2, 6
        );

        // Summary
        $display("\n================================================================");
        $display(" VERIFICATION RESULTS SUMMARY:");
        $display("   Total Sub-Pel Cases Tested : %0d", total_tests);
        $display("   Passed Cases               : %0d", pass_count);
        $display("   Failed Cases               : %0d", error_count);
        $display("================================================================");

        if (IS_REMEDIATED) begin
            if (error_count == 0) begin
                $display("\n [PASS] *** ALL TESTS PASSED: SUB-PEL FILTER PORTS PROPERLY CONNECTED AND FIR INTERPOLATION CONFORMANT ***\n");
                $finish(0);
            end else begin
                $display("\n [FAIL] Remediated RTL encountered unexpected filter errors!\n");
                $finish(1);
            end
        end else begin
            if (error_count > 0) begin
                $display("\n [CONFIRMED FLAW] *** FLAW D-13 CONFIRMED: FLOATING/DISCONNECTED SUB-PEL FILTER PORTS PRODUCE INTEGER TRUNCATION ***");
                $display(" Failure mechanism: With frac_x/y left floating/unconnected, hardware defaults to frac=0 integer copy, destroying 8-tap/4-tap FIR interpolation.");
                $display(" Status: Assert and FAIL verified on buggy hardware configuration.\n");
                $finish(1);
            end else begin
                $display("\n [UNEXPECTED] Buggy mode did not fail as expected!\n");
                $finish(2);
            end
        end
    end

endmodule
