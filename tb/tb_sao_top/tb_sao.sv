//=============================================================================
// tb_sao.sv
// Comprehensive Self-Checking Integration Testbench for sao_top
// Verifies BOTH SINGLE_PORT_BRAM_MODE = 0 and SINGLE_PORT_BRAM_MODE = 1
// Covers: Golden .dat file, EO_0..3 (incl. EO_45 right-border n0_rd_valid),
//         BO non-cyclic & cyclic (band_pos=30), Clip1 saturation, active Cb+Cr,
//         OFF bypass, and cross-CTU external neighbor memory across 4 CTUs.
//=============================================================================

`timescale 1ns/1ps
`include "parameter_pkg.vh"

`ifndef PIXEL_WIDTH
`define PIXEL_WIDTH 10
`endif
`ifndef SAO_OFFSET_WIDTH
`define SAO_OFFSET_WIDTH 5
`endif
`ifndef BIT_DEPTH
`define BIT_DEPTH 10
`endif

module tb_sao;

    logic clk;
    logic rst_n;

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // Shared Control & Parameters
    logic        active_mode; // 0=dual-port mode, 1=single-port BRAM mode
    logic [9:0]  ctu_x, ctu_y;
    logic [11:0] frame_width_px, frame_height_px;
    logic [5:0]  sao_type;
    logic [5:0]  eo_class;
    logic [74:0] eo_offset;
    logic [14:0] band_pos;
    logic [59:0] bo_offset;

    logic [1:0]  stype [3];
    logic [1:0]  eocls [3];
    logic [4:0]  bpos  [3];
    logic signed [4:0] eoff [3][5];
    logic signed [4:0] boff [3][4];

    // Mode 0 wires
    logic        m0_ctu_valid, m0_ctu_ready, m0_ctu_done;
    logic        m0_pix_rd_valid, m0_pix_rd_ready, m0_pix_resp_valid, m0_pix_resp_ready;
    logic [5:0]  m0_pix_rd_x, m0_pix_rd_y; logic [1:0] m0_pix_rd_comp;
    logic [9:0]  m0_pix_resp_data;
    logic        m0_n0_rd_valid, m0_n0_rd_ready, m0_n0_resp_valid, m0_n0_resp_ready;
    logic signed [7:0] m0_n0_rd_x, m0_n0_rd_y; logic [1:0] m0_n0_rd_comp;
    logic [9:0]  m0_n0_resp_data;
    logic        m0_n1_rd_valid, m0_n1_rd_ready, m0_n1_resp_valid, m0_n1_resp_ready;
    logic signed [7:0] m0_n1_rd_x, m0_n1_rd_y; logic [1:0] m0_n1_rd_comp;
    logic [9:0]  m0_n1_resp_data;
    logic        m0_pix_wr_valid, m0_pix_wr_ready;
    logic [5:0]  m0_pix_wr_x, m0_pix_wr_y; logic [1:0] m0_pix_wr_comp;
    logic [9:0]  m0_pix_wr_data;

    // Mode 1 wires
    logic        m1_ctu_valid, m1_ctu_ready, m1_ctu_done;
    logic        m1_pix_rd_valid, m1_pix_rd_ready, m1_pix_resp_valid, m1_pix_resp_ready;
    logic [5:0]  m1_pix_rd_x, m1_pix_rd_y; logic [1:0] m1_pix_rd_comp;
    logic [9:0]  m1_pix_resp_data;
    logic        m1_n0_rd_valid, m1_n0_rd_ready, m1_n0_resp_valid, m1_n0_resp_ready;
    logic signed [7:0] m1_n0_rd_x, m1_n0_rd_y; logic [1:0] m1_n0_rd_comp;
    logic [9:0]  m1_n0_resp_data;
    logic        m1_n1_rd_valid, m1_n1_rd_ready, m1_n1_resp_valid, m1_n1_resp_ready;
    logic signed [7:0] m1_n1_rd_x, m1_n1_rd_y; logic [1:0] m1_n1_rd_comp;
    logic [9:0]  m1_n1_resp_data;
    logic        m1_pix_wr_valid, m1_pix_wr_ready;
    logic [5:0]  m1_pix_wr_x, m1_pix_wr_y; logic [1:0] m1_pix_wr_comp;
    logic [9:0]  m1_pix_wr_data;

    sao_top #(.SINGLE_PORT_BRAM_MODE(0)) u_dut_m0 (
        .clk(clk), .rst_n(rst_n),
        .ctu_valid(m0_ctu_valid), .ctu_ready(m0_ctu_ready),
        .ctu_x(ctu_x), .ctu_y(ctu_y),
        .frame_width_px(frame_width_px), .frame_height_px(frame_height_px),
        .sao_type(sao_type), .eo_class(eo_class), .eo_offset(eo_offset),
        .band_pos(band_pos), .bo_offset(bo_offset),
        .pix_rd_valid(m0_pix_rd_valid), .pix_rd_ready(m0_pix_rd_ready),
        .pix_rd_x(m0_pix_rd_x), .pix_rd_y(m0_pix_rd_y), .pix_rd_comp(m0_pix_rd_comp),
        .pix_resp_valid(m0_pix_resp_valid), .pix_resp_ready(m0_pix_resp_ready), .pix_resp_data(m0_pix_resp_data),
        .n0_rd_valid(m0_n0_rd_valid), .n0_rd_ready(m0_n0_rd_ready),
        .n0_rd_x(m0_n0_rd_x), .n0_rd_y(m0_n0_rd_y), .n0_rd_comp(m0_n0_rd_comp),
        .n0_resp_valid(m0_n0_resp_valid), .n0_resp_ready(m0_n0_resp_ready), .n0_resp_data(m0_n0_resp_data),
        .n1_rd_valid(m0_n1_rd_valid), .n1_rd_ready(m0_n1_rd_ready),
        .n1_rd_x(m0_n1_rd_x), .n1_rd_y(m0_n1_rd_y), .n1_rd_comp(m0_n1_rd_comp),
        .n1_resp_valid(m0_n1_resp_valid), .n1_resp_ready(m0_n1_resp_ready), .n1_resp_data(m0_n1_resp_data),
        .pix_wr_valid(m0_pix_wr_valid), .pix_wr_ready(m0_pix_wr_ready),
        .pix_wr_x(m0_pix_wr_x), .pix_wr_y(m0_pix_wr_y), .pix_wr_comp(m0_pix_wr_comp), .pix_wr_data(m0_pix_wr_data),
        .ctu_done(m0_ctu_done)
    );

    sao_top #(.SINGLE_PORT_BRAM_MODE(1)) u_dut_m1 (
        .clk(clk), .rst_n(rst_n),
        .ctu_valid(m1_ctu_valid), .ctu_ready(m1_ctu_ready),
        .ctu_x(ctu_x), .ctu_y(ctu_y),
        .frame_width_px(frame_width_px), .frame_height_px(frame_height_px),
        .sao_type(sao_type), .eo_class(eo_class), .eo_offset(eo_offset),
        .band_pos(band_pos), .bo_offset(bo_offset),
        .pix_rd_valid(m1_pix_rd_valid), .pix_rd_ready(m1_pix_rd_ready),
        .pix_rd_x(m1_pix_rd_x), .pix_rd_y(m1_pix_rd_y), .pix_rd_comp(m1_pix_rd_comp),
        .pix_resp_valid(m1_pix_resp_valid), .pix_resp_ready(m1_pix_resp_ready), .pix_resp_data(m1_pix_resp_data),
        .n0_rd_valid(m1_n0_rd_valid), .n0_rd_ready(m1_n0_rd_ready),
        .n0_rd_x(m1_n0_rd_x), .n0_rd_y(m1_n0_rd_y), .n0_rd_comp(m1_n0_rd_comp),
        .n0_resp_valid(m1_n0_resp_valid), .n0_resp_ready(m1_n0_resp_ready), .n0_resp_data(m1_n0_resp_data),
        .n1_rd_valid(m1_n1_rd_valid), .n1_rd_ready(m1_n1_rd_ready),
        .n1_rd_x(m1_n1_rd_x), .n1_rd_y(m1_n1_rd_y), .n1_rd_comp(m1_n1_rd_comp),
        .n1_resp_valid(m1_n1_resp_valid), .n1_resp_ready(m1_n1_resp_ready), .n1_resp_data(m1_n1_resp_data),
        .pix_wr_valid(m1_pix_wr_valid), .pix_wr_ready(m1_pix_wr_ready),
        .pix_wr_x(m1_pix_wr_x), .pix_wr_y(m1_pix_wr_y), .pix_wr_comp(m1_pix_wr_comp), .pix_wr_data(m1_pix_wr_data),
        .ctu_done(m1_ctu_done)
    );

    // Pack SAO parameters
    always_comb begin
        sao_type = {stype[2], stype[1], stype[0]};
        eo_class = {eocls[2], eocls[1], eocls[0]};
        band_pos = {bpos[2],  bpos[1],  bpos[0]};
        eo_offset = 0; bo_offset = 0;
        for (int c = 0; c < 3; c++) begin
            for (int i = 0; i < 5; i++) eo_offset[c*25 + i*5 +: 5] = eoff[c][i];
            for (int i = 0; i < 4; i++) bo_offset[c*20 + i*5 +: 5] = boff[c][i];
        end
    end

    // Memory incl. external neighbor border (mem_nbr)
    logic [9:0] mem_y  [-1:64][-1:64];
    logic [9:0] mem_cb [-1:32][-1:32];
    logic [9:0] mem_cr [-1:32][-1:32];

    logic [9:0] exp_y  [0:63][0:63];
    logic [9:0] exp_cb [0:31][0:31];
    logic [9:0] exp_cr [0:31][0:31];

    logic [9:0] got_y  [0:63][0:63];
    logic [9:0] got_cb [0:31][0:31];
    logic [9:0] got_cr [0:31][0:31];

    logic [9:0] file_in_y  [0:63][0:63], file_in_cb  [0:31][0:31], file_in_cr  [0:31][0:31];
    logic [9:0] file_gld_y [0:63][0:63], file_gld_cb [0:31][0:31], file_gld_cr [0:31][0:31];
    logic [1:0] file_stype[3], file_eocls[3];
    logic [4:0] file_bpos[3];
    logic signed [4:0] file_eoff[3][5], file_boff[3][4];
    logic has_golden_file = 1'b0;

    function automatic logic [9:0] read_mem(input logic [1:0] comp, input int x, input int y);
        if (comp == 2'd0) begin
            if (x >= -1 && x <= 64 && y >= -1 && y <= 64) return mem_y[y][x];
            return 10'd0;
        end else if (comp == 2'd1) begin
            if (x >= -1 && x <= 32 && y >= -1 && y <= 32) return mem_cb[y][x];
            return 10'd0;
        end else begin
            if (x >= -1 && x <= 32 && y >= -1 && y <= 32) return mem_cr[y][x];
            return 10'd0;
        end
    endfunction

    assign m0_pix_rd_ready = 1'b1; assign m0_n0_rd_ready = 1'b1; assign m0_n1_rd_ready = 1'b1; assign m0_pix_wr_ready = 1'b1;
    assign m1_pix_rd_ready = 1'b1; assign m1_n0_rd_ready = 1'b1; assign m1_n1_rd_ready = 1'b1; assign m1_pix_wr_ready = 1'b1;

    int total_errors = 0;
    int m1_eo45_right_border_n0_reads = 0;
    int cur_wr_cnt = 0;

    // Mock 1-cycle synchronous BRAM responders for Mode 0 and Mode 1
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            m0_pix_resp_valid <= 0; m0_n0_resp_valid <= 0; m0_n1_resp_valid <= 0;
            m1_pix_resp_valid <= 0; m1_n0_resp_valid <= 0; m1_n1_resp_valid <= 0;
            m0_pix_resp_data  <= 0; m0_n0_resp_data  <= 0; m0_n1_resp_data  <= 0;
            m1_pix_resp_data  <= 0; m1_n0_resp_data  <= 0; m1_n1_resp_data  <= 0;
        end else begin
            // Mode 0
            m0_pix_resp_valid <= m0_pix_rd_valid;
            if (m0_pix_rd_valid) m0_pix_resp_data <= read_mem(m0_pix_rd_comp, int'(m0_pix_rd_x), int'(m0_pix_rd_y));
            m0_n0_resp_valid <= m0_n0_rd_valid;
            if (m0_n0_rd_valid)  m0_n0_resp_data  <= read_mem(m0_n0_rd_comp,  int'(m0_n0_rd_x),  int'(m0_n0_rd_y));
            m0_n1_resp_valid <= m0_n1_rd_valid;
            if (m0_n1_rd_valid)  m0_n1_resp_data  <= read_mem(m0_n1_rd_comp,  int'(m0_n1_rd_x),  int'(m0_n1_rd_y));

            // Mode 1
            m1_pix_resp_valid <= m1_pix_rd_valid;
            if (m1_pix_rd_valid) m1_pix_resp_data <= read_mem(m1_pix_rd_comp, int'(m1_pix_rd_x), int'(m1_pix_rd_y));
            m1_n0_resp_valid <= m1_n0_rd_valid;
            if (m1_n0_rd_valid)  m1_n0_resp_data  <= read_mem(m1_n0_rd_comp,  int'(m1_n0_rd_x),  int'(m1_n0_rd_y));
            m1_n1_resp_valid <= m1_n1_rd_valid;
            if (m1_n1_rd_valid)  m1_n1_resp_data  <= read_mem(m1_n1_rd_comp,  int'(m1_n1_rd_x),  int'(m1_n1_rd_y));

            // Strict single-port BRAM conflict assertion in Mode 1
            if (m1_pix_rd_valid && m1_n1_rd_valid) begin
                $display("[FAIL] SINGLE_PORT_BRAM_MODE=1 collision: pix_rd_valid && n1_rd_valid both 1 at t=%0t", $time);
                total_errors++;
            end
            if (m1_n0_rd_valid && m1_n0_rd_comp == 2'd0 && m1_n0_rd_x == 8'sd64 && m1_n0_rd_y >= 8'sd0)
                m1_eo45_right_border_n0_reads++;

            // Capture writes from active DUT
            if (!active_mode && m0_pix_wr_valid) begin
                cur_wr_cnt++;
                if (m0_pix_wr_comp == 0)      got_y[m0_pix_wr_y][m0_pix_wr_x]   <= m0_pix_wr_data;
                else if (m0_pix_wr_comp == 1) got_cb[m0_pix_wr_y][m0_pix_wr_x]  <= m0_pix_wr_data;
                else                          got_cr[m0_pix_wr_y][m0_pix_wr_x]  <= m0_pix_wr_data;
            end
            if (active_mode && m1_pix_wr_valid) begin
                cur_wr_cnt++;
                if (m1_pix_wr_comp == 0)      got_y[m1_pix_wr_y][m1_pix_wr_x]   <= m1_pix_wr_data;
                else if (m1_pix_wr_comp == 1) got_cb[m1_pix_wr_y][m1_pix_wr_x]  <= m1_pix_wr_data;
                else                          got_cr[m1_pix_wr_y][m1_pix_wr_x]  <= m1_pix_wr_data;
            end
        end
    end

    // HM Reference Computation (10-bit, full external neighbor support + pic border clamp)
    function automatic int hm_sign(input int a, input int b);
        if (a > b) return 1;
        if (a < b) return -1;
        return 0;
    endfunction

    function automatic logic [9:0] clip1(input int v);
        if (v < 0) return 10'd0;
        if (v > 1023) return 10'd1023;
        return v[9:0];
    endfunction

    task automatic compute_golden_outputs();
        for (int c = 0; c < 3; c++) begin
            int max_d = (c == 0) ? 64 : 32;
            int fw    = (c == 0) ? int'(frame_width_px)  : (int'(frame_width_px) >> 1);
            int fh    = (c == 0) ? int'(frame_height_px) : (int'(frame_height_px) >> 1);
            int cx0   = int'(ctu_x) * max_d;
            int cy0   = int'(ctu_y) * max_d;

            for (int y = 0; y < max_d; y++) begin
                for (int x = 0; x < max_d; x++) begin
                    int p = int'(read_mem(c[1:0], x, y));
                    int out_v = p;
                    if (stype[c] == 2'd1) begin
                        int abs_x = cx0 + x;
                        int abs_y = cy0 + y;
                        bit bnd = 0;
                        int n0x = x, n0y = y, n1x = x, n1y = y;
                        if (eocls[c] == 2'd0) begin
                            bnd = (abs_x == 0 || abs_x == fw - 1);
                            n0x = x - 1; n1x = x + 1;
                        end else if (eocls[c] == 2'd1) begin
                            bnd = (abs_y == 0 || abs_y == fh - 1);
                            n0y = y - 1; n1y = y + 1;
                        end else if (eocls[c] == 2'd2) begin
                            bnd = (abs_x == 0 || abs_y == 0 || abs_x == fw - 1 || abs_y == fh - 1);
                            n0x = x - 1; n0y = y - 1; n1x = x + 1; n1y = y + 1;
                        end else begin
                            bnd = (abs_x == 0 || abs_y == 0 || abs_x == fw - 1 || abs_y == fh - 1);
                            n0x = x + 1; n0y = y - 1; n1x = x - 1; n1y = y + 1;
                        end
                        if (!bnd) begin
                            int n0 = int'(read_mem(c[1:0], n0x, n0y));
                            int n1 = int'(read_mem(c[1:0], n1x, n1y));
                            int cat = hm_sign(p, n0) + hm_sign(p, n1) + 2;
                            out_v = int'(clip1(p + int'(eoff[c][cat])));
                        end
                    end else if (stype[c] == 2'd2) begin
                        int band = (p >> 5) & 31;
                        int diff = (band - int'(bpos[c])) & 31;
                        if (diff < 4)
                            out_v = int'(clip1(p + int'(boff[c][diff])));
                    end

                    if (c == 0)      exp_y[y][x]  = out_v[9:0];
                    else if (c == 1) exp_cb[y][x] = out_v[9:0];
                    else             exp_cr[y][x] = out_v[9:0];
                end
            end
        end
    endtask

    task automatic init_synthetic_mem(input int seed);
        for (int y = -1; y <= 64; y++) begin
            for (int x = -1; x <= 64; x++) begin
                mem_y[y][x] = 10'((seed * 73 + (y + 1) * 29 + (x + 1) * 17 + ((x ^ y) & 7) * 51) & 10'h3FF);
            end
        end
        for (int y = -1; y <= 32; y++) begin
            for (int x = -1; x <= 32; x++) begin
                mem_cb[y][x] = 10'((seed * 41 + (y + 1) * 19 + (x + 1) * 31 + ((x ^ y) & 3) * 63) & 10'h3FF);
                mem_cr[y][x] = 10'((seed * 59 + (y + 1) * 23 + (x + 1) * 13 + ((x + y) & 7) * 45) & 10'h3FF);
            end
        end
        // Pre-seed got buffers with input mem (so OFF-mode checks untouched retention too)
        for (int y = 0; y < 64; y++) for (int x = 0; x < 64; x++) got_y[y][x]  = mem_y[y][x];
        for (int y = 0; y < 32; y++) for (int x = 0; x < 32; x++) got_cb[y][x] = mem_cb[y][x];
        for (int y = 0; y < 32; y++) for (int x = 0; x < 32; x++) got_cr[y][x] = mem_cr[y][x];
    endtask

    task automatic run_dut_and_check(input string label, input bit ignore_eo_edge, input int exp_wr_cnt);
        int match_cnt = 0;
        int mismatch_cnt = 0;
        int timeout = 0;

        cur_wr_cnt = 0;
        @(posedge clk);
        if (!active_mode) m0_ctu_valid = 1'b1;
        else              m1_ctu_valid = 1'b1;
        @(posedge clk);
        while ((!active_mode && m0_ctu_ready) || (active_mode && m1_ctu_ready)) @(posedge clk);
        m0_ctu_valid = 1'b0;
        m1_ctu_valid = 1'b0;

        while (((!active_mode && !m0_ctu_done) || (active_mode && !m1_ctu_done)) && timeout < 200000) begin
            @(posedge clk);
            timeout++;
        end
        repeat (4) @(posedge clk);

        if (timeout >= 200000) begin
            $display("[FAIL] %s (mode=%0d): TIMEOUT!", label, active_mode);
            total_errors++;
            return;
        end
        if (exp_wr_cnt >= 0 && cur_wr_cnt != exp_wr_cnt) begin
            $display("[FAIL] %s (mode=%0d): Write count mismatch exp=%0d got=%0d", label, active_mode, exp_wr_cnt, cur_wr_cnt);
            total_errors++;
        end

        for (int y = 0; y < 64; y++) begin
            for (int x = 0; x < 64; x++) begin
                bit is_edge = (x == 0 || y == 0 || x == 63 || y == 63);
                if (ignore_eo_edge && stype[0] == 2'd1 && is_edge) continue;
                if (got_y[y][x] !== exp_y[y][x]) begin
                    mismatch_cnt++;
                    if (mismatch_cnt <= 8)
                        $display("  Mismatch Y (%0d,%0d): Exp=%0d Got=%0d", x, y, exp_y[y][x], got_y[y][x]);
                end else begin
                    match_cnt++;
                end
            end
        end
        for (int y = 0; y < 32; y++) begin
            for (int x = 0; x < 32; x++) begin
                bit is_edge = (x == 0 || y == 0 || x == 31 || y == 31);
                if (!(ignore_eo_edge && stype[1] == 2'd1 && is_edge)) begin
                    if (got_cb[y][x] !== exp_cb[y][x]) begin
                        mismatch_cnt++;
                        if (mismatch_cnt <= 8)
                            $display("  Mismatch Cb (%0d,%0d): Exp=%0d Got=%0d", x, y, exp_cb[y][x], got_cb[y][x]);
                    end else begin
                        match_cnt++;
                    end
                end
                if (!(ignore_eo_edge && stype[2] == 2'd1 && is_edge)) begin
                    if (got_cr[y][x] !== exp_cr[y][x]) begin
                        mismatch_cnt++;
                        if (mismatch_cnt <= 8)
                            $display("  Mismatch Cr (%0d,%0d): Exp=%0d Got=%0d", x, y, exp_cr[y][x], got_cr[y][x]);
                    end else begin
                        match_cnt++;
                    end
                end
            end
        end

        total_errors += mismatch_cnt;
        $display("[Mode %0d] %-32s: matches=%0d mismatches=%0d (writes=%0d)",
                 active_mode, label, match_cnt, mismatch_cnt, cur_wr_cnt);
    endtask

    initial begin
        int fd, val, r;
        int t_stype, t_eocls, t_bpos, t_eoff, t_boff;

        fd = $fopen("sao_in.dat", "r");
        if (!fd) fd = $fopen("tb/tb_sao_top/sao_in.dat", "r");
        if (fd) begin
            for (int y = 0; y < 64; y++) for (int x = 0; x < 64; x++) begin r = $fscanf(fd, "%d", val); file_in_y[y][x] = val; end
            for (int y = 0; y < 32; y++) for (int x = 0; x < 32; x++) begin r = $fscanf(fd, "%d", val); file_in_cb[y][x] = val; end
            for (int y = 0; y < 32; y++) for (int x = 0; x < 32; x++) begin r = $fscanf(fd, "%d", val); file_in_cr[y][x] = val; end
            $fclose(fd);
            fd = $fopen("sao_out_golden.dat", "r");
            if (!fd) fd = $fopen("tb/tb_sao_top/sao_out_golden.dat", "r");
            if (fd) begin
                has_golden_file = 1'b1;
                for (int c = 0; c < 3; c++) begin
                    r = $fscanf(fd, "%d %d %d", t_stype, t_eocls, t_bpos);
                    file_stype[c] = t_stype; file_eocls[c] = t_eocls; file_bpos[c] = t_bpos;
                    for (int i = 0; i < 5; i++) begin r = $fscanf(fd, "%d", t_eoff); file_eoff[c][i] = t_eoff; end
                    for (int i = 0; i < 4; i++) begin r = $fscanf(fd, "%d", t_boff); file_boff[c][i] = t_boff; end
                end
                for (int y = 0; y < 64; y++) for (int x = 0; x < 64; x++) begin r = $fscanf(fd, "%d", val); file_gld_y[y][x]  = val; end
                for (int y = 0; y < 32; y++) for (int x = 0; x < 32; x++) begin r = $fscanf(fd, "%d", val); file_gld_cb[y][x] = val; end
                for (int y = 0; y < 32; y++) for (int x = 0; x < 32; x++) begin r = $fscanf(fd, "%d", val); file_gld_cr[y][x] = val; end
                $fclose(fd);
            end
        end

        rst_n = 0;
        m0_ctu_valid = 0; m1_ctu_valid = 0;
        active_mode = 0;
        ctu_x = 0; ctu_y = 0;
        frame_width_px = 12'd128; frame_height_px = 12'd128;
        for (int c = 0; c < 3; c++) begin
            stype[c] = 0; eocls[c] = 0; bpos[c] = 0;
            for (int i = 0; i < 5; i++) eoff[c][i] = 0;
            for (int i = 0; i < 4; i++) boff[c][i] = 0;
        end
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        $display("=== Starting Comprehensive tb_sao Suite (Mode 0 & Mode 1) ===");

        for (int m = 0; m < 2; m++) begin
            active_mode = m[0];

            // Case 1: HM Golden .dat Regression (if available)
            if (has_golden_file) begin
                ctu_x = 0; ctu_y = 0; frame_width_px = 12'd128; frame_height_px = 12'd128;
                for (int y = -1; y <= 64; y++) for (int x = -1; x <= 64; x++) mem_y[y][x] = 0;
                for (int y = -1; y <= 32; y++) for (int x = -1; x <= 32; x++) begin mem_cb[y][x] = 0; mem_cr[y][x] = 0; end
                for (int y = 0; y < 64; y++) for (int x = 0; x < 64; x++) begin mem_y[y][x] = file_in_y[y][x]; got_y[y][x] = file_in_y[y][x]; exp_y[y][x] = file_gld_y[y][x]; end
                for (int y = 0; y < 32; y++) for (int x = 0; x < 32; x++) begin
                    mem_cb[y][x] = file_in_cb[y][x]; got_cb[y][x] = file_in_cb[y][x]; exp_cb[y][x] = file_gld_cb[y][x];
                    mem_cr[y][x] = file_in_cr[y][x]; got_cr[y][x] = file_in_cr[y][x]; exp_cr[y][x] = file_gld_cr[y][x];
                end
                for (int c = 0; c < 3; c++) begin
                    stype[c] = file_stype[c]; eocls[c] = file_eocls[c]; bpos[c] = file_bpos[c];
                    for (int i = 0; i < 5; i++) eoff[c][i] = file_eoff[c][i];
                    for (int i = 0; i < 4; i++) boff[c][i] = file_boff[c][i];
                end
                run_dut_and_check("Golden .dat Interior+Chroma", 1'b1, -1);
            end

            // Case 2: EO_0 Horizontal at CTU (1,1) with mem_nbr (full 6,144/6,144 check)
            ctu_x = 1; ctu_y = 1; frame_width_px = 12'd128; frame_height_px = 12'd128;
            init_synthetic_mem(1);
            for (int c = 0; c < 3; c++) begin
                stype[c] = 2'd1; eocls[c] = 2'd0; bpos[c] = 0;
                eoff[c][0] = 5'sd5; eoff[c][1] = 5'sd2; eoff[c][2] = 5'sd0; eoff[c][3] = -5'sd2; eoff[c][4] = -5'sd4;
            end
            compute_golden_outputs();
            run_dut_and_check("EO_0 CTU(1,1) mem_nbr 6144", 1'b0, 6144);

            // Case 3: EO_1 Vertical at CTU (0,1) with mem_nbr (full 6,144/6,144)
            ctu_x = 0; ctu_y = 1;
            init_synthetic_mem(2);
            for (int c = 0; c < 3; c++) begin
                stype[c] = 2'd1; eocls[c] = 2'd1;
                eoff[c][0] = 5'sd7; eoff[c][1] = 5'sd3; eoff[c][2] = 5'sd0; eoff[c][3] = -5'sd1; eoff[c][4] = -5'sd6;
            end
            compute_golden_outputs();
            run_dut_and_check("EO_1 CTU(0,1) mem_nbr 6144", 1'b0, 6144);

            // Case 4: EO_2 135-deg at CTU (1,0) with left mem_nbr (full 6,144/6,144)
            ctu_x = 1; ctu_y = 0;
            init_synthetic_mem(3);
            for (int c = 0; c < 3; c++) begin
                stype[c] = 2'd1; eocls[c] = 2'd2;
                eoff[c][0] = 5'sd4; eoff[c][1] = 5'sd1; eoff[c][2] = 5'sd0; eoff[c][3] = -5'sd3; eoff[c][4] = -5'sd5;
            end
            compute_golden_outputs();
            run_dut_and_check("EO_2 CTU(1,0) mem_nbr 6144", 1'b0, 6144);

            // Case 5: EO_3 45-deg at CTU (0,1) — exercises right-border x=max_dim n0=(x+1,y-1)
            ctu_x = 0; ctu_y = 1;
            init_synthetic_mem(4);
            // Force distinct border contrast at x=63, 64 Y and x=31, 32 C
            for (int y = -1; y <= 64; y++) begin
                mem_y[y][63] = 10'd200;
                mem_y[y][64] = (y[0] ? 10'd900 : 10'd100);
            end
            for (int c = 0; c < 3; c++) begin
                stype[c] = 2'd1; eocls[c] = 2'd3;
                eoff[c][0] = 5'sd15; eoff[c][1] = 5'sd6; eoff[c][2] = 5'sd0; eoff[c][3] = -5'sd5; eoff[c][4] = -5'sd15;
            end
            compute_golden_outputs();
            run_dut_and_check("EO_3 (EO_45) right-border 6144", 1'b0, 6144);

            // Case 6: Cyclic BO (band_pos=30 -> bands 30,31,0,1) + Clip1 near 0 and 1023 + Active Cb/Cr
            ctu_x = 0; ctu_y = 0;
            init_synthetic_mem(5);
            // Inject extreme dark/bright bands 30, 31, 0, 1 to test Clip1
            mem_y[0][0] = 10'd3;    mem_y[0][1] = 10'd1020; mem_y[0][2] = 10'd965; mem_y[0][3] = 10'd35;
            mem_cb[0][0] = 10'd2;   mem_cr[0][0] = 10'd1021;
            stype[0] = 2'd2; stype[1] = 2'd2; stype[2] = 2'd2;
            bpos[0]  = 5'd30; bpos[1]  = 5'd30; bpos[2]  = 5'd31;
            boff[0][0] = 5'sd12; boff[0][1] = -5'sd8; boff[0][2] = -5'sd15; boff[0][3] = 5'sd6;
            boff[1][0] = 5'sd4;  boff[1][1] = 5'sd9;  boff[1][2] = -5'sd10; boff[1][3] = -5'sd2;
            boff[2][0] = 5'sd15; boff[2][1] = -5'sd7; boff[2][2] = 5'sd3;   boff[2][3] = -5'sd4;
            compute_golden_outputs();
            run_dut_and_check("BO cyclic + Clip1 + Cb/Cr 6144", 1'b0, 6144);

            // Case 7: Non-cyclic BO on Y, OFF on Cb/Cr + FULL OFF bypass
            ctu_x = 1; ctu_y = 1;
            init_synthetic_mem(6);
            stype[0] = 2'd2; stype[1] = 2'd0; stype[2] = 2'd0;
            bpos[0] = 5'd12;
            boff[0][0] = -5'sd5; boff[0][1] = 5'sd7; boff[0][2] = 5'sd0; boff[0][3] = -5'sd3;
            compute_golden_outputs();
            run_dut_and_check("Y=BO non-cyclic, Cb/Cr=OFF", 1'b0, 4096);

            init_synthetic_mem(7);
            stype[0] = 2'd0; stype[1] = 2'd0; stype[2] = 2'd0;
            compute_golden_outputs();
            run_dut_and_check("All OFF Bypass", 1'b0, 0);
        end

        if (m1_eo45_right_border_n0_reads == 0) begin
            $display("[FAIL] Mode 1 never issued EO_45 right-border n0_rd_x==64 reads!");
            total_errors++;
        end else begin
            $display("[PASS] Mode 1 issued %0d EO_45 right-border n0_rd_x==64 reads!", m1_eo45_right_border_n0_reads);
        end

        if (total_errors == 0)
            $display("[PASS] ALL tb_sao tests (Mode 0 & Mode 1) PASSED with 0 errors!");
        else
            $display("[FAIL] tb_sao completed with %0d total errors!", total_errors);

        $finish(total_errors != 0);
    end

endmodule
