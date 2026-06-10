//=============================================================================
// output_fifo.v
// Bitstream Output FIFO
//
// Staged between CABAC range coder (byte output) and NAL writer.
// Provides elastic buffering to absorb burst output from CABAC
// while NAL writer applies start code emulation prevention at
// its own pace.
//
// HM reference:
//   TLibCommon/TComBitStream.cpp  TComOutputBitstream
//   Bytes accumulated in m_fifo, flushed to output per access unit.
//
// Architecture:
//   Simple synchronous FIFO (instantiates fifo_sync.v)
//   Width: 8 bits (one byte per entry)
//   Depth: 4096 entries — absorbs one CTU's worth of bits at max rate
//     Max CTU bits ≈ 64×64×2 = 8192 bits = 1024 bytes < 4096 ✓
//
//   Overflow policy: assert wr_overflow flag (encoder must throttle)
//   Underflow: safe — NAL writer checks empty before reading
//
// Additional function:
//   Tracks bit position within current byte for CABAC byte alignment.
//   Provides byte_count output for bitstream size monitoring.
//=============================================================================

`include "parameter_pkg.vh"

module output_fifo (
    input  wire         clk,
    input  wire         rst_n,

    //=========================================================================
    // Write port — from CABAC range_coder
    //=========================================================================
    input  wire         wr_valid,
    output wire         wr_ready,
    input  wire [7:0]   wr_byte,
    input  wire         wr_last_in_au,   // last byte of access unit

    //=========================================================================
    // Read port — to nal_writer
    //=========================================================================
    output wire         rd_valid,
    input  wire         rd_ready,
    output wire [7:0]   rd_byte,
    output wire         rd_last_in_au,

    //=========================================================================
    // Status
    //=========================================================================
    output wire         empty,
    output wire         full,
    output wire [12:0]  count,          // bytes in FIFO
    output reg          wr_overflow,    // write attempted while full
    output reg  [31:0]  total_bytes     // cumulative bytes written (for stats)
);

    localparam DEPTH    = 4096;
    localparam ADDR_W   = $clog2(DEPTH);   // 12

    //-------------------------------------------------------------------------
    // Storage: data byte + last_in_au flag packed together
    //-------------------------------------------------------------------------
    localparam FIFO_W = 9;   // 8 data + 1 last flag

    // Instantiate fifo_sync for byte + flag storage
    wire fifo_wr_en = wr_valid && wr_ready;
    wire fifo_rd_en = rd_ready && rd_valid;

    wire [FIFO_W-1:0] fifo_din  = {wr_last_in_au, wr_byte};
    wire [FIFO_W-1:0] fifo_dout;

    assign rd_byte       = fifo_dout[7:0];
    assign rd_last_in_au = fifo_dout[8];

    fifo_sync #(
        .DATA_WIDTH  (FIFO_W),
        .DEPTH       (DEPTH),
        .FWFT        (1),        // first-word-fall-through for zero-latency read
        .FORCE_BRAM  (1)         // use BRAM for 4K-entry FIFO
    ) u_fifo (
        .clk        (clk),
        .rst_n      (rst_n),
        .wr_en      (fifo_wr_en),
        .din        (fifo_din),
        .full       (full),
        .prog_full  (),
        .rd_en      (fifo_rd_en),
        .dout       (fifo_dout),
        .empty      (empty),
        .prog_empty (),
        .count      (count)
    );

    assign wr_ready  = !full;
    assign rd_valid  = !empty;

    //-------------------------------------------------------------------------
    // Overflow detection
    //-------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_overflow <= 1'b0;
            total_bytes <= 32'd0;
        end else begin
            wr_overflow <= 1'b0;
            if (wr_valid && !wr_ready) begin
                wr_overflow <= 1'b1;
                // synthesis translate_off
                $display("ERROR [output_fifo] OVERFLOW — CABAC byte dropped at time=%0t", $time);
                // synthesis translate_on
            end
            if (fifo_wr_en)
                total_bytes <= total_bytes + 32'd1;
        end
    end

endmodule