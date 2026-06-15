//=============================================================================
// frame_store.v
// Decoded Picture Buffer (DPB) — Reconstructed Frame Store
//
// Mapped from HM source:
//   TLibCommon/TComPicYuv.cpp   — frame buffer layout
//   TLibCommon/TComPic.cpp      — DPB slot management
//   TLibCommon/TComSlice.cpp    — reference picture list building
//
// Architecture:
//   MAX_REF_PICS = 8 slots (from parameter_pkg.vh, config MAX_REF_ACTIVE=5)
//   Each slot holds one full reconstructed frame (YCbCr 4:2:0, 10-bit)
//   4K frame (3840×2160):
//     Luma:   3840×2160 × 10-bit = 8,294,400 samples
//     Chroma: 1920×1080 × 10-bit × 2 = 4,147,200 samples
//     Total per frame: ~12.4M samples × 10-bit = ~15.6MB
//     8 slots: ~125MB → requires external DRAM
//
//   This module is a CONTROLLER — it manages:
//     1. Write port: incoming reconstructed pixels from recon_unit
//     2. Read port:  reference sample requests from mc_unit (motion comp)
//     3. DPB slot allocation/deallocation by POC
//     4. Reference picture list (L0/L1) management
//
//   Actual pixel storage: external DRAM via AXI4 memory interface
//   (Cannot fit in on-chip SRAM for 4K — 8×15.6MB = 125MB)
//   On-chip: only control registers + one CTU line buffer (prefetch cache)
//
// Memory layout (per slot, byte-addressed):
//   Luma base:    slot * FRAME_BYTES
//   Cb base:      slot * FRAME_BYTES + LUMA_BYTES
//   Cr base:      slot * FRAME_BYTES + LUMA_BYTES + CHROMA_BYTES
//   Pixel packing: 2 samples per 32-bit word (10-bit each, 12-bit padded)
//
// Config:
//   Frame: 4K = 3840×2160 (target resolution)
//   GOP:   16 B-frames → max 5 active refs (MAX_REF_ACTIVE=5 from config)
//   DPB:   8 slots (MAX_REF_PICS=8)
//
// AXI4 interface:
//   Write: recon pixels → burst write to DRAM slot
//   Read:  MC reference request → burst read from DRAM slot
//   Both use 256-bit data bus (32 pixels per beat for luma)
//
// CTU line cache (on-chip):
//   One CTU row (64px high × frame_width × 10-bit) buffered on-chip
//   for deblocking filter neighbor access
//   Size: 64 × 3840 × 10-bit = 2,457,600 bits ≈ 300KB — fits in BRAM
//=============================================================================

`include "parameter_pkg.vh"
`include "hevc_interfaces.vh"

module frame_store #(
    parameter FRAME_WIDTH  = 3840,
    parameter FRAME_HEIGHT = 2160,
    parameter AXI_DW       = 256    // AXI data bus width (bits)
)(
    input  wire         clk,
    input  wire         rst_n,

    //=========================================================================
    // WRITE PORT — reconstructed pixels from recon_unit
    //=========================================================================
    // Control
    input  wire         wr_valid,
    output wire         wr_ready,
    input  wire [`PIXEL_WIDTH-1:0] wr_pixel,
    input  wire [11:0]  wr_x,           // pixel x in frame (0..3839)
    input  wire [11:0]  wr_y,           // pixel y in frame (0..2159)
    input  wire [1:0]   wr_comp,        // 0=Y, 1=Cb, 2=Cr
    input  wire [2:0]   wr_slot,        // DPB slot 0..7
    input  wire         wr_last,        // last pixel of frame

    //=========================================================================
    // READ PORT — reference samples for motion compensation
    //=========================================================================
    // Request
    input  wire         rd_req_valid,
    output wire         rd_req_ready,
    input  wire [2:0]   rd_slot,        // which reference frame slot
    input  wire signed [12:0] rd_x,    // pixel x (signed for padding, -4..3843)
    input  wire signed [12:0] rd_y,    // pixel y (signed for padding)
    input  wire [6:0]   rd_blk_w,      // block width to prefetch
    input  wire [6:0]   rd_blk_h,      // block height
    input  wire [1:0]   rd_comp,       // component

    // Response — pixel stream
    output wire         rd_resp_valid,
    input  wire         rd_resp_ready,
    output wire [`PIXEL_WIDTH-1:0] rd_resp_pixel,
    output wire         rd_resp_last,

    //=========================================================================
    // DPB MANAGEMENT — slot allocation
    //=========================================================================
    // Allocate a slot for new frame (called at start of frame encoding)
    input  wire         alloc_valid,
    output wire         alloc_ready,
    input  wire [9:0]   alloc_poc,      // POC of frame being allocated
    output wire [2:0]   alloc_slot,     // slot assigned

    // Release a slot (called when frame no longer needed as reference)
    input  wire         free_valid,
    input  wire [2:0]   free_slot,

    // Reference picture list (from GOP controller)
    // L0 and L1 lists: slot indices for each reference position
    input  wire [14:0]  ref_l0,
    input  wire [14:0]  ref_l1,
    input  wire [2:0]   ref_l0_count,
    input  wire [2:0]   ref_l1_count,

    //=========================================================================
    // AXI4 MASTER — external DRAM interface
    //=========================================================================
    // Write address channel
    output reg          axi_awvalid,
    input  wire         axi_awready,
    output reg  [32:0]  axi_awaddr,
    output reg  [7:0]   axi_awlen,      // burst length - 1
    output reg  [2:0]   axi_awsize,     // 3'b101 = 32 bytes per beat (256-bit)
    output reg  [1:0]   axi_awburst,    // 2'b01 = INCR

    // Write data channel
    output reg          axi_wvalid,
    input  wire         axi_wready,
    output reg  [AXI_DW-1:0] axi_wdata,
    output reg  [AXI_DW/8-1:0] axi_wstrb,
    output reg          axi_wlast,

    // Write response
    input  wire         axi_bvalid,
    output wire         axi_bready,

    // Read address channel
    output reg          axi_arvalid,
    input  wire         axi_arready,
    output reg  [32:0]  axi_araddr,
    output reg  [7:0]   axi_arlen,
    output reg  [2:0]   axi_arsize,
    output reg  [1:0]   axi_arburst,

    // Read data channel
    input  wire         axi_rvalid,
    output wire         axi_rready,
    input  wire [AXI_DW-1:0] axi_rdata,
    input  wire         axi_rlast,

    //=========================================================================
    // CTU LINE CACHE output (for deblocking/SAO neighbor access)
    //=========================================================================
    output wire         cache_valid,
    output wire [`PIXEL_WIDTH-1:0] cache_pixel,
    input  wire [11:0]  cache_x,
    input  wire [11:0]  cache_y,
    input  wire [1:0]   cache_comp
);

    //-------------------------------------------------------------------------
    // Memory layout constants
    // Luma:   FRAME_WIDTH × FRAME_HEIGHT × 10-bit
    // Chroma: (FRAME_WIDTH/2) × (FRAME_HEIGHT/2) × 10-bit × 2
    // Pack 2 samples per 32-bit word (10-bit + 6-bit pad each)
    // Word address = (y * stride + x) / 2
    //-------------------------------------------------------------------------
    localparam LUMA_SAMPLES   = FRAME_WIDTH * FRAME_HEIGHT;
    localparam CHROMA_SAMPLES = (FRAME_WIDTH/2) * (FRAME_HEIGHT/2);
    localparam FRAME_SAMPLES  = LUMA_SAMPLES + 2*CHROMA_SAMPLES;

    // Each 32-bit word holds 2 pixels (10-bit each, packed in low 20 bits)
    localparam LUMA_WORDS     = LUMA_SAMPLES   / 2;
    localparam CHROMA_WORDS   = CHROMA_SAMPLES / 2;
    localparam FRAME_WORDS    = LUMA_WORDS + 2*CHROMA_WORDS;
    // 4K frame words: (8,294,400 + 2×2,073,600)/2 = 6,220,800 words
    // At 4 bytes/word: 24.9MB per slot, 8 slots: 199MB → requires DRAM

    // Base addresses per slot and component (byte addresses)
    // Slot stride: FRAME_WORDS * 4 bytes
    localparam SLOT_STRIDE_BYTES = FRAME_WORDS * 4;  // ~24.9MB per slot
    localparam CB_OFFSET_BYTES   = LUMA_WORDS  * 4;
    localparam CR_OFFSET_BYTES   = LUMA_WORDS  * 4 + CHROMA_WORDS * 4;

    //-------------------------------------------------------------------------
    // DPB slot management
    //-------------------------------------------------------------------------
    reg [7:0]  slot_valid;          // which slots are allocated
    reg [9:0]  slot_poc  [0:7];     // POC stored in each slot
    reg [7:0]  slot_ready;          // slot write complete (frame fully written)

    // Find a free slot for allocation
    wire [2:0] free_slot_idx =
        (!slot_valid[0]) ? 3'd0 :
        (!slot_valid[1]) ? 3'd1 :
        (!slot_valid[2]) ? 3'd2 :
        (!slot_valid[3]) ? 3'd3 :
        (!slot_valid[4]) ? 3'd4 :
        (!slot_valid[5]) ? 3'd5 :
        (!slot_valid[6]) ? 3'd6 :
        (!slot_valid[7]) ? 3'd7 : 3'd7;

    wire any_free = !(&slot_valid);  // at least one slot free
    assign alloc_ready  = any_free;
    assign alloc_slot   = free_slot_idx;

    integer si;
    always @(posedge clk) begin
        if (!rst_n) begin
            slot_valid <= 8'b0;
            slot_ready <= 8'b0;
            for (si = 0; si < 8; si = si + 1)
                slot_poc[si] <= 10'd0;
        end else begin
            // Allocate
            if (alloc_valid && alloc_ready) begin
                slot_valid[free_slot_idx] <= 1'b1;
                slot_ready[free_slot_idx] <= 1'b0;
                slot_poc[free_slot_idx]   <= alloc_poc;
            end
            // Free
            if (free_valid) begin
                slot_valid[free_slot] <= 1'b0;
                slot_ready[free_slot] <= 1'b0;
            end
            // Mark ready when write completes
            if (wr_valid && wr_ready && wr_last)
                slot_ready[wr_slot] <= 1'b1;
        end
    end

    //=========================================================================
    // WRITE ENGINE
    // Accumulates pixels into AXI write bursts
    // Pack 2 pixels per 32-bit word; burst 16 words (32 pixels) per AXI beat
    // For 256-bit bus: 256/32 = 8 words = 16 pixels per beat (luma)
    //
    // AXI address calculation:
    //   base = wr_slot * SLOT_STRIDE_BYTES
    //   comp_offset = (comp==Y) ? 0 : (comp==Cb) ? CB_OFFSET_BYTES : CR_OFFSET_BYTES
    //   chroma scaling: x/2, y/2 for Cb/Cr
    //   word_addr = (y * stride_words + x) / 2
    //   byte_addr = base + comp_offset + word_addr * 4
    //=========================================================================

    localparam WR_IDLE = 2'd0;
    localparam WR_AW   = 2'd1;
    localparam WR_W    = 2'd2;
    localparam WR_B    = 2'd3;

    reg [1:0]  wr_state;
    reg [32:0] cur_beat_addr;
    reg [AXI_DW-1:0] beat_data;
    reg [31:0] beat_strb;
    reg        beat_dirty;

    reg [32:0] flush_addr;
    reg [AXI_DW-1:0] flush_data;
    reg [31:0] flush_strb;

    // Compute AXI byte address for current write pixel
    wire [11:0] wr_cx = wr_x; // coordinates are natively in component scale
    wire [11:0] wr_cy = wr_y;
    wire [11:0] wr_stride = (wr_comp != 2'd0) ? 12'd1920 : 12'd3840;

    wire [31:0] wr_comp_base = (wr_comp == 2'd0) ? 32'd0 :
                                (wr_comp == 2'd1) ? CB_OFFSET_BYTES :
                                CR_OFFSET_BYTES;

    wire [32:0] wr_pixel_addr = {1'b0, wr_slot} * SLOT_STRIDE_BYTES +
                                 {1'b0, wr_comp_base} +
                                 ({21'b0, wr_cy} * {21'b0, wr_stride} + {21'b0, wr_cx}) * 33'd2; // *2: word addr to byte (/2 pixels, *4 bytes)

    wire [32:0] beat_addr = wr_pixel_addr & ~33'h1F; // 32-byte aligned beat address
    wire [3:0]  pixel_idx = wr_cx[3:0];              // which pixel inside the beat

    wire [AXI_DW-1:0] next_beat_data = beat_dirty ? beat_data : {AXI_DW{1'b0}};
    wire [31:0]       next_beat_strb = beat_dirty ? beat_strb : 32'd0;

    // Ready unless we are stalled flushing an old beat
    assign wr_ready = (wr_state == WR_IDLE) && (!beat_dirty || (beat_addr == cur_beat_addr));
    assign axi_bready = 1'b1;

    always @(posedge clk) begin
        if (!rst_n) begin
            wr_state      <= WR_IDLE;
            beat_dirty    <= 1'b0;
            axi_awvalid   <= 1'b0;
            axi_wvalid    <= 1'b0;
            axi_wlast     <= 1'b0;
        end else begin
            case (wr_state)
                WR_IDLE: begin
                    if (wr_valid) begin
                        if (!beat_dirty || (beat_addr == cur_beat_addr)) begin
                            // Accumulate pixel into 16-bit padded boundary
                            beat_dirty <= 1'b1;
                            cur_beat_addr <= beat_addr;

                            // Apply slice modifications to a local variable to bypass simulator RMW issues
                            begin : slice_update
                                integer i;
                                reg [AXI_DW-1:0] temp_data;
                                reg [31:0]       temp_strb;
                                temp_data = next_beat_data;
                                temp_strb = next_beat_strb;
                                for (i = 0; i < 16; i = i + 1) begin
                                    if (i == pixel_idx) begin
                                        temp_data[i*16 +: 16] = {6'd0, wr_pixel};
                                        temp_strb[i*2 +: 2]   = 2'b11;
                                    end
                                end
                                beat_data <= temp_data;
                                beat_strb <= temp_strb;

                                // Flush immediately if beat is full or it's the last pixel
                                if (pixel_idx == 4'd15 || wr_last) begin
                                    wr_state   <= WR_AW;
                                    flush_addr <= beat_addr;
                                    flush_data <= temp_data;
                                    flush_strb <= temp_strb;
                                    beat_dirty <= 1'b0;
                                end
                            end
                        end else begin
                            // Flush old beat (pixel belongs to new block row / beat)
                            wr_state   <= WR_AW;
                            flush_addr <= cur_beat_addr;
                            flush_data <= beat_data;
                            flush_strb <= beat_strb;
                            beat_dirty <= 1'b0;
                        end
                    end
                end

                WR_AW: begin
                    axi_awvalid <= 1'b1;
                    axi_awaddr  <= flush_addr;
                    axi_awlen   <= 8'd0; // 1 beat
                    axi_awsize  <= 3'b101; // 32 bytes
                    axi_awburst <= 2'b01;
                    if (axi_awready && axi_awvalid) begin
                        axi_awvalid <= 1'b0;
                        wr_state    <= WR_W;
                    end
                end

                WR_W: begin
                    axi_wvalid <= 1'b1;
                    axi_wdata  <= flush_data;
                    axi_wstrb  <= flush_strb;
                    axi_wlast  <= 1'b1;
                    if (axi_wready && axi_wvalid) begin
                        axi_wvalid <= 1'b0;
                        wr_state   <= WR_B;
                    end
                end

                WR_B: begin
                    if (axi_bvalid) begin
                        wr_state <= WR_IDLE;
                    end
                end
            endcase
        end
    end

    //=========================================================================
    // READ ENGINE
    // Services reference sample requests from mc_unit
    // Handles boundary padding (replicate edge pixels for out-of-frame access)
    //
    // Padding rule (HM TComYuv.cpp, xPadPicture):
    //   x < 0:               replicate pixel at x=0
    //   x >= FRAME_WIDTH:    replicate pixel at x=FRAME_WIDTH-1
    //   y < 0:               replicate pixel at y=0
    //   y >= FRAME_HEIGHT:   replicate pixel at y=FRAME_HEIGHT-1
    //=========================================================================
    localparam RD_IDLE  = 2'd0;
    localparam RD_ADDR  = 2'd1;
    localparam RD_DATA  = 2'd2;
    localparam RD_OUT   = 2'd3;

    reg [1:0]  rd_state;
    reg [6:0]  rd_blk_w_r, rd_blk_h_r;
    reg [6:0]  rd_px, rd_py;           // current pixel within requested block
    reg [2:0]  rd_slot_r;
    reg [1:0]  rd_comp_r;
    reg signed [12:0] rd_base_x, rd_base_y;

    // Boundary-clamped coordinates for current read pixel
    wire signed [12:0] rd_cur_x_raw = rd_base_x + $signed({6'b0, rd_px});
    wire signed [12:0] rd_cur_y_raw = rd_base_y + $signed({6'b0, rd_py});

    wire signed [12:0] max_x = (rd_comp_r != 2'd0) ? $signed(FRAME_WIDTH / 2)  : $signed(FRAME_WIDTH);
    wire signed [12:0] max_y = (rd_comp_r != 2'd0) ? $signed(FRAME_HEIGHT / 2) : $signed(FRAME_HEIGHT);

    wire [11:0] rd_cur_x = (rd_cur_x_raw < 13'sd0)                         ? 12'd0 :
                            (rd_cur_x_raw >= max_x)                         ? (max_x[11:0] - 12'd1) :
                            rd_cur_x_raw[11:0];
    wire [11:0] rd_cur_y = (rd_cur_y_raw < 13'sd0)                         ? 12'd0 :
                            (rd_cur_y_raw >= max_y)                         ? (max_y[11:0] - 12'd1) :
                            rd_cur_y_raw[11:0];

    wire [11:0] rd_eff_x = rd_cur_x;
    wire [11:0] rd_eff_y = rd_cur_y;
    wire [11:0] rd_stride = (rd_comp_r != 2'd0) ? 12'd1920 : 12'd3840;

    wire [31:0] rd_comp_base = (rd_comp_r == 2'd0) ? 32'd0 :
                                (rd_comp_r == 2'd1) ? CB_OFFSET_BYTES :
                                CR_OFFSET_BYTES;

    wire [32:0] rd_pixel_addr = {1'b0, rd_slot_r} * SLOT_STRIDE_BYTES +
                                 {1'b0, rd_comp_base} +
                                 ({21'b0, rd_eff_y} * {21'b0, rd_stride} + {21'b0, rd_eff_x}) * 33'd2;

    wire [6:0] next_px = (rd_px == rd_blk_w_r - 7'd1) ? 7'd0 : rd_px + 7'd1;
    wire [6:0] next_py = (rd_px == rd_blk_w_r - 7'd1) ? rd_py + 7'd1 : rd_py;

    wire signed [12:0] next_x_raw = rd_base_x + $signed({6'b0, next_px});
    wire signed [12:0] next_y_raw = rd_base_y + $signed({6'b0, next_py});

    wire [11:0] next_cur_x = (next_x_raw < 13'sd0) ? 12'd0 :
                             (next_x_raw >= max_x) ? (max_x[11:0] - 12'd1) :
                             next_x_raw[11:0];
    wire [11:0] next_cur_y = (next_y_raw < 13'sd0) ? 12'd0 :
                             (next_y_raw >= max_y) ? (max_y[11:0] - 12'd1) :
                             next_y_raw[11:0];

    wire [32:0] next_pixel_addr = {1'b0, rd_slot_r} * SLOT_STRIDE_BYTES +
                                  {1'b0, rd_comp_base} +
                                  ({21'b0, next_cur_y} * {21'b0, rd_stride} + {21'b0, next_cur_x}) * 33'd2;

    wire [32:0] next_beat_addr = next_pixel_addr & ~33'h1F;

    // Read data path — unpack pixels from AXI read data
    reg [AXI_DW-1:0] rd_data_buf;
    reg        rd_buf_valid;
    reg [32:0] cached_beat_addr;

    wire [2:0]  rd_word_idx  = rd_pixel_addr[4:2]; // which 32-bit word in the 256-bit beat
    wire [31:0] rd_word      = rd_data_buf >> ({rd_word_idx, 5'd0}); // Shift to align word to LSB
    wire [`PIXEL_WIDTH-1:0] rd_pixel_out =
        rd_eff_x[0] ? rd_word[25:16] : rd_word[9:0]; // Extracted from 16-bit padded lanes

    assign rd_req_ready  = (rd_state == RD_IDLE);
    assign rd_resp_valid = (rd_state == RD_OUT) && rd_buf_valid;
    assign rd_resp_pixel = rd_pixel_out;
    assign rd_resp_last  = (rd_px == rd_blk_w_r - 7'd1) &&
                           (rd_py == rd_blk_h_r - 7'd1);
    assign axi_rready    = (rd_state == RD_DATA);

    always @(posedge clk) begin
        if (!rst_n) begin
            rd_state     <= RD_IDLE;
            rd_buf_valid <= 1'b0;
            rd_px        <= 7'd0;
            rd_py        <= 7'd0;
            axi_arvalid  <= 1'b0;
            cached_beat_addr <= 33'h1FFFFFFFF;
        end else begin
            case (rd_state)
                RD_IDLE: begin
                    rd_buf_valid <= 1'b0;
                    cached_beat_addr <= 33'h1FFFFFFFF;
                    if (rd_req_valid) begin
                        rd_slot_r   <= rd_slot;
                        rd_comp_r   <= rd_comp;
                        rd_blk_w_r  <= rd_blk_w;
                        rd_blk_h_r  <= rd_blk_h;
                        rd_base_x   <= rd_x;
                        rd_base_y   <= rd_y;
                        rd_px       <= 7'd0;
                        rd_py       <= 7'd0;
                        rd_state    <= RD_ADDR;
                    end
                end

                RD_ADDR: begin
                    axi_arvalid <= 1'b1;
                    axi_araddr  <= rd_pixel_addr & ~33'h1F; // 32-byte aligned
                    axi_arlen   <= 8'd0;     
                    axi_arsize  <= 3'b101;   
                    axi_arburst <= 2'b01;
                    if (axi_arready) begin
                        axi_arvalid <= 1'b0;
                        rd_state    <= RD_DATA;
                    end
                end

                RD_DATA: begin
                    if (axi_rvalid) begin
                        rd_data_buf  <= axi_rdata;
                        rd_buf_valid <= 1'b1;
                        cached_beat_addr <= rd_pixel_addr & ~33'h1F;
                        rd_state     <= RD_OUT;
                    end
                end

                RD_OUT: begin
                    if (rd_resp_ready && rd_buf_valid) begin
                        // Advance to next pixel
                        rd_px <= next_px;
                        rd_py <= next_py;

                        if (rd_resp_last) begin
                            rd_state     <= RD_IDLE;
                            rd_buf_valid <= 1'b0;
                        end else begin
                            if (next_beat_addr != cached_beat_addr) begin
                                // Issue next read
                                rd_state    <= RD_ADDR;
                                rd_buf_valid<= 1'b0;
                            end
                        end
                    end
                end
            endcase
        end
    end

    //=========================================================================
    // CTU LINE CACHE — on-chip BRAM for deblocking/SAO neighbor samples
    // Stores one CTU row height (64px) × frame_width for each component
    // Written by recon_unit, read by deblocking filter
    //=========================================================================
    localparam CACHE_WIDTH   = 3840;
    localparam CACHE_HEIGHT  = 64;
    localparam CACHE_DEPTH   = CACHE_WIDTH * CACHE_HEIGHT;  // 245,760 words

    // 3 components stored sequentially
    // Luma: [0..245759], Cb: [245760..306239], Cr: [306240..366719]
    localparam CACHE_CB_OFF  = CACHE_DEPTH;
    localparam CACHE_CR_OFF  = CACHE_DEPTH + CACHE_DEPTH/4;

    (* ram_style = "block" *)
    reg [`PIXEL_WIDTH-1:0] line_cache [0:CACHE_DEPTH + CACHE_DEPTH/2 - 1];

    // Cache write from recon_unit (for luma: x,y direct; chroma: x/2, y/2)
    wire [18:0] cache_wr_addr =
        (wr_comp == 2'd0) ? ({13'b0, wr_y[5:0]} * CACHE_WIDTH + {7'b0, wr_x})     :
        (wr_comp == 2'd1) ? (CACHE_CB_OFF + {13'b0, wr_y[5:0]} * (CACHE_WIDTH/2) + {7'b0, wr_x}) :
                            (CACHE_CR_OFF + {13'b0, wr_y[5:0]} * (CACHE_WIDTH/2) + {7'b0, wr_x});

    always @(posedge clk) begin
        if (wr_valid && wr_ready)
            line_cache[cache_wr_addr] <= wr_pixel;
    end

    // Cache read for deblocking (driven externally via cache_x, cache_y, cache_comp)
    // Simple registered read — 1 cycle latency
    wire [18:0] cache_rd_addr =
        (cache_comp == 2'd0) ? ({13'b0, cache_y[5:0]} * CACHE_WIDTH + {7'b0, cache_x}) :
        (cache_comp == 2'd1) ? (CACHE_CB_OFF + {13'b0, cache_y[5:0]} * (CACHE_WIDTH/2) + {7'b0, cache_x}) :
                               (CACHE_CR_OFF + {13'b0, cache_y[5:0]} * (CACHE_WIDTH/2) + {7'b0, cache_x});

    reg [`PIXEL_WIDTH-1:0] cache_pixel_r;
    always @(posedge clk)
        cache_pixel_r <= line_cache[cache_rd_addr];

    assign cache_valid = 1'b1;  // always valid after 1 cycle
    assign cache_pixel = cache_pixel_r;

    //-------------------------------------------------------------------------
    // Simulation checks
    //-------------------------------------------------------------------------
    // synthesis translate_off
    always @(posedge clk) begin
        if (rst_n) begin
            if (alloc_valid && alloc_ready && !any_free)
                $display("ERROR [frame_store] DPB full — cannot allocate slot at time=%0t", $time);
            if (free_valid && !slot_valid[free_slot])
                $display("WARN  [frame_store] freeing empty slot %0d at time=%0t",
                         free_slot, $time);
        end
    end
    // synthesis translate_on

endmodule