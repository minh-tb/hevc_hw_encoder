`timescale 1ns / 1ps
//=============================================================================
// nal_parser.v
// Annex B NAL Unit Parser & Emulation Prevention Stripper
//
// Uses a 3-byte lookahead window to prevent Start Codes (00 00 01) and 
// Emulation Prevention Bytes (00 00 03) from leaking into the RBSP payload.
//=============================================================================

`include "parameter_pkg.vh"

module nal_parser (
    input  wire         clk,
    input  wire         rst_n,

    // Raw bitstream input
    input  wire         in_valid,
    output wire         in_ready,
    input  wire [7:0]   in_byte,
    input  wire         in_last,

    // RBSP output
    output wire         out_valid,
    input  wire         out_ready,
    output wire [7:0]   out_byte,
    output wire         out_last
);

    //=========================================================================
    // 3-Byte Lookahead Window
    //=========================================================================
    reg [7:0] win [0:2];
    reg [2:0] valid;
    reg       in_nal;
    reg       flushing;

    wire is_sc3 = (win[0] == 8'h00) && (win[1] == 8'h00) && (win[2] == 8'h01) && (valid == 3'b111);
    wire is_epb = (win[0] == 8'h00) && (win[1] == 8'h00) && (win[2] == 8'h03) && (valid == 3'b111);

    // Output FIFO signals
    wire fifo_full;
    wire fifo_prog_full;
    reg  fifo_wr_en;
    reg  [8:0] fifo_din; // [8] = is_last, [7:0] = byte

    assign in_ready = !fifo_prog_full && !flushing;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid   <= 3'd0;
            in_nal  <= 1'b0;
            flushing<= 1'b0;
            win[0]  <= 8'd0;
            win[1]  <= 8'd0;
            win[2]  <= 8'd0;
            fifo_wr_en <= 1'b0;
            fifo_din   <= 9'd0;
        end else begin
            fifo_wr_en <= 1'b0;

            if (in_valid && in_ready) begin
                if (in_last) flushing <= 1'b1;
                // Shift in the new byte
                if (valid == 3'b000) begin
                    win[0] <= in_byte; valid <= 3'b001;
                end else if (valid == 3'b001) begin
                    win[1] <= in_byte; valid <= 3'b011;
                end else if (valid == 3'b011) begin
                    win[2] <= in_byte; valid <= 3'b111;
                end else if (valid == 3'b111) begin
                    // We have 3 bytes. Analyze them.
                    if (is_sc3) begin
                        // Found a start code! 00 00 01
                        // We are now inside a NAL unit.
                        // The start code is consumed and NOT written to FIFO.
                        in_nal <= 1'b1;
                        win[0] <= in_byte; // The current in_byte becomes the first byte of next window
                        valid  <= 3'b001;
                    end else if (is_epb) begin
                        // Emulation Prevention Byte 00 00 03
                        // The '03' (win[2]) is dropped. 
                        // We write win[0] (00) to FIFO, keep win[1] (00), and shift in_byte.
                        if (in_nal) begin
                            fifo_wr_en <= 1'b1;
                            fifo_din   <= {1'b0, win[0]};
                            win[0]     <= win[1];
                            win[1]     <= in_byte;
                            valid      <= 3'b011;
                        end else begin
                            // Outside NAL unit, just discard everything
                            valid <= 3'b000;
                        end
                    end else begin
                        // Normal sequence. 
                        // Write win[0] to FIFO, shift down, and push in_byte
                        if (in_nal) begin
                            fifo_wr_en <= 1'b1;
                            fifo_din   <= { (in_last && valid == 3'b111), win[0] };
                        end
                        win[0] <= win[1];
                        win[1] <= win[2];
                        win[2] <= in_byte;
                        valid  <= 3'b111;
                    end
                end
            end else if (!in_valid && !fifo_prog_full && flushing) begin
                if (valid == 3'b111) begin
                    fifo_wr_en <= 1'b1;
                    fifo_din   <= {1'b0, win[0]};
                    win[0]     <= win[1];
                    win[1]     <= win[2];
                    valid      <= 3'b011;
                end else if (valid == 3'b011) begin
                    fifo_wr_en <= 1'b1;
                    fifo_din   <= {1'b0, win[0]};
                    win[0]     <= win[1];
                    valid      <= 3'b001;
                end else if (valid == 3'b001) begin
                    fifo_wr_en <= 1'b1;
                    fifo_din   <= {1'b1, win[0]}; // Mark the final byte as last
                    valid      <= 3'b000;
                    flushing   <= 1'b0;
                end
            end
        end
    end

    //=========================================================================
    // Output FIFO (FWFT)
    //=========================================================================
    wire fifo_empty;
    wire [8:0] fifo_dout;
    assign out_valid = !fifo_empty;
    assign out_byte  = fifo_dout[7:0];
    assign out_last  = fifo_dout[8];

    wire fifo_rd_en = out_valid && out_ready;

    fifo_sync #(
        .DATA_WIDTH (9),
        .DEPTH      (16),
        .FWFT       (1),
        .PROG_FULL_THRESH(14)
    ) u_fifo (
        .clk        (clk),
        .rst_n      (rst_n),
        .wr_en      (fifo_wr_en),
        .din        (fifo_din),
        .full       (fifo_full),
        .prog_full  (fifo_prog_full),
        .rd_en      (fifo_rd_en),
        .dout       (fifo_dout),
        .empty      (fifo_empty),
        .prog_empty (),
        .count      ()
    );

endmodule
