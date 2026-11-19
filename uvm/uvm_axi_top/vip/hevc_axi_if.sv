`timescale 1ns / 1ps
//=============================================================================
// hevc_axi_if.sv
// SystemVerilog Interface & SVA Protocol Checkers for hevc_encoder_axi_top
//=============================================================================

interface hevc_axi_if (
    input logic clk,
    input logic rst_n
);

    //=========================================================================
    // AXI4-Lite Slave Interface (Control / Status Registers)
    //=========================================================================
    logic [11:0] s_axi_lite_awaddr;
    logic [2:0]  s_axi_lite_awprot;
    logic        s_axi_lite_awvalid;
    wire         s_axi_lite_awready;

    logic [31:0] s_axi_lite_wdata;
    logic [3:0]  s_axi_lite_wstrb;
    logic        s_axi_lite_wvalid;
    wire         s_axi_lite_wready;

    wire  [1:0]  s_axi_lite_bresp;
    wire         s_axi_lite_bvalid;
    logic        s_axi_lite_bready;

    logic [11:0] s_axi_lite_araddr;
    logic [2:0]  s_axi_lite_arprot;
    logic        s_axi_lite_arvalid;
    wire         s_axi_lite_arready;

    wire  [31:0] s_axi_lite_rdata;
    wire  [1:0]  s_axi_lite_rresp;
    wire         s_axi_lite_rvalid;
    logic        s_axi_lite_rready;

    //=========================================================================
    // AXI4-Stream Video Input (YUV 4:2:0)
    //=========================================================================
    logic [31:0] s_axis_video_tdata;
    logic        s_axis_video_tvalid;
    wire         s_axis_video_tready;
    logic        s_axis_video_tlast;
    logic        s_axis_video_tuser;

    //=========================================================================
    // AXI4-Stream Bitstream Output (Annex B Byte Stream)
    //=========================================================================
    wire  [7:0]  m_axis_bitstream_tdata;
    wire         m_axis_bitstream_tvalid;
    logic        m_axis_bitstream_tready;
    wire         m_axis_bitstream_tlast;

    //=========================================================================
    // AXI4 Full Master Memory Interface (256-bit DRAM)
    //=========================================================================
    wire  [0:0]   m_axi_mem_awid;
    wire  [32:0]  m_axi_mem_awaddr;
    wire  [7:0]   m_axi_mem_awlen;
    wire  [2:0]   m_axi_mem_awsize;
    wire  [1:0]   m_axi_mem_awburst;
    wire          m_axi_mem_awlock;
    wire  [3:0]   m_axi_mem_awcache;
    wire  [2:0]   m_axi_mem_awprot;
    wire  [3:0]   m_axi_mem_awqos;
    wire          m_axi_mem_awvalid;
    logic         m_axi_mem_awready;

    wire  [255:0] m_axi_mem_wdata;
    wire  [31:0]  m_axi_mem_wstrb;
    wire          m_axi_mem_wlast;
    wire          m_axi_mem_wvalid;
    logic         m_axi_mem_wready;

    logic [0:0]   m_axi_mem_bid;
    logic [1:0]   m_axi_mem_bresp;
    logic         m_axi_mem_bvalid;
    wire          m_axi_mem_bready;

    wire  [0:0]   m_axi_mem_arid;
    wire  [32:0]  m_axi_mem_araddr;
    wire  [7:0]   m_axi_mem_arlen;
    wire  [2:0]   m_axi_mem_arsize;
    wire  [1:0]   m_axi_mem_arburst;
    wire          m_axi_mem_arlock;
    wire  [3:0]   m_axi_mem_arcache;
    wire  [2:0]   m_axi_mem_arprot;
    wire  [3:0]   m_axi_mem_arqos;
    wire          m_axi_mem_arvalid;
    logic         m_axi_mem_arready;

    logic [0:0]   m_axi_mem_rid;
    logic [255:0] m_axi_mem_rdata;
    logic [1:0]   m_axi_mem_rresp;
    logic         m_axi_mem_rlast;
    logic         m_axi_mem_rvalid;
    wire          m_axi_mem_rready;

    //=========================================================================
    // Interrupt Output
    //=========================================================================
    wire         irq;

    //=========================================================================
    // Deterministic Time-0 Initialization for TB-Driven Inputs
    //=========================================================================
    initial begin
        s_axi_lite_awaddr       = 12'd0;
        s_axi_lite_awprot       = 3'd0;
        s_axi_lite_awvalid      = 1'b0;
        s_axi_lite_wdata        = 32'd0;
        s_axi_lite_wstrb        = 4'd0;
        s_axi_lite_wvalid       = 1'b0;
        s_axi_lite_bready       = 1'b0;
        s_axi_lite_araddr       = 12'd0;
        s_axi_lite_arprot       = 3'd0;
        s_axi_lite_arvalid      = 1'b0;
        s_axi_lite_rready       = 1'b0;

        s_axis_video_tdata      = 32'd0;
        s_axis_video_tvalid     = 1'b0;
        s_axis_video_tlast      = 1'b0;
        s_axis_video_tuser      = 1'b0;

        m_axis_bitstream_tready = 1'b1;

        m_axi_mem_awready       = 1'b1;
        m_axi_mem_wready        = 1'b1;
        m_axi_mem_bid           = 1'b0;
        m_axi_mem_bresp         = 2'b00;
        m_axi_mem_bvalid        = 1'b0;
        m_axi_mem_arready       = 1'b1;
        m_axi_mem_rid           = 1'b0;
        m_axi_mem_rdata         = 256'd0;
        m_axi_mem_rresp         = 2'b00;
        m_axi_mem_rlast         = 1'b0;
        m_axi_mem_rvalid        = 1'b0;
    end

    //=========================================================================
    // SVA Protocol Assertions (Vivado xsim compatible)
    //=========================================================================
    property p_axis_video_hold;
        @(posedge clk) disable iff (!rst_n)
        (s_axis_video_tvalid && !s_axis_video_tready) |=>
            ($stable(s_axis_video_tdata) &&
             $stable(s_axis_video_tlast) &&
             s_axis_video_tvalid);
    endproperty

    property p_axis_bitstream_hold;
        @(posedge clk) disable iff (!rst_n)
        (m_axis_bitstream_tvalid && !m_axis_bitstream_tready) |=>
            ($stable(m_axis_bitstream_tdata) &&
             $stable(m_axis_bitstream_tlast) &&
             m_axis_bitstream_tvalid);
    endproperty

    property p_axi_lite_bresp_okay;
        @(posedge clk) disable iff (!rst_n)
        s_axi_lite_bvalid |-> (s_axi_lite_bresp == 2'b00);
    endproperty

    property p_axi_lite_rresp_okay;
        @(posedge clk) disable iff (!rst_n)
        s_axi_lite_rvalid |-> (s_axi_lite_rresp == 2'b00);
    endproperty

    assert_axis_video_hold: assert property (p_axis_video_hold)
        else $error("[SVA] s_axis_video violated AXI-Stream stability during backpressure");

    assert_axis_bitstream_hold: assert property (p_axis_bitstream_hold)
        else $error("[SVA] m_axis_bitstream violated AXI-Stream stability during backpressure");

    assert_axi_lite_bresp_okay: assert property (p_axi_lite_bresp_okay)
        else $error("[SVA] s_axi_lite_bresp != OKAY (2'b00) when bvalid asserted: %b", s_axi_lite_bresp);

    assert_axi_lite_rresp_okay: assert property (p_axi_lite_rresp_okay)
        else $error("[SVA] s_axi_lite_rresp != OKAY (2'b00) when rvalid asserted: %b", s_axi_lite_rresp);

endinterface
