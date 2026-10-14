`timescale 1ns / 1ps

module axi_read_arbiter (
    input  wire         clk,
    input  wire         rst_n,

    // Port 0 (High Priority - ref_frame_buffer)
    input  wire         p0_arvalid,
    output wire         p0_arready,
    input  wire [32:0]  p0_araddr,
    input  wire [7:0]   p0_arlen,
    input  wire [2:0]   p0_arsize,
    input  wire [1:0]   p0_arburst,
    output wire         p0_rvalid,
    input  wire         p0_rready,
    output wire [255:0] p0_rdata,
    output wire         p0_rlast,

    // Port 1 (Low Priority - frame_store)
    input  wire         p1_arvalid,
    output wire         p1_arready,
    input  wire [32:0]  p1_araddr,
    input  wire [7:0]   p1_arlen,
    input  wire [2:0]   p1_arsize,
    input  wire [1:0]   p1_arburst,
    output wire         p1_rvalid,
    input  wire         p1_rready,
    output wire [255:0] p1_rdata,
    output wire         p1_rlast,

    // AXI Master Port
    output wire         m_arvalid,
    input  wire         m_arready,
    output wire [32:0]  m_araddr,
    output wire [7:0]   m_arlen,
    output wire [2:0]   m_arsize,
    output wire [1:0]   m_arburst,
    input  wire         m_rvalid,
    output wire         m_rready,
    input  wire [255:0] m_rdata,
    input  wire         m_rlast
);

    reg sel;          // 0 for p0, 1 for p1 (latched during AR handshake for R-channel)
    reg active_read;  // 1 while waiting for R-data after AR handshake

    wire arb_sel = !p0_arvalid && p1_arvalid; // 0 for p0, 1 for p1
    wire ar_handshake = m_arvalid && m_arready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sel         <= 1'b0;
            active_read <= 1'b0;
        end else begin
            if (active_read) begin
                if (m_rvalid && m_rready && m_rlast) begin
                    active_read <= 1'b0;
                end
            end else if (ar_handshake) begin
                sel         <= arb_sel;
                active_read <= 1'b1;
            end
        end
    end

    // AR Channel: passed directly when no read is in-flight
    assign m_arvalid  = !active_read && (p0_arvalid || p1_arvalid);
    assign m_araddr   = arb_sel ? p1_araddr : p0_araddr;
    assign m_arlen    = arb_sel ? p1_arlen : p0_arlen;
    assign m_arsize   = arb_sel ? p1_arsize : p0_arsize;
    assign m_arburst  = arb_sel ? p1_arburst : p0_arburst;

    assign p0_arready = (!active_read && !arb_sel) ? m_arready : 1'b0;
    assign p1_arready = (!active_read &&  arb_sel) ? m_arready : 1'b0;

    // R Channel: routed to selected port
    assign p0_rvalid  = (!sel && active_read) ? m_rvalid : 1'b0;
    assign p1_rvalid  = ( sel && active_read) ? m_rvalid : 1'b0;
    assign p0_rdata   = m_rdata;
    assign p1_rdata   = m_rdata;
    assign p0_rlast   = m_rlast;
    assign p1_rlast   = m_rlast;

    assign m_rready   = active_read ? (sel ? p1_rready : p0_rready) : 1'b0;

endmodule
