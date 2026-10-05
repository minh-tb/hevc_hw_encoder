//=============================================================================
// tb_flaw_intra_rmd.sv
// Dual-State Verification Testbench for Flaw D-04:
// RMD SATD Unweighted SAD Substitution (HEVC Clause 8.4.3 / HM TComRdCost::calcHAD)
//
// Demonstrates that plain spatial SAD in intra_rmd selects suboptimal mode
// on textured/gradient blocks, whereas normative Hadamard SATD selects optimal mode.
//
// Dual-state compilation:
//   Buggy run:      vlog -sv ... tb_flaw_intra_rmd.sv
//                   -> Fails assertion and reports Flaw D-04 reproduction
//   Remediated run: vlog -sv +define+REMEDIATION_PATCH ... tb_flaw_intra_rmd.sv
//                   -> Passes assertion and reports ALL TESTS PASSED
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

    logic         ref_valid;
    logic [`PIXEL_WIDTH-1:0] ref_sample;
    logic [7:0]   ref_idx;
    logic         ref_last;

    wire          rmd_done;
    wire  [5:0]   best_mode;
    wire  [31:0]  best_cost;

    int total_errors = 0;

    // Clock generation (100 MHz)
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // 4x4 Original pixel buffer and coordinates
    logic [9:0] orig_block [0:3][0:3];
    logic [9:0] ref_top_in [0:3];
    logic [9:0] ref_left_in [0:3];
    logic [9:0] top_right_corner;
    logic [9:0] bot_left_corner;

    // Synchronous memory response for orig_rd_data (1 cycle latency)
    always @(posedge clk) begin
        if (rmd_active) begin
            orig_rd_data <= orig_block[orig_rd_addr[11:6] - pu_y][orig_rd_addr[5:0] - pu_x];
        end else begin
            orig_rd_data <= 10'd0;
        end
    end

`ifndef REMEDIATION_PATCH
    // Instantiate Unpatched (Buggy) DUT from rtl/intra/intra_rmd.v
    intra_rmd dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .start          (start),
        .pu_x           (pu_x),
        .pu_y           (pu_y),
        .pu_size_log2   (pu_size_log2),
        .orig_rd_addr   (orig_rd_addr),
        .rmd_active     (rmd_active),
        .orig_rd_data   (orig_rd_data),
        .ref_valid      (ref_valid),
        .ref_sample     (ref_sample),
        .ref_idx        (ref_idx),
        .ref_last       (ref_last),
        .rmd_done       (rmd_done),
        .best_mode      (best_mode),
        .best_cost      (best_cost)
    );
`else
    // Instantiate Remediated DUT with Hadamard SATD integration
    intra_rmd_remediated dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .start          (start),
        .pu_x           (pu_x),
        .pu_y           (pu_y),
        .pu_size_log2   (pu_size_log2),
        .orig_rd_addr   (orig_rd_addr),
        .rmd_active     (rmd_active),
        .orig_rd_data   (orig_rd_data),
        .ref_valid      (ref_valid),
        .ref_sample     (ref_sample),
        .ref_idx        (ref_idx),
        .ref_last       (ref_last),
        .rmd_done       (rmd_done),
        .best_mode      (best_mode),
        .best_cost      (best_cost)
    );
`endif

    // Reference Hadamard 1D and 2D model functions
    function automatic [47:0] hadamard_1d(input signed [11:0] a, b, c, d);
        reg signed [11:0] s0, d0, s1, d1;
        reg signed [11:0] y0, y1, y2, y3;
        begin
            s0 = a + d;
            d0 = a - d;
            s1 = b + c;
            d1 = b - c;
            y0 = s0 + s1;
            y1 = d0 + d1;
            y2 = d0 - d1;
            y3 = s0 - s1;
            hadamard_1d = {y3, y2, y1, y0};
        end
    endfunction

    function automatic [15:0] calc_satd_4x4(input signed [10:0] diff[0:3][0:3]);
        reg [47:0] r0, r1, r2, r3;
        reg signed [11:0] row_t[0:3][0:3];
        reg [47:0] c0, c1, c2, c3;
        reg signed [11:0] col_t[0:3][0:3];
        int sum_abs;
        begin
            r0 = hadamard_1d(diff[0][0], diff[0][1], diff[0][2], diff[0][3]);
            r1 = hadamard_1d(diff[1][0], diff[1][1], diff[1][2], diff[1][3]);
            r2 = hadamard_1d(diff[2][0], diff[2][1], diff[2][2], diff[2][3]);
            r3 = hadamard_1d(diff[3][0], diff[3][1], diff[3][2], diff[3][3]);

            row_t[0][0] = r0[11:0];  row_t[0][1] = r0[23:12]; row_t[0][2] = r0[35:24]; row_t[0][3] = r0[47:36];
            row_t[1][0] = r1[11:0];  row_t[1][1] = r1[23:12]; row_t[1][2] = r1[35:24]; row_t[1][3] = r1[47:36];
            row_t[2][0] = r2[11:0];  row_t[2][1] = r2[23:12]; row_t[2][2] = r2[35:24]; row_t[2][3] = r2[47:36];
            row_t[3][0] = r3[11:0];  row_t[3][1] = r3[23:12]; row_t[3][2] = r3[35:24]; row_t[3][3] = r3[47:36];

            c0 = hadamard_1d(row_t[0][0], row_t[1][0], row_t[2][0], row_t[3][0]);
            c1 = hadamard_1d(row_t[0][1], row_t[1][1], row_t[2][1], row_t[3][1]);
            c2 = hadamard_1d(row_t[0][2], row_t[1][2], row_t[2][2], row_t[3][2]);
            c3 = hadamard_1d(row_t[0][3], row_t[1][3], row_t[2][3], row_t[3][3]);

            col_t[0][0] = c0[11:0];  col_t[1][0] = c0[23:12]; col_t[2][0] = c0[35:24]; col_t[3][0] = c0[47:36];
            col_t[0][1] = c1[11:0];  col_t[1][1] = c1[23:12]; col_t[2][1] = c1[35:24]; col_t[3][1] = c1[47:36];
            col_t[0][2] = c2[11:0];  col_t[1][2] = c2[23:12]; col_t[2][2] = c2[35:24]; col_t[3][2] = c2[47:36];
            col_t[0][3] = c3[11:0];  col_t[1][3] = c3[23:12]; col_t[2][3] = c3[35:24]; col_t[3][3] = c3[47:36];

            sum_abs = 0;
            for (int y = 0; y < 4; y++) begin
                for (int x = 0; x < 4; x++) begin
                    sum_abs += (col_t[y][x] < 0) ? -col_t[y][x] : col_t[y][x];
                end
            end
            calc_satd_4x4 = (sum_abs + 1) >> 1;
        end
    endfunction

    // Task to run test
    task automatic run_rmd_test;
        int sad_planar, sad_dc, sad_hor, sad_ver;
        int satd_planar, satd_dc, satd_hor, satd_ver;
        logic signed [10:0] diff_planar[0:3][0:3];
        logic signed [10:0] diff_dc[0:3][0:3];
        logic signed [10:0] diff_hor[0:3][0:3];
        logic signed [10:0] diff_ver[0:3][0:3];
        int dc_val;
        int expected_sad_mode;
        int expected_satd_mode;

        // Initialize stimulus vectors
        ref_top_in[0] = 10'd483; ref_top_in[1] = 10'd483; ref_top_in[2] = 10'd517; ref_top_in[3] = 10'd510;
        ref_left_in[0] = 10'd512; ref_left_in[1] = 10'd513; ref_left_in[2] = 10'd490; ref_left_in[3] = 10'd483;
        top_right_corner = 10'd512;
        bot_left_corner  = 10'd485;

        orig_block[0][0] = 10'd483; orig_block[0][1] = 10'd468; orig_block[0][2] = 10'd536; orig_block[0][3] = 10'd468;
        orig_block[1][0] = 10'd490; orig_block[1][1] = 10'd511; orig_block[1][2] = 10'd475; orig_block[1][3] = 10'd532;
        orig_block[2][0] = 10'd491; orig_block[2][1] = 10'd534; orig_block[2][2] = 10'd536; orig_block[2][3] = 10'd465;
        orig_block[3][0] = 10'd539; orig_block[3][1] = 10'd470; orig_block[3][2] = 10'd513; orig_block[3][3] = 10'd534;

        // Compute Golden Reference Values
        dc_val = (483 + 483 + 517 + 510 + 512 + 513 + 490 + 483 + 4) >> 3;

        sad_planar = 0; sad_dc = 0; sad_hor = 0; sad_ver = 0;
        for (int y = 0; y < 4; y++) begin
            for (int x = 0; x < 4; x++) begin
                int pred_p = ((3 - x)*ref_left_in[y] + (x + 1)*top_right_corner +
                              (3 - y)*ref_top_in[x]  + (y + 1)*bot_left_corner + 4) >> 3;
                int pred_d = dc_val;
                int pred_h = ref_left_in[y];
                int pred_v = ref_top_in[x];

                diff_planar[y][x] = orig_block[y][x] - pred_p;
                diff_dc[y][x]     = orig_block[y][x] - pred_d;
                diff_hor[y][x]    = orig_block[y][x] - pred_h;
                diff_ver[y][x]    = orig_block[y][x] - pred_v;

                sad_planar += (diff_planar[y][x] < 0) ? -diff_planar[y][x] : diff_planar[y][x];
                sad_dc     += (diff_dc[y][x] < 0)     ? -diff_dc[y][x]     : diff_dc[y][x];
                sad_hor    += (diff_hor[y][x] < 0)    ? -diff_hor[y][x]    : diff_hor[y][x];
                sad_ver    += (diff_ver[y][x] < 0)    ? -diff_ver[y][x]    : diff_ver[y][x];
            end
        end

        satd_planar = calc_satd_4x4(diff_planar);
        satd_dc     = calc_satd_4x4(diff_dc);
        satd_hor    = calc_satd_4x4(diff_hor);
        satd_ver    = calc_satd_4x4(diff_ver);

        expected_sad_mode = 26; // Vertical mode has lowest SAD (395)
        expected_satd_mode = 1; // DC mode has lowest SATD (729)

        $display("--------------------------------------------------");
        $display(" [GOLDEN MODEL] Metric Comparison for Test Block:");
        $display("   Mode 0 (Planar):  SAD = %0d,  SATD = %0d", sad_planar, satd_planar);
        $display("   Mode 1 (DC):      SAD = %0d,  SATD = %0d  <-- [Normative SATD Winner]", sad_dc, satd_dc);
        $display("   Mode 10 (Hor):    SAD = %0d,  SATD = %0d", sad_hor, satd_hor);
        $display("   Mode 26 (Ver):    SAD = %0d,  SATD = %0d  <-- [Buggy SAD Winner]", sad_ver, satd_ver);
        $display("--------------------------------------------------");

        // Drive DUT
        pu_x = 6'd0;
        pu_y = 6'd0;
        pu_size_log2 = 3'd2; // 4x4 PU

        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        // Feed reference samples
        // ref[1..4]: top row
        for (int i = 1; i <= 4; i++) begin
            @(negedge clk);
            ref_valid  = 1'b1;
            ref_idx    = i;
            ref_sample = ref_top_in[i-1];
            ref_last   = 1'b0;
        end
        // ref[5]: top_right corner
        @(negedge clk);
        ref_valid  = 1'b1;
        ref_idx    = 8'd5;
        ref_sample = top_right_corner;
        ref_last   = 1'b0;

        // ref[9..12]: left col (2N+1 .. 3N = 9..12)
        for (int i = 9; i <= 12; i++) begin
            @(negedge clk);
            ref_valid  = 1'b1;
            ref_idx    = i;
            ref_sample = ref_left_in[i-9];
            ref_last   = 1'b0;
        end
        // ref[13]: bottom_left corner (2N+1+N = 13)
        @(negedge clk);
        ref_valid  = 1'b1;
        ref_idx    = 8'd13;
        ref_sample = bot_left_corner;
        ref_last   = 1'b1;

        @(negedge clk);
        ref_valid = 1'b0;
        ref_last  = 1'b0;

        // Wait for RMD completion
        while (!rmd_done) @(posedge clk);

        $display(" [DUT RESULT] rmd_done asserted at time %0t", $time);
        $display("   DUT Selected Mode: %0d", best_mode);
        $display("   DUT Output Cost:   %0d", best_cost);

        // Verification against Normative Standard
        if (best_mode != expected_satd_mode) begin
            $display("\n==================================================");
            $display(" [FAIL] FLAW D-04 CONFIRMED: Mode Decision Divergence!");
            $display("   DUT selected mode %0d (Plain SAD winner)", best_mode);
            $display("   Normative standard requires mode %0d (Hadamard SATD winner)", expected_satd_mode);
            $display("   RD Penalty: Selected Mode %0d SATD is %0d, optimal is %0d (Divergence = +%0d)", 
                     best_mode, (best_mode == 26 ? satd_ver : best_mode == 10 ? satd_hor : satd_planar), 
                     satd_dc, (best_mode == 26 ? (satd_ver - satd_dc) : 0));
            $display("   Standard Violation: ITU-T H.265 Clause 8.4.3 & HM TComRdCost::calcHAD");
            $display("==================================================\n");
            total_errors++;
        end else begin
            $display("\n==================================================");
            $display(" [PASS] Normative Conformance Verified!");
            $display("   DUT correctly selected mode %0d with Hadamard SATD.", best_mode);
            $display("==================================================\n");
        end
    endtask

    initial begin
        rst_n = 0;
        start = 0;
        ref_valid = 0;
        ref_sample = 0;
        ref_idx = 0;
        ref_last = 0;
        pu_x = 0;
        pu_y = 0;
        pu_size_log2 = 2;

        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        $display("==================================================");
        $display(" Starting tb_flaw_intra_rmd Simulation");
`ifdef REMEDIATION_PATCH
        $display(" Mode: REMEDIATED (Hadamard 4x4 SATD Enabled)");
`else
        $display(" Mode: UNPATCHED / BUGGY (Plain SAD Active)");
`endif
        $display("==================================================");

        run_rmd_test();

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

`ifdef REMEDIATION_PATCH
//=============================================================================
// Remediated intra_rmd module with 4x4 Hadamard SATD and 18-bit accumulator
// Integrated directly for standalone dual-state execution
//=============================================================================
module intra_rmd_remediated (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         start,
    input  wire [5:0]   pu_x,
    input  wire [5:0]   pu_y,
    input  wire [2:0]   pu_size_log2,

    output reg  [11:0]  orig_rd_addr,
    output wire         rmd_active,

    input  wire [`PIXEL_WIDTH-1:0] orig_rd_data,

    input  wire         ref_valid,
    input  wire [`PIXEL_WIDTH-1:0] ref_sample,
    input  wire [7:0]   ref_idx,
    input  wire         ref_last,

    output reg          rmd_done,
    output reg  [5:0]   best_mode,
    output reg  [31:0]  best_cost
);

    localparam S_IDLE       = 3'd0;
    localparam S_LOAD_REF   = 3'd1;
    localparam S_EVAL       = 3'd2;
    localparam S_HADAMARD   = 3'd3;
    localparam S_DONE       = 3'd4;

    reg [2:0] state, next_state;

    reg [`PIXEL_WIDTH-1:0] ref_buf [0:128];

    reg [5:0] cx, cy;
    wire [7:0] N = 8'd1 << pu_size_log2;

    reg [5:0] lat_pu_x, lat_pu_y;
    reg [5:0] cx_q, cy_q;
    reg       eval_q;

    // Buffer 4x4 differences for Hadamard transform
    reg signed [10:0] diff_planar_buf [0:15];
    reg signed [10:0] diff_dc_buf     [0:15];
    reg signed [10:0] diff_hor_buf    [0:15];
    reg signed [10:0] diff_ver_buf    [0:15];

    // DC Prediction
    reg [15:0] dc_sum;
    always @(posedge clk) begin
        if (state == S_LOAD_REF && ref_valid) begin
            if (ref_idx >= 8'd1 && ref_idx <= N[7:0]) begin
                dc_sum <= dc_sum + ref_sample;
            end
            if (ref_idx >= (N<<1) + 8'd1 && ref_idx <= (N<<1) + N[7:0]) begin
                dc_sum <= dc_sum + ref_sample;
            end
        end else if (state == S_IDLE) begin
            dc_sum <= 0;
        end
    end
    
    wire [15:0] dc_val = (dc_sum + {8'd0, N}) >> (pu_size_log2 + 1);
    wire [`PIXEL_WIDTH-1:0] pred_dc = dc_val[`PIXEL_WIDTH-1:0];

    wire [7:0] idx_left = (N << 1) + 8'd1 + {2'd0, cy_q};
    wire [`PIXEL_WIDTH-1:0] pred_hor = ref_buf[idx_left];

    wire [7:0] idx_top = 8'd1 + {2'd0, cx_q};
    wire [`PIXEL_WIDTH-1:0] pred_ver = ref_buf[idx_top];

    wire [`PIXEL_WIDTH-1:0] refL_y = ref_buf[idx_left];
    wire [`PIXEL_WIDTH-1:0] refT_x = ref_buf[idx_top];
    wire [7:0] idx_refT_N = 8'd1 + N[7:0];
    wire [7:0] idx_refL_N = (N << 1) + 8'd1 + N[7:0];
    wire [`PIXEL_WIDTH-1:0] refT_N = ref_buf[idx_refT_N];
    wire [`PIXEL_WIDTH-1:0] refL_N = ref_buf[idx_refL_N];
    
    wire [17:0] wL = (N[7:0] - 8'd1 - {2'd0, cx_q}) * refL_y;
    wire [17:0] wR = ({2'd0, cx_q} + 8'd1) * refT_N;
    wire [17:0] wT = (N[7:0] - 8'd1 - {2'd0, cy_q}) * refT_x;
    wire [17:0] wB = ({2'd0, cy_q} + 8'd1) * refL_N;
    
    // Remediation: 18-bit planar accumulator
    wire [17:0] planar_sum = wL + wR + wT + wB + {10'd0, N};
    wire [`PIXEL_WIDTH-1:0] pred_planar = planar_sum >> (pu_size_log2 + 1);

    // Differences
    wire signed [10:0] diff_p = $signed({1'b0, orig_rd_data}) - $signed({1'b0, pred_planar});
    wire signed [10:0] diff_d = $signed({1'b0, orig_rd_data}) - $signed({1'b0, pred_dc});
    wire signed [10:0] diff_h = $signed({1'b0, orig_rd_data}) - $signed({1'b0, pred_hor});
    wire signed [10:0] diff_v = $signed({1'b0, orig_rd_data}) - $signed({1'b0, pred_ver});

    assign rmd_active = (state == S_EVAL);

    // Hadamard cores
    reg had_start;
    wire had_done_p, had_done_d, had_done_h, had_done_v;
    wire [15:0] satd_p, satd_d, satd_h, satd_v;

    hadamard_satd_4x4 u_had_p (
        .clk(clk), .rst_n(rst_n), .start(had_start),
        .diff_0(diff_planar_buf[0]), .diff_1(diff_planar_buf[1]), .diff_2(diff_planar_buf[2]), .diff_3(diff_planar_buf[3]),
        .diff_4(diff_planar_buf[4]), .diff_5(diff_planar_buf[5]), .diff_6(diff_planar_buf[6]), .diff_7(diff_planar_buf[7]),
        .diff_8(diff_planar_buf[8]), .diff_9(diff_planar_buf[9]), .diff_10(diff_planar_buf[10]), .diff_11(diff_planar_buf[11]),
        .diff_12(diff_planar_buf[12]), .diff_13(diff_planar_buf[13]), .diff_14(diff_planar_buf[14]), .diff_15(diff_planar_buf[15]),
        .done(had_done_p), .satd_out(satd_p)
    );

    hadamard_satd_4x4 u_had_d (
        .clk(clk), .rst_n(rst_n), .start(had_start),
        .diff_0(diff_dc_buf[0]), .diff_1(diff_dc_buf[1]), .diff_2(diff_dc_buf[2]), .diff_3(diff_dc_buf[3]),
        .diff_4(diff_dc_buf[4]), .diff_5(diff_dc_buf[5]), .diff_6(diff_dc_buf[6]), .diff_7(diff_dc_buf[7]),
        .diff_8(diff_dc_buf[8]), .diff_9(diff_dc_buf[9]), .diff_10(diff_dc_buf[10]), .diff_11(diff_dc_buf[11]),
        .diff_12(diff_dc_buf[12]), .diff_13(diff_dc_buf[13]), .diff_14(diff_dc_buf[14]), .diff_15(diff_dc_buf[15]),
        .done(had_done_d), .satd_out(satd_d)
    );

    hadamard_satd_4x4 u_had_h (
        .clk(clk), .rst_n(rst_n), .start(had_start),
        .diff_0(diff_hor_buf[0]), .diff_1(diff_hor_buf[1]), .diff_2(diff_hor_buf[2]), .diff_3(diff_hor_buf[3]),
        .diff_4(diff_hor_buf[4]), .diff_5(diff_hor_buf[5]), .diff_6(diff_hor_buf[6]), .diff_7(diff_hor_buf[7]),
        .diff_8(diff_hor_buf[8]), .diff_9(diff_hor_buf[9]), .diff_10(diff_hor_buf[10]), .diff_11(diff_hor_buf[11]),
        .diff_12(diff_hor_buf[12]), .diff_13(diff_hor_buf[13]), .diff_14(diff_hor_buf[14]), .diff_15(diff_hor_buf[15]),
        .done(had_done_h), .satd_out(satd_h)
    );

    hadamard_satd_4x4 u_had_v (
        .clk(clk), .rst_n(rst_n), .start(had_start),
        .diff_0(diff_ver_buf[0]), .diff_1(diff_ver_buf[1]), .diff_2(diff_ver_buf[2]), .diff_3(diff_ver_buf[3]),
        .diff_4(diff_ver_buf[4]), .diff_5(diff_ver_buf[5]), .diff_6(diff_ver_buf[6]), .diff_7(diff_ver_buf[7]),
        .diff_8(diff_ver_buf[8]), .diff_9(diff_ver_buf[9]), .diff_10(diff_ver_buf[10]), .diff_11(diff_ver_buf[11]),
        .diff_12(diff_ver_buf[12]), .diff_13(diff_ver_buf[13]), .diff_14(diff_ver_buf[14]), .diff_15(diff_ver_buf[15]),
        .done(had_done_v), .satd_out(satd_v)
    );

    // FSM
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            rmd_done <= 0;
            cx <= 0; cy <= 0;
            cx_q <= 0; cy_q <= 0;
            eval_q <= 0;
            lat_pu_x <= 0; lat_pu_y <= 0;
            orig_rd_addr <= 0;
            had_start <= 0;
            best_mode <= 0;
            best_cost <= 0;
        end else begin
            state <= next_state;
            
            case (state)
                S_IDLE: begin
                    rmd_done <= 0;
                    had_start <= 0;
                    if (start) begin
                        if (pu_size_log2 > 3'd5) begin
                            rmd_done <= 1;
                            best_cost <= 32'h00FFFFFF;
                            best_mode <= 6'd0;
                        end else begin
                            cx <= 0; cy <= 0;
                            eval_q <= 0;
                            lat_pu_x <= pu_x;
                            lat_pu_y <= pu_y;
                        end
                    end
                end
                
                S_LOAD_REF: begin
                    if (ref_valid) ref_buf[ref_idx] <= ref_sample;
                end
                
                S_EVAL: begin
                    if (cy < N[5:0]) begin
                        orig_rd_addr <= { (lat_pu_y + cy[5:0]), (lat_pu_x + cx[5:0]) };
                        if (cx == N[5:0] - 6'd1) begin
                            cx <= 0;
                            cy <= cy + 1;
                        end else begin
                            cx <= cx + 1;
                        end
                    end
                    
                    cx_q <= cx;
                    cy_q <= cy;
                    eval_q <= (cy < N[5:0]);
                    
                    if (eval_q) begin
                        diff_planar_buf[{cy_q[1:0], cx_q[1:0]}] <= diff_p;
                        diff_dc_buf    [{cy_q[1:0], cx_q[1:0]}] <= diff_d;
                        diff_hor_buf   [{cy_q[1:0], cx_q[1:0]}] <= diff_h;
                        diff_ver_buf   [{cy_q[1:0], cx_q[1:0]}] <= diff_v;
                    end

                    if (!eval_q && cy == N) begin
                        had_start <= 1'b1;
                    end
                end

                S_HADAMARD: begin
                    had_start <= 1'b0;
                    if (had_done_p) begin
                        // Select mode with lowest Hadamard SATD
                        if (satd_p <= satd_d && satd_p <= satd_h && satd_p <= satd_v) begin
                            best_mode <= `INTRA_PLANAR;
                            best_cost <= {16'd0, satd_p};
                        end else if (satd_d <= satd_h && satd_d <= satd_v) begin
                            best_mode <= `INTRA_DC;
                            best_cost <= {16'd0, satd_d};
                        end else if (satd_h <= satd_v) begin
                            best_mode <= 6'd10;
                            best_cost <= {16'd0, satd_h};
                        end else begin
                            best_mode <= 6'd26;
                            best_cost <= {16'd0, satd_v};
                        end
                    end
                end
                
                S_DONE: begin
                    rmd_done <= 1;
                end
            endcase
        end
    end

    always @(*) begin
        next_state = state;
        case (state)
            S_IDLE:     if (start && pu_size_log2 <= 3'd5) next_state = S_LOAD_REF;
            S_LOAD_REF: if (ref_valid && ref_last) next_state = S_EVAL;
            S_EVAL:     if (!eval_q && cy == N) next_state = S_HADAMARD;
            S_HADAMARD: if (had_done_p) next_state = S_DONE;
            S_DONE:     next_state = S_IDLE;
        endcase
    end

endmodule
`endif
