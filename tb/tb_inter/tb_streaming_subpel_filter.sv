//=============================================================================
// tb_streaming_subpel_filter.sv
// Synthesizable Streaming Sub-Pel Interpolation Filter Unit Testbench
//
// Tests bit-exact conformance between:
//   - Synthesizable pipelined streaming_subpel_filter.v
//   - ITU-T H.265 Clause 8.5.3.3.3 reference subpel_interpolation_core.v
// Across all 16 Luma fractional phases, all 64 Chroma fractional phases,
// uni-prediction, bi-prediction, and multiple boundary/stress stimulus patterns.
//=============================================================================

`timescale 1ns/1ps
`include "parameter_pkg.vh"

module tb_streaming_subpel_filter;

    localparam PIXEL_WIDTH  = `PIXEL_WIDTH; // 10
    localparam INTERM_WIDTH = 16;

    logic clk;
    logic rst_n;
    logic valid_in;
    logic [1:0] comp;
    logic is_bi_pred;
    logic [2:0] frac_x;
    logic [2:0] frac_y;

    logic [PIXEL_WIDTH*64-1:0] win_l0_flat;
    logic [PIXEL_WIDTH*64-1:0] win_l1_flat;

    wire valid_out;
    wire [PIXEL_WIDTH-1:0] pred_pixel;

    // DUT
    streaming_subpel_filter #(
        .PIXEL_WIDTH (PIXEL_WIDTH),
        .INTERM_WIDTH(INTERM_WIDTH)
    ) u_dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .valid_in   (valid_in),
        .comp       (comp),
        .is_bi_pred (is_bi_pred),
        .frac_x     (frac_x),
        .frac_y     (frac_y),
        .win_l0_flat(win_l0_flat),
        .win_l1_flat(win_l1_flat),
        .valid_out  (valid_out),
        .pred_pixel (pred_pixel)
    );

    // Golden Reference Model using subpel_interpolation_core
    wire signed [15:0] ref_interm_l0;
    wire signed [15:0] ref_interm_l1;

    subpel_interpolation_core #(
        .PIXEL_WIDTH (PIXEL_WIDTH),
        .INTERM_WIDTH(INTERM_WIDTH)
    ) u_ref_l0 (
        .is_chroma      (comp != 2'd0),
        .frac_x         (frac_x),
        .frac_y         (frac_y),
        .win_luma_flat  (win_l0_flat),
        .win_chroma_flat(win_l0_flat[PIXEL_WIDTH*16-1:0]),
        .interm_val     (ref_interm_l0)
    );

    subpel_interpolation_core #(
        .PIXEL_WIDTH (PIXEL_WIDTH),
        .INTERM_WIDTH(INTERM_WIDTH)
    ) u_ref_l1 (
        .is_chroma      (comp != 2'd0),
        .frac_x         (frac_x),
        .frac_y         (frac_y),
        .win_luma_flat  (win_l1_flat),
        .win_chroma_flat(win_l1_flat[PIXEL_WIDTH*16-1:0]),
        .interm_val     (ref_interm_l1)
    );

    function automatic [9:0] clip_bd10;
        input signed [24:0] v;
        begin
            if (v < 25'sd0) clip_bd10 = 10'd0;
            else if (v > 25'sd1023) clip_bd10 = 10'd1023;
            else clip_bd10 = v[9:0];
        end
    endfunction

    wire [9:0] ref_pred = is_bi_pred ? clip_bd10((ref_interm_l0 + ref_interm_l1 + 32'sd16) >>> 5)
                                     : clip_bd10((ref_interm_l0 + 32'sd8) >>> 4);

    // 3-cycle pipeline delay queue for reference checking
    reg [9:0] ref_queue [0:2];
    reg       val_queue [0:2];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ref_queue[0] <= 10'd0; ref_queue[1] <= 10'd0; ref_queue[2] <= 10'd0;
            val_queue[0] <= 1'b0;  val_queue[1] <= 1'b0;  val_queue[2] <= 1'b0;
        end else begin
            ref_queue[0] <= ref_pred;
            ref_queue[1] <= ref_queue[0];
            ref_queue[2] <= ref_queue[1];

            val_queue[0] <= valid_in;
            val_queue[1] <= val_queue[0];
            val_queue[2] <= val_queue[1];
        end
    end

    // Clock generator
    always #5 clk = ~clk;

    integer total_tests = 0;
    integer total_errors = 0;

    // Self-checking monitor
    always @(posedge clk) begin
        if (rst_n && val_queue[2]) begin
            total_tests = total_tests + 1;
            if (valid_out !== 1'b1) begin
                $display("[ERROR] Cycle %0t: valid_out not asserted when expected!", $time);
                total_errors = total_errors + 1;
            end else if (pred_pixel !== ref_queue[2]) begin
                $display("[MISMATCH] Cycle %0t: DUT = %0d, Golden Ref = %0d (Diff = %0d)",
                         $time, pred_pixel, ref_queue[2], $signed({1'b0, pred_pixel}) - $signed({1'b0, ref_queue[2]}));
                total_errors = total_errors + 1;
            end
        end
    end

    // Helper tasks to populate windows
    task automatic fill_uniform(input [9:0] val_l0, input [9:0] val_l1);
        integer i;
        begin
            for (i = 0; i < 64; i = i + 1) begin
                win_l0_flat[i*PIXEL_WIDTH +: PIXEL_WIDTH] = val_l0;
                win_l1_flat[i*PIXEL_WIDTH +: PIXEL_WIDTH] = val_l1;
            end
        end
    endtask

    task automatic fill_ramp();
        integer r, c;
        begin
            for (r = 0; r < 8; r = r + 1) begin
                for (c = 0; c < 8; c = c + 1) begin
                    win_l0_flat[(r*8+c)*PIXEL_WIDTH +: PIXEL_WIDTH] = (r * 32 + c * 16 + 100) % 1024;
                    win_l1_flat[(r*8+c)*PIXEL_WIDTH +: PIXEL_WIDTH] = (r * 24 + c * 48 + 200) % 1024;
                end
            end
        end
    endtask

    task automatic fill_random(input integer seed);
        integer i;
        reg [31:0] rnd_state;
        begin
            rnd_state = seed;
            for (i = 0; i < 64; i = i + 1) begin
                rnd_state = rnd_state * 1103515245 + 12345;
                win_l0_flat[i*PIXEL_WIDTH +: PIXEL_WIDTH] = rnd_state[9:0];
                rnd_state = rnd_state * 1103515245 + 12345;
                win_l1_flat[i*PIXEL_WIDTH +: PIXEL_WIDTH] = rnd_state[9:0];
            end
        end
    endtask

    integer fx_idx, fy_idx, pattern_idx, bi_idx;

    initial begin
        clk = 0;
        rst_n = 0;
        valid_in = 0;
        comp = 0;
        is_bi_pred = 0;
        frac_x = 0;
        frac_y = 0;
        win_l0_flat = 0;
        win_l1_flat = 0;

        #30;
        rst_n = 1;
        #20;

        $display("=========================================================================");
        $display("   TESTBENCH: Synthesizable Streaming Sub-Pel Interpolation Filter       ");
        $display("=========================================================================");

        // ---------------------------------------------------------------------
        // Phase 1: Luma Tests (comp == 0) across all 16 phases x patterns
        // ---------------------------------------------------------------------
        $display("[TEST] Starting Luma sub-pel sweep (16 phases, Uni and Bi-pred)...");
        comp = 2'd0;
        for (bi_idx = 0; bi_idx < 2; bi_idx = bi_idx + 1) begin
            is_bi_pred = bi_idx[0];
            for (pattern_idx = 0; pattern_idx < 5; pattern_idx = pattern_idx + 1) begin
                case (pattern_idx)
                    0: fill_uniform(10'd512, 10'd512);
                    1: fill_uniform(10'd0, 10'd1023);
                    2: fill_ramp();
                    3: fill_random(32'h12345678 + pattern_idx);
                    4: fill_random(32'hDEADBEEF + pattern_idx);
                endcase

                for (fy_idx = 0; fy_idx < 4; fy_idx = fy_idx + 1) begin
                    for (fx_idx = 0; fx_idx < 4; fx_idx = fx_idx + 1) begin
                        @(posedge clk);
                        valid_in <= 1'b1;
                        frac_x   <= fx_idx[2:0];
                        frac_y   <= fy_idx[2:0];
                    end
                end
            end
        end

        // ---------------------------------------------------------------------
        // Phase 2: Chroma Tests (comp == 1, 2) across all 64 phases x patterns
        // ---------------------------------------------------------------------
        $display("[TEST] Starting Chroma sub-pel sweep (64 phases, Uni and Bi-pred)...");
        for (comp = 2'd1; comp <= 2'd2; comp = comp + 1) begin
            for (bi_idx = 0; bi_idx < 2; bi_idx = bi_idx + 1) begin
                is_bi_pred = bi_idx[0];
                for (pattern_idx = 0; pattern_idx < 4; pattern_idx = pattern_idx + 1) begin
                    case (pattern_idx)
                        0: fill_uniform(10'd512, 10'd512);
                        1: fill_ramp();
                        2: fill_random(32'h87654321 + pattern_idx);
                        3: fill_random(32'hCAFE1234 + pattern_idx);
                    endcase

                    for (fy_idx = 0; fy_idx < 8; fy_idx = fy_idx + 1) begin
                        for (fx_idx = 0; fx_idx < 8; fx_idx = fx_idx + 1) begin
                            @(posedge clk);
                            valid_in <= 1'b1;
                            frac_x   <= fx_idx[2:0];
                            frac_y   <= fy_idx[2:0];
                        end
                    end
                end
            end
        end

        // Drain pipeline
        @(posedge clk);
        valid_in <= 1'b0;
        repeat (10) @(posedge clk);

        $display("=========================================================================");
        $display("   RESULTS: Total Samples Tested = %0d, Total Mismatches = %0d", total_tests, total_errors);
        if (total_errors == 0 && total_tests > 0) begin
            $display("   >>> ALL TESTS PASSED: 100%% BIT-EXACT CONFORMANCE VERIFIED! <<<");
        end else begin
            $display("   >>> TEST FAILED with %0d errors! <<<", total_errors);
        end
        $display("=========================================================================");

        #20;
        $finish;
    end

endmodule
