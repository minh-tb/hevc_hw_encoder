//=============================================================================
// cabac_if.sv
// SystemVerilog Interface for HEVC CABAC M-Coder (rtl/entropy/range_coder.v)
// Enforces wire DUT outputs, deterministic initial values, and SVA assertions.
//=============================================================================

`timescale 1ns/1ps

interface cabac_if (
    input logic clk,
    input logic rst_n
);

    // Slice initialization
    logic        coder_init;

    // Bin input (regular, EP bypass, terminating)
    logic        bin_valid;
    logic        bin_value;
    logic [5:0]  bin_pstate;
    logic        bin_valmps;
    logic [7:0]  bin_ctx_id;
    wire         bin_ready;
    logic        ep_valid;
    logic        trm_valid;

    // Flush handshake
    logic        flush_valid;
    wire         flush_done;

    // Byte output channel
    wire         byte_valid;
    wire  [7:0]  byte_out;
    logic        byte_ready;

    // Status
    wire         coder_busy;

    // -------------------------------------------------------------------------
    // Deterministic Time-0 Initialization for TB-Driven Inputs
    // -------------------------------------------------------------------------
    initial begin
        coder_init  = 1'b0;
        bin_valid   = 1'b0;
        bin_value   = 1'b0;
        bin_pstate  = 6'd0;
        bin_valmps  = 1'b0;
        bin_ctx_id  = 8'd0;
        ep_valid    = 1'b0;
        trm_valid   = 1'b0;
        flush_valid = 1'b0;
        byte_ready  = 1'b1;
    end

    // -------------------------------------------------------------------------
    // SVA Protocol Assertions
    // -------------------------------------------------------------------------
    property p_byte_hold_on_stall;
        @(posedge clk) disable iff (!rst_n)
        (byte_valid && !byte_ready) |=> ($stable(byte_out) && byte_valid);
    endproperty
    a_byte_hold_on_stall: assert property (p_byte_hold_on_stall)
        else $error("[CABAC_IF] SVA violation p_byte_hold_on_stall at %0t: byte_out=0x%02x, byte_valid=%0b",
                    $time, byte_out, byte_valid);

    property p_flush_done_pulse;
        @(posedge clk) disable iff (!rst_n)
        flush_done |=> !flush_done;
    endproperty
    a_flush_done_pulse: assert property (p_flush_done_pulse)
        else $error("[CABAC_IF] SVA violation p_flush_done_pulse at %0t: flush_done stayed asserted > 1 cycle",
                    $time);

endinterface
