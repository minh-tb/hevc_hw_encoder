//=============================================================================
// tb_sao_stats.sv
// Standalone Verification Testbench for sao_stats Multi-Mode RDO Decision
//=============================================================================

`timescale 1ns/1ps
`include "parameter_pkg.vh"

module tb_sao_stats;

    logic        clk;
    logic        rst_n;
    logic        start;
    logic        done;

    logic        rec_rd_valid;
    logic [5:0]  rec_rd_x;
    logic [5:0]  rec_rd_y;
    logic [1:0]  rec_rd_comp;
    logic [9:0]  rec_resp_data;

    logic        org_rd_valid;
    logic [5:0]  org_rd_x;
    logic [5:0]  org_rd_y;
    logic [1:0]  org_rd_comp;
    logic [9:0]  org_resp_data;

    logic [5:0]  sao_type;
    logic [5:0]  eo_class;
    logic [74:0] eo_offset;
    logic [14:0] band_pos;
    logic [59:0] bo_offset;

    logic [5:0]  ctu_x = 0;
    logic [5:0]  ctu_y = 0;
    logic [11:0] frame_width_px = 0;
    logic [11:0] frame_height_px = 0;

    // Instantiate with SINGLE_PASS_CAUSAL_SYNC = 0 for full RDO decision testing
    sao_stats #(
        .SINGLE_PASS_CAUSAL_SYNC(0)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .done(done),
        .ctu_x(ctu_x),
        .ctu_y(ctu_y),
        .frame_width_px(frame_width_px),
        .frame_height_px(frame_height_px),
        .rec_rd_valid(rec_rd_valid),
        .rec_rd_x(rec_rd_x),
        .rec_rd_y(rec_rd_y),
        .rec_rd_comp(rec_rd_comp),
        .rec_resp_data(rec_resp_data),
        .org_rd_valid(org_rd_valid),
        .org_rd_x(org_rd_x),
        .org_rd_y(org_rd_y),
        .org_rd_comp(org_rd_comp),
        .org_resp_data(org_resp_data),
        .sao_type(sao_type),
        .eo_class(eo_class),
        .eo_offset(eo_offset),
        .band_pos(band_pos),
        .bo_offset(bo_offset)
    );

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    int test_mode = 0; // 0=zero diff, 1=BO bias, 2=EO pattern
    int total_errors = 0;

    // Mock responder with 1-cycle latency
    always @(posedge clk) begin
        case (test_mode)
            0: rec_resp_data <= 10'd512;
            1: rec_resp_data <= 10'd500;
            2: rec_resp_data <= (rec_rd_x[4] ? 10'd513 : 10'd511);
            default: rec_resp_data <= 10'd512;
        endcase
        case (test_mode)
            0: org_resp_data <= 10'd512;
            1: org_resp_data <= 10'd540; // bias > 32
            2: org_resp_data <= 10'd512;
            default: org_resp_data <= 10'd512;
        endcase
    end

    task automatic run_case(int mode, string name, logic [5:0] exp_type);
        test_mode = mode;
        repeat(5) @(posedge clk);
        start = 1'b1;
        @(posedge clk);
        start = 1'b0;

        while (!done) @(posedge clk);
        @(posedge clk);

        $display("Testing %s: sao_type=%b, eo_class=%b", name, sao_type, eo_class);
        if (sao_type !== exp_type) begin
            $display("[ERROR] Expected sao_type=%b, got %b", exp_type, sao_type);
            total_errors++;
        end else begin
            $display("[PASS] Correct sao_type: %b", sao_type);
        end

        // Verify shared Cb/Cr type & eo_class
        if (sao_type[5:4] !== sao_type[3:2]) begin
            $display("[ERROR] Cb/Cr sao_type mismatch: Cb=%b, Cr=%b", sao_type[3:2], sao_type[5:4]);
            total_errors++;
        end
        if (eo_class[5:4] !== eo_class[3:2]) begin
            $display("[ERROR] Cb/Cr eo_class mismatch: Cb=%b, Cr=%b", eo_class[3:2], eo_class[5:4]);
            total_errors++;
        end
    endtask

    initial begin
        rst_n = 0;
        start = 0;
        rec_resp_data = 0;
        org_resp_data = 0;
        repeat(5) @(posedge clk);
        rst_n = 1;
        repeat(5) @(posedge clk);

        $display("=== Starting SAO Stats RDO Verification ===");

        // Test 1: Zero distortion -> OFF (sao_type == 6'd0)
        run_case(0, "Zero Distortion (OFF)", 6'b00_00_00);

        // Test 2: Large DC bias -> BO (sao_type == 6'b10_10_10)
        run_case(1, "Large Bias (BO)", 6'b10_10_10);

        // Test 3: Alternating edge pattern -> EO (sao_type == 6'b01_01_01)
        run_case(2, "Alternating Edge (EO)", 6'b01_01_01);

        $display("=== SAO Stats Verification Completed ===");
        if (total_errors == 0)
            $display(">> SUCCESS: All SAO Stats RDO tests passed with 0 errors!");
        else
            $display(">> FAILURE: %0d errors detected.", total_errors);

        $finish;
    end

endmodule
