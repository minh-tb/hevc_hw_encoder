//=============================================================================
// tb_flaw_intra_rmd.sv
// Dual-State Verification Testbench for Flaw D-04:
// RMD SATD Unweighted SAD Substitution (HEVC Clause 8.4.3 / HM TComRdCost::calcHAD)
//
// Instantiates the real rtl/intra/intra_rmd.v directly for both states:
//   Buggy run:      vlog -sv +define+NO_REMEDIATION ... tb_flaw_intra_rmd.sv
//                   -> Spatial SAD picks suboptimal mode/cost -> FLAW D-04 CONFIRMED
//   Remediated run: vlog -sv +define+REMEDIATION ... tb_flaw_intra_rmd.sv
//                   -> 4x4-tiled Hadamard SATD passes 4x4, 8x8, 16x16, 32x32
//                      (exact best_mode, exact best_cost, and Chroma Table 8-2)
//=============================================================================

`timescale 1ns / 1ps
`include "parameter_pkg.vh"

module tb_flaw_intra_rmd;

    logic         clk;
    logic         rst_n;
    logic         start;
    logic [5:0]   pu_x, pu_y;
    logic [2:0]   pu_size_log2;

    wire  [11:0]  orig_rd_addr;
    wire          rmd_active;
    logic [`PIXEL_WIDTH-1:0] orig_rd_data;

    wire  [9:0]   orig_c_rd_addr;
    logic [`PIXEL_WIDTH-1:0] orig_u_rd_data;
    logic [`PIXEL_WIDTH-1:0] orig_v_rd_data;

    logic         ref_valid;
    logic [`PIXEL_WIDTH-1:0] ref_sample;
    logic [7:0]   ref_idx;
    logic         ref_last;
    logic [`PIXEL_WIDTH-1:0] ref_sample_u;
    logic [`PIXEL_WIDTH-1:0] ref_sample_v;

    wire          rmd_done;
    wire  [5:0]   best_mode;
    wire  [31:0]  best_cost;
    wire  [2:0]   best_chroma_pred_mode;
    wire  [5:0]   best_chroma_dir;

    int total_errors = 0;

    // Clock generation (100 MHz)
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // Full-CTU Original Pixel Memories (64x64 Luma, 32x32 Cb/Cr)
    logic [9:0] orig_y_mem [0:63][0:63];
    logic [9:0] orig_u_mem [0:31][0:31];
    logic [9:0] orig_v_mem [0:31][0:31];

    // Stimulus Reference Buffers (max N=32 Luma, N_C=16 Chroma)
    logic [9:0] ref_top_luma  [0:31];
    logic [9:0] ref_left_luma [0:31];
    logic [9:0] top_right_luma;
    logic [9:0] bot_left_luma;

    logic [9:0] ref_top_u     [0:31];
    logic [9:0] ref_left_u    [0:15];
    logic [9:0] top_right_u;
    logic [9:0] bot_left_u;

    logic [9:0] ref_top_v     [0:31];
    logic [9:0] ref_left_v    [0:15];
    logic [9:0] top_right_v;
    logic [9:0] bot_left_v;

    // Synchronous memory responses (1-cycle latency matching hevc_encoder_top.v)
    always @(posedge clk) begin
        if (rmd_active) begin
            orig_rd_data   <= orig_y_mem[orig_rd_addr[11:6]][orig_rd_addr[5:0]];
            orig_u_rd_data <= orig_u_mem[orig_c_rd_addr[9:5]][orig_c_rd_addr[4:0]];
            orig_v_rd_data <= orig_v_mem[orig_c_rd_addr[9:5]][orig_c_rd_addr[4:0]];
        end else begin
            orig_rd_data   <= 10'd0;
            orig_u_rd_data <= 10'd0;
            orig_v_rd_data <= 10'd0;
        end
    end

    // Direct instantiation of real RTL intra_rmd for both NO_REMEDIATION and REMEDIATION
    intra_rmd dut (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .start                 (start),
        .pu_x                  (pu_x),
        .pu_y                  (pu_y),
        .pu_size_log2          (pu_size_log2),
        .orig_rd_addr          (orig_rd_addr),
        .rmd_active            (rmd_active),
        .orig_rd_data          (orig_rd_data),
        .orig_c_rd_addr        (orig_c_rd_addr),
        .orig_u_rd_data        (orig_u_rd_data),
        .orig_v_rd_data        (orig_v_rd_data),
        .ref_valid             (ref_valid),
        .ref_sample            (ref_sample),
        .ref_idx               (ref_idx),
        .ref_last              (ref_last),
        .ref_sample_u          (ref_sample_u),
        .ref_sample_v          (ref_sample_v),
        .rmd_done              (rmd_done),
        .best_mode             (best_mode),
        .best_cost             (best_cost),
        .best_chroma_pred_mode (best_chroma_pred_mode),
        .best_chroma_dir       (best_chroma_dir)
    );

    // Full-precision Reference 2D 4x4 Hadamard SATD function (no 12-bit overflow)
    function automatic int calc_satd_4x4(input int diff[0:3][0:3]);
        int row_t[0:3][0:3];
        int col_t[0:3][0:3];
        int s0, d0, s1, d1;
        int sum_abs;
        for (int y = 0; y < 4; y++) begin
            s0 = diff[y][0] + diff[y][3];
            d0 = diff[y][0] - diff[y][3];
            s1 = diff[y][1] + diff[y][2];
            d1 = diff[y][1] - diff[y][2];
            row_t[y][0] = s0 + s1;
            row_t[y][1] = d0 + d1;
            row_t[y][2] = d0 - d1;
            row_t[y][3] = s0 - s1;
        end
        for (int x = 0; x < 4; x++) begin
            s0 = row_t[0][x] + row_t[3][x];
            d0 = row_t[0][x] - row_t[3][x];
            s1 = row_t[1][x] + row_t[2][x];
            d1 = row_t[1][x] - row_t[2][x];
            col_t[0][x] = s0 + s1;
            col_t[1][x] = d0 + d1;
            col_t[2][x] = d0 - d1;
            col_t[3][x] = s0 - s1;
        end
        sum_abs = 0;
        for (int y = 0; y < 4; y++) begin
            for (int x = 0; x < 4; x++) begin
                sum_abs += (col_t[y][x] < 0) ? -col_t[y][x] : col_t[y][x];
            end
        end
        calc_satd_4x4 = (sum_abs + 1) >> 1;
    endfunction

    // Helper: clear CTU memories to deterministic baseline
    task automatic clear_memories();
        for (int y = 0; y < 64; y++) begin
            for (int x = 0; x < 64; x++) begin
                orig_y_mem[y][x] = 10'd512;
            end
        end
        for (int y = 0; y < 32; y++) begin
            for (int x = 0; x < 32; x++) begin
                orig_u_mem[y][x] = 10'd512;
                orig_v_mem[y][x] = 10'd512;
            end
        end
        for (int i = 0; i < 32; i++) begin
            ref_top_luma[i]  = 10'd512;
            ref_left_luma[i] = 10'd512;
            ref_top_u[i]     = 10'd512;
            ref_top_v[i]     = 10'd512;
        end
        for (int i = 0; i < 16; i++) begin
            ref_left_u[i] = 10'd512;
            ref_left_v[i] = 10'd512;
        end
        top_right_luma = 10'd512;
        bot_left_luma  = 10'd512;
        top_right_u    = 10'd512;
        bot_left_u     = 10'd512;
        top_right_v    = 10'd512;
        bot_left_v     = 10'd512;
    endtask

    // Helper: drive PU, compute golden Luma + Chroma expectations, and verify DUT
    task automatic execute_and_check(
        input string case_name,
        input logic [2:0] size_log2,
        input logic [5:0] px,
        input logic [5:0] py
    );
        int N, N_C;
        int dc_sum, dc_val;
        int dc_sum_u, dc_sum_v, dc_val_u, dc_val_v;
        int sad_planar, sad_dc, sad_hor, sad_ver;
        int satd_planar, satd_dc, satd_hor, satd_ver;
        int diff_p[0:31][0:31];
        int diff_d[0:31][0:31];
        int diff_h[0:31][0:31];
        int diff_v[0:31][0:31];
        int tile_p[0:3][0:3];
        int tile_d[0:3][0:3];
        int tile_h[0:3][0:3];
        int tile_v[0:3][0:3];
        int exp_sad_mode, exp_sad_cost;
        int exp_satd_mode, exp_satd_cost;

        int sad_c_planar, sad_c_dc, sad_c_hor, sad_c_ver, sad_c_34;
        int win_luma;
        int dir_cand[0:4];
        int cost_cand[0:4];
        int exp_chroma_mode, exp_chroma_dir;
        int timeout_cnt;

        N   = 1 << size_log2;
        N_C = N >> 1;

        // 1. Compute Golden Luma SAD & Multi-Tile Hadamard SATD
        dc_sum = 0;
        for (int i = 0; i < N; i++) begin
            dc_sum += ref_top_luma[i] + ref_left_luma[i];
        end
        dc_val = (dc_sum + N) >> (size_log2 + 1);

        sad_planar = 0; sad_dc = 0; sad_hor = 0; sad_ver = 0;
        for (int y = 0; y < N; y++) begin
            for (int x = 0; x < N; x++) begin
                int orig_px = orig_y_mem[py + y][px + x];
                int pred_p  = ((N - 1 - x) * ref_left_luma[y] + (x + 1) * top_right_luma +
                               (N - 1 - y) * ref_top_luma[x]  + (y + 1) * bot_left_luma + N) >> (size_log2 + 1);
                int pred_d  = dc_val;
                int pred_h  = ref_left_luma[y];
                int pred_v  = ref_top_luma[x];
                if (pred_p > 1023) pred_p = 1023;

                diff_p[y][x] = orig_px - pred_p;
                diff_d[y][x] = orig_px - pred_d;
                diff_h[y][x] = orig_px - pred_h;
                diff_v[y][x] = orig_px - pred_v;

                sad_planar += (diff_p[y][x] < 0) ? -diff_p[y][x] : diff_p[y][x];
                sad_dc     += (diff_d[y][x] < 0) ? -diff_d[y][x] : diff_d[y][x];
                sad_hor    += (diff_h[y][x] < 0) ? -diff_h[y][x] : diff_h[y][x];
                sad_ver    += (diff_v[y][x] < 0) ? -diff_v[y][x] : diff_v[y][x];
            end
        end

        satd_planar = 0; satd_dc = 0; satd_hor = 0; satd_ver = 0;
        for (int ty = 0; ty < N; ty += 4) begin
            for (int tx = 0; tx < N; tx += 4) begin
                for (int dy = 0; dy < 4; dy++) begin
                    for (int dx = 0; dx < 4; dx++) begin
                        tile_p[dy][dx] = diff_p[ty + dy][tx + dx];
                        tile_d[dy][dx] = diff_d[ty + dy][tx + dx];
                        tile_h[dy][dx] = diff_h[ty + dy][tx + dx];
                        tile_v[dy][dx] = diff_v[ty + dy][tx + dx];
                    end
                end
                satd_planar += calc_satd_4x4(tile_p);
                satd_dc     += calc_satd_4x4(tile_d);
                satd_hor    += calc_satd_4x4(tile_h);
                satd_ver    += calc_satd_4x4(tile_v);
            end
        end

        if (sad_planar <= sad_dc && sad_planar <= sad_hor && sad_planar <= sad_ver) begin
            exp_sad_mode = 0;  exp_sad_cost = sad_planar;
        end else if (sad_dc <= sad_hor && sad_dc <= sad_ver) begin
            exp_sad_mode = 1;  exp_sad_cost = sad_dc;
        end else if (sad_hor <= sad_ver) begin
            exp_sad_mode = 10; exp_sad_cost = sad_hor;
        end else begin
            exp_sad_mode = 26; exp_sad_cost = sad_ver;
        end

        if (satd_planar <= satd_dc && satd_planar <= satd_hor && satd_planar <= satd_ver) begin
            exp_satd_mode = 0;  exp_satd_cost = satd_planar;
        end else if (satd_dc <= satd_hor && satd_dc <= satd_ver) begin
            exp_satd_mode = 1;  exp_satd_cost = satd_dc;
        end else if (satd_hor <= satd_ver) begin
            exp_satd_mode = 10; exp_satd_cost = satd_hor;
        end else begin
            exp_satd_mode = 26; exp_satd_cost = satd_ver;
        end

        // 2. Compute Golden Chroma Table 8-2
        dc_sum_u = 0; dc_sum_v = 0;
        for (int i = 0; i < N_C; i++) begin
            dc_sum_u += ref_top_u[i] + ref_left_u[i];
            dc_sum_v += ref_top_v[i] + ref_left_v[i];
        end
        dc_val_u = (dc_sum_u + N_C) >> size_log2;
        dc_val_v = (dc_sum_v + N_C) >> size_log2;

        sad_c_planar = 0; sad_c_dc = 0; sad_c_hor = 0; sad_c_ver = 0; sad_c_34 = 0;
        for (int y = 0; y < N_C; y++) begin
            for (int x = 0; x < N_C; x++) begin
                int ou = orig_u_mem[py[5:1] + y][px[5:1] + x];
                int ov = orig_v_mem[py[5:1] + y][px[5:1] + x];
                int pp_u = ((N_C - 1 - x) * ref_left_u[y] + (x + 1) * top_right_u +
                            (N_C - 1 - y) * ref_top_u[x]  + (y + 1) * bot_left_u + N_C) >> size_log2;
                int pp_v = ((N_C - 1 - x) * ref_left_v[y] + (x + 1) * top_right_v +
                            (N_C - 1 - y) * ref_top_v[x]  + (y + 1) * bot_left_v + N_C) >> size_log2;
                int p34_u = ref_top_u[x + y + 1]; // ref_buf_u[x + y + 2]
                int p34_v = ref_top_v[x + y + 1];
                if (pp_u > 1023) pp_u = 1023;
                if (pp_v > 1023) pp_v = 1023;

                sad_c_planar += ((ou > pp_u) ? (ou - pp_u) : (pp_u - ou)) + ((ov > pp_v) ? (ov - pp_v) : (pp_v - ov));
                sad_c_dc     += ((ou > dc_val_u) ? (ou - dc_val_u) : (dc_val_u - ou)) + ((ov > dc_val_v) ? (ov - dc_val_v) : (dc_val_v - ov));
                sad_c_hor    += ((ou > ref_left_u[y]) ? (ou - ref_left_u[y]) : (ref_left_u[y] - ou)) + ((ov > ref_left_v[y]) ? (ov - ref_left_v[y]) : (ref_left_v[y] - ov));
                sad_c_ver    += ((ou > ref_top_u[x]) ? (ou - ref_top_u[x]) : (ref_top_u[x] - ou)) + ((ov > ref_top_v[x]) ? (ov - ref_top_v[x]) : (ref_top_v[x] - ov));
                sad_c_34     += ((ou > p34_u) ? (ou - p34_u) : (p34_u - ou)) + ((ov > p34_v) ? (ov - p34_v) : (p34_v - ov));
            end
        end

`ifdef REMEDIATION
        win_luma = exp_satd_mode;
`else
        win_luma = exp_sad_mode;
`endif
        dir_cand[0] = (win_luma == 0)  ? 34 : 0;
        dir_cand[1] = (win_luma == 26) ? 34 : 26;
        dir_cand[2] = (win_luma == 10) ? 34 : 10;
        dir_cand[3] = (win_luma == 1)  ? 34 : 1;
        dir_cand[4] = win_luma;

        for (int c = 0; c < 5; c++) begin
            int sc;
            case (dir_cand[c])
                0:       sc = sad_c_planar;
                1:       sc = sad_c_dc;
                10:      sc = sad_c_hor;
                26:      sc = sad_c_ver;
                default: sc = sad_c_34;
            endcase
            cost_cand[c] = (c == 4) ? sc : (sc + 8);
        end

        if (cost_cand[4] <= cost_cand[0] && cost_cand[4] <= cost_cand[1] && cost_cand[4] <= cost_cand[2] && cost_cand[4] <= cost_cand[3]) begin
            exp_chroma_mode = 4; exp_chroma_dir = dir_cand[4];
        end else if (cost_cand[0] <= cost_cand[1] && cost_cand[0] <= cost_cand[2] && cost_cand[0] <= cost_cand[3]) begin
            exp_chroma_mode = 0; exp_chroma_dir = dir_cand[0];
        end else if (cost_cand[1] <= cost_cand[2] && cost_cand[1] <= cost_cand[3]) begin
            exp_chroma_mode = 1; exp_chroma_dir = dir_cand[1];
        end else if (cost_cand[2] <= cost_cand[3]) begin
            exp_chroma_mode = 2; exp_chroma_dir = dir_cand[2];
        end else begin
            exp_chroma_mode = 3; exp_chroma_dir = dir_cand[3];
        end

        $display("--------------------------------------------------");
        $display(" [%s] PU=%0dx%0d @ (%0d,%0d)", case_name, N, N, px, py);
        $display("   Mode 0 (Planar):  SAD = %0d,  SATD = %0d", sad_planar, satd_planar);
        $display("   Mode 1 (DC):      SAD = %0d,  SATD = %0d", sad_dc, satd_dc);
        $display("   Mode 10 (Hor):    SAD = %0d,  SATD = %0d", sad_hor, satd_hor);
        $display("   Mode 26 (Ver):    SAD = %0d,  SATD = %0d", sad_ver, satd_ver);
        $display("   Golden: SAD_win=(%0d,%0d), SATD_win=(%0d,%0d), Chroma=(%0d,dir=%0d)",
                 exp_sad_mode, exp_sad_cost, exp_satd_mode, exp_satd_cost, exp_chroma_mode, exp_chroma_dir);

        // 3. Drive DUT
        @(negedge clk);
        pu_x         = px;
        pu_y         = py;
        pu_size_log2 = size_log2;
        start        = 1'b1;
        @(negedge clk);
        start        = 1'b0;

        // Continuous reference stream: ref_idx = 0..4*N
        for (int idx = 0; idx <= 4 * N; idx++) begin
            @(negedge clk);
            ref_valid = 1'b1;
            ref_idx   = idx[7:0];
            ref_last  = (idx == 4 * N);

            // Luma reference sample
            if (idx == 0) begin
                ref_sample = 10'd512;
            end else if (idx <= N) begin
                ref_sample = ref_top_luma[idx - 1];
            end else if (idx <= 2 * N) begin
                ref_sample = top_right_luma;
            end else if (idx <= 3 * N) begin
                ref_sample = ref_left_luma[idx - 2 * N - 1];
            end else begin
                ref_sample = bot_left_luma;
            end

            // Chroma reference samples (0..2*N = 0..4*N_C)
            if (idx == 0) begin
                ref_sample_u = 10'd512;
                ref_sample_v = 10'd512;
            end else if (idx <= N) begin
                ref_sample_u = ref_top_u[idx - 1];
                ref_sample_v = ref_top_v[idx - 1];
            end else if (idx <= N + N_C) begin
                ref_sample_u = ref_left_u[idx - N - 1];
                ref_sample_v = ref_left_v[idx - N - 1];
            end else if (idx <= 2 * N) begin
                ref_sample_u = bot_left_u;
                ref_sample_v = bot_left_v;
            end else begin
                ref_sample_u = 10'd0;
                ref_sample_v = 10'd0;
            end
        end

        @(negedge clk);
        ref_valid = 1'b0;
        ref_last  = 1'b0;

        // Wait for rmd_done with safety timeout
        timeout_cnt = 0;
        while (!rmd_done && timeout_cnt < 5000) begin
            @(posedge clk);
            timeout_cnt++;
        end

        if (!rmd_done) begin
            $display(" [FAIL] Timeout waiting for rmd_done on %s!", case_name);
            total_errors++;
        end else begin
            $display(" [DUT RESULT] mode=%0d cost=%0d chroma=(%0d,dir=%0d) at %0t",
                     best_mode, best_cost, best_chroma_pred_mode, best_chroma_dir, $time);

            if (best_mode !== exp_satd_mode || best_cost !== exp_satd_cost) begin
                $display(" [FAIL] FLAW D-04 CONFIRMED: Mode/Cost Divergence on %s!", case_name);
                $display("   DUT: mode=%0d cost=%0d | Normative SATD expected: mode=%0d cost=%0d",
                         best_mode, best_cost, exp_satd_mode, exp_satd_cost);
                total_errors++;
            end else if (best_chroma_pred_mode !== exp_chroma_mode || best_chroma_dir !== exp_chroma_dir) begin
                $display(" [FAIL] Chroma Table 8-2 mismatch on %s: got (%0d,dir=%0d), expected (%0d,dir=%0d)",
                         case_name, best_chroma_pred_mode, best_chroma_dir, exp_chroma_mode, exp_chroma_dir);
                total_errors++;
            end else begin
                $display(" [PASS] %s verified (mode=%0d, cost=%0d, chroma=%0d/dir=%0d).",
                         case_name, best_mode, best_cost, best_chroma_pred_mode, best_chroma_dir);
            end
        end

        @(posedge clk);
    endtask

    // Base 4x4 textured stimulus from original D-04 case
    function automatic int base_o4(input int y, input int x);
        case (y)
            0: case (x) 0: return 483; 1: return 468; 2: return 536; default: return 468; endcase
            1: case (x) 0: return 490; 1: return 511; 2: return 475; default: return 532; endcase
            2: case (x) 0: return 491; 1: return 534; 2: return 536; default: return 465; endcase
            default: case (x) 0: return 539; 1: return 470; 2: return 513; default: return 534; endcase
        endcase
    endfunction

    // Test 1: 4x4 @ (0,0) - Classic D-04 (SAD Ver=395 vs SATD DC=729) + DM_CHROMA
    task automatic run_test_4x4();
        clear_memories();
        ref_top_luma[0] = 10'd483; ref_top_luma[1] = 10'd483; ref_top_luma[2] = 10'd517; ref_top_luma[3] = 10'd510;
        ref_left_luma[0] = 10'd512; ref_left_luma[1] = 10'd513; ref_left_luma[2] = 10'd490; ref_left_luma[3] = 10'd483;
        top_right_luma = 10'd512;
        bot_left_luma  = 10'd485;

        for (int y = 0; y < 4; y++) begin
            for (int x = 0; x < 4; x++) begin
                orig_y_mem[y][x] = base_o4(y, x);
            end
        end

        // 2x2 Chroma matching DC (DM_CHROMA when win_luma == DC=1)
        ref_top_u[0] = 10'd300; ref_top_u[1] = 10'd500;
        ref_left_u[0] = 10'd300; ref_left_u[1] = 10'd500;
        top_right_u = 10'd500; bot_left_u = 10'd500;
        ref_top_u[2] = top_right_u; ref_top_u[3] = top_right_u;
        ref_top_v[0] = 10'd420; ref_top_v[1] = 10'd420;
        ref_left_v[0] = 10'd420; ref_left_v[1] = 10'd420;
        top_right_v = 10'd420; bot_left_v = 10'd420;
        ref_top_v[2] = top_right_v; ref_top_v[3] = top_right_v;
        for (int y = 0; y < 2; y++) begin
            for (int x = 0; x < 2; x++) begin
                orig_u_mem[y][x] = 10'd400; // Matches DC_U=400
                orig_v_mem[y][x] = 10'd420;
            end
        end

        execute_and_check("Test 1 (4x4 D-04 + DM_CHROMA)", 3'd2, 6'd0, 6'd0);
    endtask

    // Test 2: 8x8 @ (8,8) - 4-tile SATD, negative col_t coeffs, non-zero offset, Chroma mode 34 subst
    task automatic run_test_8x8();
        logic [9:0] rt4[0:3];
        logic [9:0] rl4[0:3];
        clear_memories();
        rt4[0] = 10'd483; rt4[1] = 10'd483; rt4[2] = 10'd517; rt4[3] = 10'd510;
        rl4[0] = 10'd512; rl4[1] = 10'd513; rl4[2] = 10'd490; rl4[3] = 10'd483;

        // Transposed pattern: Hor(10) wins SAD (1580), DC(1) wins SATD (2916)
        for (int i = 0; i < 8; i++) begin
            ref_top_luma[i]  = rl4[i & 3];
            ref_left_luma[i] = rt4[i & 3];
        end
        top_right_luma = 10'd485;
        bot_left_luma  = 10'd512;

        for (int y = 0; y < 8; y++) begin
            for (int x = 0; x < 8; x++) begin
                orig_y_mem[8 + y][8 + x] = base_o4(x & 3, y & 3);
            end
        end

        // 4x4 Chroma @ (4,4): diagonal ramp matching mode 34 (substituted for DC=1 in Table 8-2)
        for (int i = 0; i < 8; i++) begin
            ref_top_u[i] = 10'd120 + i * 10'd90;
            ref_top_v[i] = 10'd800 - i * 10'd70;
        end
        for (int i = 0; i < 4; i++) begin
            ref_left_u[i] = 10'd200;
            ref_left_v[i] = 10'd300;
        end
        top_right_u = ref_top_u[4];
        top_right_v = ref_top_v[4];
        bot_left_u  = 10'd200;
        bot_left_v  = 10'd300;
        for (int y = 0; y < 4; y++) begin
            for (int x = 0; x < 4; x++) begin
                orig_u_mem[4 + y][4 + x] = ref_top_u[x + y + 1];
                orig_v_mem[4 + y][4 + x] = ref_top_v[x + y + 1];
            end
        end

        execute_and_check("Test 2 (8x8 @ (8,8) + Mode 34 Chroma)", 3'd3, 6'd8, 6'd8);
    endtask

    // Test 3: 16x16 @ (16,16) - 16 tiles, |diff| > 512 (proves 13b/15b no-overflow), Hor Chroma
    task automatic run_test_16x16();
        logic [9:0] rt4[0:3];
        logic [9:0] rl4[0:3];
        clear_memories();
        rt4[0] = 10'd883; rt4[1] = 10'd883; rt4[2] = 10'd917; rt4[3] = 10'd910;
        rl4[0] = 10'd912; rl4[1] = 10'd913; rl4[2] = 10'd890; rl4[3] = 10'd883;

        for (int i = 0; i < 16; i++) begin
            ref_top_luma[i]  = rt4[i & 3];
            ref_left_luma[i] = rl4[i & 3];
        end
        top_right_luma = 10'd912;
        bot_left_luma  = 10'd885;

        for (int y = 0; y < 16; y++) begin
            for (int x = 0; x < 16; x++) begin
                if (y < 4 && x < 4) begin
                    orig_y_mem[16 + y][16 + x] = 10'd50; // |diff| ~ 850 > 512 -> row_t~3452, col_t~13592
                end else begin
                    orig_y_mem[16 + y][16 + x] = base_o4(y & 3, x & 3) + 10'd400;
                end
            end
        end

        // 8x8 Chroma @ (8,8): matches Horizontal (mode 10)
        for (int i = 0; i < 16; i++) begin
            ref_top_u[i] = 10'd300;
            ref_top_v[i] = 10'd600;
        end
        for (int i = 0; i < 8; i++) begin
            ref_left_u[i] = 10'd180 + i * 10'd80;
            ref_left_v[i] = 10'd750 - i * 10'd60;
        end
        top_right_u = 10'd300; bot_left_u = 10'd740;
        top_right_v = 10'd600; bot_left_v = 10'd330;
        for (int y = 0; y < 8; y++) begin
            for (int x = 0; x < 8; x++) begin
                orig_u_mem[8 + y][8 + x] = ref_left_u[y];
                orig_v_mem[8 + y][8 + x] = ref_left_v[y];
            end
        end

        execute_and_check("Test 3 (16x16 @ (16,16) Large-Swing + Hor Chroma)", 3'd4, 6'd16, 6'd16);
    endtask

    // Test 4: 32x32 @ (32,0) - 64 tiles, peak-white Planar (1023), Planar wins SATD vs DC SAD, Ver Chroma
    task automatic run_test_32x32();
        clear_memories();
        for (int i = 0; i < 32; i++) begin
            ref_top_luma[i]  = (i & 1) ? 10'd1023 : 10'd960;
            ref_left_luma[i] = (i & 1) ? 10'd960  : 10'd1023;
        end
        top_right_luma = 10'd1023;
        bot_left_luma  = 10'd1023;

        for (int y = 0; y < 32; y++) begin
            for (int x = 0; x < 32; x++) begin
                int pp = ((31 - x) * ref_left_luma[y] + (x + 1) * top_right_luma +
                          (31 - y) * ref_top_luma[x]  + (y + 1) * bot_left_luma + 32) >> 6;
                if (pp > 1023) pp = 1023;
                orig_y_mem[y][32 + x] = (pp > 22) ? (pp - 22) : 0;
            end
        end

        // 16x16 Chroma @ (16,0): matches Vertical (mode 26)
        for (int i = 0; i < 32; i++) begin
            ref_top_u[i] = (i < 16) ? (10'd100 + i * 10'd45) : 10'd800;
            ref_top_v[i] = (i < 16) ? (10'd850 - i * 10'd40) : 10'd200;
        end
        for (int i = 0; i < 16; i++) begin
            ref_left_u[i] = 10'd450;
            ref_left_v[i] = 10'd450;
        end
        top_right_u = ref_top_u[16]; bot_left_u = 10'd450;
        top_right_v = ref_top_v[16]; bot_left_v = 10'd450;
        for (int y = 0; y < 16; y++) begin
            for (int x = 0; x < 16; x++) begin
                orig_u_mem[y][16 + x] = ref_top_u[x];
                orig_v_mem[y][16 + x] = ref_top_v[x];
            end
        end

        execute_and_check("Test 4 (32x32 @ (32,0) Peak-White Planar + Ver Chroma)", 3'd5, 6'd32, 6'd0);
    endtask

    initial begin
        rst_n        = 1'b0;
        start        = 1'b0;
        ref_valid    = 1'b0;
        ref_sample   = 10'd0;
        ref_sample_u = 10'd0;
        ref_sample_v = 10'd0;
        ref_idx      = 8'd0;
        ref_last     = 1'b0;
        pu_x         = 6'd0;
        pu_y         = 6'd0;
        pu_size_log2 = 3'd2;
        clear_memories();

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        $display("==================================================");
        $display(" Starting tb_flaw_intra_rmd Simulation");
`ifdef REMEDIATION
        $display(" Mode: REMEDIATED (Real RTL 4x4-Tiled Hadamard SATD Enabled)");
`else
        $display(" Mode: UNPATCHED / BUGGY (Real RTL Plain SAD Active)");
`endif
        $display("==================================================");

        run_test_4x4();
        run_test_8x8();
        run_test_16x16();
        run_test_32x32();

        $display("==================================================");
        if (total_errors == 0) begin
            $display(" *** ALL TESTS PASSED ***");
        end else begin
            $display(" *** FAILED: %0d Algorithmic Discrepancies Detected ***", total_errors);
        end
        $display("==================================================\n");
        $finish;
    end

endmodule
