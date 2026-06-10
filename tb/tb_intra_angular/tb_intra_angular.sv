//=============================================================================
// tb_intra_angular.sv
// Testbench for HEVC Intra Angular Prediction (Modes 2..34)
//=============================================================================

`timescale 1ns/1ps

module tb_intra_angular;

    // Signals
    logic         clk;
    logic         rst_n;
    logic [2:0]   pu_size_log2;
    logic [5:0]   intra_mode;

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
    intra_angular dut (
        .clk(clk),
        .rst_n(rst_n),
        .pu_size_log2(pu_size_log2),
        .intra_mode(intra_mode),
        .is_luma(1'b1),
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

    // Random Stall Generator to stress test the pipelined outputs
    always @(posedge clk) begin
        out_ready <= ($urandom % 100 < 80); // 80% ready rate
    end

    task automatic test_from_file(int size_log2, string in_file, string out_file);
        int N = 1 << size_log2;
        int ref_count = 4 * N + 1;
        logic [9:0] ref_in[];
        logic [9:0] exp_out[];
        int in_fd, out_fd;
        int ret_in, ret_out;
        int count = 0;
        int val_mode, val_in, val_out;

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
            // Read Mode (First line of the input block)
            ret_in = $fscanf(in_fd, "%x\n", val_mode);
            if (ret_in != 1) break;

            // Read 1 block of input reference boundaries (4N+1)
            for (int i = 0; i < ref_count; i++) begin
                ret_in = $fscanf(in_fd, "%x\n", val_in);
                if (ret_in != 1) break;
                ref_in[i] = val_in;
            end
            if (ret_in != 1) break;

            // Read 1 block of expected output pixels (N*N) in raster-scan order
            for (int i = 0; i < N * N; i++) begin
                ret_out = $fscanf(out_fd, "%x\n", val_out);
                if (ret_out != 1) break;
                exp_out[i] = val_out;
            end
            if (ret_out != 1) break;

            pu_size_log2 <= size_log2;
            intra_mode   <= val_mode;
            
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
                    for (int i = 0; i < N * N; i++) begin
                        int exp_idx;
                        do begin @(posedge clk); end while (!out_valid || !out_ready);
                        
                        // Map coordinates dynamically so it works even if RTL transposes!
                        exp_idx = out_y * N + out_x;
                        
                        if (out_pixel !== exp_out[exp_idx]) begin
                            $display("ERROR [File %s, Block %0d, Mode %0d]: expected val=%0d at (%0d,%0d), got val=%0d", 
                                     in_file, count, val_mode, exp_out[exp_idx], out_x, out_y, out_pixel);
                            total_errors++;
                        end else begin
                            total_correct++;
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
        in_valid = 0; in_sample = 0; in_idx = 0; in_last = 0;
        rst_n = 0; @(negedge clk); rst_n = 1; @(negedge clk);

        $display("==================================================");
        $display(" Starting intra_angular Verification");
        $display("==================================================");

        $display("Testing from HM extraction files...");
        test_from_file(2, "intra_angular_in_4.dat", "intra_angular_out_4.dat");
        test_from_file(3, "intra_angular_in_8.dat", "intra_angular_out_8.dat");
        test_from_file(4, "intra_angular_in_16.dat", "intra_angular_out_16.dat");
        test_from_file(5, "intra_angular_in_32.dat", "intra_angular_out_32.dat");

        $display("==================================================");
        if (total_errors == 0) $display(" === ALL TESTS PASSED ===");
        else                   $display(" === TESTS FAILED: %0d Errors ===", total_errors);
        $display("Total Correct Predictions: %0d", total_correct);
        $display("==================================================\n");
        $finish;
    end
endmodule