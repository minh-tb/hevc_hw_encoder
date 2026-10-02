//=============================================================================
// dct_top.v
// HEVC 2D Transform Engine (Row-Serial Architecture)
//
// Mapped from HM source:
//   TLibCommon/TComTrQuant.cpp  xTrMxN() / xITrMxN()
//   TLibCommon/TComRom.cpp      g_aiT4, g_aiT8, g_aiT16, g_aiT32
//
// Architecture:
//   Replaces the legacy fully-unrolled 2D parallel transform (~57,411 mults)
//   with an area-efficient row-serial architecture (~949 mults):
//     - 1x transform_1d_core (DCT-II 4/8/16/32-pt & DST-VII 4-pt)
//     - 1x transpose_ram_32x32 (Dual-Port row-write / col-read buffer)
//     - Pipelined FSM controller (Pass 1 row transform -> Transpose RAM ->
//       Pass 2 col transform -> Output register array)
//
// Latency:
//   - 4x4:   ~12 cycles
//   - 8x8:   ~20 cycles
//   - 16x16: ~36 cycles
//   - 32x32: ~68 cycles
//   (Far faster than downstream serialization/quantization budget of N^2 cycles)
//
// Pin & Interface Compatibility:
//   - in_data [16383:0]: 32x32 signed 16-bit coefficients (row-major)
//   - out_data [16383:0]: 32x32 signed 16-bit coefficients (row-major)
//   - in_valid / in_ready handshake
//   - out_valid / out_ready handshake
//   - out_tu_size_log2, out_fwd_inv_n passthrough
//=============================================================================

`timescale 1ns / 1ps
`include "parameter_pkg.vh"

module dct_top (
    input  wire         clk,
    input  wire         rst_n,

    // Control — from tu_info_if
    input  wire         fwd_inv_n,          // 1=forward, 0=inverse
    input  wire [2:0]   tu_size_log2,       // 2=4x4, 3=8x8, 4=16x16, 5=32x32

    // Input — max 32x32, smaller TUs packed in top-left
    // Matches TU_INFO_BUS: data arrives row-major
    input  wire         in_valid,
    output wire         in_ready,
    input  wire [16383:0] in_data,

    // Output — max 32x32, smaller TUs valid in [0:N-1][0:N-1]
    output wire         out_valid,
    input  wire         out_ready,
    output wire [16383:0] out_data,

    // Passthrough size info for downstream quant_unit (driven combinationally)
    output wire [2:0]   out_tu_size_log2,
    output wire         out_fwd_inv_n
);

    //-------------------------------------------------------------------------
    // FSM States
    //-------------------------------------------------------------------------
    localparam S_IDLE       = 3'd0;
    localparam S_ROW_FEED   = 3'd1; // Stream vectors into 1D core (Pass 1)
    localparam S_ROW_WAIT   = 3'd2; // Wait for last 1D core output of Pass 1
    localparam S_ROW_DONE   = 3'd3; // Request col 0 from RAM
    localparam S_COL_PREP   = 3'd4; // Request col 1 from RAM
    localparam S_COL_FEED   = 3'd5; // Stream columns from RAM into 1D core (Pass 2)
    localparam S_COL_WAIT   = 3'd6; // Wait for last 1D core output of Pass 2
    localparam S_DONE       = 3'd7; // Assert out_valid and hold output

    reg [2:0] state;

    // Latched control registers
    reg        latched_fwd_inv_n;
    reg [2:0]  latched_tu_size_log2;
    wire [5:0] tu_size = (6'd1 << latched_tu_size_log2); // 4, 8, 16, or 32

    // Input holding buffer: 32x32 signed 16-bit
    reg signed [15:0] in_buf [0:31][0:31];

    // Output buffer: 32x32 signed 16-bit
    reg signed [15:0] out_data_reg [0:31][0:31];

    // Connect output array to flattened out_data
    genvar gi, gj;
    generate
        for (gi = 0; gi < 32; gi = gi + 1) begin : gen_out_row
            for (gj = 0; gj < 32; gj = gj + 1) begin : gen_out_col
                assign out_data[(gi*32+gj)*16 +: 16] = out_data_reg[gi][gj];
            end
        end
    endgenerate

    // Handshake and sideband assignments
    assign in_ready         = (state == S_IDLE);
    assign out_valid        = (state == S_DONE);
    assign out_tu_size_log2 = latched_tu_size_log2;
    assign out_fwd_inv_n    = latched_fwd_inv_n;

    // Counters for streaming passes
    reg [5:0] feed_cnt;
    reg [5:0] wr_cnt;
    reg [5:0] out_cnt;

    //-------------------------------------------------------------------------
    // 1D Transform Core Connections
    //-------------------------------------------------------------------------
    reg         core_fwd_inv_n;
    reg  [2:0]  core_tu_size_log2;
    reg         core_is_second_pass;
    reg         core_in_valid;
    wire        core_in_ready;
    reg  [511:0] core_in_vec;
    wire        core_out_valid;
    wire        core_out_ready = 1'b1; // Always ready to receive 1D core results
    wire [511:0] core_out_vec;

    transform_1d_core u_1d_core (
        .clk            (clk),
        .rst_n          (rst_n),
        .fwd_inv_n      (core_fwd_inv_n),
        .tu_size_log2   (core_tu_size_log2),
        .is_dst7        (1'b0),
        .is_second_pass (core_is_second_pass),
        .in_valid       (core_in_valid),
        .in_ready       (core_in_ready),
        .in_vec         (core_in_vec),
        .out_valid      (core_out_valid),
        .out_ready      (core_out_ready),
        .out_vec        (core_out_vec)
    );

    //-------------------------------------------------------------------------
    // Transpose RAM Buffer (32x32 x 16-bit)
    //-------------------------------------------------------------------------
    reg         ram_wr_en;
    reg  [4:0]  ram_wr_row;
    reg  [511:0] ram_wr_vec;
    reg  [4:0]  ram_rd_col;
    wire [511:0] ram_rd_vec;

    transpose_ram_32x32 u_transpose_ram (
        .clk    (clk),
        .wr_en  (ram_wr_en),
        .wr_row (ram_wr_row),
        .wr_vec (ram_wr_vec),
        .rd_col (ram_rd_col),
        .rd_vec (ram_rd_vec)
    );

    // Helper functions / variables
    integer r, c, k;

    // Combinational multiplexing for Pass 1 input vector
    reg [511:0] pass1_vec;
    always @(*) begin
        pass1_vec = 512'd0;
        for (c = 0; c < 32; c = c + 1) begin
            if (c < tu_size) begin
                if (latched_fwd_inv_n) begin
                    // Forward Pass 1: row feed_cnt
                    pass1_vec[c*16 +: 16] = in_buf[feed_cnt[4:0]][c];
                end else begin
                    // Inverse Pass 1: col feed_cnt
                    pass1_vec[c*16 +: 16] = in_buf[c][feed_cnt[4:0]];
                end
            end
        end
    end

    //-------------------------------------------------------------------------
    // Main Sequential FSM Control
    //-------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state                <= S_IDLE;
            latched_fwd_inv_n    <= 1'b1;
            latched_tu_size_log2 <= 3'd2;
            feed_cnt             <= 6'd0;
            wr_cnt               <= 6'd0;
            out_cnt              <= 6'd0;
            core_in_valid        <= 1'b0;
            core_in_vec          <= 512'd0;
            core_fwd_inv_n       <= 1'b1;
            core_tu_size_log2    <= 3'd2;
            core_is_second_pass  <= 1'b0;
            ram_wr_en            <= 1'b0;
            ram_wr_row           <= 5'd0;
            ram_wr_vec           <= 512'd0;
            ram_rd_col           <= 5'd0;

            for (r = 0; r < 32; r = r + 1) begin
                for (c = 0; c < 32; c = c + 1) begin
                    in_buf[r][c]       <= 16'sd0;
                    out_data_reg[r][c] <= 16'sd0;
                end
            end
        end else begin
            // Default non-sticky pulse signals
            ram_wr_en     <= 1'b0;
            core_in_valid <= 1'b0;

            case (state)
                //-------------------------------------------------------------
                // S_IDLE: Wait for input transaction
                //-------------------------------------------------------------
                S_IDLE: begin
                    if (in_valid && in_ready) begin
                        latched_fwd_inv_n    <= fwd_inv_n;
                        latched_tu_size_log2 <= tu_size_log2;
                        feed_cnt             <= 6'd0;
                        wr_cnt               <= 6'd0;
                        out_cnt              <= 6'd0;

                        // Latch and unpack input array
                        for (r = 0; r < 32; r = r + 1) begin
                            for (c = 0; c < 32; c = c + 1) begin
                                in_buf[r][c]       <= in_data[(r*32+c)*16 +: 16];
                                out_data_reg[r][c] <= 16'sd0;
                            end
                        end

                        state <= S_ROW_FEED;
                    end
                end

                //-------------------------------------------------------------
                // S_ROW_FEED: Stream vectors into 1D core (Pass 1)
                //-------------------------------------------------------------
                S_ROW_FEED: begin
                    core_fwd_inv_n      <= latched_fwd_inv_n;
                    core_tu_size_log2   <= latched_tu_size_log2;
                    core_is_second_pass <= 1'b0;
                    core_in_valid       <= 1'b1;
                    core_in_vec         <= pass1_vec;
                    feed_cnt            <= feed_cnt + 6'd1;

                    // RAM write on core_out_valid (arrives starting cycle 1)
                    if (core_out_valid) begin
                        ram_wr_en  <= 1'b1;
                        ram_wr_row <= wr_cnt[4:0];
                        ram_wr_vec <= core_out_vec;
                        wr_cnt     <= wr_cnt + 6'd1;
                    end

                    if (feed_cnt == tu_size - 6'd1) begin
                        state <= S_ROW_WAIT;
                    end
                end

                //-------------------------------------------------------------
                // S_ROW_WAIT: Collect remaining Pass 1 results into Transpose RAM
                //-------------------------------------------------------------
                S_ROW_WAIT: begin
                    if (core_out_valid) begin
                        ram_wr_en  <= 1'b1;
                        ram_wr_row <= wr_cnt[4:0];
                        ram_wr_vec <= core_out_vec;
                        wr_cnt     <= wr_cnt + 6'd1;

                        if (wr_cnt == tu_size - 6'd1) begin
                            state <= S_ROW_DONE;
                        end
                    end
                end

                //-------------------------------------------------------------
                // S_ROW_DONE: Last write commits; request column 0 from RAM
                //-------------------------------------------------------------
                S_ROW_DONE: begin
                    ram_rd_col <= 5'd0;
                    state      <= S_COL_PREP;
                end

                //-------------------------------------------------------------
                // S_COL_PREP: RAM samples col 0; request column 1 from RAM
                //-------------------------------------------------------------
                S_COL_PREP: begin
                    ram_rd_col <= 5'd1;
                    feed_cnt   <= 6'd0;
                    out_cnt    <= 6'd0;
                    state      <= S_COL_FEED;
                end

                //-------------------------------------------------------------
                // S_COL_FEED: Read columns from RAM and stream into 1D core (Pass 2)
                //-------------------------------------------------------------
                S_COL_FEED: begin
                    // Feed currently available RAM column into 1D core
                    core_fwd_inv_n      <= latched_fwd_inv_n;
                    core_tu_size_log2   <= latched_tu_size_log2;
                    core_is_second_pass <= 1'b1;
                    core_in_valid       <= 1'b1;
                    core_in_vec         <= ram_rd_vec;
                    feed_cnt            <= feed_cnt + 6'd1;

                    // Pipeline next RAM column read
                    if (feed_cnt < tu_size - 6'd2) begin
                        ram_rd_col <= feed_cnt[4:0] + 5'd2;
                    end

                    if (feed_cnt == tu_size - 6'd1) begin
                        state <= S_COL_WAIT;
                    end

                    // Store arriving Pass 2 outputs into out_data_reg
                    if (core_out_valid) begin
                        for (k = 0; k < 32; k = k + 1) begin
                            if (k < tu_size) begin
                                if (latched_fwd_inv_n)
                                    out_data_reg[k][out_cnt[4:0]] <= core_out_vec[k*16 +: 16];
                                else
                                    out_data_reg[out_cnt[4:0]][k] <= core_out_vec[k*16 +: 16];
                            end
                        end
                        out_cnt <= out_cnt + 6'd1;
                    end
                end

                //-------------------------------------------------------------
                // S_COL_WAIT: Collect remaining Pass 2 results into output buffer
                //-------------------------------------------------------------
                S_COL_WAIT: begin
                    core_in_valid <= 1'b0;
                    if (core_out_valid) begin
                        for (k = 0; k < 32; k = k + 1) begin
                            if (k < tu_size) begin
                                if (latched_fwd_inv_n)
                                    out_data_reg[k][out_cnt[4:0]] <= core_out_vec[k*16 +: 16];
                                else
                                    out_data_reg[out_cnt[4:0]][k] <= core_out_vec[k*16 +: 16];
                            end
                        end
                        out_cnt <= out_cnt + 6'd1;

                        if (out_cnt == tu_size - 6'd1) begin
                            state <= S_DONE;
                        end
                    end
                end

                //-------------------------------------------------------------
                // S_DONE: Output valid pulse and size/direction status
                //-------------------------------------------------------------
                S_DONE: begin
                    if (out_ready) begin
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule