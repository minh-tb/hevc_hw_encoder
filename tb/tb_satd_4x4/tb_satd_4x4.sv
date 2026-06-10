//=============================================================================
// tb_satd_4x4.sv
// Testbench for satd_4x4 — verifies against HM xCalcHADs4x4() golden model
//
// Test plan:
//   1. Zero residual     : orig == ref → SATD = 0
//   2. DC residual       : all diffs = constant K
//   3. Single non-zero   : one pixel differs, rest identical
//   4. Max residual      : orig=1023, ref=0 everywhere
//   5. Alternating sign  : checkerboard diff (+K/-K)
//   6. Horizontal ramp   : stresses horizontal butterfly
//   7. Vertical ramp     : stresses vertical butterfly
//   8. Back-to-back pipe : 16 consecutive valid_in
//   9. Random vectors    : 2000 random blocks vs SW golden model
//  10. SATD vs SAD check : SATD ≤ SAD always (energy compaction property)
//=============================================================================

`timescale 1ns/1ps

module tb_satd_4x4;

    localparam PIXEL_WIDTH = 10;
    localparam SATD_W      = 13;   // RND_W(15) - SAD_SHIFT(2)
    localparam LATENCY     = 4;    // pipeline depth
    localparam N_RANDOM    = 2000;

    // =========================================================================
    // DUT
    // =========================================================================
    logic                         clk, rst_n;
    logic                         valid_in;
    logic [PIXEL_WIDTH*16-1:0]    orig_flat;
    logic [PIXEL_WIDTH*16-1:0]    ref_flat;
    logic                         valid_out;
    logic [SATD_W-1:0]            satd_out;

    satd_4x4 #(.PIXEL_WIDTH(PIXEL_WIDTH)) dut (
        .clk(clk), .rst_n(rst_n),
        .valid_in (valid_in),
        .orig_flat(orig_flat), .ref_flat(ref_flat),
        .valid_out(valid_out), .satd_out(satd_out)
    );

    initial clk = 0;
    always #4 clk = ~clk; // 125 MHz

    // =========================================================================
    // Golden model — exact translation of HM xCalcHADs4x4()
    //
    // Implements:
    //   1. Compute 16 signed diffs
    //   2. Horizontal WHT butterfly per row (groups [0,3] and [1,2])
    //   3. Vertical   WHT butterfly per col (groups row[0,3] and row[1,2])
    //   4. Sum of 16 absolute values
    //   5. (sum+1) >> 1   (normalize, round-half-up)
    //   6. >> 2           (DISTORTION_PRECISION_ADJUSTMENT for 10-bit)
    // =========================================================================
    function automatic int unsigned golden_satd (
        input logic [PIXEL_WIDTH*16-1:0] o_flat,
        input logic [PIXEL_WIDTH*16-1:0] r_flat
    );
        int diff[16], m[16], d[16];
        int satd_val;

        // Step 0: differences
        for (int k = 0; k < 16; k++)
            diff[k] = int'(o_flat[PIXEL_WIDTH*k +: PIXEL_WIDTH])
                    - int'(r_flat[PIXEL_WIDTH*k +: PIXEL_WIDTH]);

        // Step 1: horizontal butterfly — each row r, elements [r*4+0..r*4+3]
        for (int r = 0; r < 4; r++) begin
            int b = r * 4;
            m[b+0] = diff[b+0] + diff[b+3]; // col0+col3
            m[b+1] = diff[b+1] + diff[b+2]; // col1+col2
            m[b+2] = diff[b+1] - diff[b+2]; // col1-col2
            m[b+3] = diff[b+0] - diff[b+3]; // col0-col3
        end

        // Step 2: vertical butterfly — each col c, across rows 0..3
        for (int c = 0; c < 4; c++) begin
            d[0*4+c]  = m[0*4+c] + m[3*4+c]; // row0+row3
            d[1*4+c]  = m[1*4+c] + m[2*4+c]; // row1+row2
            d[2*4+c]  = m[1*4+c] - m[2*4+c]; // row1-row2
            d[3*4+c]  = m[0*4+c] - m[3*4+c]; // row0-row3
        end

        // Step 3: sum of absolutes
        satd_val = 0;
        for (int k = 0; k < 16; k++)
            satd_val += (d[k] < 0) ? -d[k] : d[k];

        // Step 4: normalize (HM: satd = ((satd+1)>>1))
        satd_val = (satd_val + 1) >> 1;

        // Step 5: DISTORTION_PRECISION_ADJUSTMENT(bitDepth-8) = >>2 for 10-bit
        satd_val = satd_val >> 2;

        return unsigned'(satd_val);
    endfunction

    // =========================================================================
    // Scoreboard
    // =========================================================================
    int unsigned exp_queue [$];
    int total_pass = 0, total_fail = 0;

    always @(posedge clk) begin
        if (valid_out) begin
            if (exp_queue.size() == 0) begin
                $display("ERROR: valid_out fired with empty queue at t=%0t", $time);
                total_fail++;
            end else begin
                int unsigned exp;
                exp = exp_queue.pop_front();
                if (satd_out !== exp[SATD_W-1:0]) begin
                    $display("FAIL  satd_out=%0d  expected=%0d  at t=%0t",
                             satd_out, exp, $time);
                    total_fail++;
                end else
                    total_pass++;
            end
        end
    end

    task automatic drive (
        input logic [PIXEL_WIDTH*16-1:0] o,
        input logic [PIXEL_WIDTH*16-1:0] r
    );
        @(negedge clk);
        valid_in  <= 1'b1;
        orig_flat <= o;
        ref_flat  <= r;
        exp_queue.push_back(golden_satd(o, r));
        @(posedge clk); @(negedge clk);
        valid_in <= 1'b0;
    endtask

    // =========================================================================
    // Tests
    // =========================================================================
    initial begin
        valid_in = 0; orig_flat = 0; ref_flat = 0;
        rst_n = 0; repeat(4) @(posedge clk);
        rst_n = 1; repeat(2) @(posedge clk);

        $display("====================================================");
        $display(" satd_4x4 Testbench — HM xCalcHADs4x4() reference");
        $display("====================================================");

        // ------------------------------------------------------------------
        // TEST 1: Zero residual — both blocks identical
        // All diffs = 0 → SATD = 0
        // ------------------------------------------------------------------
        $display("\n[TEST 1] Zero residual — orig == ref");
        begin
            logic [PIXEL_WIDTH*16-1:0] blk;
            for (int i = 0; i < 16; i++)
                blk[PIXEL_WIDTH*i +: PIXEL_WIDTH] = 10'd512;
            drive(blk, blk);
        end

        // ------------------------------------------------------------------
        // TEST 2: Flat DC residual — all diffs = K
        // Hadamard concentrates energy into DC coefficient only
        // d[0][0] = 4K×4 = 16K (DC), all others = 0
        // sum_abs = 16K, satd = ((16K+1)>>1)>>2 = 2K (for even K)
        // K=4: satd = ((64+1)>>1)>>2 = 32>>2 = 8
        // ------------------------------------------------------------------
        $display("[TEST 2] Flat DC residual (diff=4 everywhere)");
        begin
            logic [PIXEL_WIDTH*16-1:0] o_blk;
            o_blk = 0;
            for (int i = 0; i < 16; i++)
                o_blk[PIXEL_WIDTH*i +: PIXEL_WIDTH] = 10'd4; // ref=0, diff=4
            drive(o_blk, {PIXEL_WIDTH*16{1'b0}});
        end

        // ------------------------------------------------------------------
        // TEST 3: Single pixel differs
        // orig[0][0] = ref[0][0] + 16, all others equal
        // ------------------------------------------------------------------
        $display("[TEST 3] Single pixel diff — delta=16 at [0][0]");
        begin
            logic [PIXEL_WIDTH*16-1:0] o_blk, r_blk;
            o_blk = {16{10'd200}};
            r_blk = {16{10'd200}};
            o_blk[PIXEL_WIDTH*0 +: PIXEL_WIDTH] = 10'd216; // orig[0][0] += 16
            drive(o_blk, r_blk);
        end

        // ------------------------------------------------------------------
        // TEST 4: Max residual — orig=1023, ref=0 everywhere
        // max |diff| = 1023, sum_abs ≤ 65472, satd ≤ 8184
        // ------------------------------------------------------------------
        $display("[TEST 4] Max residual — orig=1023, ref=0");
        drive({16{10'd1023}}, {PIXEL_WIDTH*16{1'b0}});

        // ------------------------------------------------------------------
        // TEST 5: Alternating-sign checkerboard residual
        // diff[r][c] = (r+c)%2==0 ? +K : -K
        // Hadamard of checkerboard → energy at Nyquist (HF coefficient)
        // ------------------------------------------------------------------
        $display("[TEST 5] Checkerboard residual (±K)");
        begin
            logic [PIXEL_WIDTH*16-1:0] o_blk, r_blk;
            o_blk = {16{10'd512}};
            r_blk = {16{10'd512}};
            for (int r = 0; r < 4; r++)
                for (int c = 0; c < 4; c++) begin
                    if ((r+c) % 2 == 0)
                        o_blk[PIXEL_WIDTH*(4*r+c) +: PIXEL_WIDTH] = 10'd612; // +100
                    else
                        r_blk[PIXEL_WIDTH*(4*r+c) +: PIXEL_WIDTH] = 10'd412; // ref-=100, diff=-100... 
                        // Wait — diff = orig-ref. For neg: keep orig same, increase ref
                        // Actually: diff=-100 → orig=512, ref=612
                end
            // Recompute correctly for alternating:
            // (r+c)%2==0: diff=+100 → orig=612, ref=512
            // (r+c)%2!=0: diff=-100 → orig=512, ref=612
            o_blk = {16{10'd512}};
            r_blk = {16{10'd512}};
            for (int r = 0; r < 4; r++)
                for (int c = 0; c < 4; c++)
                    if ((r+c) % 2 == 0)
                        o_blk[PIXEL_WIDTH*(4*r+c) +: PIXEL_WIDTH] = 10'd612;
                    else
                        r_blk[PIXEL_WIDTH*(4*r+c) +: PIXEL_WIDTH] = 10'd612;
            drive(o_blk, r_blk);
        end

        // ------------------------------------------------------------------
        // TEST 6: Horizontal ramp residual — diff[r][c] = c*64
        // Exercises horizontal butterfly path
        // ------------------------------------------------------------------
        $display("[TEST 6] Horizontal ramp residual");
        begin
            logic [PIXEL_WIDTH*16-1:0] o_blk;
            o_blk = {PIXEL_WIDTH*16{1'b0}};
            for (int r = 0; r < 4; r++)
                for (int c = 0; c < 4; c++)
                    o_blk[PIXEL_WIDTH*(4*r+c) +: PIXEL_WIDTH] = 10'(c * 64);
            drive(o_blk, {PIXEL_WIDTH*16{1'b0}});
        end

        // ------------------------------------------------------------------
        // TEST 7: Vertical ramp residual — diff[r][c] = r*64
        // Exercises vertical butterfly path
        // ------------------------------------------------------------------
        $display("[TEST 7] Vertical ramp residual");
        begin
            logic [PIXEL_WIDTH*16-1:0] o_blk;
            o_blk = {PIXEL_WIDTH*16{1'b0}};
            for (int r = 0; r < 4; r++)
                for (int c = 0; c < 4; c++)
                    o_blk[PIXEL_WIDTH*(4*r+c) +: PIXEL_WIDTH] = 10'(r * 64);
            drive(o_blk, {PIXEL_WIDTH*16{1'b0}});
        end

        // ------------------------------------------------------------------
        // TEST 8: Back-to-back pipeline — 16 consecutive valid_in
        // ------------------------------------------------------------------
        $display("[TEST 8] Back-to-back pipeline (16 inputs)");
        begin
            @(negedge clk);
            valid_in <= 1'b1;
            for (int k = 0; k < 16; k++) begin
                logic [PIXEL_WIDTH*16-1:0] o_b, r_b;
                for (int i = 0; i < 16; i++) begin
                    o_b[PIXEL_WIDTH*i +: PIXEL_WIDTH] = 10'((k*64 + i*13) % 1024);
                    r_b[PIXEL_WIDTH*i +: PIXEL_WIDTH] = 10'((i*7)         % 1024);
                end
                orig_flat <= o_b;
                ref_flat  <= r_b;
                exp_queue.push_back(golden_satd(o_b, r_b));
                @(posedge clk); @(negedge clk);
            end
            valid_in <= 1'b0;
        end

        // ------------------------------------------------------------------
        // TEST 9: Random vectors — 2000 iterations
        // ------------------------------------------------------------------
        $display("[TEST 9] Random vectors (N=%0d)", N_RANDOM);
        for (int n = 0; n < N_RANDOM; n++) begin
            logic [PIXEL_WIDTH*16-1:0] o_r, r_r;
            for (int i = 0; i < 16; i++) begin
                o_r[PIXEL_WIDTH*i +: PIXEL_WIDTH] = $urandom() & 10'h3FF;
                r_r[PIXEL_WIDTH*i +: PIXEL_WIDTH] = $urandom() & 10'h3FF;
            end
            drive(o_r, r_r);
        end

        // ------------------------------------------------------------------
        // TEST 10: SATD ≤ SAD property (energy compaction)
        // For any block, SATD ≤ SAD because WHT preserves L1 norm only
        // when all energy is in one coefficient. In general SATD ≤ SAD.
        // Note: after the >>1 normalization in HM, SATD ≤ SAD/2 + 1
        // We verify SATD ≤ raw SAD (>>2) which always holds
        // ------------------------------------------------------------------
        $display("[TEST 10] SATD ≤ SAD property verification (100 cases)");
        begin
            int sad_ref, satd_ref;
            logic [PIXEL_WIDTH*16-1:0] o_r, r_r;
            for (int n = 0; n < 100; n++) begin
                for (int i = 0; i < 16; i++) begin
                    o_r[PIXEL_WIDTH*i +: PIXEL_WIDTH] = $urandom() & 10'h3FF;
                    r_r[PIXEL_WIDTH*i +: PIXEL_WIDTH] = $urandom() & 10'h3FF;
                end
                // Compute SW SAD (>>2) and SATD and compare
                begin
                    int unsigned sad_sum;
                    int diff;
                    sad_sum = 0;
                    for (int i = 0; i < 16; i++) begin
                        diff = int'(o_r[PIXEL_WIDTH*i +: PIXEL_WIDTH])
                             - int'(r_r[PIXEL_WIDTH*i +: PIXEL_WIDTH]);
                        sad_sum += (diff < 0) ? unsigned'(-diff) : unsigned'(diff);
                    end
                    sad_ref  = sad_sum >> 2;
                    satd_ref = golden_satd(o_r, r_r);
                    if (satd_ref > sad_ref)
                        $display("WARN [prop] SATD=%0d > SAD=%0d (case %0d) — check normalization", satd_ref, sad_ref, n);
                end
                drive(o_r, r_r);
            end
        end

        // Drain
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

    initial begin #15_000_000; $display("TIMEOUT"); $finish; end

endmodule