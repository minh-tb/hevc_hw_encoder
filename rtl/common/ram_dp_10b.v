//=============================================================================
// ram_dp_10b.v
// Dual-Port 10-bit SRAM Macro Wrapper
//
// Used by:
//   ref_frame_buffer.v  — decoded reference frame storage
//   input_buffer.v      — incoming YUV frame staging
//   recon_unit.v        — reconstructed CTU pixel store
//   coeff store         — transform coefficient buffering
//
// Architecture:
//   Port A — write primary  (also readable)
//   Port B — read primary   (also writable)
//   True dual-port: A and B operate fully independently
//   Both ports synchronous to clk (single clock domain)
//   Output registered: data appears one cycle after address
//
// Synthesis targets:
//   FPGA  — infers Xilinx/Intel Block RAM (TRUE_DP mode)
//   ASIC  — replace ram_array instantiation with foundry SRAM macro
//
// Parameters:
//   DATA_WIDTH  — bit width per word  (default 10 for luma pixel)
//   ADDR_WIDTH  — address bits        (depth = 2^ADDR_WIDTH)
//   DEPTH       — explicit depth override (default 2^ADDR_WIDTH)
//=============================================================================

`include "parameter_pkg.vh"

module ram_dp_10b #(
    parameter DATA_WIDTH = `PIXEL_WIDTH,        // 10
    parameter ADDR_WIDTH = 12,                  // 4096 words default
    parameter DEPTH      = (1 << ADDR_WIDTH),
    parameter INIT_FILE  = ""                   // optional $readmemh init
)(
    // Port A — primary write port
    input  wire                  clk_a,
    input  wire                  en_a,          // port enable
    input  wire                  we_a,          // write enable
    input  wire [ADDR_WIDTH-1:0] addr_a,
    input  wire [DATA_WIDTH-1:0] din_a,
    output reg  [DATA_WIDTH-1:0] dout_a,        // registered, 1-cycle latency

    // Port B — primary read port
    input  wire                  clk_b,
    input  wire                  en_b,
    input  wire                  we_b,
    input  wire [ADDR_WIDTH-1:0] addr_b,
    input  wire [DATA_WIDTH-1:0] din_b,
    output reg  [DATA_WIDTH-1:0] dout_b         // registered, 1-cycle latency
);
    //-------------------------------------------------------------------------
    // For FPGA: this infers Block RAM in TRUE_DP mode
    //-------------------------------------------------------------------------
    (* ram_style = "block" *)                   // Xilinx: force BRAM
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    //-------------------------------------------------------------------------
    // Optional memory initialisation (simulation only)
    //-------------------------------------------------------------------------
    initial begin
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, mem);
        end
    end

    //-------------------------------------------------------------------------
    // Port A — synchronous read/write
    // Write-first mode: on simultaneous read+write to same address,
    // dout_a reflects the NEW data being written (matches HM behaviour
    // where reconstructed pixel is immediately available for intra pred)
    //-------------------------------------------------------------------------
    always @(posedge clk_a) begin
        if (en_a) begin
            if (we_a) begin
                mem[addr_a] <= din_a;
                dout_a      <= din_a;   // write-first: output new data
            end else begin
                dout_a <= mem[addr_a];
            end
        end
    end

    //-------------------------------------------------------------------------
    // Port B — synchronous read/write
    // Read-first mode on port B: on simultaneous A-write + B-read to same
    // address, port B returns OLD data. This is safe for the ME path because
    // reference frames are fully reconstructed before ME reads them.
    //-------------------------------------------------------------------------
    always @(posedge clk_b) begin
        if (en_b) begin
            dout_b <= mem[addr_b];          // read-first on port B
            if (we_b) begin
                mem[addr_b] <= din_b;
            end
        end
    end

    //-------------------------------------------------------------------------
    // Collision warning (simulation only)
    // Fires if both ports write to the same address simultaneously —
    // this is undefined behaviour and must not occur in normal operation.
    //-------------------------------------------------------------------------
// synthesis translate_off
    always @(posedge clk_a) begin
        if (en_a && we_a && en_b && we_b && (addr_a == addr_b)) begin
            $display("WARNING [ram_dp_10b] simultaneous write collision at addr=%0h time=%0t",
                     addr_a, $time);
        end
    end
// synthesis translate_on

    //-------------------------------------------------------------------------
    // Assertions (simulation)
    //-------------------------------------------------------------------------
// synthesis translate_off
    initial begin
        if (DATA_WIDTH < 1 || DATA_WIDTH > 64)
            $fatal(1, "ram_dp_10b: DATA_WIDTH=%0d out of range", DATA_WIDTH);
        if (DEPTH < 2)
            $fatal(1, "ram_dp_10b: DEPTH=%0d must be >= 2", DEPTH);
    end
// synthesis translate_on

endmodule