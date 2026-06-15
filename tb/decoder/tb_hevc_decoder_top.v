`timescale 1ns / 1ps

module tb_hevc_decoder_top;

    reg clk;
    reg rst_n;

    // Clock generation
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // Reset generation
    initial begin
        rst_n = 0;
        #20 rst_n = 1;
        #100;
        $display("Decoder Elaboration Successful!");
        $finish;
    end

    // DUT instantiation
    hevc_decoder_top dut (
        .clk(clk),
        .rst_n(rst_n),
        .bs_valid(1'b0),
        .bs_ready(),
        .bs_byte(8'd0),
        .bs_last(1'b0),
        .out_valid(),
        .out_ready(1'b1),
        .out_pixel_y(),
        .out_pixel_u(),
        .out_pixel_v(),
        .out_frame_last(),
        .axi_awvalid(),
        .axi_awready(1'b1),
        .axi_awaddr(),
        .axi_awlen(),
        .axi_awsize(),
        .axi_awburst(),
        .axi_wvalid(),
        .axi_wready(1'b1),
        .axi_wdata(),
        .axi_wstrb(),
        .axi_wlast(),
        .axi_bvalid(1'b0),
        .axi_bready(),
        .axi_arvalid(),
        .axi_arready(1'b1),
        .axi_araddr(),
        .axi_arlen(),
        .axi_arsize(),
        .axi_arburst(),
        .axi_rvalid(1'b0),
        .axi_rready(),
        .axi_rdata(256'd0),
        .axi_rlast(1'b0)
    );

endmodule
