//=============================================================================
// tb_ref_sample_filter.sv
// Testbench for HEVC Reference Sample Filter
//=============================================================================

`timescale 1ns/1ps

module tb_ref_sample_filter;

    // Signals
    logic         clk;
    logic         rst_n;
    logic [2:0]   pu_size_log2;
    logic [5:0]   intra_mode;
    logic         is_luma;

    logic         in_valid;
    logic         in_ready;
    logic [9:0]   in_sample;
    logic [7:0]   in_idx;
    logic         in_last;

    logic         out_valid;
    logic         out_ready;
    logic [9:0]   out_sample;
    logic [7:0]   out_idx;
    logic         out_last;

    int total_errors = 0;

    // DUT
    ref_sample_filter dut (
        .clk(clk),
        .rst_n(rst_n),
        .pu_size_log2(pu_size_log2),
        .intra_mode(intra_mode),
        .is_luma(is_luma),
        .in_valid(in_valid),
        .in_ready(in_ready),
        .in_sample(in_sample),
        .in_idx(in_idx),
        .in_last(in_last),
        .out_valid(out_valid),
        .out_ready(out_ready),
        .out_sample(out_sample),
        .out_idx(out_idx),
        .out_last(out_last)
    );

    // Clock
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // Random Stall Generator
    always @(posedge clk) begin
        out_ready <= ($urandom % 100 < 80); // 80% ready rate to stress FSM
    end

    // HEVC Reference Model
    function automatic void compute_golden(
        input logic [2:0] size_log2,
        input logic [5:0] mode,
        input logic       luma,
        input logic [9:0] ref_in[],
        output logic [9:0] ref_out[]
    );
        int N = 1 << size_log2;
        int ref_count = 4*N + 1;
        int use_filter = 0;
        int use_strong = 0;
        ref_out = new[ref_count];
        
        if (luma) begin
            if (mode == 0 && N >= 8) use_filter = 1;
            else if (mode >= 2 && mode <= 34) begin
                int dist_v = (mode >= 26) ? (mode - 26) : (26 - mode);
                int dist_h = (mode >= 10) ? (mode - 10) : (10 - mode);
                int min_dist = (dist_v < dist_h) ? dist_v : dist_h;
                int thresh = (N==4)? 32 : (N==8)? 7 : (N==16)? 1 : 0;
                if (min_dist > thresh) use_filter = 1;
            end
        end
        
        if (luma && N == 32) begin
            int corner    = ref_in[0];
            int top_mid   = ref_in[N];
            int top_right = ref_in[2*N];
            int left_mid  = ref_in[3*N];
            int bot_left  = ref_in[4*N];
            
            int abs_top = top_right + corner - 2*top_mid;
            int abs_left = bot_left + corner - 2*left_mid;
            
            if (abs_top < 0) abs_top = -abs_top;
            if (abs_left < 0) abs_left = -abs_left;

            if (abs_top < 32 && abs_left < 32) begin
                use_strong = 1;
            end
        end
        
        for (int i = 0; i < ref_count; i++) begin
            if (!use_filter && !use_strong) begin
                ref_out[i] = ref_in[i];
            end else if (use_strong) begin
                if (i == 0 || i == 2*N || i == 4*N) ref_out[i] = ref_in[i];
                else if (i > 0 && i < 2*N) begin
                    ref_out[i] = ((2*N - i) * ref_in[0] + i * ref_in[2*N] + N) >> (size_log2 + 1);
                end else if (i > 2*N && i < 4*N) begin
                    int step = i - 2*N;
                    ref_out[i] = ((2*N - step) * ref_in[0] + step * ref_in[4*N] + N) >> (size_log2 + 1);
                end
            end else begin
                if (i == 2*N || i == 4*N) ref_out[i] = ref_in[i];
                else if (i == 0) ref_out[i] = (ref_in[2*N+1] + 2*ref_in[0] + ref_in[1] + 2) >> 2;
                else if (i == 2*N + 1) begin
                    ref_out[i] = (ref_in[0] + 2*ref_in[i] + ref_in[i+1] + 2) >> 2;
                end else begin
                    ref_out[i] = (ref_in[i-1] + 2*ref_in[i] + ref_in[i+1] + 2) >> 2;
                end
            end
        end
    endfunction

    task automatic test_block(int size_log2, int mode, int is_luma_flag, int force_strong);
        int N = 1 << size_log2;
        int ref_count = 4*N + 1;
        logic [9:0] ref_in[];
        logic [9:0] exp_out[];
        ref_in = new[ref_count];
        
        if (force_strong && N == 32) begin
            int corner = 500;
            int top_right = 700;
            int bot_left = 300;
            ref_in[0] = corner;
            for (int i=1; i<=2*N; i++) ref_in[i] = corner + (i*(top_right-corner))/(2*N) + ($urandom%5 - 2);
            for (int i=1; i<=2*N; i++) ref_in[2*N+i] = corner + (i*(bot_left-corner))/(2*N) + ($urandom%5 - 2);
        end else begin
            for(int i=0; i<ref_count; i++) ref_in[i] = $urandom % 1024;
        end
        
        compute_golden(size_log2, mode, is_luma_flag, ref_in, exp_out);
        
        pu_size_log2 <= size_log2;
        intra_mode   <= mode;
        is_luma      <= is_luma_flag;
        
        fork
            begin
                for (int i=0; i<ref_count; i++) begin
                    in_valid <= 1;
                    in_sample <= ref_in[i];
                    in_idx <= i;
                    in_last <= (i == ref_count - 1);
                    do begin
                        @(posedge clk);
                    end while (!in_ready);
                end
                in_valid <= 0;
            end
            begin
                for (int i=0; i<ref_count; i++) begin
                    do begin
                        @(posedge clk);
                    end while (!out_valid || !out_ready);
                    
                    if (out_sample !== exp_out[i] || out_idx !== i) begin
                        $display("ERROR [N=%0d, Mode %0d]: idx %0d expected %0d, got %0d (out_idx %0d)", 
                                 N, mode, i, exp_out[i], out_sample, out_idx);
                        total_errors++;
                    end
                end
            end
        join
    endtask

    initial begin
        in_valid = 0;
        in_sample = 0;
        in_idx = 0;
        in_last = 0;

        rst_n = 0;
        @(negedge clk);
        rst_n = 1;
        @(negedge clk);

        $display("==================================================");
        $display(" Starting ref_sample_filter Verification");
        $display("==================================================");

        $display("Testing 4x4 (No filter)...");
        test_block(2, 0, 1, 0); // 4x4 planar luma (no filter)
        
        $display("Testing 8x8 (Planar filter)...");
        test_block(3, 0, 1, 0); // 8x8 planar luma
        
        $display("Testing 16x16 (Angular filter)...");
        test_block(4, 26, 1, 0); // 16x16 pure vertical
        test_block(4, 18, 1, 0); // 16x16 diagonal (dist > 1)
        
        $display("Testing 32x32 (Strong smoothing)...");
        test_block(5, 0, 1, 1); // 32x32 forced strong

        $display("Testing Chroma (No filter)...");
        test_block(4, 0, 0, 0); // 16x16 chroma (should not filter)

        $display("Running 50 random test cases...");
        for (int i=0; i<50; i++) begin
            test_block(($urandom%4)+2, $urandom%35, $urandom%2, 0);
        end

        $display("==================================================");
        if (total_errors == 0) $display(" === ALL TESTS PASSED ===");
        else                   $display(" === TESTS FAILED: %0d Errors ===", total_errors);
        $display("==================================================\n");
        $finish;
    end

endmodule