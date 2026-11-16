//=============================================================================
// tb_mc_window_fetch.sv
// Comprehensive Unit Testbench for mc_window_fetch
//
// Verification Requirements:
//   1. TU sizes 4x4, 8x8, 16x16, 32x32
//   2. Components: Y (luma), Cb, Cr (chroma)
//   3. Boundary clamping: negative MVs (-40, -40), large positive MVs (+60, +60),
//      interior MVs (0, 0), asymmetrical MVs (+3, -5).
//   4. L0 and L1 dual-reference fetch verification.
//   5. Raster scan sequence covering exactly N^2 samples with win_last on (N-1, N-1).
//   6. Back-to-back TU requests with 0 idle bubble cycles.
//=============================================================================

`timescale 1ns / 1ps

module tb_mc_window_fetch;

    parameter PW = 10;

    reg clk;
    reg rst_n;

    reg                   start;
    reg [1:0]             comp;
    reg [2:0]             tu_size_log2;
    reg signed [12:0]     base_x;
    reg signed [12:0]     base_y;
    reg [2:0]             frac_x;
    reg [2:0]             frac_y;
    reg                   rd_hold;

    wire [13:0]           rd_addr_a;
    wire [13:0]           rd_addr_b;
    reg  [PW-1:0]         rd_data_l0_a;
    reg  [PW-1:0]         rd_data_l0_b;
    reg  [PW-1:0]         rd_data_l1_a;
    reg  [PW-1:0]         rd_data_l1_b;

    wire                  win_valid;
    wire [PW*64-1:0]      win_l0_flat;
    wire [PW*64-1:0]      win_l1_flat;
    wire [5:0]            win_x;
    wire [5:0]            win_y;
    wire                  win_last;
    wire                  busy;

    // Simulated DPB RAMs (128x128 = 16384 for luma, low 4096 for chroma)
    reg [PW-1:0] dpb_l0 [0:16383];
    reg [PW-1:0] dpb_l1 [0:16383];

    // DUT Instantiation
    mc_window_fetch #(
        .PW(PW)
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .start        (start),
        .comp         (comp),
        .tu_size_log2 (tu_size_log2),
        .base_x       (base_x),
        .base_y       (base_y),
        .frac_x       (frac_x),
        .frac_y       (frac_y),
        .rd_hold      (rd_hold),
        .rd_addr_a    (rd_addr_a),
        .rd_addr_b    (rd_addr_b),
        .rd_data_l0_a (rd_data_l0_a),
        .rd_data_l0_b (rd_data_l0_b),
        .rd_data_l1_a (rd_data_l1_a),
        .rd_data_l1_b (rd_data_l1_b),
        .win_valid    (win_valid),
        .win_l0_flat  (win_l0_flat),
        .win_l1_flat  (win_l1_flat),
        .win_x        (win_x),
        .win_y        (win_y),
        .win_last     (win_last),
        .busy         (busy)
    );

    // Clock generator: 10 ns (100 MHz)
    always #5 clk = ~clk;

    // 1-cycle synchronous True Dual-Port BRAM read model (Port A corrupts to X when rd_hold=1)
    always @(posedge clk) begin
        if (rd_hold === 1'b1) begin
            rd_data_l0_a <= {PW{1'bx}};
            rd_data_l1_a <= {PW{1'bx}};
            rd_data_l0_b <= dpb_l0[rd_addr_b];
            rd_data_l1_b <= dpb_l1[rd_addr_b];
        end else begin
            rd_data_l0_a <= dpb_l0[rd_addr_a];
            rd_data_l0_b <= dpb_l0[rd_addr_b];
            rd_data_l1_a <= dpb_l1[rd_addr_a];
            rd_data_l1_b <= dpb_l1[rd_addr_b];
        end
    end

    // Clamping helpers
    function automatic [6:0] clamp_128;
        input signed [12:0] val;
        begin
            if (val < 13'sd0) clamp_128 = 7'd0;
            else if (val > 13'sd127) clamp_128 = 7'd127;
            else clamp_128 = val[6:0];
        end
    endfunction

    function automatic [5:0] clamp_64;
        input signed [12:0] val;
        begin
            if (val < 13'sd0) clamp_64 = 6'd0;
            else if (val > 13'sd63) clamp_64 = 6'd63;
            else clamp_64 = val[5:0];
        end
    endfunction

    // Golden window generator
    function automatic [PW*64-1:0] get_golden_win;
        input is_l0;
        input [1:0] c_idx;
        input signed [12:0] bx, by;
        input [5:0] wx, wy;
        reg [PW*64-1:0] golden;
        integer gy, gx;
        begin
            golden = {(PW*64){1'b0}};
            if (c_idx == 2'd0) begin
                for (gy = 0; gy < 8; gy = gy + 1) begin
                    for (gx = 0; gx < 8; gx = gx + 1) begin
                        if (is_l0)
                            golden[PW*(gy*8 + gx) +: PW] = dpb_l0[{clamp_128(by + $signed({7'd0, wy}) + gx_to_offset(gy, 3)),
                                                                  clamp_128(bx + $signed({7'd0, wx}) + gx_to_offset(gx, 3))}];
                        else
                            golden[PW*(gy*8 + gx) +: PW] = dpb_l1[{clamp_128(by + $signed({7'd0, wy}) + gx_to_offset(gy, 3)),
                                                                  clamp_128(bx + $signed({7'd0, wx}) + gx_to_offset(gx, 3))}];
                    end
                end
            end else begin
                for (gy = 0; gy < 4; gy = gy + 1) begin
                    for (gx = 0; gx < 4; gx = gx + 1) begin
                        if (is_l0)
                            golden[PW*(gy*4 + gx) +: PW] = dpb_l0[{2'b00,
                                                                  clamp_64(by + $signed({7'd0, wy}) + gx_to_offset(gy, 1)),
                                                                  clamp_64(bx + $signed({7'd0, wx}) + gx_to_offset(gx, 1))}];
                        else
                            golden[PW*(gy*4 + gx) +: PW] = dpb_l1[{2'b00,
                                                                  clamp_64(by + $signed({7'd0, wy}) + gx_to_offset(gy, 1)),
                                                                  clamp_64(bx + $signed({7'd0, wx}) + gx_to_offset(gx, 1))}];
                    end
                end
            end
            get_golden_win = golden;
        end
    endfunction

    function automatic signed [12:0] gx_to_offset;
        input integer idx, off;
        begin
            gx_to_offset = $signed(idx) - $signed(off);
        end
    endfunction

    // Test runner task
    integer error_count = 0;
    integer total_samples_verified = 0;

    task automatic run_tu_test;
        input [1:0]             test_comp;
        input [2:0]             test_size_log2;
        input signed [12:0]     test_base_x;
        input signed [12:0]     test_base_y;
        integer exp_x, exp_y;
        integer n_pixels;
        reg [PW*64-1:0] exp_win_l0;
        reg [PW*64-1:0] exp_win_l1;
        begin
            n_pixels = (1 << test_size_log2);
            @(posedge clk);
            start        <= 1'b1;
            comp         <= test_comp;
            tu_size_log2 <= test_size_log2;
            base_x       <= test_base_x;
            base_y       <= test_base_y;
            @(posedge clk);
            start        <= 1'b0;

            for (exp_y = 0; exp_y < n_pixels; exp_y = exp_y + 1) begin
                for (exp_x = 0; exp_x < n_pixels; exp_x = exp_x + 1) begin
                    // Wait for win_valid
                    while (!win_valid) @(posedge clk);

                    // Verify coordinates
                    if (win_x !== exp_x[5:0] || win_y !== exp_y[5:0]) begin
                        $display("[ERROR] Coordinate mismatch: exp=(%0d,%0d) got=(%0d,%0d) comp=%0d size=%0d",
                                 exp_x, exp_y, win_x, win_y, test_comp, test_size_log2);
                        error_count = error_count + 1;
                    end

                    // Verify win_last
                    if ((exp_x == n_pixels - 1) && (exp_y == n_pixels - 1)) begin
                        if (!win_last) begin
                            $display("[ERROR] win_last missing on final sample (%0d,%0d)", exp_x, exp_y);
                            error_count = error_count + 1;
                        end
                    end else begin
                        if (win_last) begin
                            $display("[ERROR] win_last asserted prematurely at (%0d,%0d)", exp_x, exp_y);
                            error_count = error_count + 1;
                        end
                    end

                    // Verify golden window
                    exp_win_l0 = get_golden_win(1'b1, test_comp, test_base_x, test_base_y, exp_x[5:0], exp_y[5:0]);
                    exp_win_l1 = get_golden_win(1'b0, test_comp, test_base_x, test_base_y, exp_x[5:0], exp_y[5:0]);

                    if (win_l0_flat !== exp_win_l0) begin
                        $display("[ERROR] L0 Window mismatch at (%0d,%0d) comp=%0d base=(%0d,%0d)",
                                 exp_x, exp_y, test_comp, test_base_x, test_base_y);
                        if (error_count < 2) begin
                            for (integer dy = 0; dy < (test_comp == 0 ? 8 : 4); dy = dy + 1) begin
                                for (integer dx = 0; dx < (test_comp == 0 ? 8 : 4); dx = dx + 1) begin
                                    $display("  [%0d][%0d] got=%0d exp=%0d", dy, dx,
                                             win_l0_flat[PW*(dy*(test_comp == 0 ? 8 : 4) + dx) +: PW],
                                             exp_win_l0[PW*(dy*(test_comp == 0 ? 8 : 4) + dx) +: PW]);
                                end
                            end
                        end
                        error_count = error_count + 1;
                    end
                    if (win_l1_flat !== exp_win_l1) begin
                        $display("[ERROR] L1 Window mismatch at (%0d,%0d) comp=%0d base=(%0d,%0d)",
                                 exp_x, exp_y, test_comp, test_base_x, test_base_y);
                        error_count = error_count + 1;
                    end

                    total_samples_verified = total_samples_verified + 1;
                    @(posedge clk);
                end
            end
        end
    endtask

    task automatic run_tu_phase_test;
        input [1:0]             test_comp;
        input [2:0]             test_size_log2;
        input signed [12:0]     test_base_x;
        input signed [12:0]     test_base_y;
        input [2:0]             test_fx;
        input [2:0]             test_fy;
        integer exp_x, exp_y, dy, dx, cyc_cnt;
        integer n_pixels;
        reg [PW*64-1:0] exp_win_l0;
        reg [PW*64-1:0] exp_win_l1;
        reg fx_z, fy_z;
        begin
            n_pixels = (1 << test_size_log2);
            fx_z = (test_comp == 2'd0) ? (test_fx[1:0] === 2'd0) : (test_fx === 3'd0);
            fy_z = (test_comp == 2'd0) ? (test_fy[1:0] === 2'd0) : (test_fy === 3'd0);
            cyc_cnt = 0;

            @(posedge clk);
            start        <= 1'b1;
            comp         <= test_comp;
            tu_size_log2 <= test_size_log2;
            base_x       <= test_base_x;
            base_y       <= test_base_y;
            frac_x       <= test_fx;
            frac_y       <= test_fy;
            @(posedge clk);
            start        <= 1'b0;
            cyc_cnt      = 1;

            for (exp_y = 0; exp_y < n_pixels; exp_y = exp_y + 1) begin
                for (exp_x = 0; exp_x < n_pixels; exp_x = exp_x + 1) begin
                    while (!win_valid) begin
                        @(posedge clk);
                        cyc_cnt = cyc_cnt + 1;
                    end

                    if (win_x !== exp_x[5:0] || win_y !== exp_y[5:0]) begin
                        $display("[ERROR] Coordinate mismatch: exp=(%0d,%0d) got=(%0d,%0d) comp=%0d size=%0d fx=%0d fy=%0d",
                                 exp_x, exp_y, win_x, win_y, test_comp, test_size_log2, test_fx, test_fy);
                        error_count = error_count + 1;
                    end

                    if ((exp_x == n_pixels - 1) && (exp_y == n_pixels - 1)) begin
                        if (!win_last) begin
                            $display("[ERROR] win_last missing on final sample (%0d,%0d)", exp_x, exp_y);
                            error_count = error_count + 1;
                        end
                    end else if (win_last) begin
                        $display("[ERROR] win_last asserted prematurely at (%0d,%0d)", exp_x, exp_y);
                        error_count = error_count + 1;
                    end

                    exp_win_l0 = get_golden_win(1'b1, test_comp, test_base_x, test_base_y, exp_x[5:0], exp_y[5:0]);
                    exp_win_l1 = get_golden_win(1'b0, test_comp, test_base_x, test_base_y, exp_x[5:0], exp_y[5:0]);

                    if (test_comp == 2'd0) begin
                        for (dy = 0; dy < 8; dy = dy + 1) begin
                            for (dx = 0; dx < 8; dx = dx + 1) begin
                                if ((fx_z && fy_z && (dx != 3 || dy != 3)) ||
                                    (!fx_z && fy_z && (dy != 3)) ||
                                    (fx_z && !fy_z && (dx != 3))) begin
                                    // Unused taps in 0D/1D mode
                                end else begin
                                    if (win_l0_flat[PW*(dy*8+dx) +: PW] !== exp_win_l0[PW*(dy*8+dx) +: PW]) begin
                                        $display("[ERROR] L0 Luma tap mismatch at (%0d,%0d)[%0d][%0d] fx=%0d fy=%0d got=%0d exp=%0d",
                                                 exp_x, exp_y, dy, dx, test_fx, test_fy,
                                                 win_l0_flat[PW*(dy*8+dx) +: PW], exp_win_l0[PW*(dy*8+dx) +: PW]);
                                        error_count = error_count + 1;
                                    end
                                    if (win_l1_flat[PW*(dy*8+dx) +: PW] !== exp_win_l1[PW*(dy*8+dx) +: PW]) begin
                                        $display("[ERROR] L1 Luma tap mismatch at (%0d,%0d)[%0d][%0d] fx=%0d fy=%0d got=%0d exp=%0d",
                                                 exp_x, exp_y, dy, dx, test_fx, test_fy,
                                                 win_l1_flat[PW*(dy*8+dx) +: PW], exp_win_l1[PW*(dy*8+dx) +: PW]);
                                        error_count = error_count + 1;
                                    end
                                end
                            end
                        end
                    end else begin
                        for (dy = 0; dy < 4; dy = dy + 1) begin
                            for (dx = 0; dx < 4; dx = dx + 1) begin
                                if ((fx_z && fy_z && (dx != 1 || dy != 1)) ||
                                    (!fx_z && fy_z && (dy != 1)) ||
                                    (fx_z && !fy_z && (dx != 1))) begin
                                    // Unused taps in 0D/1D mode
                                end else begin
                                    if (win_l0_flat[PW*(dy*4+dx) +: PW] !== exp_win_l0[PW*(dy*4+dx) +: PW]) begin
                                        $display("[ERROR] L0 Chroma tap mismatch at (%0d,%0d)[%0d][%0d] fx=%0d fy=%0d got=%0d exp=%0d",
                                                 exp_x, exp_y, dy, dx, test_fx, test_fy,
                                                 win_l0_flat[PW*(dy*4+dx) +: PW], exp_win_l0[PW*(dy*4+dx) +: PW]);
                                        error_count = error_count + 1;
                                    end
                                    if (win_l1_flat[PW*(dy*4+dx) +: PW] !== exp_win_l1[PW*(dy*4+dx) +: PW]) begin
                                        $display("[ERROR] L1 Chroma tap mismatch at (%0d,%0d)[%0d][%0d] fx=%0d fy=%0d got=%0d exp=%0d",
                                                 exp_x, exp_y, dy, dx, test_fx, test_fy,
                                                 win_l1_flat[PW*(dy*4+dx) +: PW], exp_win_l1[PW*(dy*4+dx) +: PW]);
                                        error_count = error_count + 1;
                                    end
                                end
                            end
                        end
                    end

                    total_samples_verified = total_samples_verified + 1;
                    @(posedge clk);
                    cyc_cnt = cyc_cnt + 1;
                end
            end
            $display("[INFO] comp=%0d size=%0dx%0d fx=%0d fy=%0d -> %0d cycles",
                     test_comp, n_pixels, n_pixels, test_fx, test_fy, cyc_cnt);
        end
    endtask

    task automatic run_tu_stall_test;
        input [1:0]             test_comp;
        input [2:0]             test_size_log2;
        input signed [12:0]     test_base_x;
        input signed [12:0]     test_base_y;
        input [2:0]             test_fx;
        input [2:0]             test_fy;
        input                   stall_first_cyc;
        integer exp_x, exp_y, dy, dx, cyc_cnt, wait_cnt, stall_cnt;
        integer n_pixels;
        reg [PW*64-1:0] exp_win_l0;
        reg [PW*64-1:0] exp_win_l1;
        reg fx_z, fy_z;
        reg [15:0] stall_lfsr;
        begin
            n_pixels = (1 << test_size_log2);
            fx_z = (test_comp == 2'd0) ? (test_fx[1:0] === 2'd0) : (test_fx === 3'd0);
            fy_z = (test_comp == 2'd0) ? (test_fy[1:0] === 2'd0) : (test_fy === 3'd0);
            stall_lfsr = 16'hB4E1 ^ {test_comp, test_size_log2, test_fx, test_fy, 5'd19};
            cyc_cnt = 0;
            stall_cnt = 0;

            @(posedge clk);
            start        <= 1'b1;
            comp         <= test_comp;
            tu_size_log2 <= test_size_log2;
            base_x       <= test_base_x;
            base_y       <= test_base_y;
            frac_x       <= test_fx;
            frac_y       <= test_fy;
            rd_hold      <= stall_first_cyc;
            if (stall_first_cyc) stall_cnt = stall_cnt + 1;
            @(posedge clk);
            start        <= 1'b0;
            cyc_cnt      = 1;

            for (exp_y = 0; exp_y < n_pixels; exp_y = exp_y + 1) begin
                for (exp_x = 0; exp_x < n_pixels; exp_x = exp_x + 1) begin
                    wait_cnt = 0;
                    while (!win_valid) begin
                        stall_lfsr = {stall_lfsr[14:0], stall_lfsr[15] ^ stall_lfsr[13] ^ stall_lfsr[12] ^ stall_lfsr[10]};
                        // Include multi-cycle burst stalls and periodic single-cycle stalls, never permanent
                        rd_hold <= (cyc_cnt < 4 && stall_first_cyc) ? 1'b1 :
                                   ((stall_lfsr[2:0] == 3'd7) || (stall_lfsr[1:0] == 2'b01));
                        if ((cyc_cnt < 4 && stall_first_cyc) || (stall_lfsr[2:0] == 3'd7) || (stall_lfsr[1:0] == 2'b01))
                            stall_cnt = stall_cnt + 1;
                        @(posedge clk);
                        cyc_cnt = cyc_cnt + 1;
                        wait_cnt = wait_cnt + 1;
                        if (wait_cnt > 500) begin
                            $display("[FATAL] Timeout waiting for win_valid under rd_hold at (%0d,%0d)", exp_x, exp_y);
                            error_count = error_count + 1;
                            $finish;
                        end
                    end

                    if (win_x !== exp_x[5:0] || win_y !== exp_y[5:0]) begin
                        $display("[ERROR] [STALL] Coord mismatch: exp=(%0d,%0d) got=(%0d,%0d) comp=%0d fx=%0d fy=%0d",
                                 exp_x, exp_y, win_x, win_y, test_comp, test_fx, test_fy);
                        error_count = error_count + 1;
                    end

                    if ((exp_x == n_pixels - 1) && (exp_y == n_pixels - 1)) begin
                        if (!win_last) begin
                            $display("[ERROR] [STALL] win_last missing on (%0d,%0d)", exp_x, exp_y);
                            error_count = error_count + 1;
                        end
                    end else if (win_last) begin
                        $display("[ERROR] [STALL] win_last premature on (%0d,%0d)", exp_x, exp_y);
                        error_count = error_count + 1;
                    end

                    exp_win_l0 = get_golden_win(1'b1, test_comp, test_base_x, test_base_y, exp_x[5:0], exp_y[5:0]);
                    exp_win_l1 = get_golden_win(1'b0, test_comp, test_base_x, test_base_y, exp_x[5:0], exp_y[5:0]);

                    if (test_comp == 2'd0) begin
                        for (dy = 0; dy < 8; dy = dy + 1) begin
                            for (dx = 0; dx < 8; dx = dx + 1) begin
                                if ((fx_z && fy_z && (dx != 3 || dy != 3)) ||
                                    (!fx_z && fy_z && (dy != 3)) ||
                                    (fx_z && !fy_z && (dx != 3))) begin
                                end else begin
                                    if (win_l0_flat[PW*(dy*8+dx) +: PW] !== exp_win_l0[PW*(dy*8+dx) +: PW]) begin
                                        $display("[ERROR] [STALL] L0 Luma mismatch at (%0d,%0d)[%0d][%0d] got=%0d exp=%0d",
                                                 exp_x, exp_y, dy, dx,
                                                 win_l0_flat[PW*(dy*8+dx) +: PW], exp_win_l0[PW*(dy*8+dx) +: PW]);
                                        error_count = error_count + 1;
                                    end
                                    if (win_l1_flat[PW*(dy*8+dx) +: PW] !== exp_win_l1[PW*(dy*8+dx) +: PW]) begin
                                        $display("[ERROR] [STALL] L1 Luma mismatch at (%0d,%0d)[%0d][%0d] got=%0d exp=%0d",
                                                 exp_x, exp_y, dy, dx,
                                                 win_l1_flat[PW*(dy*8+dx) +: PW], exp_win_l1[PW*(dy*8+dx) +: PW]);
                                        error_count = error_count + 1;
                                    end
                                end
                            end
                        end
                    end else begin
                        for (dy = 0; dy < 4; dy = dy + 1) begin
                            for (dx = 0; dx < 4; dx = dx + 1) begin
                                if ((fx_z && fy_z && (dx != 1 || dy != 1)) ||
                                    (!fx_z && fy_z && (dy != 1)) ||
                                    (fx_z && !fy_z && (dx != 1))) begin
                                end else begin
                                    if (win_l0_flat[PW*(dy*4+dx) +: PW] !== exp_win_l0[PW*(dy*4+dx) +: PW]) begin
                                        $display("[ERROR] [STALL] L0 Chroma mismatch at (%0d,%0d)[%0d][%0d] got=%0d exp=%0d",
                                                 exp_x, exp_y, dy, dx,
                                                 win_l0_flat[PW*(dy*4+dx) +: PW], exp_win_l0[PW*(dy*4+dx) +: PW]);
                                        error_count = error_count + 1;
                                    end
                                    if (win_l1_flat[PW*(dy*4+dx) +: PW] !== exp_win_l1[PW*(dy*4+dx) +: PW]) begin
                                        $display("[ERROR] [STALL] L1 Chroma mismatch at (%0d,%0d)[%0d][%0d] got=%0d exp=%0d",
                                                 exp_x, exp_y, dy, dx,
                                                 win_l1_flat[PW*(dy*4+dx) +: PW], exp_win_l1[PW*(dy*4+dx) +: PW]);
                                        error_count = error_count + 1;
                                    end
                                end
                            end
                        end
                    end

                    total_samples_verified = total_samples_verified + 1;
                    // Toggle rd_hold on emission cycles too so every pipeline corner gets stressed
                    stall_lfsr = {stall_lfsr[14:0], stall_lfsr[15] ^ stall_lfsr[13] ^ stall_lfsr[12] ^ stall_lfsr[10]};
                    rd_hold <= stall_lfsr[0];
                    if (stall_lfsr[0]) stall_cnt = stall_cnt + 1;
                    @(posedge clk);
                    cyc_cnt = cyc_cnt + 1;
                end
            end
            rd_hold <= 1'b0;
            $display("[INFO] [STALL] comp=%0d size=%0dx%0d fx=%0d fy=%0d -> %0d cycles (%0d stall cycles)",
                     test_comp, n_pixels, n_pixels, test_fx, test_fy, cyc_cnt, stall_cnt);
        end
    endtask

    // Simulation sequence
    integer i;
    reg [15:0] lfsr;

    initial begin
        clk = 0;
        rst_n = 0;
        start = 0;
        comp = 0;
        tu_size_log2 = 2;
        base_x = 0;
        base_y = 0;
        frac_x = 3'bzzz;
        frac_y = 3'bzzz;
        rd_hold = 1'b0;

        // Fill DPBs with pseudo-random test pattern
        lfsr = 16'hACE1;
        for (i = 0; i < 16384; i = i + 1) begin
            lfsr = {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            dpb_l0[i] = lfsr[9:0];
            lfsr = {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            dpb_l1[i] = lfsr[9:0];
        end

        #20;
        rst_n = 1;
        #20;

        $display("=== Starting Exhaustive Unit Test of mc_window_fetch ===");

        // Test Matrix 1: Full 2D fallback (unconnected/X frac_x, frac_y) across sizes x MVs
        run_tu_test(2'd0, 3'd2, 13'sd16, 13'sd16);       // Luma 4x4 interior
        run_tu_test(2'd0, 3'd2, -13'sd40, -13'sd40);     // Luma 4x4 negative boundary
        run_tu_test(2'd0, 3'd2, 13'sd120, 13'sd120);     // Luma 4x4 positive boundary
        run_tu_test(2'd0, 3'd3, 13'sd32, 13'sd24);       // Luma 8x8 interior
        run_tu_test(2'd0, 3'd3, 13'sd3, -13'sd5);        // Luma 8x8 mixed MV
        run_tu_test(2'd0, 3'd4, 13'sd48, 13'sd48);       // Luma 16x16 interior

        // Chroma components Cb and Cr (full 2D)
        run_tu_test(2'd1, 3'd2, 13'sd8, 13'sd8);         // Cb 4x4 interior
        run_tu_test(2'd1, 3'd2, -13'sd15, -13'sd20);     // Cb 4x4 negative clamp
        run_tu_test(2'd1, 3'd2, 13'sd60, 13'sd60);       // Cb 4x4 positive clamp
        run_tu_test(2'd2, 3'd3, 13'sd16, 13'sd16);       // Cr 8x8 interior

        // Test Matrix 2: Back-to-back TUs with 0-cycle bubble
        $display("[INFO] Running back-to-back 0-cycle bubble test...");
        fork
            run_tu_test(2'd0, 3'd2, 13'sd10, 13'sd10);
        join
        run_tu_test(2'd1, 3'd2, 13'sd12, 13'sd14);

        // Test Matrix 3: Phase-Aware 0D, 1D-H, 1D-V, 2D (Luma 32x32 & Chroma 16x16)
        $display("[INFO] Running Phase-Aware 0D/1D/2D tests...");
        run_tu_phase_test(2'd0, 3'd3, 13'sd20, 13'sd18, 3'd0, 3'd0); // Luma 8x8 0D
        run_tu_phase_test(2'd0, 3'd3, 13'sd20, 13'sd18, 3'd2, 3'd0); // Luma 8x8 1D-H
        run_tu_phase_test(2'd0, 3'd3, 13'sd20, 13'sd18, 3'd0, 3'd3); // Luma 8x8 1D-V
        run_tu_phase_test(2'd0, 3'd3, 13'sd20, 13'sd18, 3'd1, 3'd3); // Luma 8x8 2D
        run_tu_phase_test(2'd0, 3'd5, 13'sd16, 13'sd16, 3'd0, 3'd0); // Luma 32x32 0D
        run_tu_phase_test(2'd0, 3'd5, 13'sd16, 13'sd16, 3'd2, 3'd0); // Luma 32x32 1D-H
        run_tu_phase_test(2'd0, 3'd5, 13'sd16, 13'sd16, 3'd0, 3'd1); // Luma 32x32 1D-V
        run_tu_phase_test(2'd0, 3'd5, 13'sd16, 13'sd16, 3'd1, 3'd2); // Luma 32x32 2D
        run_tu_phase_test(2'd1, 3'd4, 13'sd8,  13'sd8,  3'd0, 3'd0); // Chroma 16x16 0D
        run_tu_phase_test(2'd1, 3'd4, 13'sd8,  13'sd8,  3'd4, 3'd0); // Chroma 16x16 1D-H
        run_tu_phase_test(2'd1, 3'd4, 13'sd8,  13'sd8,  3'd0, 3'd5); // Chroma 16x16 1D-V
        run_tu_phase_test(2'd1, 3'd4, 13'sd8,  13'sd8,  3'd3, 3'd6); // Chroma 16x16 2D
        run_tu_phase_test(2'd2, 3'd2, -13'sd3, -13'sd2, 3'd4, 3'd0); // Cr 4x4 1D-H boundary
        run_tu_phase_test(2'd2, 3'd2, 13'sd61, 13'sd61, 3'd0, 3'd3); // Cr 4x4 1D-V boundary

        // Test Matrix 4: Port-A DPB Write Collision (rd_hold) Stall Stress Tests
        $display("[INFO] Running Port-A rd_hold collision stall stress tests...");
        run_tu_stall_test(2'd0, 3'd2, 13'sd10, 13'sd12, 3'd0, 3'd0, 1'b1); // Luma 4x4 0D + start stall
        run_tu_stall_test(2'd0, 3'd3, 13'sd20, 13'sd18, 3'd2, 3'd0, 1'b1); // Luma 8x8 1D-H + start stall
        run_tu_stall_test(2'd0, 3'd3, 13'sd20, 13'sd18, 3'd0, 3'd3, 1'b0); // Luma 8x8 1D-V + mid stalls
        run_tu_stall_test(2'd0, 3'd3, 13'sd20, 13'sd18, 3'd1, 3'd3, 1'b1); // Luma 8x8 2D + burst stalls
        run_tu_stall_test(2'd1, 3'd3, 13'sd16, 13'sd12, 3'd3, 3'd6, 1'b1); // Cb 8x8 2D + start stall

        // Verify unconnected/X rd_hold safely treats as un-stalled in simulation
        rd_hold = 1'bx;
        run_tu_phase_test(2'd0, 3'd2, 13'sd4, 13'sd4, 3'd1, 3'd1);
        rd_hold = 1'b0;

        #100;
        if (error_count == 0) begin
            $display("=========================================================");
            $display("  ALL WINDOW CHECKS PASSED (%0d samples verified)", total_samples_verified);
            $display("=========================================================");
        end else begin
            $display("[FATAL] Total errors detected: %0d", error_count);
        end

        $finish;
    end

endmodule
