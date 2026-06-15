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

    reg sel; // 0 for p0, 1 for p1

    always @(posedge clk) begin
        if (!rst_n) begin
            sel <= 1'b0;
        end else begin
            if (m_arvalid && m_arready) begin
                // Lock selection until burst completes
            end else if (m_rvalid && m_rready && m_rlast) begin
                // Burst complete, unlock
                if (p0_arvalid) sel <= 1'b0;
                else if (p1_arvalid) sel <= 1'b1;
            end else if (!m_arvalid && !m_rvalid) begin
                // Idle, update selection
                if (p0_arvalid) sel <= 1'b0;
                else if (p1_arvalid) sel <= 1'b1;
            end
        end
    end

    // AR Channel
    assign m_arvalid  = sel ? p1_arvalid : p0_arvalid;
    assign m_araddr   = sel ? p1_araddr : p0_araddr;
    assign m_arlen    = sel ? p1_arlen : p0_arlen;
    assign m_arsize   = sel ? p1_arsize : p0_arsize;
    assign m_arburst  = sel ? p1_arburst : p0_arburst;

    assign p0_arready = !sel ? m_arready : 1'b0;
    assign p1_arready =  sel ? m_arready : 1'b0;

    // R Channel
    assign p0_rvalid  = !sel ? m_rvalid : 1'b0;
    assign p1_rvalid  =  sel ? m_rvalid : 1'b0;
    assign p0_rdata   = m_rdata;
    assign p1_rdata   = m_rdata;
    assign p0_rlast   = m_rlast;
    assign p1_rlast   = m_rlast;

    assign m_rready   = sel ? p1_rready : p0_rready;

endmodule
