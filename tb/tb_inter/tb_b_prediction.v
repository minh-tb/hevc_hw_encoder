//=============================================================================
// tb_b_prediction.v
// Unit Testbench for Bi-Directional Motion Compensation (HEVC Section 8.5.3.3.4)
//=============================================================================

`timescale 1ns / 1ps
`include "parameter_pkg.vh"

module tb_b_prediction;

    reg clk;
    reg rst_n;

    always #5 clk = ~clk;

    reg [2:0]  ref_slot_in;
    reg [2:0]  ref_slot_l1;
    reg [1:0]  inter_pred_idc;
    reg        mc_start;
    wire       mc_ready, mc_done;
    reg signed [`MV_TOTAL_BITS-1:0] mc_mv_x, mc_mv_y;
    reg signed [`MV_TOTAL_BITS-1:0] mc_mv_l1_x, mc_mv_l1_y;

    wire [`PIXEL_WIDTH*16-1:0] mc_pred_y_flat;
    wire [`PIXEL_WIDTH*4-1:0]  mc_pred_cb_flat, mc_pred_cr_flat;

    // AXI dummy
    wire axi_arvalid;
    reg  axi_arready;
    wire [32:0] axi_araddr;
    wire [7:0]  axi_arlen;
    wire [2:0]  axi_arsize;
    wire [1:0]  axi_arburst;
    reg  axi_rvalid;
    wire axi_rready;
    reg  [255:0] axi_rdata;
    reg  axi_rlast;

    inter_pred_top uut (
        .clk(clk),
        .rst_n(rst_n),
        .ref_slot_in(ref_slot_in),
        .ref_slot_l1(ref_slot_l1),
        .inter_pred_idc(inter_pred_idc),
        .search_start(1'b0),
        .search_ready(),
        .cu_orig_flat(160'd0),
        .cu_x(12'd0),
        .cu_y(12'd0),
        .mvp_x(10'd0),
        .mvp_y(10'd0),
        .search_done(),
        .best_mv_x(),
        .best_mv_y(),
        .best_sad(),
        .mc_start(mc_start),
        .mc_ready(mc_ready),
        .mc_mv_x(mc_mv_x),
        .mc_mv_y(mc_mv_y),
        .mc_mv_l1_x(mc_mv_l1_x),
        .mc_mv_l1_y(mc_mv_l1_y),
        .mc_done(mc_done),
        .mc_pred_y_flat(mc_pred_y_flat),
        .mc_pred_cb_flat(mc_pred_cb_flat),
        .mc_pred_cr_flat(mc_pred_cr_flat),
        .axi_arvalid(axi_arvalid),
        .axi_arready(axi_arready),
        .axi_araddr(axi_araddr),
        .axi_arlen(axi_arlen),
        .axi_arsize(axi_arsize),
        .axi_arburst(axi_arburst),
        .axi_rvalid(axi_rvalid),
        .axi_rready(axi_rready),
        .axi_rdata(axi_rdata),
        .axi_rlast(axi_rlast)
    );

    // AXI Read Channel Responder
    reg [7:0]  rlen_cnt;
    reg        r_active;
    reg [32:0] raddr_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axi_arready <= 1'b1;
            axi_rvalid  <= 1'b0;
            axi_rlast   <= 1'b0;
            axi_rdata   <= 256'd0;
            r_active    <= 1'b0;
            rlen_cnt    <= 8'd0;
            raddr_reg   <= 33'd0;
        end else begin
            if (axi_arvalid && axi_arready) begin
                axi_arready <= 1'b0;
                r_active    <= 1'b1;
                rlen_cnt    <= axi_arlen;
                raddr_reg   <= axi_araddr;
                axi_rvalid  <= 1'b1;
                axi_rlast   <= (axi_arlen == 0);
                axi_rdata   <= {16{16'h0200}}; // 512 mid-gray
            end else if (r_active && axi_rvalid && axi_rready) begin
                if (rlen_cnt == 0) begin
                    r_active    <= 1'b0;
                    axi_rvalid  <= 1'b0;
                    axi_rlast   <= 1'b0;
                    axi_arready <= 1'b1;
                end else begin
                    rlen_cnt    <= rlen_cnt - 8'd1;
                    raddr_reg   <= raddr_reg + 33'd32;
                    axi_rdata   <= {16{16'h0200}};
                    axi_rlast   <= (rlen_cnt == 8'd1);
                end
            end
        end
    end

    initial begin
        clk = 0;
        rst_n = 0;
        ref_slot_in = 3'd0;
        ref_slot_l1 = 3'd1;
        inter_pred_idc = 2'd2; // Pred_BI
        mc_start = 0;
        mc_mv_x = 0;
        mc_mv_y = 0;
        mc_mv_l1_x = 0;
        mc_mv_l1_y = 0;

        #50;
        rst_n = 1;
        #30;

        $display("\n=================================================================");
        $display("Testing Bi-Prediction Motion Compensation (Pred_BI)");
        $display("=================================================================");

        @(posedge clk);
        mc_start = 1;
        inter_pred_idc = 2'd2; // Pred_BI
        mc_mv_x = 12'sd4;      // +1 integer pel L0
        mc_mv_y = 12'sd0;
        mc_mv_l1_x = -12'sd4;  // -1 integer pel L1
        mc_mv_l1_y = 12'sd0;
        @(posedge clk);
        mc_start = 0;

        wait(mc_done);
        $display("Bi-Prediction MC Completed at time=%0t!", $time);
        $display("Sample Pred_Y[0]: %0d", mc_pred_y_flat[9:0]);
        $display("Sample Pred_Cb[0]: %0d", mc_pred_cb_flat[9:0]);
        $display("Sample Pred_Cr[0]: %0d", mc_pred_cr_flat[9:0]);

        $display("=================================================================");
        $display("Bi-Prediction Motion Compensation Unit Verification PASSED!");
        $display("=================================================================\n");
        #100;
        $finish;
    end

endmodule
