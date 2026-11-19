//=============================================================================
// tb_uvm_cabac.sv
// UVM 1.2 Top-Level Testbench for HEVC CABAC M-Coder (rtl/entropy/range_coder.v)
//=============================================================================

`timescale 1ns/1ps

module tb_uvm_cabac;

    import uvm_pkg::*;
    `include "uvm_macros.svh"
    import cabac_uvm_pkg::*;

    // Clock & Reset
    logic clk;
    logic rst_n;

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk; // 100 MHz
    end

    initial begin
        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
    end

    // Watchdog timeout guard
    initial begin
        #10_000_000; // 10 ms limit
        `uvm_fatal("TB_TOP", "Simulation timeout (10 ms) reached - possible deadlock!")
    end

    // Interface Instance
    cabac_if vif (
        .clk   (clk),
        .rst_n (rst_n)
    );

    // DUT Instance
    range_coder dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .coder_init (vif.coder_init),
        .bin_valid  (vif.bin_valid),
        .bin_value  (vif.bin_value),
        .bin_pstate (vif.bin_pstate),
        .bin_valmps (vif.bin_valmps),
        .bin_ctx_id (vif.bin_ctx_id),
        .bin_ready  (vif.bin_ready),
        .ep_valid   (vif.ep_valid),
        .trm_valid  (vif.trm_valid),
        .flush_valid(vif.flush_valid),
        .flush_done (vif.flush_done),
        .byte_valid (vif.byte_valid),
        .byte_out   (vif.byte_out),
        .byte_ready (vif.byte_ready),
        .coder_busy (vif.coder_busy)
    );

    // UVM Configuration & Test Execution
    initial begin
        uvm_config_db#(virtual cabac_if)::set(null, "*", "vif", vif);
        run_test("cabac_uvm_test");
    end

endmodule
