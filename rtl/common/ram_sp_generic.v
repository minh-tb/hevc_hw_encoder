//=============================================================================
// ram_sp_generic.v
// Single-Port SRAM Generic Wrapper
//
// Used by:
//   ctx_model_store.v   — 154 CABAC context model entries (7-bit each)
//   intra_angular.v     — refExt buffer (small, LUTRAM)
//   ctu_partitioner.v   — quadtree stack (16-entry, registers)
//   pu_cu_splitter.v    — TU stack (32-entry, registers)
//
// Architecture:
//   Single clock domain, synchronous read/write
//   Read-first mode: on simultaneous read+write to same address,
//   dout reflects the OLD data (read before write)
//   This is the safe default for Xilinx BRAM and matches most ASIC SRAMs
//
//   For ASIC: replace the mem array with foundry SRAM macro
//   For FPGA: (* ram_style = "auto" *) lets tool choose BRAM or LUTRAM
//             based on depth/width — tool chooses BRAM for depth >= 512
//
// Parameters:
//   DATA_WIDTH  — word width in bits
//   DEPTH       — number of words (need not be power-of-2 for single-port)
//   ADDR_WIDTH  — address bits = ceil(log2(DEPTH))
//   READ_LATENCY— 1=registered output (BRAM), 0=combinational (LUTRAM/reg)
//   INIT_VAL    — optional reset value for simulation
//=============================================================================

`include "parameter_pkg.vh"

module ram_sp_generic #(
    parameter DATA_WIDTH  = 8,
    parameter DEPTH       = 256,
    parameter ADDR_WIDTH  = $clog2(DEPTH),
    parameter READ_LATENCY= 1,          // 1=registered, 0=combinational
    parameter INIT_VAL    = 0           // simulation init value
)(
    input  wire                  clk,
    input  wire                  en,    // chip enable
    input  wire                  we,    // write enable
    input  wire [ADDR_WIDTH-1:0] addr,
    input  wire [DATA_WIDTH-1:0] din,
    output wire [DATA_WIDTH-1:0] dout
);

    //-------------------------------------------------------------------------
    // Memory array
    //-------------------------------------------------------------------------
    (* ram_style = "auto" *)
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    //-------------------------------------------------------------------------
    // Optional initialisation (simulation)
    //-------------------------------------------------------------------------
    // synthesis translate_off
    integer init_i;
    initial begin
        for (init_i = 0; init_i < DEPTH; init_i = init_i + 1)
            mem[init_i] = INIT_VAL;
    end
    // synthesis translate_on

    //-------------------------------------------------------------------------
    // Write port
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (en && we)
            mem[addr] <= din;
    end

    //-------------------------------------------------------------------------
    // Read port
    // READ_LATENCY=1: registered output — guaranteed BRAM inference
    // READ_LATENCY=0: combinational — infers as LUTRAM or registers
    //-------------------------------------------------------------------------
    generate
        if (READ_LATENCY == 1) begin : gen_reg_read

            reg [DATA_WIDTH-1:0] dout_r;

            // READ_FIRST: read outside we condition (BRAM inference template)
            always @(posedge clk) begin
                if (en)
                    dout_r <= mem[addr];
            end

            assign dout = dout_r;

        end else begin : gen_comb_read

            // Combinational read — for small register-file style arrays
            assign dout = mem[addr];

        end
    endgenerate

    //-------------------------------------------------------------------------
    // Simulation checks
    //-------------------------------------------------------------------------
    // synthesis translate_off
    always @(posedge clk) begin
        if (en && !we && addr >= DEPTH)
            $display("ERROR [ram_sp_generic] read addr=%0d out of range (DEPTH=%0d) t=%0t",
                     addr, DEPTH, $time);
        if (en && we && addr >= DEPTH)
            $display("ERROR [ram_sp_generic] write addr=%0d out of range (DEPTH=%0d) t=%0t",
                     addr, DEPTH, $time);
    end
    // synthesis translate_on

endmodule