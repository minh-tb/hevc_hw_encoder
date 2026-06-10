//=============================================================================
// ref_frame_buffer.v
// Decoded Reference Frame Buffer — Ping-Pong SRAM + AXI DDR Interface
//
// Mapped from HM source:
//   TLibCommon/TComPicYuv.cpp  :: getLumaAddr() / getCbAddr() / getCrAddr()
//   TLibCommon/TComPrediction.cpp :: xPadding() / getPaddedBuf()
//   TLibCommon/TComPic.cpp     :: getPicYuvRec() — reconstructed picture access
//
// HM reference access model:
//   Pel* refPtr = refPic->getAddr(compID)         // base pointer
//               + yInt * refPic->getStride(compID) // row offset
//               + xInt;                             // column offset
//   Border padding: HM pads reference frame by MAX_FILTER_SIZE/2 pixels
//   For luma 8-tap: 4 pixels each side → stored contiguously
//   Hardware equivalent: clamp addressing + border pixel replication
//
// Architecture:
//   For each MC request (comp, slot, x, y):
//   1. Row-by-row DDR fetch for BLK_EXT rows (11 luma, 5 chroma)
//   2. Each row: 1-2 AXI 256-bit beats covering BLK_EXT pixels
//   3. Border clamping: x → [0, frame_w-1], y → [0, frame_h-1]
//   4. Pixel extraction from 256-bit beats (same packing as frame_store.v)
//   5. Assembly into extended flat block → drive ref_resp_*_flat
//
// Pixel packing (identical to frame_store.v):
//   2 pixels per 32-bit word: word[9:0]=even pixel, word[25:16]=odd pixel
//   16 pixels per 256-bit AXI beat
//   Pixel byte addr = comp_base + (y*stride + x) * 2
//   Beat addr = pixel_byte_addr & ~32'h1F  (32-byte aligned)
//
// Frame layout in DDR (Main10 4K, matches frame_store.v localparams):
//   LUMA_SAMPLES   = 3840 × 2160 = 8,294,400
//   LUMA_WORDS     = LUMA_SAMPLES / 2 = 4,147,200
//   CB_OFFSET_BYTES = LUMA_WORDS × 4 = 16,588,800
//   CR_OFFSET_BYTES = CB_OFFSET_BYTES + CHROMA_WORDS × 4 = 20,736,000
//   SLOT_STRIDE_BYTES = FRAME_WORDS × 4 = 24,883,200   (per DPB slot)
//
// Border clamping (replicate-pad, matches HM TComPicYuv::extendPicBorder):
//   x < 0           → use pixel at x=0           (left edge replication)
//   x >= frame_w    → use pixel at x=frame_w-1   (right edge replication)
//   y < 0           → use pixel at y=0           (top edge replication)
//   y >= frame_h    → use pixel at y=frame_h-1   (bottom edge replication)
//
// AXI4 read port: 256-bit data, 33-bit address, burst length=1 (single beat)
//
// FSM per request:
//   IDLE → INIT → [per row: ROW_AR1 → ROW_R1 → (ROW_AR2 → ROW_R2) → ROW_STORE]
//        → DONE (→ IDLE)
//   11 rows × (1 or 2 beats) + overhead ≈ 80-100 cycles per luma extended block
//=============================================================================

`include "parameter_pkg.vh"

module ref_frame_buffer #(
    parameter PIXEL_WIDTH  = `PIXEL_WIDTH,   // 10
    parameter BLK_SIZE     = 4,              // CU size (luma)

    // Derived block extension sizes (matches hpel_filter_luma/chroma)
    parameter BLK_EXT_Y    = BLK_SIZE + 7,  // 11: luma extended (8-tap border 3+4)
    parameter BLK_EXT_C    = BLK_SIZE/2 + 3,// 5:  chroma extended (4-tap border 1+2)

    // Frame dimensions (Main10 4K)
    parameter FRAME_W_Y    = 3840,
    parameter FRAME_H_Y    = 2160,
    parameter FRAME_W_C    = 1920,
    parameter FRAME_H_C    = 1080,

    // AXI
    parameter AXI_DW       = 256,
    parameter AXI_AW       = 33,

    // DDR layout (must match frame_store.v)
    parameter LUMA_SAMPLES  = FRAME_W_Y * FRAME_H_Y,           // 8,294,400
    parameter CHROMA_SAMPLES = FRAME_W_C * FRAME_H_C,          // 2,073,600
    parameter LUMA_WORDS    = LUMA_SAMPLES   / 2,              // 4,147,200
    parameter CHROMA_WORDS  = CHROMA_SAMPLES / 2,              // 1,036,800
    parameter FRAME_WORDS   = LUMA_WORDS + 2*CHROMA_WORDS,     // 6,220,800
    parameter CB_OFFSET     = LUMA_WORDS  * 4,                 // bytes
    parameter CR_OFFSET     = CB_OFFSET + CHROMA_WORDS * 4,    // bytes
    parameter SLOT_STRIDE   = FRAME_WORDS * 4,                 // bytes

    // Output flat vector widths
    parameter PX_EXT_Y     = PIXEL_WIDTH * BLK_EXT_Y * BLK_EXT_Y,  // 1210
    parameter PX_EXT_C     = PIXEL_WIDTH * BLK_EXT_C * BLK_EXT_C   //  250
)(
    input  wire clk,
    input  wire rst_n,

    // Request port — from mc_unit / tz_search
    input  wire                      ref_req_valid,
    output reg                       ref_req_ready,
    input  wire [1:0]                ref_req_comp,   // 0=Y, 1=Cb, 2=Cr
    input  wire [2:0]                ref_req_slot,   // DPB frame slot
    input  wire [11:0]               ref_req_x,      // top-left x of extended region
    input  wire [11:0]               ref_req_y,      // top-left y of extended region
    // (signed interpretation: negative = left/above frame border)

    // Response port — to mc_unit
    output reg                       ref_resp_valid,
    output reg  [PX_EXT_Y-1:0]      ref_resp_y_flat,
    output reg  [PX_EXT_C-1:0]      ref_resp_cb_flat,
    output reg  [PX_EXT_C-1:0]      ref_resp_cr_flat,

    // AXI4 Read Channel — to DDR controller
    output reg                       axi_arvalid,
    input  wire                      axi_arready,
    output reg  [AXI_AW-1:0]        axi_araddr,
    output reg  [7:0]                axi_arlen,   // 0 = 1 beat
    output reg  [2:0]                axi_arsize,  // 3'b101 = 32 bytes
    output reg  [1:0]                axi_arburst, // 2'b01  = INCR
    input  wire                      axi_rvalid,
    output wire                      axi_rready,
    input  wire [AXI_DW-1:0]        axi_rdata,
    input  wire                      axi_rlast
);

    // =========================================================================
    // FSM encoding
    // =========================================================================
    localparam [3:0]
        S_IDLE      = 4'd0,
        S_INIT      = 4'd1,
        S_ROW_AR1   = 4'd2,   // AXI AR for beat 1 of current row
        S_ROW_R1    = 4'd3,   // AXI R  for beat 1
        S_ROW_AR2   = 4'd4,   // AXI AR for beat 2 (if row spans 2 beats)
        S_ROW_R2    = 4'd5,   // AXI R  for beat 2
        S_ROW_STORE = 4'd6,   // extract + store row pixels into ext_block
        S_NEXT_ROW  = 4'd7,   // increment row counter
        S_DONE      = 4'd8;

    reg [3:0] state;

    // Always ready to accept AXI R data when in R-wait states
    assign axi_rready = (state == S_ROW_R1) || (state == S_ROW_R2);

    // =========================================================================
    // Request registers
    // =========================================================================
    reg  [1:0]   comp_r;
    reg  [2:0]   slot_r;
    reg  signed [12:0] req_x_r;   // 13-bit signed (can be negative for border)
    reg  signed [12:0] req_y_r;

    // Current row being fetched (0 .. BLK_EXT-1)
    reg  [3:0]   row_idx;         // max BLK_EXT_Y=11 → 4 bits

    // Frame dimension and stride for current component
    reg  [11:0]  frame_w, frame_h;
    reg  [11:0]  stride;
    reg  [32:0]  comp_base;       // byte offset of component in DDR slot
    reg  [32:0]  slot_base;       // byte offset of DPB slot

    // AXI beat data latches (two beats per row)
    reg [AXI_DW-1:0] beat1_data, beat2_data;
    reg               need_beat2;    // row spans two 256-bit beats

    // =========================================================================
    // Extended block accumulator
    // One register bank, sized for max (luma: 11×11×10 = 1210 bits)
    // =========================================================================
    reg [PIXEL_WIDTH-1:0] ext_buf [0:BLK_EXT_Y-1][0:BLK_EXT_Y-1];

    // Current BLK_EXT (depends on component)
    wire [3:0] blk_ext_cur = (comp_r == 2'd0) ? BLK_EXT_Y : BLK_EXT_C;

    // =========================================================================
    // Address computation helpers
    // =========================================================================

    // Clamp signed coordinate to [0, max-1]
    function [11:0] clamp_coord;
        input signed [12:0] v;
        input [11:0]         maxv;
        begin
            if (v < 13'sd0)
                clamp_coord = 12'd0;
            else if ($signed(v) >= $signed({1'b0, maxv}))
                clamp_coord = maxv - 12'd1;
            else
                clamp_coord = v[11:0];
        end
    endfunction

    // Compute DDR byte address for pixel (x, y, comp, slot)
    // Matches frame_store.v address formula
    function [AXI_AW-1:0] pixel_byte_addr;
        input [11:0]  px, py;
        input [11:0]  pstride;
        input [32:0]  pcomp_base;
        input [32:0]  pslot_base;
        reg   [32:0]  row_word_offset;
        begin
            row_word_offset = {1'b0, py} * {1'b0, pstride} + {1'b0, px};
            pixel_byte_addr = pslot_base + pcomp_base + row_word_offset * 33'd2;
        end
    endfunction

    // Extract pixel from 256-bit beat at byte-address px_addr within beat
    function [PIXEL_WIDTH-1:0] extract_pixel;
        input [AXI_DW-1:0] beat;
        input [AXI_AW-1:0] px_addr;   // full pixel byte address
        reg   [2:0]  word_idx;
        reg   [31:0] word32;
        begin
            word_idx        = px_addr[4:2];                      // which 32-bit word in beat
            word32          = beat >> ({word_idx, 5'd0});         // right-justify word
            extract_pixel   = px_addr[1] ? word32[25:16] : word32[9:0]; // even/odd pixel
        end
    endfunction

    // =========================================================================
    // Clamped pixel coordinates for current row / current column
    // =========================================================================
    wire signed [12:0] cur_y_raw  = req_y_r + $signed({9'b0, row_idx});
    wire [11:0]         cur_y_cl   = clamp_coord(cur_y_raw, frame_h);

    // Pixel addresses for beat 1 and beat 2 of this row
    // Beat 1: covers pixel at req_x (possibly clamped), aligned down to 32-byte boundary
    // Beat 2: next 32-byte beat (for pixels that overflow beat 1)
    wire [AXI_AW-1:0] px0_addr = pixel_byte_addr(
                                    clamp_coord(req_x_r, frame_w),
                                    cur_y_cl, stride, comp_base, slot_base);
    wire [AXI_AW-1:0] beat1_addr = px0_addr & ~33'h1F;   // 32-byte aligned
    wire [AXI_AW-1:0] beat2_addr = beat1_addr + 33'd32;  // next beat

    // Check if last pixel of the row falls in a different beat
    wire [AXI_AW-1:0] px_last_addr = pixel_byte_addr(
                        clamp_coord(req_x_r + $signed({9'b0, blk_ext_cur - 4'd1}), frame_w),
                        cur_y_cl, stride, comp_base, slot_base);
    wire spans_two_beats = (px_last_addr[AXI_AW-1:5] != px0_addr[AXI_AW-1:5]);

    // =========================================================================
    // Main FSM
    // =========================================================================
    integer ci;  // column loop variable

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= S_IDLE;
            ref_req_ready  <= 1'b1;
            ref_resp_valid <= 1'b0;
            axi_arvalid    <= 1'b0;
            row_idx        <= 4'd0;
        end else begin
            axi_arvalid    <= 1'b0;
            ref_resp_valid <= 1'b0;

            case (state)

            // ---------------------------------------------------------------
            S_IDLE: begin
                ref_req_ready <= 1'b1;
                if (ref_req_valid) begin
                    ref_req_ready <= 1'b0;
                    state         <= S_INIT;
                end
            end

            // ---------------------------------------------------------------
            // INIT — latch request, resolve frame parameters
            // ---------------------------------------------------------------
            S_INIT: begin
                comp_r    <= ref_req_comp;
                slot_r    <= ref_req_slot;
                req_x_r   <= {ref_req_x[11], ref_req_x}; // fix: properly sign-extend for border math
                req_y_r   <= {ref_req_y[11], ref_req_y};
                row_idx   <= 4'd0;
                slot_base <= {30'b0, ref_req_slot} * SLOT_STRIDE;

                // Component-specific frame dimensions and DDR base offset
                case (ref_req_comp)
                    2'd0: begin  // Luma
                        frame_w   <= FRAME_W_Y;
                        frame_h   <= FRAME_H_Y;
                        stride    <= FRAME_W_Y;
                        comp_base <= 33'd0;
                    end
                    2'd1: begin  // Cb
                        frame_w   <= FRAME_W_C;
                        frame_h   <= FRAME_H_C;
                        stride    <= FRAME_W_C;
                        comp_base <= CB_OFFSET;
                    end
                    default: begin  // Cr
                        frame_w   <= FRAME_W_C;
                        frame_h   <= FRAME_H_C;
                        stride    <= FRAME_W_C;
                        comp_base <= CR_OFFSET;
                    end
                endcase
                state <= S_ROW_AR1;
            end

            // ---------------------------------------------------------------
            // ROW_AR1 — issue AXI AR for beat 1 of current row
            // ---------------------------------------------------------------
            S_ROW_AR1: begin
                axi_arvalid  <= 1'b1;
                axi_araddr   <= beat1_addr;
                axi_arlen    <= 8'd0;         // 1 beat
                axi_arsize   <= 3'b101;       // 32 bytes
                axi_arburst  <= 2'b01;        // INCR
                need_beat2   <= spans_two_beats;
                if (axi_arvalid && axi_arready) begin
                    axi_arvalid <= 1'b0;
                    state       <= S_ROW_R1;
                end
            end

            // ---------------------------------------------------------------
            // ROW_R1 — receive beat 1 data
            // ---------------------------------------------------------------
            S_ROW_R1: begin
                if (axi_rvalid) begin
                    beat1_data <= axi_rdata;
                    state      <= need_beat2 ? S_ROW_AR2 : S_ROW_STORE;
                end
            end

            // ---------------------------------------------------------------
            // ROW_AR2 / ROW_R2 — second beat (when row spans beat boundary)
            // ---------------------------------------------------------------
            S_ROW_AR2: begin
                axi_arvalid <= 1'b1;
                axi_araddr  <= beat2_addr;
                axi_arlen   <= 8'd0;
                axi_arsize  <= 3'b101;
                axi_arburst <= 2'b01;
                if (axi_arvalid && axi_arready) begin
                    axi_arvalid <= 1'b0;
                    state       <= S_ROW_R2;
                end
            end

            S_ROW_R2: begin
                if (axi_rvalid) begin
                    beat2_data <= axi_rdata;
                    state      <= S_ROW_STORE;
                end
            end

            // ---------------------------------------------------------------
            // ROW_STORE — extract BLK_EXT pixels for this row into ext_buf
            //
            // For each column ci (0 .. blk_ext_cur-1):
            //   x_raw = req_x + ci  (possibly negative / out of frame)
            //   x_cl  = clamp(x_raw, 0, frame_w-1)
            //   px_addr = pixel_byte_addr(x_cl, cur_y_cl)
            //   If px_addr in beat1: use beat1_data, else beat2_data
            //   Extract pixel using extract_pixel()
            // ---------------------------------------------------------------
            S_ROW_STORE: begin
                for (ci = 0; ci < BLK_EXT_Y; ci = ci + 1) begin
                    if (ci < blk_ext_cur) begin : px_extract
                        reg signed [12:0] x_raw;
                        reg [11:0]         x_cl;
                        reg [AXI_AW-1:0]  px_addr;
                        reg [AXI_DW-1:0]  src_beat;
                        x_raw    = req_x_r + ci;
                        x_cl     = clamp_coord(x_raw, frame_w);
                        px_addr  = pixel_byte_addr(x_cl, cur_y_cl,
                                                   stride, comp_base, slot_base);
                        // Select which beat the pixel came from
                        src_beat = (px_addr[AXI_AW-1:5] == beat1_addr[AXI_AW-1:5])
                                 ? beat1_data : beat2_data;
                        ext_buf[row_idx][ci] <= extract_pixel(src_beat, px_addr);
                    end
                end
                state <= S_NEXT_ROW;
            end

            // ---------------------------------------------------------------
            // NEXT_ROW — advance row, check completion
            // ---------------------------------------------------------------
            S_NEXT_ROW: begin
                if (row_idx == blk_ext_cur - 1) begin
                    state <= S_DONE;
                end else begin
                    row_idx <= row_idx + 4'd1;
                    state   <= S_ROW_AR1;
                end
            end

            // ---------------------------------------------------------------
            // DONE — pack ext_buf into response flat vectors
            // ---------------------------------------------------------------
            S_DONE: begin : pack_output
                integer r, c;
                ref_resp_valid <= 1'b1;
                ref_req_ready  <= 1'b1;

                // Zero all response buses first (only requested comp will be populated)
                ref_resp_y_flat  <= {PX_EXT_Y{1'b0}};
                ref_resp_cb_flat <= {PX_EXT_C{1'b0}};
                ref_resp_cr_flat <= {PX_EXT_C{1'b0}};

                case (comp_r)
                    2'd0: begin  // Luma — pack BLK_EXT_Y × BLK_EXT_Y
                        for (r = 0; r < BLK_EXT_Y; r = r + 1)
                            for (c = 0; c < BLK_EXT_Y; c = c + 1)
                                ref_resp_y_flat[PIXEL_WIDTH*(BLK_EXT_Y*r+c) +: PIXEL_WIDTH]
                                    <= ext_buf[r][c];
                    end
                    2'd1: begin  // Cb — pack BLK_EXT_C × BLK_EXT_C
                        for (r = 0; r < BLK_EXT_C; r = r + 1)
                            for (c = 0; c < BLK_EXT_C; c = c + 1)
                                ref_resp_cb_flat[PIXEL_WIDTH*(BLK_EXT_C*r+c) +: PIXEL_WIDTH]
                                    <= ext_buf[r][c];
                    end
                    default: begin  // Cr
                        for (r = 0; r < BLK_EXT_C; r = r + 1)
                            for (c = 0; c < BLK_EXT_C; c = c + 1)
                                ref_resp_cr_flat[PIXEL_WIDTH*(BLK_EXT_C*r+c) +: PIXEL_WIDTH]
                                    <= ext_buf[r][c];
                    end
                endcase

                state <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

    // =========================================================================
    // Simulation assertions
    // =========================================================================
    // synthesis translate_off
    always @(posedge clk) begin
        if (ref_resp_valid)
            $display("INFO [ref_frame_buf] resp: comp=%0d slot=%0d x=%0d y=%0d blk_ext=%0d",
                     comp_r, slot_r,
                     $signed(req_x_r), $signed(req_y_r), blk_ext_cur);
        if (state == S_ROW_STORE) begin
            if (cur_y_cl != cur_y_raw[11:0] && cur_y_raw >= 13'sd0)
                $display("INFO [ref_frame_buf] y clamped: raw=%0d → %0d (frame_h=%0d)",
                         $signed(cur_y_raw), cur_y_cl, frame_h);
        end
    end
    // synthesis translate_off

endmodule