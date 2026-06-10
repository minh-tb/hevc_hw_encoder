//=============================================================================
// tb_intra_dc.sv
// Testbench for HEVC Intra DC Prediction
//=============================================================================

`timescale 1ns/1ps

module tb_intra_dc;

    // Signals
    logic         clk;
    logic         rst_n;
    logic [2:0]   pu_size_log2;
    logic         is_luma;

    logic         in_valid;
    logic         in_ready;
    logic [9:0]   in_sample;
    logic [7:0]   in_idx;
    logic         in_last;

    logic         out_valid;
    logic         out_ready;
    logic [9:0]   out_pixel;
    logic [5:0]   out_x;
    logic [5:0]   out_y;
    logic         out_last;

    int total_errors = 0;
    int total_correct = 0;
    // DUT
    intra_dc dut (
        .clk(clk),
        .rst_n(rst_n),
        .pu_size_log2(pu_size_log2),
        .is_luma(is_luma),
        .in_valid(in_valid),
        .in_ready(in_ready),
        .in_sample(in_sample),
        .in_idx(in_idx),
        .in_last(in_last),
        .out_valid(out_valid),
        .out_ready(out_ready),
        .out_pixel(out_pixel),
        .out_x(out_x),
        .out_y(out_y),
        .out_last(out_last)
    );

    // Clock
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // Random Stall Generator to stress test the FSM
    always @(posedge clk) begin
        out_ready <= ($urandom % 100 < 80); // 80% ready rate
    end

    // HEVC Golden Model for DC Prediction
    function automatic void compute_golden_dc(
        input logic [2:0] size_log2,
        input logic       luma,
        input logic [9:0] ref_in[],
        output logic [9:0] pred_out[]
    );
        int N = 1 << size_log2;
        int sum_top = 0;
        int sum_left = 0;
        int dc_val = 0;
        int apply_filter = luma && (size_log2 < 5); // N < 32 (4, 8, 16)

        // Calculate Sums (only first N pixels of top and left)
        for (int i = 1; i <= N; i++) sum_top += ref_in[i];
        for (int i = 2*N + 1; i <= 3*N; i++) sum_left += ref_in[i];

        // Calculate DC Value
        dc_val = (sum_top + sum_left + N) >> (size_log2 + 1);

        pred_out = new[N*N];

        // Generate predicted pixels
        for (int y = 0; y < N; y++) begin
            for (int x = 0; x < N; x++) begin
                int idx = y * N + x;
                if (!apply_filter) begin
                    pred_out[idx] = dc_val;
                end else if (x == 0 && y == 0) begin
                    pred_out[idx] = (ref_in[1] + ref_in[2*N+1] + 2*dc_val + 2) >> 2;
                end else if (y == 0) begin
                    pred_out[idx] = (ref_in[1+x] + 3*dc_val + 2) >> 2;
                end else if (x == 0) begin
                    pred_out[idx] = (ref_in[2*N+1+y] + 3*dc_val + 2) >> 2;
                end else begin
                    pred_out[idx] = dc_val;
                end
            end
        end
    endfunction

    task automatic test_block(int size_log2, int is_luma_flag);
        int N = 1 << size_log2;
        int ref_count = 4*N + 1;
        logic [9:0] ref_in[];
        logic [9:0] exp_out[];
        ref_in = new[ref_count];
        
        for(int i=0; i<ref_count; i++) ref_in[i] = $urandom % 1024;
        
        compute_golden_dc(size_log2, is_luma_flag, ref_in, exp_out);
        
        pu_size_log2 <= size_log2;
        is_luma      <= is_luma_flag;
        
        fork
            // Thread 1: Feed reference array
            begin
                for (int i=0; i<ref_count; i++) begin
                    in_valid <= 1;
                    in_sample <= ref_in[i];
                    in_idx <= i;
                    in_last <= (i == ref_count - 1);
                    do begin @(posedge clk); end while (!in_ready);
                end
                in_valid <= 0;
            end
            // Thread 2: Verify N*N predicted output
            begin
                for (int y=0; y<N; y++) begin
                    for (int x=0; x<N; x++) begin
                        int idx = y*N + x;
                        do begin @(posedge clk); end while (!out_valid || !out_ready);
                        
                        if (out_pixel !== exp_out[idx] || out_x !== x || out_y !== y) begin
                            $display("ERROR [N=%0d]: expected val=%0d at (%0d,%0d), got val=%0d at (%0d,%0d)", 
                                     N, exp_out[idx], x, y, out_pixel, out_x, out_y);
                            total_errors++;
                        end
                        else begin
                            total_correct++;
                        end
                    end
                end
            end
        join
    endtask

    task automatic test_from_file(int size_log2, string in_file, string out_file);
        int N = 1 << size_log2;
        int ref_count = 4 * N + 1;
        logic [9:0] ref_in[];
        logic [9:0] exp_out[];
        int in_fd, out_fd;
        int ret_in, ret_out;
        int count = 0;
        int val_in, val_out;

        in_fd = $fopen(in_file, "r");
        if (in_fd == 0) begin
            $display("Warning: Cannot open %s, skipping", in_file);
            return;
        end
        out_fd = $fopen(out_file, "r");
        if (out_fd == 0) begin
            $display("Warning: Cannot open %s, skipping", out_file);
            $fclose(in_fd);
            return;
        end

        ref_in = new[ref_count];
        exp_out = new[N*N];

        $display("Testing from file: %s, N=%0d", in_file, N);

        while (!$feof(in_fd) && !$feof(out_fd)) begin
            // Read 1 block of inputs (4N+1)
            for (int i = 0; i < ref_count; i++) begin
                ret_in = $fscanf(in_fd, "%x\n", val_in);
                if (ret_in != 1) break;
                ref_in[i] = val_in;
            end
            if (ret_in != 1) break;

            // Read 1 block of outputs (N*N)
            for (int i = 0; i < N * N; i++) begin
                ret_out = $fscanf(out_fd, "%x\n", val_out);
                if (ret_out != 1) break;
                exp_out[i] = val_out;
            end
            if (ret_out != 1) break;

            pu_size_log2 <= size_log2;
            is_luma      <= 1; // HM extraction is for Luma
            
            fork
                // Thread 1: Feed reference array
                begin
                    for (int i = 0; i < ref_count; i++) begin
                        in_valid <= 1;
                        in_sample <= ref_in[i];
                        in_idx <= i;
                        in_last <= (i == ref_count - 1);
                        do begin @(posedge clk); end while (!in_ready);
                    end
                    in_valid <= 0;
                end
                // Thread 2: Verify N*N predicted output
                begin
                    for (int y = 0; y < N; y++) begin
                        for (int x = 0; x < N; x++) begin
                            int idx = y * N + x;
                            do begin @(posedge clk); end while (!out_valid || !out_ready);
                            
                            if (out_pixel !== exp_out[idx] || out_x !== x || out_y !== y) begin
                                $display("ERROR [File %s, Block %0d]: expected val=%0d at (%0d,%0d), got val=%0d at (%0d,%0d)", 
                                         in_file, count, exp_out[idx], x, y, out_pixel, out_x, out_y);
                                total_errors++;
                            end else begin
                                total_correct++;
                            end
                        end
                    end
                end
            join
            count++;
        end

        $fclose(in_fd);
        $fclose(out_fd);
        $display("Finished testing %0d blocks from %s", count, in_file);
    endtask

    initial begin
        // [Testbench stimulus execution left identical to ref_sample_filter initialization]
        // Initialization
        in_valid = 0;
        in_sample = 0;
        in_idx = 0;
        in_last = 0;

        rst_n = 0;
        @(negedge clk);
        rst_n = 1;
        @(negedge clk);

        $display("==================================================");
        $display(" Starting intra_dc Verification");
        $display("==================================================");

        $display("Testing from HM extraction files...");
        test_from_file(2, "intra_dc_in_4.dat", "intra_dc_out_4.dat");
        test_from_file(3, "intra_dc_in_8.dat", "intra_dc_out_8.dat");
        test_from_file(4, "intra_dc_in_16.dat", "intra_dc_out_16.dat");
        test_from_file(5, "intra_dc_in_32.dat", "intra_dc_out_32.dat");

        $display("Testing 4x4 Luma (No filter)...");
        test_block(2, 1);
        
        $display("Testing 8x8 Luma (Filtered boundaries)...");
        test_block(3, 1);
        
        $display("Testing 16x16 Luma (Filtered boundaries)...");
        test_block(4, 1);
        
        $display("Testing 32x32 Luma (Filtered boundaries)...");
        test_block(5, 1);

        $display("Testing Chroma 16x16 (No filter)...");
        test_block(4, 0); 

        $display("Running 20 random test cases...");
        for (int i=0; i<20; i++) begin
            test_block(($urandom%4)+2, $urandom%2);
        end

        $display("==================================================");
        if (total_errors == 0) $display(" === ALL TESTS PASSED ===");
        else                   $display(" === TESTS FAILED: %0d Errors ===", total_errors);
        $display("Total Correct Predictions: %0d", total_correct);
        $display("==================================================\n");
        $finish;
    end

endmodule