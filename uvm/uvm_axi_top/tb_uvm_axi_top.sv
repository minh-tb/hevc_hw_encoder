`timescale 1ns / 1ps
//=============================================================================
// tb_uvm_axi_top.sv
// Phase 3 UVM SoC Integration Testbench Top Harness for hevc_encoder_axi_top
//=============================================================================

module tb_uvm_axi_top;

    import uvm_pkg::*;
    `include "uvm_macros.svh"
    import hevc_ral_pkg::*;
    import hevc_axi_vip_pkg::*;
    import hevc_axi_env_pkg::*;
    import hevc_axi_tests_pkg::*;

    localparam time CLK_HALF_PERIOD = 10ns; // 50 MHz (20 ns period)

    logic clk;
    logic rst_n;

    // 50 MHz Clock Generator
    initial begin
        clk = 1'b0;
        forever #CLK_HALF_PERIOD clk = ~clk;
    end

    // Synchronous Active-Low Reset Release
    initial begin
        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
    end

    // Generous Watchdog Timeout (50 ms)
    initial begin
        #50_000_000;
        `uvm_fatal("TB_TOP", "Simulation timeout (50 ms) reached - possible deadlock!")
    end

    // SoC Virtual Interface & Protocol Assertions
    hevc_axi_if vif (
        .clk   (clk),
        .rst_n (rst_n)
    );

    // DUT Instantiation
    hevc_encoder_axi_top #(
        .FRAME_WIDTH         (64),
        .FRAME_HEIGHT        (64),
        .GOP_STRUCTURE       (0),
        .BASE_QP             (28),
        .RC_ENABLE           (0),
        .TARGET_BITRATE_KBPS (5000)
    ) dut (
        .clk                     (clk),
        .rst_n                   (rst_n),

        .s_axi_lite_awaddr       (vif.s_axi_lite_awaddr),
        .s_axi_lite_awprot       (vif.s_axi_lite_awprot),
        .s_axi_lite_awvalid      (vif.s_axi_lite_awvalid),
        .s_axi_lite_awready      (vif.s_axi_lite_awready),

        .s_axi_lite_wdata        (vif.s_axi_lite_wdata),
        .s_axi_lite_wstrb        (vif.s_axi_lite_wstrb),
        .s_axi_lite_wvalid       (vif.s_axi_lite_wvalid),
        .s_axi_lite_wready       (vif.s_axi_lite_wready),

        .s_axi_lite_bresp        (vif.s_axi_lite_bresp),
        .s_axi_lite_bvalid       (vif.s_axi_lite_bvalid),
        .s_axi_lite_bready       (vif.s_axi_lite_bready),

        .s_axi_lite_araddr       (vif.s_axi_lite_araddr),
        .s_axi_lite_arprot       (vif.s_axi_lite_arprot),
        .s_axi_lite_arvalid      (vif.s_axi_lite_arvalid),
        .s_axi_lite_arready      (vif.s_axi_lite_arready),

        .s_axi_lite_rdata        (vif.s_axi_lite_rdata),
        .s_axi_lite_rresp        (vif.s_axi_lite_rresp),
        .s_axi_lite_rvalid       (vif.s_axi_lite_rvalid),
        .s_axi_lite_rready       (vif.s_axi_lite_rready),

        .s_axis_video_tdata      (vif.s_axis_video_tdata),
        .s_axis_video_tvalid     (vif.s_axis_video_tvalid),
        .s_axis_video_tready     (vif.s_axis_video_tready),
        .s_axis_video_tlast      (vif.s_axis_video_tlast),
        .s_axis_video_tuser      (vif.s_axis_video_tuser),

        .m_axis_bitstream_tdata  (vif.m_axis_bitstream_tdata),
        .m_axis_bitstream_tvalid (vif.m_axis_bitstream_tvalid),
        .m_axis_bitstream_tready (vif.m_axis_bitstream_tready),
        .m_axis_bitstream_tlast  (vif.m_axis_bitstream_tlast),

        .m_axi_mem_awid          (vif.m_axi_mem_awid),
        .m_axi_mem_awaddr        (vif.m_axi_mem_awaddr),
        .m_axi_mem_awlen         (vif.m_axi_mem_awlen),
        .m_axi_mem_awsize        (vif.m_axi_mem_awsize),
        .m_axi_mem_awburst       (vif.m_axi_mem_awburst),
        .m_axi_mem_awlock        (vif.m_axi_mem_awlock),
        .m_axi_mem_awcache       (vif.m_axi_mem_awcache),
        .m_axi_mem_awprot        (vif.m_axi_mem_awprot),
        .m_axi_mem_awqos         (vif.m_axi_mem_awqos),
        .m_axi_mem_awvalid       (vif.m_axi_mem_awvalid),
        .m_axi_mem_awready       (vif.m_axi_mem_awready),

        .m_axi_mem_wdata         (vif.m_axi_mem_wdata),
        .m_axi_mem_wstrb         (vif.m_axi_mem_wstrb),
        .m_axi_mem_wlast         (vif.m_axi_mem_wlast),
        .m_axi_mem_wvalid        (vif.m_axi_mem_wvalid),
        .m_axi_mem_wready        (vif.m_axi_mem_wready),

        .m_axi_mem_bid           (vif.m_axi_mem_bid),
        .m_axi_mem_bresp         (vif.m_axi_mem_bresp),
        .m_axi_mem_bvalid        (vif.m_axi_mem_bvalid),
        .m_axi_mem_bready        (vif.m_axi_mem_bready),

        .m_axi_mem_arid          (vif.m_axi_mem_arid),
        .m_axi_mem_araddr        (vif.m_axi_mem_araddr),
        .m_axi_mem_arlen         (vif.m_axi_mem_arlen),
        .m_axi_mem_arsize        (vif.m_axi_mem_arsize),
        .m_axi_mem_arburst       (vif.m_axi_mem_arburst),
        .m_axi_mem_arlock        (vif.m_axi_mem_arlock),
        .m_axi_mem_arcache       (vif.m_axi_mem_arcache),
        .m_axi_mem_arprot        (vif.m_axi_mem_arprot),
        .m_axi_mem_arqos         (vif.m_axi_mem_arqos),
        .m_axi_mem_arvalid       (vif.m_axi_mem_arvalid),
        .m_axi_mem_arready       (vif.m_axi_mem_arready),

        .m_axi_mem_rid           (vif.m_axi_mem_rid),
        .m_axi_mem_rdata         (vif.m_axi_mem_rdata),
        .m_axi_mem_rresp         (vif.m_axi_mem_rresp),
        .m_axi_mem_rlast         (vif.m_axi_mem_rlast),
        .m_axi_mem_rvalid        (vif.m_axi_mem_rvalid),
        .m_axi_mem_rready        (vif.m_axi_mem_rready),

        .irq                     (vif.irq)
    );

    initial begin
        uvm_config_db #(virtual hevc_axi_if)::set(null, "*", "vif", vif);
        run_test();
    end

endmodule
