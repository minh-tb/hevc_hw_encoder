//=============================================================================
// tb_intra_pred_top.sv
// Testbench for HEVC Intra Prediction Dispatcher
//=============================================================================
//
`timescale 1ns/1ps

module tb_intra_pred_top;

    // Signals
    logic         clk;
    logic         rst_n;
    logic [2:0]   pu_size_log2;
    logic [5:0]   intra_mode;
    logic         is_luma;

    logic         ref_valid;
    logic         ref_ready;
    logic [9:0]   ref_sample;
    logic [7:0]   ref_idx;
    logic         ref_last;

    logic         out_valid;
    logic         out_ready;
    logic [9:0]   out_pixel;
    logic [5:0]   out_x;
    logic [5:0]   out_y;
    logic         out_last;

    int total_errors = 0;
    int total_correct = 0;

    // DUT
    intra_pred_top dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .pu_size_log2   (pu_size_log2),
        .intra_mode     (intra_mode),
        .is_luma        (is_luma),
        .ref_valid      (ref_valid),
        .ref_ready      (ref_ready),
        .ref_sample     (ref_sample),
        .ref_idx        (ref_idx),
        .ref_last       (ref_last),
        .out_valid      (out_valid),
        .out_ready      (out_ready),
        .out_pixel      (out_pixel),
        .out_x          (out_x),
        .out_y          (out_y),
        .out_last       (out_last)
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

    task automatic test_block_from_file(
        int size_log2, 
        int mode, 
        int is_luma_flag,
        ref logic [9:0] ref_in[],
        ref logic [9:0] exp_out[],
        input string in_file,
        input int count
    );
        int N = 1 << size_log2;
        int ref_count = 4 * N + 1;
        
        pu_size_log2 <= size_log2;
        intra_mode   <= mode;
        is_luma      <= is_luma_flag;
        
        fork
            // Thread 1: Feed reference array
            begin
                for (int i = 0; i < ref_count; i++) begin
                    ref_valid <= 1;
                    ref_sample <= ref_in[i];
                    ref_idx <= i;
                    ref_last <= (i == ref_count - 1);
                    do begin @(posedge clk); end while (!ref_ready);
                end
                ref_valid <= 0;
            end
            // Thread 2: Verify N*N predicted output
            begin
                for (int i = 0; i < N * N; i++) begin
                    int exp_idx;
                    do begin @(posedge clk); end while (!out_valid || !out_ready);
                    
                    // Map coordinates dynamically (intra_angular might transpose!)
                    exp_idx = out_y * N + out_x;
                    
                    if (out_pixel !== exp_out[exp_idx]) begin
                        $display("ERROR [File %s, Block %0d, Mode %0d]: expected val=%0d at (%0d,%0d), got val=%0d", 
                                 in_file, count, mode, exp_out[exp_idx], out_x, out_y, out_pixel);
                        total_errors++;
                    end else begin
                        total_correct++;
                    end
                end
            end
        join
    endtask

    task automatic run_combined_test(int size_log2);
        int N = 1 << size_log2;
        int ref_count = 4 * N + 1;
        
        int fd_in_dc, fd_out_dc;
        int fd_in_planar, fd_out_planar;
        int fd_in_ang, fd_out_ang;
        
        string fn_in_dc = $sformatf("intra_dc_in_%0d.dat", N);
        string fn_out_dc = $sformatf("intra_dc_out_%0d.dat", N);
        string fn_in_planar = $sformatf("intra_planar_in_%0d.dat", N);
        string fn_out_planar = $sformatf("intra_planar_out_%0d.dat", N);
        string fn_in_ang = $sformatf("intra_angular_in_%0d.dat", N);
        string fn_out_ang = $sformatf("intra_angular_out_%0d.dat", N);

        int count = 0;

        logic [9:0] ref_in[];
        logic [9:0] exp_out[];
        
        ref_in = new[ref_count];
        exp_out = new[N*N];

        fd_in_dc = $fopen(fn_in_dc, "r");
        fd_out_dc = $fopen(fn_out_dc, "r");
        fd_in_planar = $fopen(fn_in_planar, "r");
        fd_out_planar = $fopen(fn_out_planar, "r");
        fd_in_ang = $fopen(fn_in_ang, "r");
        fd_out_ang = $fopen(fn_out_ang, "r");

        if (!fd_in_dc || !fd_out_dc || !fd_in_planar || !fd_out_planar || !fd_in_ang || !fd_out_ang) begin
            $display("Warning: Cannot open some files for N=%0d, skipping combined test.", N);
            if (fd_in_dc) $fclose(fd_in_dc);
            if (fd_out_dc) $fclose(fd_out_dc);
            if (fd_in_planar) $fclose(fd_in_planar);
            if (fd_out_planar) $fclose(fd_out_planar);
            if (fd_in_ang) $fclose(fd_in_ang);
            if (fd_out_ang) $fclose(fd_out_ang);
            return;
        end

        $display("Testing dynamic switching for N=%0d...", N);

        // Run until one of the files runs out of data
        while (!$feof(fd_in_dc) && !$feof(fd_in_planar) && !$feof(fd_in_ang)) begin
            int val_in, val_out, val_mode;
            int ret_in, ret_out;

            // --- PLANAR ---
            for (int i = 0; i < ref_count; i++) begin
                ret_in = $fscanf(fd_in_planar, "%x\n", val_in);
                if (ret_in != 1) break;
                ref_in[i] = val_in;
            end
            for (int i = 0; i < N * N; i++) begin
                ret_out = $fscanf(fd_out_planar, "%x\n", val_out);
                if (ret_out != 1) break;
                exp_out[i] = val_out;
            end
            if (ret_in == 1 && ret_out == 1) test_block_from_file(size_log2, 0, 1, ref_in, exp_out, fn_in_planar, count);

            // --- DC ---
            for (int i = 0; i < ref_count; i++) begin
                ret_in = $fscanf(fd_in_dc, "%x\n", val_in);
                if (ret_in != 1) break;
                ref_in[i] = val_in;
            end
            for (int i = 0; i < N * N; i++) begin
                ret_out = $fscanf(fd_out_dc, "%x\n", val_out);
                if (ret_out != 1) break;
                exp_out[i] = val_out;
            end
            if (ret_in == 1 && ret_out == 1) test_block_from_file(size_log2, 1, 1, ref_in, exp_out, fn_in_dc, count);

            // --- ANGULAR ---
            ret_in = $fscanf(fd_in_ang, "%x\n", val_mode);
            for (int i = 0; i < ref_count; i++) begin
                ret_in = $fscanf(fd_in_ang, "%x\n", val_in);
                if (ret_in != 1) break;
                ref_in[i] = val_in;
            end
            for (int i = 0; i < N * N; i++) begin
                ret_out = $fscanf(fd_out_ang, "%x\n", val_out);
                if (ret_out != 1) break;
                exp_out[i] = val_out;
            end
            if (ret_in == 1 && ret_out == 1) test_block_from_file(size_log2, val_mode, 1, ref_in, exp_out, fn_in_ang, count);

            count++;
        end

        $fclose(fd_in_dc);
        $fclose(fd_out_dc);
        $fclose(fd_in_planar);
        $fclose(fd_out_planar);
        $fclose(fd_in_ang);
        $fclose(fd_out_ang);
        $display("Finished dynamic switching test for N=%0d, total round-robin cycles: %0d", N, count);
    endtask

    initial begin
        ref_valid = 0; ref_sample = 0; ref_idx = 0; ref_last = 0;
        rst_n = 0; @(negedge clk); rst_n = 1; @(negedge clk);

        $display("==================================================");
        $display(" Starting intra_pred_top Verification");
        $display("==================================================");

        run_combined_test(2); // 4x4
        run_combined_test(3); // 8x8
        run_combined_test(4); // 16x16
        run_combined_test(5); // 32x32

        $display("==================================================");
        if (total_errors == 0) $display(" === ALL TESTS PASSED ===");
        else                   $display(" === TESTS FAILED: %0d Errors ===", total_errors);
        $display("Total Correct Predictions: %0d", total_correct);
        $display("==================================================\n");
        $finish;
    end

endmodule
