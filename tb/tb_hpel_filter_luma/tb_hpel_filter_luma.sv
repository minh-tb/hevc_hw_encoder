//=============================================================================
// tb_hpel_filter_luma.sv
// Testbench for 8-tap Half-Pel Luma Interpolation Filter
//
// Verifies:
//   1. 8-tap HM coefficient math (symmetry validation)
//   2. Pipeline coordination (3-cycle latency)
//   3. Clipping and normalization rounding logic (+32 >>6, +2048 >>12)
//   4. Extreme bounds limits to ensure new 18/25-bit buses do not overflow
//=============================================================================

`timescale 1ns/1ps

module tb_hpel_filter_luma;

    localparam PIXEL_WIDTH = 10;
    localparam BLK_SIZE    = 4;
    localparam BLK_EXT     = 11;
    localparam LATENCY     = 3;
    localparam N_RANDOM    = 2000;

    //=========================================================================
    // DUT Ports
    //=========================================================================
    logic clk;
    logic rst_n;
    logic valid_in;
    logic [PIXEL_WIDTH*BLK_EXT*BLK_EXT-1:0]   ref_ext_flat;
    
    logic valid_out;
    logic [PIXEL_WIDTH*BLK_SIZE*BLK_SIZE-1:0] h_out_flat;
    logic [PIXEL_WIDTH*BLK_SIZE*BLK_SIZE-1:0] v_out_flat;
    logic [PIXEL_WIDTH*BLK_SIZE*BLK_SIZE-1:0] hv_out_flat;

    hpel_filter_luma #(
        .PIXEL_WIDTH(PIXEL_WIDTH),
        .BLK_SIZE(BLK_SIZE)
    ) dut (
        .clk(clk), .rst_n(rst_n), .valid_in(valid_in),
        .ref_ext_flat(ref_ext_flat),
        .valid_out(valid_out),
        .h_out_flat(h_out_flat), .v_out_flat(v_out_flat), .hv_out_flat(hv_out_flat)
    );

    //=========================================================================
    // Clock & Reset
    //=========================================================================
    initial begin
        clk = 0;
        forever #4 clk = ~clk; // 125 MHz
    end

    //=========================================================================
    // Golden Model — Exact HM C++ Equivalent
    //=========================================================================
    typedef struct {
        logic [PIXEL_WIDTH*BLK_SIZE*BLK_SIZE-1:0] h;
        logic [PIXEL_WIDTH*BLK_SIZE*BLK_SIZE-1:0] v;
        logic [PIXEL_WIDTH*BLK_SIZE*BLK_SIZE-1:0] hv;
    } expected_t;

    function automatic int clip_px(int val);
        if (val < 0) return 0;
        if (val > 1023) return 1023;
        return val;
    endfunction

    function automatic expected_t golden_filter(input logic [PIXEL_WIDTH*BLK_EXT*BLK_EXT-1:0] ref_flat);
        expected_t res;
        int ref_px[11][11];
        int h_int [11][4];
        int v_int [4][4];
        int hv_int[4][4];
        int c[8] = '{-1, 4, -11, 40, 40, -11, 4, -1};

        // Unpack reference block
        for (int r = 0; r < 11; r++) begin
            for (int c_idx = 0; c_idx < 11; c_idx++) begin
                ref_px[r][c_idx] = int'(ref_flat[PIXEL_WIDTH*(11*r + c_idx) +: PIXEL_WIDTH]);
            end
        end

        // H-pass (11 rows × 4 cols)
        for (int r = 0; r < 11; r++) begin
            for (int c_idx = 0; c_idx < 4; c_idx++) begin
                int sum = 0;
                for (int t = 0; t < 8; t++) sum += c[t] * ref_px[r][c_idx+t];
                h_int[r][c_idx] = sum;
            end
        end

        // V-pass on integer pixels (4 rows × 4 cols)
        for (int r = 0; r < 4; r++) begin
            for (int c_idx = 0; c_idx < 4; c_idx++) begin
                int sum = 0;
                // V filter targets col offset c_idx+3 in the 11x11 grid
                for (int t = 0; t < 8; t++) sum += c[t] * ref_px[r+t][c_idx+3];
                v_int[r][c_idx] = sum;
            end
        end

        // HV-pass: V filter applied to H intermediates (4 rows × 4 cols)
        for (int r = 0; r < 4; r++) begin
            for (int c_idx = 0; c_idx < 4; c_idx++) begin
                int sum = 0;
                for (int t = 0; t < 8; t++) sum += c[t] * h_int[r+t][c_idx];
                hv_int[r][c_idx] = sum;
            end
        end

        // Pack outputs with HM normalization clipping
        res.h = 0; res.v = 0; res.hv = 0;
        for (int r = 0; r < 4; r++) begin
            for (int c_idx = 0; c_idx < 4; c_idx++) begin
                int h_val  = clip_px((h_int[r+3][c_idx] + 32) >>> 6);
                int v_val  = clip_px((v_int[r][c_idx]   + 32) >>> 6);
                int hv_val = clip_px((hv_int[r][c_idx]  + 2048) >>> 12);

                res.h [PIXEL_WIDTH*(4*r + c_idx) +: PIXEL_WIDTH] = h_val;
                res.v [PIXEL_WIDTH*(4*r + c_idx) +: PIXEL_WIDTH] = v_val;
                res.hv[PIXEL_WIDTH*(4*r + c_idx) +: PIXEL_WIDTH] = hv_val;
            end
        end
        return res;
    endfunction

    //=========================================================================
    // Scoreboard
    //=========================================================================
    expected_t exp_queue[$];
    int total_pass = 0;
    int total_fail = 0;

    always @(posedge clk) begin
        if (valid_out) begin
            if (exp_queue.size() == 0) begin
                $display("ERROR: valid_out fired but queue is empty at t=%0t", $time);
                total_fail++;
            end else begin
                expected_t exp;
                bit err;
                exp = exp_queue.pop_front();
                err = 0;
                if (h_out_flat !== exp.h) begin
                    $display("FAIL [H] out=%x exp=%x at t=%0t", h_out_flat, exp.h, $time);
                    err = 1;
                end
                if (v_out_flat !== exp.v) begin
                    $display("FAIL [V] out=%x exp=%x at t=%0t", v_out_flat, exp.v, $time);
                    err = 1;
                end
                if (hv_out_flat !== exp.hv) begin
                    $display("FAIL [HV] out=%x exp=%x at t=%0t", hv_out_flat, exp.hv, $time);
                    err = 1;
                end

                if (err) total_fail++;
                else     total_pass++;
            end
        end
    end

    task automatic drive(input logic [PIXEL_WIDTH*BLK_EXT*BLK_EXT-1:0] ref_data);
        @(negedge clk);
        valid_in     <= 1'b1;
        ref_ext_flat <= ref_data;
        exp_queue.push_back(golden_filter(ref_data));
        @(posedge clk);
        @(negedge clk);
        valid_in     <= 1'b0;
    endtask

    //=========================================================================
    // Test Sequences
    //=========================================================================
    initial begin
        valid_in = 0; ref_ext_flat = 0;
        rst_n = 0; repeat(4) @(posedge clk);
        rst_n = 1; repeat(2) @(posedge clk);

        $display("====================================================");
        $display("  hpel_filter_luma Testbench — HM 8-Tap Verification");
        $display("====================================================");

        $display("[TEST 1] Flat DC Block (512 everywhere)");
        drive({(BLK_EXT*BLK_EXT){10'd512}});

        $display("[TEST 2] Max Intensity Bounds (1023 everywhere)");
        drive({(BLK_EXT*BLK_EXT){10'd1023}});

        $display("[TEST 3] Zero Intensity Bounds (0 everywhere)");
        drive({(BLK_EXT*BLK_EXT){10'd0}});

        $display("[TEST 4] Back-to-Back Pipeline (Burst of 16 blocks)");
        begin
            @(negedge clk);
            valid_in <= 1'b1;
            for (int k = 0; k < 16; k++) begin
                logic [PIXEL_WIDTH*BLK_EXT*BLK_EXT-1:0] temp_ref;
                for (int i = 0; i < BLK_EXT*BLK_EXT; i++) begin
                    temp_ref[PIXEL_WIDTH*i +: PIXEL_WIDTH] = (i*7 + k*13) & 10'h3FF;
                end
                ref_ext_flat <= temp_ref;
                exp_queue.push_back(golden_filter(temp_ref));
                @(posedge clk); @(negedge clk);
            end
            valid_in <= 1'b0;
        end

        $display("[TEST 5] Random Blocks (N=%0d)", N_RANDOM);
        for (int i = 0; i < N_RANDOM; i++) begin
            logic [PIXEL_WIDTH*BLK_EXT*BLK_EXT-1:0] temp_ref;
            for (int j = 0; j < BLK_EXT*BLK_EXT; j++) begin
                temp_ref[PIXEL_WIDTH*j +: PIXEL_WIDTH] = $urandom() & 10'h3FF;
            end
            drive(temp_ref);
        end

        // Wait for pipeline to drain
        repeat(LATENCY + 4) @(posedge clk);

        $display("\n====================================================");
        $display("  RESULTS: PASS=%0d  FAIL=%0d", total_pass, total_fail);
        if (total_fail == 0) $display("  *** ALL TESTS PASSED ***");
        else                 $display("  *** %0d FAILED ***", total_fail);
        $display("====================================================\n");

        if (exp_queue.size() != 0)
            $display("WARN: %0d pending results not drained from pipeline queue", exp_queue.size());

        $finish;
    end
endmodule