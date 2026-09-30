//=============================================================================
// fifo_sync.v
// Synchronous FIFO — Single Clock Domain
//
// Used by (instantiated across entire encoder/decoder pipeline):
//   output_fifo.v       — bitstream byte staging between CABAC and NAL writer
//   pixel_block_if      — pixel block handoff between prediction and recon
//   coeff_if            — coefficient stream between quant and CABAC
//   me_top.v            — SAD/SATD result buffering in TZ search
//
// Architecture:
//   Standard two-pointer (wr_ptr / rd_ptr) circular buffer
//   Registered output (FWFT = First-Word-Fall-Through disabled by default)
//   FWFT mode selectable via parameter for low-latency paths
//   Full/empty derived from pointer MSB XOR (no counter — saves area)
//   Depth must be power of 2
//
// Synthesis:
//   RAM infers as Block RAM when DEPTH >= 512 (Vivado/Quartus threshold)
//   RAM infers as distributed RAM / LUTRAM when DEPTH < 512
//   Use (* ram_style = "block" *) override via FORCE_BRAM parameter
//
// Parameters:
//   DATA_WIDTH  — payload width in bits
//   DEPTH       — number of entries (must be power of 2, min 2)
//   FWFT        — 0: standard (read latency 1 cycle)
//                 1: first-word-fall-through (data appears on dout
//                    in same cycle as rd_en, zero read latency)
//   FORCE_BRAM  — 1: attach (* ram_style="block" *) pragma
//                 0: let tool decide based on depth
//   PROG_FULL_THRESH  — programmable full threshold (0 = disable)
//   PROG_EMPTY_THRESH — programmable empty threshold (0 = disable)
//=============================================================================

`include "parameter_pkg.vh"

module fifo_sync #(
    parameter DATA_WIDTH       = `PIXEL_WIDTH,  // 10 bits default
    parameter DEPTH            = 512,           // must be power of 2
    parameter FWFT             = 0,             // 0=standard, 1=fall-through
    parameter FORCE_BRAM       = 0,             // force block RAM pragma
    parameter PROG_FULL_THRESH = 0,             // 0 = disable prog_full
    parameter PROG_EMPTY_THRESH= 0,             // 0 = disable prog_empty
    parameter ADDR_W           = $clog2(DEPTH)  // pointer width (without wrap bit)
)(
    input  wire                  clk,
    input  wire                  rst_n,         // active-low synchronous reset

    // Write port
    input  wire                  wr_en,
    input  wire [DATA_WIDTH-1:0] din,
    output wire                  full,
    output wire                  prog_full,     // asserts when entries >= PROG_FULL_THRESH

    // Read port
    input  wire                  rd_en,
    output wire [DATA_WIDTH-1:0] dout,
    output wire                  empty,
    output wire                  prog_empty,    // asserts when entries <= PROG_EMPTY_THRESH

    // Status
    output wire [ADDR_W:0]       count          // number of valid entries in FIFO
);

    //-------------------------------------------------------------------------
    // Parameter sanity checks (simulation)
    //-------------------------------------------------------------------------
    // synthesis translate_off
    initial begin
        if ((DEPTH & (DEPTH-1)) != 0)
            $fatal(1, "fifo_sync: DEPTH=%0d must be a power of 2", DEPTH);
        if (DEPTH < 2)
            $fatal(1, "fifo_sync: DEPTH=%0d must be >= 2", DEPTH);
        if (DATA_WIDTH < 1)
            $fatal(1, "fifo_sync: DATA_WIDTH=%0d must be >= 1", DATA_WIDTH);
        if (PROG_FULL_THRESH > DEPTH)
            $fatal(1, "fifo_sync: PROG_FULL_THRESH=%0d > DEPTH=%0d",
                   PROG_FULL_THRESH, DEPTH);
        if (PROG_EMPTY_THRESH > DEPTH)
            $fatal(1, "fifo_sync: PROG_EMPTY_THRESH=%0d > DEPTH=%0d",
                   PROG_EMPTY_THRESH, DEPTH);
    end
    // synthesis translate_on

    //-------------------------------------------------------------------------
    // Storage array
    // Extra bit on pointer used for full/empty discrimination (Gray-code trick)
    // Pointer format: {wrap_bit, addr[ADDR_W-1:0]}
    //-------------------------------------------------------------------------
    reg [ADDR_W:0] wr_ptr;   // {wrap, addr}
    reg [ADDR_W:0] rd_ptr;

    wire [ADDR_W-1:0] wr_addr = wr_ptr[ADDR_W-1:0];
    wire [ADDR_W-1:0] rd_addr = rd_ptr[ADDR_W-1:0];

    assign full  = (wr_ptr[ADDR_W]   != rd_ptr[ADDR_W]) &&
                   (wr_ptr[ADDR_W-1:0] == rd_ptr[ADDR_W-1:0]);

    assign empty = (wr_ptr == rd_ptr);

    // Entry count: always non-negative, fits in ADDR_W+1 bits
    assign count = wr_ptr - rd_ptr;

    //-------------------------------------------------------------------------
    // Programmable thresholds
    //-------------------------------------------------------------------------
    generate
        if (PROG_FULL_THRESH > 0) begin : gen_prog_full
            assign prog_full = (count >= PROG_FULL_THRESH[ADDR_W:0]);
        end else begin : gen_no_prog_full
            assign prog_full = 1'b0;
        end
    endgenerate

    generate
        if (PROG_EMPTY_THRESH > 0) begin : gen_prog_empty
            assign prog_empty = (count <= PROG_EMPTY_THRESH[ADDR_W:0]);
        end else begin : gen_no_prog_empty
            assign prog_empty = 1'b0;
        end
    endgenerate

    //-------------------------------------------------------------------------
    // Write & Read Control Logic
    //-------------------------------------------------------------------------
    wire wr_fire = wr_en && (!full || rd_en); // simultaneous R+W on full is ok
    wire rd_fire = rd_en && !empty;

    always @(posedge clk) begin
        if (!rst_n) begin
            wr_ptr <= {(ADDR_W+1){1'b0}};
        end else if (wr_fire) begin
            wr_ptr <= wr_ptr + 1'b1;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            rd_ptr <= {(ADDR_W+1){1'b0}};
        end else if (rd_fire) begin
            rd_ptr <= rd_ptr + 1'b1;
        end
    end

    //-------------------------------------------------------------------------
    // Storage array and Read Data Logic
    // FWFT=0 (standard): dout is registered, appears one cycle after rd_en
    // FWFT=1 (fall-through): dout is combinational from head of FIFO
    //-------------------------------------------------------------------------
    generate
        if (FORCE_BRAM) begin : gen_bram
            (* ram_style = "block" *)
            reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

            always @(posedge clk) begin
                if (wr_fire) mem[wr_addr] <= din;
            end

            if (FWFT == 0) begin : gen_standard_read
                reg [DATA_WIDTH-1:0] dout_reg;
                always @(posedge clk) begin
                    if (rd_fire) dout_reg <= mem[rd_addr];
                end
                assign dout = dout_reg;
            end else begin : gen_fwft_read
                // Note: Asynchronous read for FWFT mode forces distributed RAM (LUTRAM)
                // in synthesis tools. For true BRAM with zero-cycle latency, use a registered
                // skid buffer or set FORCE_BRAM=0 for explicit distributed RAM.
                assign dout = mem[rd_addr];
            end

        end else begin : gen_auto
            (* ram_style = "auto" *)
            reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

            always @(posedge clk) begin
                if (wr_fire) mem[wr_addr] <= din;
            end

            if (FWFT == 0) begin : gen_standard_read
                reg [DATA_WIDTH-1:0] dout_reg;
                always @(posedge clk) begin
                    if (rd_fire) dout_reg <= mem[rd_addr];
                end
                assign dout = dout_reg;
            end else begin : gen_fwft_read
                assign dout = mem[rd_addr];
            end
        end
    endgenerate

    //-------------------------------------------------------------------------
    // Overflow / underflow detection (simulation only)
    //-------------------------------------------------------------------------
    // synthesis translate_off
    always @(posedge clk) begin
        if (rst_n) begin
            if (wr_en && full && !rd_en) begin
                $display("ERROR [fifo_sync] OVERFLOW  at time=%0t  instance=%m", $time);
                $fatal(1, "fifo_sync: write to full FIFO");
            end
            if (rd_en && empty) begin
                $display("ERROR [fifo_sync] UNDERFLOW at time=%0t  instance=%m", $time);
                $fatal(1, "fifo_sync: read from empty FIFO");
            end
        end
    end
    // synthesis translate_on

    //-------------------------------------------------------------------------
    // Simulation coverage helpers (no hardware generated)
    //-------------------------------------------------------------------------
    // synthesis translate_off
    // Track maximum fill level reached — useful for sizing FIFO in final design
    integer max_count;
    initial max_count = 0;
    always @(posedge clk) begin
        if (rst_n && ($signed({1'b0, count}) > max_count))
            max_count = count;
    end
    // synthesis translate_on

endmodule