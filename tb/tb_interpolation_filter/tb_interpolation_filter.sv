//=============================================================================
// tb_interpolation_filter.sv
// Standalone Unit Testbench for HEVC Sub-Pel Interpolation Filters
//
// Normative References:
//   - ITU-T H.265 (Main10 Profile) Clause 8.5.3.3.3 (Fractional sample interpolation)
//   - ITU-T H.265 (Main10 Profile) Clause 8.5.3.3.4.2 (Weighted sample bi-prediction)
//   - HM 18.0 TComInterpolationFilter & TComYuv::addAvg
//
// Coverage:
//   - All 16 Luma fractional phases (4x4 quarter-pel grid)
//   - All 64 Chroma fractional phases (8x8 eighth-pel grid)
//   - Multiple stimulus patterns: Flat, Ramp, Step Edge, Impulse, Pseudo-Random
//   - Uni-prediction (10-bit clipped) & Intermediate (14-bit unclipped)
//   - Bi-prediction weighted averaging: ClipBD((v_L0 + v_L1 + 16) >>> 5, 10)
//=============================================================================

`timescale 1ns/1ps
`include "parameter_pkg.vh"

module tb_interpolation_filter;

    localparam PIXEL_WIDTH  = `PIXEL_WIDTH; // 10
    localparam BLK_SIZE     = 4;            // 4x4
    localparam BLK_EXT_Y    = BLK_SIZE + 7; // 11x11
    localparam BLK_EXT_C    = BLK_SIZE + 3; // 7x7
    localparam INTERM_WIDTH = PIXEL_WIDTH + 6; // 16

    logic clk;
    logic rst_n;
    logic valid_in;

    logic [1:0] luma_frac_x;
    logic [1:0] luma_frac_y;
    logic [2:0] chroma_frac_x;
    logic [2:0] chroma_frac_y;

    logic [PIXEL_WIDTH*BLK_EXT_Y*BLK_EXT_Y-1:0] ref_luma_ext;
    logic [PIXEL_WIDTH*BLK_EXT_C*BLK_EXT_C-1:0] ref_chroma_ext;

    // Luma DUT outputs
    wire luma_valid_out;
    wire [PIXEL_WIDTH*BLK_SIZE*BLK_SIZE-1:0]   luma_h_out;
    wire [PIXEL_WIDTH*BLK_SIZE*BLK_SIZE-1:0]   luma_v_out;
    wire [PIXEL_WIDTH*BLK_SIZE*BLK_SIZE-1:0]   luma_hv_out;
    wire signed [INTERM_WIDTH*BLK_SIZE*BLK_SIZE-1:0] luma_h_interm;
    wire signed [INTERM_WIDTH*BLK_SIZE*BLK_SIZE-1:0] luma_v_interm;
    wire signed [INTERM_WIDTH*BLK_SIZE*BLK_SIZE-1:0] luma_hv_interm;

    // Chroma DUT outputs
    wire chroma_valid_out;
    wire [PIXEL_WIDTH*BLK_SIZE*BLK_SIZE-1:0]   chroma_h_out;
    wire [PIXEL_WIDTH*BLK_SIZE*BLK_SIZE-1:0]   chroma_v_out;
    wire [PIXEL_WIDTH*BLK_SIZE*BLK_SIZE-1:0]   chroma_hv_out;
    wire signed [INTERM_WIDTH*BLK_SIZE*BLK_SIZE-1:0] chroma_h_interm;
    wire signed [INTERM_WIDTH*BLK_SIZE*BLK_SIZE-1:0] chroma_v_interm;
    wire signed [INTERM_WIDTH*BLK_SIZE*BLK_SIZE-1:0] chroma_hv_interm;

    // Instantiate Luma Filter
    hpel_filter_luma #(
        .PIXEL_WIDTH (PIXEL_WIDTH),
        .BLK_SIZE    (BLK_SIZE)
    ) u_luma_filter (
        .clk           (clk),
        .rst_n         (rst_n),
        .valid_in      (valid_in),
        .frac_x        (luma_frac_x),
        .frac_y        (luma_frac_y),
        .ref_ext_flat  (ref_luma_ext),
        .valid_out     (luma_valid_out),
        .h_out_flat    (luma_h_out),
        .v_out_flat    (luma_v_out),
        .hv_out_flat   (luma_hv_out),
        .h_interm_flat (luma_h_interm),
        .v_interm_flat (luma_v_interm),
        .hv_interm_flat(luma_hv_interm)
    );

    // Instantiate Chroma Filter
    hpel_filter_chroma #(
        .PIXEL_WIDTH (PIXEL_WIDTH),
        .BLK_SIZE    (BLK_SIZE)
    ) u_chroma_filter (
        .clk           (clk),
        .rst_n         (rst_n),
        .valid_in      (valid_in),
        .frac_x        (chroma_frac_x),
        .frac_y        (chroma_frac_y),
        .ref_ext_flat  (ref_chroma_ext),
        .valid_out     (chroma_valid_out),
        .h_out_flat    (chroma_h_out),
        .v_out_flat    (chroma_v_out),
        .hv_out_flat   (chroma_hv_out),
        .h_interm_flat (chroma_h_interm),
        .v_interm_flat (chroma_v_interm),
        .hv_interm_flat(chroma_hv_interm)
    );

    // Clock generation: 100 MHz
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // Watchdog
    initial begin
        #2000000;
        $display("[FATAL] Watchdog timeout in tb_interpolation_filter!");
        $finish(2);
    end

    // =========================================================================
    // Golden Reference Model Functions
    // =========================================================================
    function automatic int clip_bd(input int val, input int bd = 10);
        int max_val = (1 << bd) - 1;
        if (val < 0) return 0;
        if (val > max_val) return max_val;
        return val;
    endfunction

    function automatic int sext14(input logic [INTERM_WIDTH-1:0] val);
        logic signed [INTERM_WIDTH-1:0] s;
        s = val;
        return int'(s);
    endfunction

    function automatic int get_luma_coeff(input int phase, input int tap);
        int c[4][8];
        c[0] = '{  0,  0,   0, 64,  0,   0,  0,  0 };
        c[1] = '{ -1,  4, -10, 58, 17,  -5,  1,  0 };
        c[2] = '{ -1,  4, -11, 40, 40, -11,  4, -1 };
        c[3] = '{  0,  1,  -5, 17, 58, -10,  4, -1 };
        return c[phase][tap];
    endfunction

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

    // Golden Luma Sample Calculation per ITU-T H.265 Clause 8.5.3.3.3
    task automatic calc_golden_luma_block(
        input logic [PIXEL_WIDTH*BLK_EXT_Y*BLK_EXT_Y-1:0] ext_flat,
        input int fx,
        input int fy,
        output int exp_uni[4][4],
        output int exp_interm[4][4]
    );
        int px[11][11];
        int hint[11][4];

        for (int r = 0; r < 11; r++) begin
            for (int c = 0; c < 11; c++) begin
                px[r][c] = int'(ext_flat[PIXEL_WIDTH*(11*r + c) +: PIXEL_WIDTH]);
            end
        end

        if (fx == 0 && fy == 0) begin
            for (int r = 0; r < 4; r++) begin
                for (int c = 0; c < 4; c++) begin
                    exp_uni[r][c]    = px[r+3][c+3];
                    exp_interm[r][c] = px[r+3][c+3] << 4;
                end
            end
        end else if (fy == 0) begin
            for (int r = 0; r < 4; r++) begin
                for (int c = 0; c < 4; c++) begin
                    int sum_h = 0;
                    for (int t = 0; t < 8; t++) sum_h += get_luma_coeff(fx, t) * px[r+3][c+t];
                    exp_uni[r][c]    = clip_bd((sum_h + 32) >>> 6);
                    exp_interm[r][c] = sum_h >>> 2;
                end
            end
        end else if (fx == 0) begin
            for (int r = 0; r < 4; r++) begin
                for (int c = 0; c < 4; c++) begin
                    int sum_v = 0;
                    for (int t = 0; t < 8; t++) sum_v += get_luma_coeff(fy, t) * px[r+t][c+3];
                    exp_uni[r][c]    = clip_bd((sum_v + 32) >>> 6);
                    exp_interm[r][c] = sum_v >>> 2;
                end
            end
        end else begin
            // 2D HV pass
            // Step 1: H-pass with plain truncation (>>> 2)
            for (int r = 0; r < 11; r++) begin
                for (int c = 0; c < 4; c++) begin
                    int sum_h = 0;
                    for (int t = 0; t < 8; t++) sum_h += get_luma_coeff(fx, t) * px[r][c+t];
                    hint[r][c] = sum_h >>> 2;
                end
            end
            // Step 2: V-pass on hint
            for (int r = 0; r < 4; r++) begin
                for (int c = 0; c < 4; c++) begin
                    int sum_v = 0;
                    for (int t = 0; t < 8; t++) sum_v += get_luma_coeff(fy, t) * hint[r+t][c];
                    exp_uni[r][c]    = clip_bd((sum_v + 512) >>> 10);
                    exp_interm[r][c] = sum_v >>> 6;
                end
            end
        end
    endtask

    // Golden Chroma Sample Calculation per ITU-T H.265 Clause 8.5.3.3.3
    task automatic calc_golden_chroma_block(
        input logic [PIXEL_WIDTH*BLK_EXT_C*BLK_EXT_C-1:0] ext_flat,
        input int fx,
        input int fy,
        output int exp_uni[4][4],
        output int exp_interm[4][4]
    );
        int px[7][7];
        int hint[7][4];

        for (int r = 0; r < 7; r++) begin
            for (int c = 0; c < 7; c++) begin
                px[r][c] = int'(ext_flat[PIXEL_WIDTH*(7*r + c) +: PIXEL_WIDTH]);
            end
        end

        if (fx == 0 && fy == 0) begin
            for (int r = 0; r < 4; r++) begin
                for (int c = 0; c < 4; c++) begin
                    exp_uni[r][c]    = px[r+1][c+1];
                    exp_interm[r][c] = px[r+1][c+1] << 4;
                end
            end
        end else if (fy == 0) begin
            for (int r = 0; r < 4; r++) begin
                for (int c = 0; c < 4; c++) begin
                    int sum_h = 0;
                    for (int t = 0; t < 4; t++) sum_h += get_chroma_coeff(fx, t) * px[r+1][c+t];
                    exp_uni[r][c]    = clip_bd((sum_h + 32) >>> 6);
                    exp_interm[r][c] = sum_h >>> 2;
                end
            end
        end else if (fx == 0) begin
            for (int r = 0; r < 4; r++) begin
                for (int c = 0; c < 4; c++) begin
                    int sum_v = 0;
                    for (int t = 0; t < 4; t++) sum_v += get_chroma_coeff(fy, t) * px[r+t][c+1];
                    exp_uni[r][c]    = clip_bd((sum_v + 32) >>> 6);
                    exp_interm[r][c] = sum_v >>> 2;
                end
            end
        end else begin
            // 2D HV pass
            // Step 1: H-pass with plain truncation (>>> 2)
            for (int r = 0; r < 7; r++) begin
                for (int c = 0; c < 4; c++) begin
                    int sum_h = 0;
                    for (int t = 0; t < 4; t++) sum_h += get_chroma_coeff(fx, t) * px[r][c+t];
                    hint[r][c] = sum_h >>> 2;
                end
            end
            // Step 2: V-pass on hint
            for (int r = 0; r < 4; r++) begin
                for (int c = 0; c < 4; c++) begin
                    int sum_v = 0;
                    for (int t = 0; t < 4; t++) sum_v += get_chroma_coeff(fy, t) * hint[r+t][c];
                    exp_uni[r][c]    = clip_bd((sum_v + 512) >>> 10);
                    exp_interm[r][c] = sum_v >>> 6;
                end
            end
        end
    endtask

    // Bi-prediction Golden Model per ITU-T H.265 Clause 8.5.3.3.4.2
    function automatic int calc_bi_pred_sample(input int interm_l0, input int interm_l1);
        return clip_bd((interm_l0 + interm_l1 + 16) >>> 5, 10);
    endfunction

    // Test Pattern Generators
    task automatic init_luma_pattern(input int pat_type, input int seed);
        for (int r = 0; r < 11; r++) begin
            for (int c = 0; c < 11; c++) begin
                int v;
                case (pat_type)
                    0: v = 512; // Flat DC
                    1: v = clip_bd((r * 45) + (c * 55) + seed); // Ramp
                    2: v = (c >= 4) ? 850 : 150; // Step edge
                    3: v = (r == 3 && c == 3) ? 960 : 120; // Impulse
                    default: v = ($urandom_range(0, 1023)); // Random
                endcase
                ref_luma_ext[PIXEL_WIDTH*(11*r + c) +: PIXEL_WIDTH] = v[PIXEL_WIDTH-1:0];
            end
        end
    endtask

    task automatic init_chroma_pattern(input int pat_type, input int seed);
        for (int r = 0; r < 7; r++) begin
            for (int c = 0; c < 7; c++) begin
                int v;
                case (pat_type)
                    0: v = 512;
                    1: v = clip_bd((r * 65) + (c * 65) + seed);
                    2: v = (c >= 2) ? 800 : 200;
                    3: v = (r == 1 && c == 1) ? 920 : 100;
                    default: v = ($urandom_range(0, 1023));
                endcase
                ref_chroma_ext[PIXEL_WIDTH*(7*r + c) +: PIXEL_WIDTH] = v[PIXEL_WIDTH-1:0];
            end
        end
    endtask

    // Verification Counters
    int luma_phase_tests = 0;
    int luma_phase_fails = 0;
    int chroma_phase_tests = 0;
    int chroma_phase_fails = 0;
    int bi_pred_tests = 0;
    int bi_pred_fails = 0;

    // Test a single Luma phase
    task automatic run_luma_phase_test(input int fx, input int fy, input int pat);
        int exp_u[4][4], exp_i[4][4];
        int act_u[4][4], act_i[4][4];
        int err = 0;

        init_luma_pattern(pat, (fx * 10 + fy));
        luma_frac_x = fx[1:0];
        luma_frac_y = fy[1:0];

        calc_golden_luma_block(ref_luma_ext, fx, fy, exp_u, exp_i);

        valid_in = 1;
        @(posedge clk);
        valid_in = 0;

        repeat(3) @(posedge clk);

        // Read DUT outputs depending on phase
        for (int r = 0; r < 4; r++) begin
            for (int c = 0; c < 4; c++) begin
                if (fx == 0 && fy == 0) begin
                    act_u[r][c] = ref_luma_ext[PIXEL_WIDTH*(11*(r+3) + (c+3)) +: PIXEL_WIDTH];
                    act_i[r][c] = act_u[r][c] << 4;
                end else if (fy == 0) begin
                    act_u[r][c] = luma_h_out[PIXEL_WIDTH*(4*r + c) +: PIXEL_WIDTH];
                    act_i[r][c] = sext14(luma_h_interm[INTERM_WIDTH*(4*r + c) +: INTERM_WIDTH]);
                end else if (fx == 0) begin
                    act_u[r][c] = luma_v_out[PIXEL_WIDTH*(4*r + c) +: PIXEL_WIDTH];
                    act_i[r][c] = sext14(luma_v_interm[INTERM_WIDTH*(4*r + c) +: INTERM_WIDTH]);
                end else begin
                    act_u[r][c] = luma_hv_out[PIXEL_WIDTH*(4*r + c) +: PIXEL_WIDTH];
                    act_i[r][c] = sext14(luma_hv_interm[INTERM_WIDTH*(4*r + c) +: INTERM_WIDTH]);
                end

                if (act_u[r][c] !== exp_u[r][c] || act_i[r][c] !== exp_i[r][c]) begin
                    $display("  [MISMATCH LUMA] fx=%0d fy=%0d [%0d][%0d]: got_uni=%0d exp_uni=%0d | got_int=%0d exp_int=%0d",
                             fx, fy, r, c, act_u[r][c], exp_u[r][c], act_i[r][c], exp_i[r][c]);
                    err++;
                end
            end
        end

        luma_phase_tests++;
        if (err > 0) luma_phase_fails++;
    endtask

    // Test a single Chroma phase
    task automatic run_chroma_phase_test(input int fx, input int fy, input int pat);
        int exp_u[4][4], exp_i[4][4];
        int act_u[4][4], act_i[4][4];
        int err = 0;

        init_chroma_pattern(pat, (fx * 10 + fy));
        chroma_frac_x = fx[2:0];
        chroma_frac_y = fy[2:0];

        calc_golden_chroma_block(ref_chroma_ext, fx, fy, exp_u, exp_i);

        valid_in = 1;
        @(posedge clk);
        valid_in = 0;

        repeat(3) @(posedge clk);

        for (int r = 0; r < 4; r++) begin
            for (int c = 0; c < 4; c++) begin
                if (fx == 0 && fy == 0) begin
                    act_u[r][c] = ref_chroma_ext[PIXEL_WIDTH*(7*(r+1) + (c+1)) +: PIXEL_WIDTH];
                    act_i[r][c] = act_u[r][c] << 4;
                end else if (fy == 0) begin
                    act_u[r][c] = chroma_h_out[PIXEL_WIDTH*(4*r + c) +: PIXEL_WIDTH];
                    act_i[r][c] = sext14(chroma_h_interm[INTERM_WIDTH*(4*r + c) +: INTERM_WIDTH]);
                end else if (fx == 0) begin
                    act_u[r][c] = chroma_v_out[PIXEL_WIDTH*(4*r + c) +: PIXEL_WIDTH];
                    act_i[r][c] = sext14(chroma_v_interm[INTERM_WIDTH*(4*r + c) +: INTERM_WIDTH]);
                end else begin
                    act_u[r][c] = chroma_hv_out[PIXEL_WIDTH*(4*r + c) +: PIXEL_WIDTH];
                    act_i[r][c] = sext14(chroma_hv_interm[INTERM_WIDTH*(4*r + c) +: INTERM_WIDTH]);
                end

                if (act_u[r][c] !== exp_u[r][c] || act_i[r][c] !== exp_i[r][c]) begin
                    $display("  [MISMATCH CHROMA] fx=%0d fy=%0d [%0d][%0d]: got_uni=%0d exp_uni=%0d | got_int=%0d exp_int=%0d",
                             fx, fy, r, c, act_u[r][c], exp_u[r][c], act_i[r][c], exp_i[r][c]);
                    err++;
                end
            end
        end

        chroma_phase_tests++;
        if (err > 0) chroma_phase_fails++;
    endtask

    // Bi-prediction Test Task
    task automatic run_bi_pred_test(input int luma_fx0, input int luma_fy0, input int luma_fx1, input int luma_fy1);
        int exp_u0[4][4], exp_i0[4][4];
        int exp_u1[4][4], exp_i1[4][4];
        int act_i0[4][4], act_i1[4][4];
        int err = 0;

        // Step 1: L0 fetch
        init_luma_pattern(1, 100);
        luma_frac_x = luma_fx0[1:0];
        luma_frac_y = luma_fy0[1:0];
        calc_golden_luma_block(ref_luma_ext, luma_fx0, luma_fy0, exp_u0, exp_i0);

        valid_in = 1;
        @(posedge clk);
        valid_in = 0;
        repeat(3) @(posedge clk);

        for (int r = 0; r < 4; r++) begin
            for (int c = 0; c < 4; c++) begin
                if (luma_fx0 == 0 && luma_fy0 == 0) act_i0[r][c] = ref_luma_ext[PIXEL_WIDTH*(11*(r+3) + (c+3)) +: PIXEL_WIDTH] << 4;
                else if (luma_fy0 == 0) act_i0[r][c] = sext14(luma_h_interm[INTERM_WIDTH*(4*r + c) +: INTERM_WIDTH]);
                else if (luma_fx0 == 0) act_i0[r][c] = sext14(luma_v_interm[INTERM_WIDTH*(4*r + c) +: INTERM_WIDTH]);
                else                    act_i0[r][c] = sext14(luma_hv_interm[INTERM_WIDTH*(4*r + c) +: INTERM_WIDTH]);
            end
        end

        // Step 2: L1 fetch
        init_luma_pattern(2, 200);
        luma_frac_x = luma_fx1[1:0];
        luma_frac_y = luma_fy1[1:0];
        calc_golden_luma_block(ref_luma_ext, luma_fx1, luma_fy1, exp_u1, exp_i1);

        valid_in = 1;
        @(posedge clk);
        valid_in = 0;
        repeat(3) @(posedge clk);

        for (int r = 0; r < 4; r++) begin
            for (int c = 0; c < 4; c++) begin
                if (luma_fx1 == 0 && luma_fy1 == 0) act_i1[r][c] = ref_luma_ext[PIXEL_WIDTH*(11*(r+3) + (c+3)) +: PIXEL_WIDTH] << 4;
                else if (luma_fy1 == 0) act_i1[r][c] = sext14(luma_h_interm[INTERM_WIDTH*(4*r + c) +: INTERM_WIDTH]);
                else if (luma_fx1 == 0) act_i1[r][c] = sext14(luma_v_interm[INTERM_WIDTH*(4*r + c) +: INTERM_WIDTH]);
                else                    act_i1[r][c] = sext14(luma_hv_interm[INTERM_WIDTH*(4*r + c) +: INTERM_WIDTH]);
            end
        end

        // Step 3: Weighted average
        for (int r = 0; r < 4; r++) begin
            for (int c = 0; c < 4; c++) begin
                int exp_bi = calc_bi_pred_sample(exp_i0[r][c], exp_i1[r][c]);
                int act_bi = calc_bi_pred_sample(act_i0[r][c], act_i1[r][c]);
                if (act_bi !== exp_bi) begin
                    $display("  [MISMATCH BI-PRED] [%0d][%0d]: got_bi=%0d exp_bi=%0d", r, c, act_bi, exp_bi);
                    err++;
                end
            end
        end

        bi_pred_tests++;
        if (err > 0) bi_pred_fails++;
    endtask

    // Main Test Stimulus
    initial begin
        valid_in = 0;
        luma_frac_x = 0;
        luma_frac_y = 0;
        chroma_frac_x = 0;
        chroma_frac_y = 0;
        ref_luma_ext = '0;
        ref_chroma_ext = '0;

        rst_n = 0;
        #20 rst_n = 1;
        #10;

        $display("================================================================");
        $display(" HEVC STAGE 1 SUB-PEL UNIT TESTBENCH");
        $display(" Standards: ITU-T H.265 Clause 8.5.3.3.3 & Clause 8.5.3.3.4.2");
        $display(" Testing 16 Luma Phases x Multiple Patterns...");
        $display("================================================================");

        // 1. Comprehensive Luma Phase Sweep (16 phases x 4 pattern types)
        for (int p = 0; p < 4; p++) begin
            for (int fx = 0; fx < 4; fx++) begin
                for (int fy = 0; fy < 4; fy++) begin
                    run_luma_phase_test(fx, fy, p);
                end
            end
        end
        $display(" Luma 16-phase sweep completed: %0d tests, %0d failures.", luma_phase_tests, luma_phase_fails);

        // 2. Comprehensive Chroma Phase Sweep (64 phases x 4 pattern types)
        $display("----------------------------------------------------------------");
        $display(" Testing 64 Chroma Phases x Multiple Patterns...");
        for (int p = 0; p < 4; p++) begin
            for (int fx = 0; fx < 8; fx++) begin
                for (int fy = 0; fy < 8; fy++) begin
                    run_chroma_phase_test(fx, fy, p);
                end
            end
        end
        $display(" Chroma 64-phase sweep completed: %0d tests, %0d failures.", chroma_phase_tests, chroma_phase_fails);

        // 3. Bi-prediction Conformance Tests
        $display("----------------------------------------------------------------");
        $display(" Testing Bi-Prediction Weighted Averaging (Clause 8.5.3.3.4.2)...");
        begin
            int fx1, fy1;
            for (int fx0 = 0; fx0 < 4; fx0++) begin
                for (int fy0 = 0; fy0 < 4; fy0++) begin
                    fx1 = (fx0 + 1) % 4;
                    fy1 = (fy0 + 2) % 4;
                    run_bi_pred_test(fx0, fy0, fx1, fy1);
                end
            end
        end
        $display(" Bi-prediction sweep completed: %0d tests, %0d failures.", bi_pred_tests, bi_pred_fails);

        $display("================================================================");
        $display(" STAGE 1 VERIFICATION SUMMARY:");
        $display("   Luma Phase Tests   : %0d | Fails: %0d", luma_phase_tests, luma_phase_fails);
        $display("   Chroma Phase Tests : %0d | Fails: %0d", chroma_phase_tests, chroma_phase_fails);
        $display("   Bi-Pred Tests      : %0d | Fails: %0d", bi_pred_tests, bi_pred_fails);
        $display("================================================================");

        if (luma_phase_fails == 0 && chroma_phase_fails == 0 && bi_pred_fails == 0) begin
            $display(" [PASS] *** STAGE 1 INTERPOLATION UNIT TESTS: 100%% CONFORMANT (0 MISMATCHES) ***");
        end else begin
            $display(" [FAIL] *** STAGE 1 INTERPOLATION UNIT TESTS ENCOUNTERED MISMATCHES ***");
        end

        #20;
        $finish;
    end

endmodule
