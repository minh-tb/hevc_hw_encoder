module tb_syntax_pred;

    // =========================================================================
    // Parameters & Signals
    // =========================================================================
    parameter CTX_ID_W = 8;
    parameter MVD_W    = 12;
    parameter MAX_REF  = 4;

    logic                  clk;
   logic                  rst_n;

    logic                  pred_valid;
    logic                  pred_done;
    logic                  slice_is_b;
    logic [1:0]            cu_depth;
    logic [1:0]            inter_dir;

    logic [2:0]            ref_idx_l0;
    logic                  mvp_flag_l0;
    logic signed [MVD_W-1:0] mvd_l0_x;
    logic signed [MVD_W-1:0] mvd_l0_y;

    logic [2:0]            ref_idx_l1;
    logic                  mvp_flag_l1;
    logic signed [MVD_W-1:0] mvd_l1_x;
    logic signed [MVD_W-1:0] mvd_l1_y;
    logic                  bin_valid;
    logic                  bin_value;
    logic [CTX_ID_W-1:0]   bin_ctx_id;
    logic                  bin_is_ep;
    logic                  bin_rdy;

    // =========================================================================
    // DUT Instantiation
   // =========================================================================
    syntax_pred #(
        .CTX_ID_W(CTX_ID_W),
        .MVD_W(MVD_W),
        .MAX_REF(MAX_REF)
    ) dut (.*);

    // =========================================================================
    // Clock & Reset
   // =========================================================================
    initial begin clk = 0; forever #5 clk = ~clk; end

    // Randomize bin_rdy to test FSM stall logic (80% ready rate)
    always @(posedge clk) begin
        if (!rst_n) bin_rdy <= 1'b0;
        else        bin_rdy <= ($urandom_range(0, 100) > 20);
    end

    // =========================================================================
    // Golden Model & Checking Queue
    // =========================================================================
    typedef struct {
        logic val;
        logic [7:0] ctx;
        logic ep;
    } bin_t;
    
    bin_t expected_bins[$];
    int total_errors = 0;

    // Background thread to check emitted bins against the queue
    always @(posedge clk) begin
        if (bin_valid && bin_rdy && rst_n) begin
            if (expected_bins.size() == 0) begin
                $display("[ERROR] %0t | Unexpected bin emitted! val=%b ctx=%0d ep=%b", $time, bin_value, bin_ctx_id, bin_is_ep);
                total_errors++;
            end else begin
                automatic bin_t exp = expected_bins.pop_front();
                if (exp.val !== bin_value || exp.ctx !== bin_ctx_id || exp.ep !== bin_is_ep) begin
                    $display("[ERROR] %0t | Bin mismatch! Exp: val=%b ctx=%0d ep=%b | Got: val=%b ctx=%0d ep=%b", 
                             $time, exp.val, exp.ctx, exp.ep, bin_value, bin_ctx_id, bin_is_ep);
                    total_errors++;
                end
            end
        end
    end

    // --- Golden Helper Functions ---
    task automatic expect_bin(logic v, logic [7:0] c, logic e);
        bin_t b;
        b.val = v; b.ctx = c; b.ep = e;
        expected_bins.push_back(b);
    endtask

    // Golden Exp-Golomb (Order k=1 for MVD)
    task automatic expect_eg(int val);
        int symbol = val;
        int count = 2; // HM starts at 1<<k (where k=1)
        int suffix_bits = 0;
        int temp_count;
        // Prefix
        while (symbol >= count) begin
            expect_bin(1, 0, 1);
            symbol -= count;
            count <<= 1;
        end
        expect_bin(0, 0, 1); // Terminator

        // Suffix
       temp_count = count;
        while (temp_count > 1) begin
            suffix_bits++;
            temp_count >>= 1;
       end

        // Bits are emitted MSB first
        for (int i = suffix_bits - 1; i >= 0; i--) begin
            expect_bin((symbol >> i) & 1, 0, 1);
        end
    endtask

    task automatic test_mvd(int mvd);
        int abs_mvd = (mvd < 0) ? -mvd : mvd;
        logic sign = (mvd < 0) ? 1 : 0;

        if (abs_mvd > 0) begin
            expect_bin(1, 27, 0); // GT0 flag
            if (abs_mvd > 1) begin
                expect_bin(1, 28, 0); // GT1 flag
                expect_eg(abs_mvd - 2);
            end else begin
                expect_bin(0, 28, 0);
            end
            expect_bin(sign, 0, 1); // Sign flag (bypass)
        end else begin
            expect_bin(0, 27, 0);
        end
   endtask

    task automatic test_ref(int ref_idx);
        if (ref_idx > 0) begin
           expect_bin(1, 23, 0);
            if (ref_idx > 1) begin
                expect_bin(1, 24, 0);
                for (int i = 2; i < ref_idx; i++) expect_bin(1, 0, 1);
                expect_bin(0, 0, 1);
            end else begin
                expect_bin(0, 24, 0);
            end
        end else begin
            expect_bin(0, 23, 0);
        end
    endtask

    // --- Master Driver Task ---
    task automatic run_test(
        logic is_b, logic [1:0] depth, logic [1:0] idir,
        logic [2:0] r0, logic mvp0, int mvd0x, int mvd0y,
        logic [2:0] r1, logic mvp1, int mvd1x, int mvd1y
   );
        // 1. Build expectations
        // B-Slices send inter_pred_idc (1 or 2 bins). P-Slices send nothing.
        if (is_b) begin
            expect_bin(idir == 2, 18 + depth, 0); // Bin 0: Bi-dir vs Univariate
            if (idir != 2) expect_bin(idir == 1, 18 + depth, 0); // Bin 1: L1 vs L0
        end

        test_ref(r0); test_mvd(mvd0x); test_mvd(mvd0y); expect_bin(mvp0, 0, 1);

        if (is_b && idir != 0) begin
            test_ref(r1); test_mvd(mvd1x); test_mvd(mvd1y); expect_bin(mvp1, 0, 1);
        end

        // 2. Drive DUT
        slice_is_b = is_b; cu_depth = depth; inter_dir = idir;
        ref_idx_l0 = r0; mvp_flag_l0 = mvp0; mvd_l0_x = mvd0x; mvd_l0_y = mvd0y;
        ref_idx_l1 = r1; mvp_flag_l1 = mvp1; mvd_l1_x = mvd1x; mvd_l1_y = mvd1y;

        @(posedge clk) pred_valid = 1;
        @(posedge clk) pred_valid = 0;

        // 3. Wait for DUT to finish
        while (!pred_done) @(posedge clk);
        @(posedge clk);

        if (expected_bins.size() > 0) begin
            $display("[ERROR] %0t | Missing %0d expected bins!", $time, expected_bins.size());
            total_errors++;
            expected_bins.delete(); // Clear queue for next test
        end else begin
            $display("[PASS] Test case finished correctly.");
        end
    endtask

    // =========================================================================
    // Test Sequence
    // =========================================================================
    initial begin
        rst_n = 0; pred_valid = 0;
        
        // Default safe values
        slice_is_b = 0; cu_depth = 0; inter_dir = 0;
        ref_idx_l0 = 0; mvp_flag_l0 = 0; mvd_l0_x = 0; mvd_l0_y = 0;
        ref_idx_l1 = 0; mvp_flag_l1 = 0; mvd_l1_x = 0; mvd_l1_y = 0;

        repeat(5) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        $display("\n--- Starting syntax_pred Tests ---\n");

        $display("Test 1: P-Slice, Zero MVD, Ref 0");
        run_test(0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0);

        $display("Test 2: P-Slice, Small MVD, Ref 1");
        run_test(0, 1, 0,  1, 1, 1, -1,  0, 0, 0, 0);

        $display("Test 3: P-Slice, Large MVD (Triggers Exp-Golomb), Ref 3");
        run_test(0, 2, 0,  3, 0, 14, -2048,  0, 0, 0, 0);

        $display("Test 4: B-Slice (Bi-Dir), Mixed MVDs");
        run_test(1, 3, 2,  0, 1, 5, 0,  2, 0, 0, -42);

        $display("\n--- Simulation Complete ---");
        if (total_errors == 0)
            $display(">> SUCCESS: All tests passed with 0 errors!");
        else
            $display(">> FAILURE: %0d errors detected.", total_errors);
            
        $finish;
    end

endmodule
