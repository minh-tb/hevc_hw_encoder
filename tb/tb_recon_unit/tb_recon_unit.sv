//=============================================================================
// tb_recon_unit.sv
// Testbench for Reconstruction Unit
//=============================================================================

`timescale 1ns/1ps

module tb_recon_unit;

    // Signals
    logic         clk;
    logic         rst_n;

    logic         transform_skip;
    logic [1:0]   comp;

    logic         pred_valid;
    logic         pred_ready;
    logic [9:0]   pred_pixel;
    logic [5:0]   pred_x;
    logic [5:0]   pred_y;
    logic         pred_last;

    logic         res_valid;
    logic         res_ready;
    logic signed [15:0] res_coeff;
    logic [5:0]   res_x;
    logic [5:0]   res_y;
    logic         res_last;

    logic         out_valid;
    logic         out_ready;
    logic [9:0]   out_pixel;
    logic [5:0]   out_x;
    logic [5:0]   out_y;
    logic         out_last;
    logic [1:0]   out_comp;

    int total_errors = 0;
    int total_correct = 0;

    // DUT
    recon_unit dut (
        .clk(clk),
        .rst_n(rst_n),
        .transform_skip(transform_skip),
        .comp(comp),
        .pred_valid(pred_valid),
        .pred_ready(pred_ready),
        .pred_pixel(pred_pixel),
        .pred_x(pred_x),
        .pred_y(pred_y),
        .pred_last(pred_last),
        .res_valid(res_valid),
        .res_ready(res_ready),
        .res_coeff(res_coeff),
        .res_x(res_x),
        .res_y(res_y),
        .res_last(res_last),
        .out_valid(out_valid),
        .out_ready(out_ready),
        .out_pixel(out_pixel),
        .out_x(out_x),
        .out_y(out_y),
        .out_last(out_last),
        .out_comp(out_comp)
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
        input logic [9:0] pred_in[],
        input logic signed [15:0] res_in[],
        input logic [9:0] exp_out[],
        input string in_file,
        input int count
    );
        int N = 1 << size_log2;
        
        transform_skip <= 1'b0;
        comp <= 2'd0; // Luma for basic tests
        
        fork
            // Thread 1: Feed prediction array with random valid-skews
            begin
                for (int i = 0; i < N * N; i++) begin
                    pred_valid <= 1;
                    pred_pixel <= pred_in[i];
                    pred_x <= i % N;
                    pred_y <= i / N;
                    pred_last <= (i == (N * N) - 1);
                    
                    // Block until DUT accepts the data
                    do begin
                        @(posedge clk);
                    end while (!pred_ready);
                    
                    // Optional stall
                    if ($urandom % 100 < 15) begin
                        pred_valid <= 0;
                        repeat ($urandom % 3 + 1) @(posedge clk);
                    end
                end
                pred_valid <= 0;
            end
            
            // Thread 2: Feed residual array with random valid-skews
            begin
                for (int i = 0; i < N * N; i++) begin
                    res_valid <= 1;
                    res_coeff <= res_in[i];
                    res_x <= i % N;
                    res_y <= i / N;
                    res_last <= (i == (N * N) - 1);
                    
                    // Block until DUT accepts the data
                    do begin
                        @(posedge clk);
                    end while (!res_ready);
                    
                    // Optional stall
                    if ($urandom % 100 < 15) begin
                        res_valid <= 0;
                        repeat ($urandom % 3 + 1) @(posedge clk);
                    end
                end
                res_valid <= 0;
            end
            
            // Thread 3: Verify N*N reconstructed output
            begin
                for (int i = 0; i < N * N; i++) begin
                    int exp_idx;
                    do begin @(posedge clk); end while (!out_valid || !out_ready);
                    
                    // Protect against SIGSEGV if DUT outputs bad coordinates
                    if ($isunknown(out_x) || $isunknown(out_y) || out_x >= N || out_y >= N) begin
                        $display("FATAL [File %s, Block %0d]: Invalid coord (%0d,%0d)", in_file, count, out_x, out_y);
                        total_errors++;
                        break;
                    end

                    exp_idx = out_y * N + out_x;
                    
                    if (out_pixel !== exp_out[exp_idx]) begin
                        $display("ERROR [File %s, Block %0d]: expected val=%0d at (%0d,%0d), got val=%0d", 
                                 in_file, count, exp_out[exp_idx], out_x, out_y, out_pixel);
                        total_errors++;
                    end else begin
                        total_correct++;
                    end
                end
            end
        join
    endtask

    task automatic run_recon_test(int size_log2);
        int N = 1 << size_log2;
        
        int fd_pred, fd_res, fd_out;
        string fn_pred = $sformatf("recon_pred_in_%0d.dat", N);
        string fn_res = $sformatf("recon_res_in_%0d.dat", N);
        string fn_out = $sformatf("recon_out_%0d.dat", N);
        int count = 0;

        logic [9:0] pred_in[];
        logic signed [15:0] res_in[];
        logic [9:0] exp_out[];
        
        pred_in = new[N*N];
        res_in = new[N*N];
        exp_out = new[N*N];

        fd_pred = $fopen(fn_pred, "r");
        fd_res = $fopen(fn_res, "r");
        fd_out = $fopen(fn_out, "r");

        if (!fd_pred || !fd_res || !fd_out) begin
            $display("Warning: Cannot open some files for N=%0d, skipping test.", N);
            if (fd_pred) $fclose(fd_pred);
            if (fd_res) $fclose(fd_res);
            if (fd_out) $fclose(fd_out);
            return;
        end

        $display("Testing reconstruction for N=%0d...", N);

        while (!$feof(fd_pred) && !$feof(fd_res) && !$feof(fd_out)) begin
            int val_pred, val_res, val_out;
            int ret_pred, ret_res, ret_out;

            for (int i = 0; i < N * N; i++) begin
                ret_pred = $fscanf(fd_pred, "%x\n", val_pred);
                ret_res  = $fscanf(fd_res, "%x\n", val_res);
                ret_out  = $fscanf(fd_out, "%x\n", val_out);
                if (ret_pred != 1 || ret_res != 1 || ret_out != 1) break;
                
                // Mask to prevent 4-state X truncation bleeding in ModelSim
                pred_in[i] = val_pred & 10'h3FF;
                res_in[i]  = val_res & 16'hFFFF;
                exp_out[i] = val_out & 10'h3FF;
            end
            
            if (ret_pred == 1 && ret_res == 1 && ret_out == 1) begin
                test_block_from_file(size_log2, pred_in, res_in, exp_out, fn_pred, count);
                count++;
            end else begin
                break;
            end
        end

        $fclose(fd_pred);
        $fclose(fd_res);
        $fclose(fd_out);
        $display("Finished testing for N=%0d, total blocks: %0d", N, count);
    endtask

    initial begin
        pred_valid = 0; pred_pixel = 0; pred_x = 0; pred_y = 0; pred_last = 0;
        res_valid = 0; res_coeff = 0; res_x = 0; res_y = 0; res_last = 0;
        transform_skip = 0; comp = 0;
        rst_n = 0; @(negedge clk); rst_n = 1; @(negedge clk);

        $display("==================================================");
        $display(" Starting recon_unit Verification");
        $display("==================================================");

        run_recon_test(2); // 4x4
        run_recon_test(3); // 8x8
        run_recon_test(4); // 16x16
        run_recon_test(5); // 32x32

        $display("==================================================");
        if (total_errors == 0) $display(" === ALL TESTS PASSED ===");
        else                   $display(" === TESTS FAILED: %0d Errors ===", total_errors);
        $display("Total Correct Reconstructions: %0d", total_correct);
        $display("==================================================\n");
        $finish;
    end

endmodule