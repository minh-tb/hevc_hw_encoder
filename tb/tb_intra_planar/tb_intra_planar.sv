//=============================================================================
// tb_intra_planar.sv
// Testbench for HEVC Intra Planar Prediction
//=============================================================================

`timescale 1ns/1ps

module tb_intra_planar;

    // Signals
    logic         clk;
    logic         rst_n;
    logic [2:0]   pu_size_log2;

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
    intra_planar dut (
        .clk(clk),
        .rst_n(rst_n),
        .pu_size_log2(pu_size_log2),
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

    // HEVC Golden Model for Planar Prediction
    function automatic void compute_golden_planar(
        input logic [2:0] size_log2,
        input logic [9:0] ref_in[],
        output logic [9:0] pred_out[]
    );
        int N = 1 << size_log2;
        int refT[];
        int refL[];
        refT = new[N+1];
        refL = new[N+1];
        
        // Map 1D flattened ref buffer to top and left bounds
        for (int i=0; i<=N; i++) refT[i] = ref_in[1+i];         // ref[1..N+1]
        for (int i=0; i<=N; i++) refL[i] = ref_in[2*N+1+i];     // ref[2N+1..3N+1]
        
        pred_out = new[N*N];

        for (int y=0; y<N; y++) begin
            for (int x=0; x<N; x++) begin
                int hor = (N - 1 - x) * refL[y] + (x + 1) * refT[N];
                int ver = (N - 1 - y) * refT[x] + (y + 1) * refL[N];
                pred_out[y*N + x] = (hor + ver + N) >> (size_log2 + 1);
            end
        end
    endfunction

    task automatic test_block(int size_log2);
        int N = 1 << size_log2;
        int ref_count = 4*N + 1;
        logic [9:0] ref_in[];
        logic [9:0] exp_out[];
        ref_in = new[ref_count];
        
        for(int i=0; i<ref_count; i++) ref_in[i] = $urandom % 1024;
        
        compute_golden_planar(size_log2, ref_in, exp_out);
        pu_size_log2 <= size_log2;
        
        fork
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
            begin
                for (int y=0; y<N; y++) begin
                    for (int x=0; x<N; x++) begin
                        int idx = y*N + x;
                        do begin @(posedge clk); end while (!out_valid || !out_ready);
                        
                        if (out_pixel !== exp_out[idx] || out_x !== x || out_y !== y) begin
                            $display("ERROR [N=%0d]: expected val=%0d at (%0d,%0d), got val=%0d at (%0d,%0d)", 
                                     N, exp_out[idx], x, y, out_pixel, out_x, out_y);
                            total_errors++;
                        end else begin
                            total_correct++;
                        end
                    end
                end
            end
        join
    endtask

    initial begin
        in_valid = 0; in_sample = 0; in_idx = 0; in_last = 0;
        rst_n = 0; @(negedge clk); rst_n = 1; @(negedge clk);

        $display("==================================================");
        $display(" Starting intra_planar Verification");
        $display("==================================================");

        $display("Running tests for all block sizes...");
        for (int i=0; i<50; i++) test_block(($urandom%4)+2); // Tests random N=4,8,16,32

        $display("==================================================");
        if (total_errors == 0) $display(" === ALL TESTS PASSED ===");
        else                   $display(" === TESTS FAILED: %0d Errors ===", total_errors);
        $display("Total Correct Predictions: %0d", total_correct);
        $display("==================================================\n");
        $finish;
    end
endmodule