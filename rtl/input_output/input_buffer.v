//=============================================================================
// input_buffer.v
// YUV 4:2:0 Frame Input Buffer
//
// Staged between external YUV source and the CTU raster scan engine.
// Accepts raw 10-bit YUV samples in raster scan order (Y plane first,
// then Cb, then Cr — standard planar YUV layout matching HM input).
//
// HM reference:
//   TLibVideoIO/TVideoIOYuv.cpp  read() — reads one frame into TComPicYuv
//   Frame is stored as three separate planes in memory.
//
// Architecture:
//   External source pushes samples via wr_* interface.
//   CTU partitioner pulls CTU-sized pixel blocks via rd_* interface.
//
//   Storage: ping-pong dual-frame buffer
//     - One frame being written (from external input)
//     - One frame being read   (by encoder pipeline)
//     - Swap on frame boundaries
//
//   For 4K (3840×2160) 10-bit:
//     Luma:   3840×2160 = 8,294,400 samples × 10-bit
//     Chroma: 1920×1080 × 2 planes   = 4,147,200 samples × 10-bit
//     Total per frame ≈ 15.6 MB → too large for on-chip SRAM
//     → External DRAM via AXI4 (same interface as frame_store)
//
//   On-chip: one CTU line buffer (64px × frame_width) for read-ahead
//   prefetch to hide DRAM latency.
//
// Input format: packed 10-bit samples, 2 samples per 32-bit word
//   word[9:0]  = first sample
//   word[19:10] = second sample
//   word[31:20] = padding zeros
//
// Config:
//   FRAME_WIDTH  = 3840 (4K target)
//   FRAME_HEIGHT = 2160
//   BIT_DEPTH    = 10
//=============================================================================

`include "parameter_pkg.vh"
`include "hevc_interfaces.vh"

module input_buffer #(
    parameter FRAME_WIDTH  = 3840,
    parameter FRAME_HEIGHT = 2160
)(
    input  wire         clk,
    input  wire         rst_n,

    //=========================================================================
    // Write port — from external YUV source (DMA or test bench)
    //=========================================================================
    input  wire         wr_valid,
    output wire         wr_ready,
    input  wire [`PIXEL_WIDTH-1:0] wr_data,   // one sample per cycle
    input  wire [11:0]  wr_x,                 // pixel x in frame
    input  wire [11:0]  wr_y,                 // pixel y in frame
    input  wire [1:0]   wr_comp,              // 0=Y,1=Cb,2=Cr
    input  wire [9:0]   wr_poc,               // POC of this frame
    input  wire         wr_frame_last,         // last sample of frame

    //=========================================================================
    // Read port — to CTU partitioner / intra prediction / ME
    // Block read: request a (blk_w × blk_h) pixel block starting at (x,y)
    //=========================================================================
    input  wire         rd_req_valid,
    output wire         rd_req_ready,
    input  wire [11:0]  rd_x,
    input  wire [11:0]  rd_y,
    input  wire [6:0]   rd_blk_w,
    input  wire [6:0]   rd_blk_h,
    input  wire [1:0]   rd_comp,

    // Response — pixel stream (row-major within requested block)
    output wire         rd_resp_valid,
    input  wire         rd_resp_ready,
    output wire [`PIXEL_WIDTH-1:0] rd_resp_data,
    output wire         rd_resp_last,

    //=========================================================================
    // AXI4 master — external DRAM
    //=========================================================================
    output reg          axi_awvalid,
    input  wire         axi_awready,
    output reg  [32:0]  axi_awaddr,
    output reg  [7:0]   axi_awlen,
    output reg  [2:0]   axi_awsize,
    output reg  [1:0]   axi_awburst,

    output reg          axi_wvalid,
    input  wire         axi_wready,
    output reg  [31:0]  axi_wdata,
    output reg  [3:0]   axi_wstrb,
    output reg          axi_wlast,

    input  wire         axi_bvalid,
    output wire         axi_bready,

    output reg          axi_arvalid,
    input  wire         axi_arready,
    output reg  [32:0]  axi_araddr,
    output reg  [7:0]   axi_arlen,
    output reg  [2:0]   axi_arsize,
    output reg  [1:0]   axi_arburst,

    input  wire         axi_rvalid,
    output wire         axi_rready,
    input  wire [31:0]  axi_rdata,
    input  wire         axi_rlast,

    //=========================================================================
    // Frame status
    //=========================================================================
    output reg          frame_ready,    // 1 when a complete frame is buffered
    output reg [9:0]    buffered_poc,   // POC of the ready frame
    input  wire         frame_consumed  // pulse: encoder done with this frame
);

    //-------------------------------------------------------------------------
    // Memory layout (same packing as frame_store):
    //   2 samples per 32-bit word (10-bit each, bits [19:0])
    //   Ping buffer: slot 0, Pong buffer: slot 1
    //   Luma base:    slot * SLOT_STRIDE
    //   Cb base:      slot * SLOT_STRIDE + LUMA_WORDS * 4
    //   Cr base:      slot * SLOT_STRIDE + (LUMA_WORDS + CHROMA_WORDS) * 4
    //-------------------------------------------------------------------------
    localparam LUMA_WORDS   = (FRAME_WIDTH * FRAME_HEIGHT) / 2;
    localparam CHROMA_WORDS = (FRAME_WIDTH/2 * FRAME_HEIGHT/2) / 2;
    localparam SLOT_STRIDE  = (LUMA_WORDS + 2*CHROMA_WORDS) * 4; // bytes

    //-------------------------------------------------------------------------
    // Ping-pong slot management & Frame Status
    //-------------------------------------------------------------------------
    reg wr_slot;    // which slot is being written (0 or 1)
    reg rd_slot;    // which slot is being read

    localparam WR_IDLE  = 2'd0;
    localparam WR_ADDR  = 2'd1;
    localparam WR_RESP  = 2'd3;

    reg [1:0]  wr_state;
    reg [`PIXEL_WIDTH-1:0] wr_pack;    // hold first of pair
    reg        wr_half;                // 0=waiting first, 1=waiting second
    reg [31:0] wr_word;
    reg        wr_is_last;
    reg [9:0]  wr_latched_poc;

    localparam RD_IDLE = 2'd0;
    localparam RD_ADDR = 2'd1;
    localparam RD_DATA = 2'd2;
    localparam RD_OUT  = 2'd3;

    reg [1:0]  rd_state;
    reg [6:0]  rd_px, rd_py;
    reg [6:0]  rd_blk_w_r, rd_blk_h_r;
    reg [11:0] rd_base_x, rd_base_y;
    reg [1:0]  rd_comp_r;
    reg [31:0] rd_word_buf;
    reg        rd_word_valid;
    reg        rd_pix_sel;    // which of 2 pixels in current word

    assign axi_bready = 1'b1;
    assign axi_rready = (rd_state == RD_DATA);
    
    always @(posedge clk) begin
        if (!rst_n) begin
            frame_ready  <= 1'b0;
            buffered_poc <= 10'd0;
            wr_slot      <= 1'b0;
            rd_slot      <= 1'b0;
        end else begin
            if (frame_consumed) begin
                frame_ready <= 1'b0;
                rd_slot     <= ~rd_slot; // Advance reader to next buffered frame
            end
            if (wr_state == WR_RESP && axi_bvalid && wr_is_last) begin
                frame_ready  <= 1'b1;
                buffered_poc <= wr_latched_poc;
                wr_slot      <= ~wr_slot; // Advance writer to next empty slot
            end
        end
    end

    //-------------------------------------------------------------------------
    // Write FSM — accepts incoming samples and writes to DRAM
    //-------------------------------------------------------------------------

    // Address calculation
    wire [23:0] wr_stride = (wr_comp != 2'd0) ? (FRAME_WIDTH / 2) : FRAME_WIDTH;
    wire [11:0] wr_cx = wr_x;
    wire [11:0] wr_cy = wr_y;
    wire [31:0] wr_comp_off = (wr_comp==2'd0) ? 32'd0 :
                               (wr_comp==2'd1) ? (LUMA_WORDS*4) :
                               (LUMA_WORDS + CHROMA_WORDS)*4;
    wire [32:0] wr_addr = (wr_slot ? SLOT_STRIDE[32:0] : 33'd0) + wr_comp_off +
                          ((wr_cy * 33'd1) * wr_stride + wr_cx) * 33'd2;

    assign wr_ready = (wr_state == WR_IDLE);

    always @(posedge clk) begin
        if (!rst_n) begin
            wr_state   <= WR_IDLE;
            wr_half    <= 1'b0;
            axi_awvalid<= 1'b0;
            axi_wvalid <= 1'b0;
        end else begin
            case (wr_state)
                WR_IDLE: begin
                    if (wr_valid && wr_ready) begin
                        if (!wr_half) begin
                            wr_pack  <= wr_data;
                            wr_half  <= 1'b1;
                        end else begin
                            // Second sample — form word and issue 4-byte aligned write
                            wr_word        <= {12'd0, wr_data, wr_pack};
                            wr_half        <= 1'b0;
                            wr_is_last     <= wr_frame_last;
                            wr_latched_poc <= wr_poc;
                            axi_awaddr     <= wr_addr & ~33'd3;
                            axi_awlen      <= 8'd0;       // single beat
                            axi_awsize     <= 3'b010;     // 4 bytes
                            axi_awburst    <= 2'b01;
                            axi_awvalid    <= 1'b1;
                            wr_state       <= WR_ADDR;
                        end
                    end
                end
                WR_ADDR: begin
                    if (axi_awready) begin
                        axi_awvalid <= 1'b0;
                        axi_wvalid  <= 1'b1;
                        axi_wdata   <= wr_word;
                        axi_wstrb   <= 4'b1111;    // Write all 4 bytes of the packed 32-bit word
                        axi_wlast   <= 1'b1;
                        wr_state    <= WR_RESP;
                    end
                end
                WR_RESP: begin
                    if (axi_wready) axi_wvalid <= 1'b0;
                    if (axi_bvalid) begin
                        wr_state <= WR_IDLE;
                    end
                end
            endcase
        end
    end

    //-------------------------------------------------------------------------
    // Read FSM — services block read requests from encoder pipeline
    //-------------------------------------------------------------------------

    assign rd_req_ready  = (rd_state == RD_IDLE);
    assign rd_resp_valid = (rd_state == RD_OUT) && rd_word_valid;
    assign rd_resp_last  = (rd_px == rd_blk_w_r - 7'd1) &&
                           (rd_py == rd_blk_h_r - 7'd1);
    assign rd_resp_data  = rd_pix_sel ? rd_word_buf[19:10] : rd_word_buf[9:0];

    wire [6:0] next_rd_px = (rd_px == rd_blk_w_r - 7'd1) ? 7'd0 : rd_px + 7'd1;
    wire [6:0] next_rd_py = (rd_px == rd_blk_w_r - 7'd1) ? rd_py + 7'd1 : rd_py;

    wire [11:0] rd_cur_x = rd_base_x + {5'b0, rd_px};
    wire [11:0] rd_ex    = rd_cur_x;

    wire [11:0] tgt_req_x = (rd_state == RD_IDLE) ? rd_x : rd_base_x + {5'b0, next_rd_px};
    wire [11:0] tgt_req_y = (rd_state == RD_IDLE) ? rd_y : rd_base_y + {5'b0, next_rd_py};
    wire [1:0]  tgt_req_comp = (rd_state == RD_IDLE) ? rd_comp : rd_comp_r;

    wire [11:0] tgt_ex    = tgt_req_x;
    wire [11:0] tgt_ey    = tgt_req_y;
    wire [23:0] tgt_stride= (tgt_req_comp!=0) ? (FRAME_WIDTH / 2) : FRAME_WIDTH;
    wire [31:0] tgt_coff  = (tgt_req_comp==0) ? 32'd0 :
                            (tgt_req_comp==1) ? (LUMA_WORDS*4) :
                            (LUMA_WORDS+CHROMA_WORDS)*4;
    
    wire [32:0] tgt_paddr = (rd_slot ? SLOT_STRIDE[32:0] : 33'd0) + tgt_coff +
                            ((tgt_ey * 33'd1) * tgt_stride + tgt_ex) * 33'd2;

    always @(posedge clk) begin
        if (!rst_n) begin
            rd_state     <= RD_IDLE;
            rd_word_valid<= 1'b0;
            axi_arvalid  <= 1'b0;
        end else begin
            case (rd_state)
                RD_IDLE: begin
                    rd_word_valid <= 1'b0;
                    if (rd_req_valid) begin
                        rd_base_x  <= rd_x;
                        rd_base_y  <= rd_y;
                        rd_blk_w_r <= rd_blk_w;
                        rd_blk_h_r <= rd_blk_h;
                        rd_comp_r  <= rd_comp;
                        rd_px      <= 7'd0;
                        rd_py      <= 7'd0;
                        rd_state   <= RD_ADDR;
                        axi_araddr <= tgt_paddr & ~33'd3; // Ensure 4-byte alignment
                        axi_arlen  <= 8'd0;
                        axi_arsize <= 3'b010;
                        axi_arburst<= 2'b01;
                        axi_arvalid<= 1'b1;
                    end
                end
                RD_ADDR: begin
                    if (axi_arready) begin
                        axi_arvalid <= 1'b0;
                        rd_state    <= RD_DATA;
                    end
                end
                RD_DATA: begin
                    if (axi_rvalid) begin
                        rd_word_buf  <= axi_rdata;
                        rd_pix_sel   <= rd_ex[0];  // which pixel in word
                        rd_word_valid<= 1'b1;
                        rd_state     <= RD_OUT;
                    end
                end
                RD_OUT: begin
                    if (rd_resp_ready && rd_word_valid) begin
                        if (rd_resp_last) begin
                            rd_state     <= RD_IDLE;
                            rd_word_valid<= 1'b0;
                        end else begin
                            rd_px <= next_rd_px;
                            rd_py <= next_rd_py;

                            rd_state    <= RD_ADDR;
                            rd_word_valid<=1'b0;
                            axi_araddr  <= tgt_paddr & ~33'd3;
                            axi_arlen   <= 8'd0;
                            axi_arsize  <= 3'b010;
                            axi_arburst <= 2'b01;
                            axi_arvalid <= 1'b1;
                        end
                    end
                end
            endcase
        end
    end

    // synthesis translate_off
    always @(posedge clk) begin
        if (rst_n && frame_ready && wr_valid && wr_frame_last)
            $display("WARN [input_buffer] frame_ready overrun — encoder too slow POC=%0d",
                     buffered_poc);
    end
    // synthesis translate_on

endmodule