`timescale 1ns / 1ps
//=============================================================================
// hevc_encoder_axi_top.v
// SoC Integration Top-Level Wrapper for HEVC/H.265 Hardware Video Encoder
//
// Interfaces:
//   - s_axi_lite:       AXI4-Lite Slave (Control / Status Registers)
//   - s_axis_video:     AXI4-Stream Slave (YUV 4:2:0 Video Pixel Input)
//   - m_axis_bitstream: AXI4-Stream Master (Annex B Bitstream Byte Output)
//   - m_axi_mem:        AXI4 Full Master (External DRAM for Reference Frames)
//   - irq:              Interrupt Output (Level/Pulse to Host Processor)
//
// Register Map (s_axi_lite, 32-bit registers):
//   0x00: Control Register (RW)
//         bit [0]: START (Write 1 triggers encode_start pulse, self-clearing)
//         bit [1]: SOFT_RESET (Active high soft reset to core)
//         bit [2]: IRQ_EN (1 = Enable interrupt assertion on completion)
//   0x04: Status Register (RO)
//         bit [0]: DONE (Encode completed)
//         bit [1]: BUSY (Encoder is running)
//         bit [2]: READY (Encoder idle, ready for start)
//   0x08: IRQ Status & Acknowledge (RW)
//         bit [0]: IRQ_STATUS (Read: irq pending; Write 1: clear interrupt)
//   0x0C: Total Frames (RW, default: 1)
//         bits [15:0]: total_frames to encode
//   0x10: Base QP (RW, default: BASE_QP parameter)
//         bits [5:0]: base_qp [0..51]
//   0x14: GOP Structure (RW, default: GOP_STRUCTURE parameter)
//         bits [1:0]: 0=IPP, 1=IPBB (Low-Delay B), 2=Hierarchical B
//   0x18: Target Bitrate (RW, default: TARGET_BITRATE_KBPS parameter)
//         bits [15:0]: target_bitrate_kbps
//   0x1C: Magic ID (RO)
//         bits [31:0]: 0x48455643 (ASCII "HEVC")
//   0x20: Resolution (RO)
//         bits [31:16]: FRAME_WIDTH
//         bits [15:0]:  FRAME_HEIGHT
//=============================================================================

`include "parameter_pkg.vh"
`include "hevc_interfaces.vh"

module hevc_encoder_axi_top #(
    // Video Encoder Core Parameters
    parameter FRAME_WIDTH                 = `DEFAULT_FRAME_WIDTH,
    parameter FRAME_HEIGHT                = `DEFAULT_FRAME_HEIGHT,
    parameter GOP_STRUCTURE               = `DEFAULT_GOP_STRUCTURE,
    parameter [5:0]  BASE_QP              = `QP_DEFAULT,
    parameter        RC_ENABLE            = `RATE_CONTROL,
    parameter [15:0] TARGET_BITRATE_KBPS  = `TARGET_BITRATE_DEFAULT,

    // Bus Width Parameters
    parameter C_S_AXI_LITE_DATA_WIDTH     = 32,
    parameter C_S_AXI_LITE_ADDR_WIDTH     = 12,
    parameter C_S_AXIS_VIDEO_DATA_WIDTH   = 32,
    parameter C_M_AXIS_BITSTREAM_DATA_WIDTH = 8,
    parameter C_M_AXI_MEM_ID_WIDTH        = 1,
    parameter C_M_AXI_MEM_ADDR_WIDTH      = 33,
    parameter C_M_AXI_MEM_DATA_WIDTH      = 256
)(
    // Global Clock & Reset
    input  wire                                         clk,
    input  wire                                         rst_n,

    //=========================================================================
    // AXI4-Lite Slave Interface (Control and Status Registers)
    //=========================================================================
    input  wire [C_S_AXI_LITE_ADDR_WIDTH-1:0]           s_axi_lite_awaddr,
    input  wire [2:0]                                   s_axi_lite_awprot,
    input  wire                                         s_axi_lite_awvalid,
    output wire                                         s_axi_lite_awready,

    input  wire [C_S_AXI_LITE_DATA_WIDTH-1:0]           s_axi_lite_wdata,
    input  wire [(C_S_AXI_LITE_DATA_WIDTH/8)-1:0]       s_axi_lite_wstrb,
    input  wire                                         s_axi_lite_wvalid,
    output wire                                         s_axi_lite_wready,

    output wire [1:0]                                   s_axi_lite_bresp,
    output wire                                         s_axi_lite_bvalid,
    input  wire                                         s_axi_lite_bready,

    input  wire [C_S_AXI_LITE_ADDR_WIDTH-1:0]           s_axi_lite_araddr,
    input  wire [2:0]                                   s_axi_lite_arprot,
    input  wire                                         s_axi_lite_arvalid,
    output wire                                         s_axi_lite_arready,

    output wire [C_S_AXI_LITE_DATA_WIDTH-1:0]           s_axi_lite_rdata,
    output wire [1:0]                                   s_axi_lite_rresp,
    output wire                                         s_axi_lite_rvalid,
    input  wire                                         s_axi_lite_rready,

    //=========================================================================
    // AXI4-Stream Video Input (YUV 4:2:0)
    //=========================================================================
    input  wire [C_S_AXIS_VIDEO_DATA_WIDTH-1:0]         s_axis_video_tdata,
    input  wire                                         s_axis_video_tvalid,
    output wire                                         s_axis_video_tready,
    input  wire                                         s_axis_video_tlast,
    input  wire                                         s_axis_video_tuser,

    //=========================================================================
    // AXI4-Stream Bitstream Output (Annex B Stream)
    //=========================================================================
    output wire [C_M_AXIS_BITSTREAM_DATA_WIDTH-1:0]     m_axis_bitstream_tdata,
    output wire                                         m_axis_bitstream_tvalid,
    input  wire                                         m_axis_bitstream_tready,
    output wire                                         m_axis_bitstream_tlast,

    //=========================================================================
    // AXI4 Master Memory Interface (Reference Frames in DRAM)
    //=========================================================================
    // Write Address Channel
    output wire [C_M_AXI_MEM_ID_WIDTH-1:0]              m_axi_mem_awid,
    output wire [C_M_AXI_MEM_ADDR_WIDTH-1:0]            m_axi_mem_awaddr,
    output wire [7:0]                                   m_axi_mem_awlen,
    output wire [2:0]                                   m_axi_mem_awsize,
    output wire [1:0]                                   m_axi_mem_awburst,
    output wire                                         m_axi_mem_awlock,
    output wire [3:0]                                   m_axi_mem_awcache,
    output wire [2:0]                                   m_axi_mem_awprot,
    output wire [3:0]                                   m_axi_mem_awqos,
    output wire                                         m_axi_mem_awvalid,
    input  wire                                         m_axi_mem_awready,

    // Write Data Channel
    output wire [C_M_AXI_MEM_DATA_WIDTH-1:0]            m_axi_mem_wdata,
    output wire [(C_M_AXI_MEM_DATA_WIDTH/8)-1:0]        m_axi_mem_wstrb,
    output wire                                         m_axi_mem_wlast,
    output wire                                         m_axi_mem_wvalid,
    input  wire                                         m_axi_mem_wready,

    // Write Response Channel
    input  wire [C_M_AXI_MEM_ID_WIDTH-1:0]              m_axi_mem_bid,
    input  wire [1:0]                                   m_axi_mem_bresp,
    input  wire                                         m_axi_mem_bvalid,
    output wire                                         m_axi_mem_bready,

    // Read Address Channel
    output wire [C_M_AXI_MEM_ID_WIDTH-1:0]              m_axi_mem_arid,
    output wire [C_M_AXI_MEM_ADDR_WIDTH-1:0]            m_axi_mem_araddr,
    output wire [7:0]                                   m_axi_mem_arlen,
    output wire [2:0]                                   m_axi_mem_arsize,
    output wire [1:0]                                   m_axi_mem_arburst,
    output wire                                         m_axi_mem_arlock,
    output wire [3:0]                                   m_axi_mem_arcache,
    output wire [2:0]                                   m_axi_mem_arprot,
    output wire [3:0]                                   m_axi_mem_arqos,
    output wire                                         m_axi_mem_arvalid,
    input  wire                                         m_axi_mem_arready,

    // Read Data Channel
    input  wire [C_M_AXI_MEM_ID_WIDTH-1:0]              m_axi_mem_rid,
    input  wire [C_M_AXI_MEM_DATA_WIDTH-1:0]            m_axi_mem_rdata,
    input  wire [1:0]                                   m_axi_mem_rresp,
    input  wire                                         m_axi_mem_rlast,
    input  wire                                         m_axi_mem_rvalid,
    output wire                                         m_axi_mem_rready,

    //=========================================================================
    // Interrupt Output
    //=========================================================================
    output wire                                         irq
);

    //=========================================================================
    // Internal Core Interface Signals
    //=========================================================================
    wire        core_rst_n;
    wire        core_encode_done;
    wire        core_frame_done;
    reg         encode_start_pulse;
    wire [7:0]  core_out_byte;
    wire        core_out_valid;
    wire        core_out_ready;

    wire [32:0] core_axi_awaddr;
    wire [32:0] core_axi_araddr;

    //=========================================================================
    // AXI4-Lite CSR Registers
    //=========================================================================
    reg        axi_awready;
    reg        axi_wready;
    reg [1:0]  axi_bresp;
    reg        axi_bvalid;

    reg        axi_arready;
    reg [31:0] axi_rdata;
    reg [1:0]  axi_rresp;
    reg        axi_rvalid;

    reg        reg_soft_rst;
    reg        reg_irq_en;
    reg        reg_busy;
    reg        reg_done;
    reg        irq_status;
    reg        prev_encode_done;

    reg [15:0] reg_total_frames;
    reg [5:0]  reg_base_qp;
    reg [1:0]  reg_gop_structure;
    reg [15:0] reg_target_bitrate_kbps;
    reg        reg_rc_enable;
    reg        reg_sao_enable;
    wire [15:0] status_vbv_fullness_pct;

    // Active-low soft reset combined with hardware pin reset
    assign core_rst_n = rst_n & (~reg_soft_rst);

    // Interrupt output: asserted if enabled and event pending
    assign irq = reg_irq_en & irq_status;

    //-------------------------------------------------------------------------
    // AXI-Lite Write Address and Data Handshake
    //-------------------------------------------------------------------------
    wire slv_wren = s_axi_lite_awvalid && s_axi_lite_wvalid && (!axi_awready) && (!axi_bvalid || s_axi_lite_bready);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axi_awready <= 1'b0;
            axi_wready  <= 1'b0;
            axi_bvalid  <= 1'b0;
            axi_bresp   <= 2'b00;
        end else begin
            if (slv_wren) begin
                axi_awready <= 1'b1;
                axi_wready  <= 1'b1;
                axi_bvalid  <= 1'b1;
                axi_bresp   <= 2'b00; // OKAY
            end else begin
                axi_awready <= 1'b0;
                axi_wready  <= 1'b0;
                if (s_axi_lite_bready && axi_bvalid) begin
                    axi_bvalid <= 1'b0;
                end
            end
        end
    end

    assign s_axi_lite_awready = axi_awready;
    assign s_axi_lite_wready  = axi_wready;
    assign s_axi_lite_bvalid  = axi_bvalid;
    assign s_axi_lite_bresp   = axi_bresp;

    //-------------------------------------------------------------------------
    // Register Writes
    //-------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            encode_start_pulse      <= 1'b0;
            reg_soft_rst            <= 1'b0;
            reg_irq_en              <= 1'b0;
            reg_total_frames        <= 16'd1;
            reg_base_qp             <= BASE_QP;
            reg_gop_structure       <= GOP_STRUCTURE;
            reg_target_bitrate_kbps <= TARGET_BITRATE_KBPS;
            reg_rc_enable           <= RC_ENABLE[0];
            reg_sao_enable          <= 1'b0;
        end else begin
            // Single-cycle pulse on start
            encode_start_pulse <= 1'b0;

            if (slv_wren) begin
                case (s_axi_lite_awaddr[5:2])
                    4'h0: begin // 0x00: Control Register
                        if (s_axi_lite_wstrb[0]) begin
                            if (s_axi_lite_wdata[0]) encode_start_pulse <= 1'b1;
                            reg_soft_rst <= s_axi_lite_wdata[1];
                            reg_irq_en   <= s_axi_lite_wdata[2];
                        end
                    end
                    4'h3: begin // 0x0C: Total Frames
                        if (s_axi_lite_wstrb[0]) reg_total_frames[7:0]  <= s_axi_lite_wdata[7:0];
                        if (s_axi_lite_wstrb[1]) reg_total_frames[15:8] <= s_axi_lite_wdata[15:8];
                    end
                    4'h4: begin // 0x10: Base QP
                        if (s_axi_lite_wstrb[0]) reg_base_qp <= s_axi_lite_wdata[5:0];
                    end
                    4'h5: begin // 0x14: GOP Structure
                        if (s_axi_lite_wstrb[0]) reg_gop_structure <= s_axi_lite_wdata[1:0];
                    end
                    4'h6: begin // 0x18: Target Bitrate
                        if (s_axi_lite_wstrb[0]) reg_target_bitrate_kbps[7:0]  <= s_axi_lite_wdata[7:0];
                        if (s_axi_lite_wstrb[1]) reg_target_bitrate_kbps[15:8] <= s_axi_lite_wdata[15:8];
                    end
                    4'h7: begin // 0x1C: Feature Enable (write), Magic ID (read)
                        if (s_axi_lite_wstrb[0]) begin
                            reg_rc_enable  <= s_axi_lite_wdata[0];
                            reg_sao_enable <= s_axi_lite_wdata[1];
                        end
                    end
                    default: ;
                endcase
            end
        end
    end

    //-------------------------------------------------------------------------
    // Status & Interrupt Event Tracking
    //-------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_busy         <= 1'b0;
            reg_done         <= 1'b0;
            irq_status       <= 1'b0;
            prev_encode_done <= 1'b0;
        end else begin
            prev_encode_done <= core_encode_done;

            if (reg_soft_rst) begin
                reg_busy   <= 1'b0;
                reg_done   <= 1'b0;
                irq_status <= 1'b0;
            end else begin
                // State transitions for Busy & Done
                if (encode_start_pulse) begin
                    reg_busy <= 1'b1;
                    reg_done <= 1'b0;
                end else if (core_encode_done) begin
                    reg_busy <= 1'b0;
                    reg_done <= 1'b1;
                end

                // Interrupt event detection & W1C handling (assert on frame completion or full encode completion)
                if ((core_encode_done && !prev_encode_done) || core_frame_done) begin
                    irq_status <= 1'b1;
                end else if (slv_wren && (s_axi_lite_awaddr[5:2] == 4'h2) && s_axi_lite_wstrb[0] && s_axi_lite_wdata[0]) begin
                    // 0x08: Write 1 to clear IRQ
                    irq_status <= 1'b0;
                end
            end
        end
    end

    //-------------------------------------------------------------------------
    // AXI-Lite Read Handshake and Data Multiplexer
    //-------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axi_arready <= 1'b0;
            axi_rvalid  <= 1'b0;
            axi_rresp   <= 2'b00;
            axi_rdata   <= 32'h0;
        end else begin
            if (~axi_arready && s_axi_lite_arvalid && (~axi_rvalid || s_axi_lite_rready)) begin
                axi_arready <= 1'b1;
                axi_rvalid  <= 1'b1;
                axi_rresp   <= 2'b00;

                case (s_axi_lite_araddr[5:2])
                    4'h0: axi_rdata <= {29'd0, reg_irq_en, reg_soft_rst, 1'b0};
                    4'h1: axi_rdata <= {29'd0, ~reg_busy, reg_busy, reg_done};
                    4'h2: axi_rdata <= {31'd0, irq_status};
                    4'h3: axi_rdata <= {16'd0, reg_total_frames};
                    4'h4: axi_rdata <= {26'd0, reg_base_qp};
                    4'h5: axi_rdata <= {30'd0, reg_gop_structure};
                    4'h6: axi_rdata <= {16'd0, reg_target_bitrate_kbps};
                    4'h7: axi_rdata <= 32'h48455643; // Magic ID: "HEVC"
                    4'h8: axi_rdata <= {FRAME_WIDTH[15:0], FRAME_HEIGHT[15:0]};
                    4'h9: axi_rdata <= {16'd0, status_vbv_fullness_pct}; // 0x24: VBV Fullness Pct
                    default: axi_rdata <= 32'h0;
                endcase
            end else begin
                axi_arready <= 1'b0;
                if (s_axi_lite_rready && axi_rvalid) begin
                    axi_rvalid <= 1'b0;
                end
            end
        end
    end

    assign s_axi_lite_arready = axi_arready;
    assign s_axi_lite_rvalid  = axi_rvalid;
    assign s_axi_lite_rresp   = axi_rresp;
    assign s_axi_lite_rdata   = axi_rdata;

    //=========================================================================
    // AXI4-Stream Video Input Mapping (YUV 4:2:0)
    //=========================================================================
    wire [`PIXEL_WIDTH-1:0] core_in_pixel_y;
    wire [`PIXEL_WIDTH-1:0] core_in_pixel_u;
    wire [`PIXEL_WIDTH-1:0] core_in_pixel_v;

    assign core_in_pixel_y = s_axis_video_tdata[`PIXEL_WIDTH-1:0];
    assign core_in_pixel_u = s_axis_video_tdata[`PIXEL_WIDTH*2-1:`PIXEL_WIDTH];
    assign core_in_pixel_v = s_axis_video_tdata[`PIXEL_WIDTH*3-1:`PIXEL_WIDTH*2];

    //=========================================================================
    // AXI4-Stream Bitstream Output Staging & TLAST Generation
    // Uses a 2-entry staging FIFO to detect the final byte of each frame
    // and assert m_axis_bitstream_tlast coincident with that byte.
    //=========================================================================
    reg [7:0] bitstream_buf [0:1];
    reg [1:0] bitstream_cnt;
    reg       bitstream_wr_ptr;
    reg       bitstream_rd_ptr;
    reg       bitstream_frame_ending;

    wire core_wr = core_out_valid && core_out_ready;
    wire axis_rd = m_axis_bitstream_tvalid && m_axis_bitstream_tready;

    assign core_out_ready          = (bitstream_cnt < 2'd2) || axis_rd;
    assign m_axis_bitstream_tvalid = bitstream_frame_ending ? (bitstream_cnt > 2'd0) : (bitstream_cnt >= 2'd2);
    assign m_axis_bitstream_tdata  = bitstream_buf[bitstream_rd_ptr];
    assign m_axis_bitstream_tlast  = bitstream_frame_ending && (bitstream_cnt == 2'd1);

    always @(posedge clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            bitstream_cnt          <= 2'd0;
            bitstream_wr_ptr       <= 1'b0;
            bitstream_rd_ptr       <= 1'b0;
            bitstream_frame_ending <= 1'b0;
        end else begin
            // Detect frame completion to flush remaining bytes with TLAST on final byte
            if (core_frame_done || core_encode_done) begin
                if (bitstream_cnt > 2'd0 || core_wr) begin
                    bitstream_frame_ending <= 1'b1;
                end
            end

            // Write into FIFO from core
            if (core_wr) begin
                bitstream_buf[bitstream_wr_ptr] <= core_out_byte;
                bitstream_wr_ptr <= ~bitstream_wr_ptr;
            end

            // Read out of FIFO to AXI-Stream master
            if (axis_rd) begin
                bitstream_rd_ptr <= ~bitstream_rd_ptr;
                if (m_axis_bitstream_tlast) begin
                    bitstream_frame_ending <= 1'b0;
                end
            end

            // Occupancy counter tracking
            case ({core_wr, axis_rd})
                2'b10: bitstream_cnt <= bitstream_cnt + 2'd1;
                2'b01: bitstream_cnt <= bitstream_cnt - 2'd1;
                default: ; // unchanged
            endcase
        end
    end

    //=========================================================================
    // AXI4 Memory Master Mapping (External DRAM Frame Buffers)
    //=========================================================================
    assign m_axi_mem_awid    = {C_M_AXI_MEM_ID_WIDTH{1'b0}};
    assign m_axi_mem_awlock  = 1'b0;
    assign m_axi_mem_awcache = 4'b0011; // Normal Non-cacheable Bufferable
    assign m_axi_mem_awprot  = 3'b000;
    assign m_axi_mem_awqos   = 4'b0000;

    assign m_axi_mem_arid    = {C_M_AXI_MEM_ID_WIDTH{1'b0}};
    assign m_axi_mem_arlock  = 1'b0;
    assign m_axi_mem_arcache = 4'b0011;
    assign m_axi_mem_arprot  = 3'b000;
    assign m_axi_mem_arqos   = 4'b0000;

    // Address width parameter adaptation
    generate
        if (C_M_AXI_MEM_ADDR_WIDTH > 33) begin : gen_addr_wide
            assign m_axi_mem_awaddr = {{(C_M_AXI_MEM_ADDR_WIDTH-33){1'b0}}, core_axi_awaddr};
            assign m_axi_mem_araddr = {{(C_M_AXI_MEM_ADDR_WIDTH-33){1'b0}}, core_axi_araddr};
        end else if (C_M_AXI_MEM_ADDR_WIDTH == 33) begin : gen_addr_match
            assign m_axi_mem_awaddr = core_axi_awaddr;
            assign m_axi_mem_araddr = core_axi_araddr;
        end else begin : gen_addr_narrow
            assign m_axi_mem_awaddr = core_axi_awaddr[C_M_AXI_MEM_ADDR_WIDTH-1:0];
            assign m_axi_mem_araddr = core_axi_araddr[C_M_AXI_MEM_ADDR_WIDTH-1:0];
        end
    endgenerate

    //=========================================================================
    // Core Instance: hevc_encoder_top
    //=========================================================================
    hevc_encoder_top #(
        .FRAME_WIDTH         (FRAME_WIDTH),
        .FRAME_HEIGHT        (FRAME_HEIGHT),
        .GOP_STRUCTURE       (GOP_STRUCTURE),
        .BASE_QP             (BASE_QP),
        .RC_ENABLE           (RC_ENABLE),
        .TARGET_BITRATE_KBPS (TARGET_BITRATE_KBPS)
    ) u_hevc_encoder_top (
        .clk          (clk),
        .rst_n        (core_rst_n),

        // Host Control
        .encode_start (encode_start_pulse),
        .total_frames (reg_total_frames),
        .encode_done  (core_encode_done),
        .frame_done   (core_frame_done),

        // Video Stream In
        .in_valid     (s_axis_video_tvalid),
        .in_ready     (s_axis_video_tready),
        .in_pixel_y   (core_in_pixel_y),
        .in_pixel_u   (core_in_pixel_u),
        .in_pixel_v   (core_in_pixel_v),

        // Bitstream Stream Out
        .out_valid    (core_out_valid),
        .out_ready    (core_out_ready),
        .out_byte     (core_out_byte),

        // External Memory Master
        .axi_awvalid  (m_axi_mem_awvalid),
        .axi_awready  (m_axi_mem_awready),
        .axi_awaddr   (core_axi_awaddr),
        .axi_awlen    (m_axi_mem_awlen),
        .axi_awsize   (m_axi_mem_awsize),
        .axi_awburst  (m_axi_mem_awburst),

        .axi_wvalid   (m_axi_mem_wvalid),
        .axi_wready   (m_axi_mem_wready),
        .axi_wdata    (m_axi_mem_wdata),
        .axi_wstrb    (m_axi_mem_wstrb),
        .axi_wlast    (m_axi_mem_wlast),

        .axi_bvalid   (m_axi_mem_bvalid),
        .axi_bready   (m_axi_mem_bready),

        .axi_arvalid  (m_axi_mem_arvalid),
        .axi_arready  (m_axi_mem_arready),
        .axi_araddr   (core_axi_araddr),
        .axi_arlen    (m_axi_mem_arlen),
        .axi_arsize   (m_axi_mem_arsize),
        .axi_arburst  (m_axi_mem_arburst),

        .axi_rvalid   (m_axi_mem_rvalid),
        .axi_rready   (m_axi_mem_rready),
        .axi_rdata    (m_axi_mem_rdata),
        .axi_rlast    (m_axi_mem_rlast),

        // Runtime Dynamic Configuration & Status Interface
        .cfg_base_qp             (reg_base_qp),
        .cfg_gop_structure       (reg_gop_structure),
        .cfg_rc_enable           (reg_rc_enable),
        .cfg_target_bitrate_kbps (reg_target_bitrate_kbps),
        .cfg_sao_enable          (reg_sao_enable),
        .status_vbv_fullness_pct (status_vbv_fullness_pct)
    );

endmodule
