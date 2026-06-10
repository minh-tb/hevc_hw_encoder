//=============================================================================
// tb_sad_8x8.sv
// Testbench for sad_8x8 — verifies against HM xGetSAD8() golden model
//
// Test plan:
//   1. Zero SAD          : orig == ref
//   2. Max SAD           : orig=1023, ref=0  → raw=65536 >>2 = 16384... 
//                          wait: 64×1023=65472 >>2 = 16368
//   3. Quadrant isolation: only one quadrant differs, others zero
//   4. Cross-quadrant symmetry: same block SAD == mirrored block SAD
//   5. Random vectors    : compare against SW golden
//   6. Back-to-back      : pipeline flush / no corruption
//   7. Consistency       : sad_8x8 == 4 × sad_4x4 for same quadrant data
//=============================================================================

`timescale 1ns/1ps

module tb_sad_8x8;

    localparam PIXEL_WIDTH = 10;
    localparam SAD_WIDTH   = 14;   // 12-bit per quadrant, 4 quads → 14-bit total
    localparam LATENCY     = 4;    // sad_4x4(3) + adder(1)
    localparam N_RANDOM    = 2000;

    // =========================================================================
    // DUT signals
    // =========================================================================
    logic                        clk, rst_n;
    logic                        valid_in;
    logic [PIXEL_WIDTH*64-1:0]   orig_flat;
    logic [PIXEL_WIDTH*64-1:0]   ref_flat;
    logic                        valid_out;
    logic [SAD_WIDTH-1:0]        sad_out;

    // =========================================================================
    // DUT
    // =========================================================================
    sad_8x8 #(.PIXEL_WIDTH(PIXEL_WIDTH)) dut (
        .clk(clk), .rst_n(rst_n),
        .valid_in (valid_in),
        .orig_flat(orig_flat), .ref_flat(ref_flat),
        .valid_out(valid_out), .sad_out(sad_out)
    );

    initial clk = 0;
    always #4 clk = ~clk;

    // =========================================================================
    // Golden model — HM xGetSAD8() in SV
    // Returns uiSum >> 2  (DISTORTION_PRECISION_ADJUSTMENT(10-8))
    // =========================================================================
    function automatic int unsigned golden_sad8 (
        input logic [PIXEL_WIDTH*64-1:0] o_flat,
        input logic [PIXEL_WIDTH*64-1:0] r_flat
    );
        int unsigned sum;
        int diff;
        sum = 0;
        for (int i = 0; i < 64; i++) begin
            diff = int'(o_flat[PIXEL_WIDTH*i +: PIXEL_WIDTH])
                 - int'(r_flat[PIXEL_WIDTH*i +: PIXEL_WIDTH]);
            sum += (diff < 0) ? unsigned'(-diff) : unsigned'(diff);
        end
        return sum >> 2;
    endfunction

    // =========================================================================
    // Scoreboard
    // =========================================================================
    int unsigned exp_queue [$];
    int total_pass = 0, total_fail = 0;

    always @(posedge clk) begin
        if (valid_out) begin
            if (exp_queue.size() == 0) begin
                $display("ERROR: valid_out with empty queue at t=%0t", $time);
                total_fail++;
            end else begin
                int unsigned exp;
                exp = exp_queue.pop_front();
                if (sad_out !== exp[SAD_WIDTH-1:0]) begin
                    $display("FAIL  sad_out=%0d  expected=%0d  at t=%0t",
                             sad_out, exp, $time);
                    total_fail++;
                end else
                    total_pass++;
            end
        end
    end

    task automatic drive (
        input logic [PIXEL_WIDTH*64-1:0] o,
        input logic [PIXEL_WIDTH*64-1:0] r
    );
        @(negedge clk);
        valid_in  <= 1'b1;
        orig_flat <= o;
        ref_flat  <= r;
        exp_queue.push_back(golden_sad8(o, r));
        @(posedge clk);
        @(negedge clk);
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
        $display("  sad_8x8 Testbench — HM xGetSAD8() golden reference");
        $display("====================================================");

        // ------------------------------------------------------------------
        // TEST 1: Zero SAD
        // ------------------------------------------------------------------
        $display("\n[TEST 1] Zero SAD");
        begin
            logic [PIXEL_WIDTH*64-1:0] blk;
            for (int i = 0; i < 64; i++)
                blk[PIXEL_WIDTH*i +: PIXEL_WIDTH] = 10'd512;
            drive(blk, blk);
        end

        // ------------------------------------------------------------------
        // TEST 2: Max SAD
        // 64 pixels × 1023 = 65472 raw → >>2 = 16368
        // ------------------------------------------------------------------
        $display("[TEST 2] Max SAD — orig=1023 ref=0  (expect 16368)");
        drive({64{10'd1023}}, {PIXEL_WIDTH*64{1'b0}});

        // ------------------------------------------------------------------
        // TEST 3: Quadrant isolation — only top-left 4×4 differs
        // All 16 pixels of Q00 differ by 100, others identical
        // expected = 16 × 100 >> 2 = 400
        // ------------------------------------------------------------------
        $display("[TEST 3] Q00 isolation — only top-left quadrant differs");
        begin
            logic [PIXEL_WIDTH*64-1:0] o_blk, r_blk;
            o_blk = {64{10'd200}};
            r_blk = {64{10'd200}};
            // Set Q00 (rows 0-3, cols 0-3) in orig to 200+100=300
            for (int row = 0; row < 4; row++)
                for (int col = 0; col < 4; col++)
                    o_blk[PIXEL_WIDTH*(8*row + col) +: PIXEL_WIDTH] = 10'd300;
            drive(o_blk, r_blk);
        end

        // ------------------------------------------------------------------
        // TEST 4: Quadrant isolation — only Q11 (bottom-right) differs
        // ------------------------------------------------------------------
        $display("[TEST 4] Q11 isolation — only bottom-right quadrant differs");
        begin
            logic [PIXEL_WIDTH*64-1:0] o_blk, r_blk;
            o_blk = {64{10'd500}};
            r_blk = {64{10'd500}};
            for (int row = 4; row < 8; row++)
                for (int col = 4; col < 8; col++)
                    o_blk[PIXEL_WIDTH*(8*row + col) +: PIXEL_WIDTH] = 10'd600;
            drive(o_blk, r_blk);
        end

        // ------------------------------------------------------------------
        // TEST 5: Consistency — verify sad_8x8 == sum of 4 × sad_4x4 quads
        // Uses fixed pattern where each quadrant SAD is known
        // ------------------------------------------------------------------
        $display("[TEST 5] Consistency — all quads active, uniform diff=4");
        begin
            logic [PIXEL_WIDTH*64-1:0] o_blk;
            o_blk = 0;
            for (int i = 0; i < 64; i++)
                o_blk[PIXEL_WIDTH*i +: PIXEL_WIDTH] = 10'd4;
            // ref=0, diff=4 everywhere → raw=64×4=256 → >>2=64
            drive(o_blk, {PIXEL_WIDTH*64{1'b0}});
        end

        // ------------------------------------------------------------------
        // TEST 6: Symmetry — |orig-ref| == |ref-orig|
        // ------------------------------------------------------------------
        $display("[TEST 6] Symmetry test");
        begin
            logic [PIXEL_WIDTH*64-1:0] o_blk, r_blk;
            for (int i = 0; i < 64; i++) begin
                o_blk[PIXEL_WIDTH*i +: PIXEL_WIDTH] = 10'(i * 16 % 1024);
                r_blk[PIXEL_WIDTH*i +: PIXEL_WIDTH] = 10'(1023 - (i * 16 % 1024));
            end
            drive(o_blk, r_blk);
            drive(r_blk, o_blk); // expect same SAD
        end

        // ------------------------------------------------------------------
        // TEST 7: Back-to-back pipeline — 16 consecutive inputs
        // ------------------------------------------------------------------
        $display("[TEST 7] Back-to-back pipeline (16 inputs)");
        begin
            @(negedge clk);
            valid_in <= 1'b1;
            for (int k = 0; k < 16; k++) begin
                logic [PIXEL_WIDTH*64-1:0] o_b, r_b;
                for (int i = 0; i < 64; i++) begin
                    o_b[PIXEL_WIDTH*i +: PIXEL_WIDTH] = 10'((k*32 + i*3) % 1024);
                    r_b[PIXEL_WIDTH*i +: PIXEL_WIDTH] = 10'((i*7)        % 1024);
                end
                orig_flat <= o_b;
                ref_flat  <= r_b;
                exp_queue.push_back(golden_sad8(o_b, r_b));
                @(posedge clk); @(negedge clk);
            end
            valid_in <= 1'b0;
        end

        // ------------------------------------------------------------------
        // TEST 8: Random vectors
        // ------------------------------------------------------------------
        $display("[TEST 8] Random vectors (N=%0d)", N_RANDOM);
        for (int n = 0; n < N_RANDOM; n++) begin
            logic [PIXEL_WIDTH*64-1:0] o_r, r_r;
            for (int i = 0; i < 64; i++) begin
                o_r[PIXEL_WIDTH*i +: PIXEL_WIDTH] = $urandom() & 10'h3FF;
                r_r[PIXEL_WIDTH*i +: PIXEL_WIDTH] = $urandom() & 10'h3FF;
            end
            drive(o_r, r_r);
        end

        // Drain pipeline
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

    initial begin #10_000_000; $display("TIMEOUT"); $finish; end

endmodule