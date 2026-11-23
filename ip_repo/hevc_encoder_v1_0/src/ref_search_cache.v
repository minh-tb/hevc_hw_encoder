`timescale 1ns / 1ps
//=============================================================================
// ref_search_cache.v
// On-Chip 128x128 Luma Search-Window BRAM Cache for Motion Estimation
//
// Intercepts Luma 4x4 (TZ search) and 12x12 (FME search) reference requests:
//   - Cache hit  : serves 4x4 in 4-6 cycles / 12x12 in 14 cycles via TDP BRAM
//                  (zero external AXI DDR read traffic).
//   - Cache miss : prefetches a CTU-centered [128 x 128] (clamped to frame)
//                  Luma window via burst-8 AXI4 reads (strictly 4KB-aligned)
//                  while preserving 100% bit-exact border clamping.
//   - Bypass     : forwards Chroma, MC (req_force_bypass), or outlier windows
//                  outside the CTU-centered window straight to ref_frame_buffer.
//=============================================================================

`include "parameter_pkg.vh"

module ref_search_cache #(
    parameter PIXEL_WIDTH    = `PIXEL_WIDTH,
    parameter BLK_EXT_Y      = 12,
    parameter BLK_EXT_C      = 5,
    parameter FRAME_W_Y      = 128,
    parameter FRAME_H_Y      = 128,
    parameter FRAME_W_C      = 64,
    parameter FRAME_H_C      = 64,
    parameter AXI_DW         = 256,
    parameter AXI_AW         = 33,
    parameter LUMA_SAMPLES   = FRAME_W_Y * FRAME_H_Y,
    parameter CHROMA_SAMPLES = FRAME_W_C * FRAME_H_C,
    parameter LUMA_WORDS     = LUMA_SAMPLES / 2,
    parameter CHROMA_WORDS   = CHROMA_SAMPLES / 2,
    parameter FRAME_WORDS    = LUMA_WORDS + 2 * CHROMA_WORDS,
    parameter SLOT_STRIDE    = FRAME_WORDS * 4,
    parameter PX_EXT_Y       = PIXEL_WIDTH * BLK_EXT_Y * BLK_EXT_Y,
    parameter PX_EXT_C       = PIXEL_WIDTH * BLK_EXT_C * BLK_EXT_C
)(
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire                      cache_invalidate,

    // Current CTU origin in Luma pixels (aligned to CTU grid)
    input  wire [11:0]               ctu_base_x,
    input  wire [11:0]               ctu_base_y,

    // Upstream client request / response interface
    input  wire                      req_valid,
    output reg                       req_ready,
    input  wire [1:0]                req_comp,
    input  wire [2:0]                req_slot,
    input  wire signed [11:0]        req_x,
    input  wire signed [11:0]        req_y,
    input  wire                      req_is_4x4,
    input  wire                      req_force_bypass,
    output wire                      resp_valid,
    output wire [PX_EXT_Y-1:0]       resp_y_flat,
    output wire [PX_EXT_C-1:0]       resp_cb_flat,
    output wire [PX_EXT_C-1:0]       resp_cr_flat,

    // Bypass path to ref_frame_buffer
    output reg                       buf_req_valid,
    input  wire                      buf_req_ready,
    output wire [1:0]                buf_req_comp,
    output wire [2:0]                buf_req_slot,
    output wire [11:0]               buf_req_x,
    output wire [11:0]               buf_req_y,
    output wire                      buf_req_is_4x4,
    input  wire                      buf_resp_valid,
    input  wire [PX_EXT_Y-1:0]       buf_resp_y_flat,
    input  wire [PX_EXT_C-1:0]       buf_resp_cb_flat,
    input  wire [PX_EXT_C-1:0]       buf_resp_cr_flat,

    // Direct AXI4 read channel (muxed onto ref port when axi_active=1)
    output wire                      axi_active,
    output reg                       axi_arvalid,
    input  wire                      axi_arready,
    output reg  [AXI_AW-1:0]         axi_araddr,
    output reg  [7:0]                axi_arlen,
    output wire [2:0]                axi_arsize,
    output wire [1:0]                axi_arburst,
    input  wire                      axi_rvalid,
    output wire                      axi_rready,
    input  wire [AXI_DW-1:0]         axi_rdata,
    input  wire                      axi_rlast
);

    // =========================================================================
    // Derived Window Constants
    // =========================================================================
    localparam integer WIN_W            = (FRAME_W_Y < 128) ? FRAME_W_Y : 128;
    localparam integer WIN_H            = (FRAME_H_Y < 128) ? FRAME_H_Y : 128;
    localparam integer BEATS_PER_ROW    = (WIN_W + 15) >> 4;
    localparam integer MAX_WIN_X        = FRAME_W_Y - WIN_W;
    localparam integer MAX_WIN_Y        = FRAME_H_Y - WIN_H;
    localparam integer ROW_STRIDE_BYTES = FRAME_W_Y * 2;

    localparam [11:0]  WIN_W_12         = WIN_W;
    localparam [11:0]  WIN_H_12         = WIN_H;
    localparam [11:0]  F_W_Y_12         = FRAME_W_Y;
    localparam [11:0]  F_H_Y_12         = FRAME_H_Y;
    localparam [11:0]  MAX_WIN_X_12     = MAX_WIN_X;
    localparam [11:0]  MAX_WIN_Y_12     = MAX_WIN_Y;
    localparam [3:0]   BEATS_PER_ROW_4  = BEATS_PER_ROW;
    localparam [6:0]   WIN_H_7          = WIN_H;
    localparam [32:0]  SLOT_STRIDE_33   = SLOT_STRIDE;
    localparam [32:0]  ROW_STRIDE_33    = ROW_STRIDE_BYTES;

    // =========================================================================
    // FSM States
    // =========================================================================
    localparam [3:0]
        S_IDLE        = 4'd0,
        S_CHECK       = 4'd1,
        S_FILL_INIT   = 4'd2,
        S_FILL_AR     = 4'd3,
        S_FILL_R      = 4'd4,
        S_RD          = 4'd5,
        S_RD_LAST     = 4'd6,
        S_BYPASS_REQ  = 4'd7,
        S_BYPASS_WAIT = 4'd8;

    reg [3:0] state;

    assign axi_active  = (state == S_FILL_AR) || (state == S_FILL_R);
    assign axi_arsize  = 3'b101; // 32 bytes (256-bit beat)
    assign axi_arburst = 2'b01;  // INCR
    assign axi_rready  = (state == S_FILL_R);

    // =========================================================================
    // Coordinate Helpers (Exact Match to ref_frame_buffer.v)
    // =========================================================================
    function automatic [11:0] clamp_coord;
        input signed [12:0] v;
        input [11:0]        maxv;
        begin
            if (v < 13'sd0)
                clamp_coord = 12'd0;
            else if ($signed(v) >= $signed({1'b0, maxv}))
                clamp_coord = maxv - 12'd1;
            else
                clamp_coord = v[11:0];
        end
    endfunction

    function automatic [7:0] calc_burst_arlen;
        input [3:0]  b_x;
        input [32:0] c_addr;
        reg   [3:0]  row_rem;
        reg   [6:0]  page_rem;
        begin
            row_rem  = BEATS_PER_ROW_4 - b_x - 4'd1;
            page_rem = ~c_addr[11:5];
            if ({3'd0, row_rem} <= page_rem)
                calc_burst_arlen = {4'd0, row_rem};
            else
                calc_burst_arlen = {1'b0, page_rem};
        end
    endfunction

    // =========================================================================
    // Cache Tag & Latched Request Registers
    // =========================================================================
    reg               cache_valid;
    reg               inv_during_fill;
    reg  [2:0]        cache_slot;
    reg  [11:0]       cache_win_x;
    reg  [11:0]       cache_win_y;

    reg  [1:0]        comp_r;
    reg  [2:0]        slot_r;
    reg  signed [12:0] req_x_r;
    reg  signed [12:0] req_y_r;
    reg               is_4x4_r;
    reg               force_bypass_r;
    reg  [11:0]       ctu_base_x_r;
    reg  [11:0]       ctu_base_y_r;

    assign buf_req_comp   = comp_r;
    assign buf_req_slot   = slot_r;
    assign buf_req_x      = req_x_r[11:0];
    assign buf_req_y      = req_y_r[11:0];
    assign buf_req_is_4x4 = is_4x4_r;

    // Fill FSM counters & AXI address state
    reg  [6:0]        fill_row_y;
    reg  [3:0]        fill_beat_x;
    reg  [32:0]       fill_row_addr;
    reg  [32:0]       fill_cur_addr;

    wire [32:0]       fill_base_addr = ({30'd0, cache_slot} * SLOT_STRIDE_33) +
                                       ((({21'd0, cache_win_y} * {21'd0, F_W_Y_12}) + {21'd0, cache_win_x}) << 1);

    // =========================================================================
    // Hit / Miss & Window Boundary Evaluation
    // =========================================================================
    wire [3:0]        blk_ext_minus1 = is_4x4_r ? 4'd3 : 4'd11;
    wire [11:0]       min_x = clamp_coord(req_x_r, F_W_Y_12);
    wire [11:0]       max_x = clamp_coord(req_x_r + $signed({9'd0, blk_ext_minus1}), F_W_Y_12);
    wire [11:0]       min_y = clamp_coord(req_y_r, F_H_Y_12);
    wire [11:0]       max_y = clamp_coord(req_y_r + $signed({9'd0, blk_ext_minus1}), F_H_Y_12);

    wire              cache_hit = cache_valid && (comp_r == 2'd0) && !force_bypass_r &&
                                  (cache_slot == slot_r) &&
                                  (min_x >= cache_win_x) && ({1'b0, max_x} < ({1'b0, cache_win_x} + {1'b0, WIN_W_12})) &&
                                  (min_y >= cache_win_y) && ({1'b0, max_y} < ({1'b0, cache_win_y} + {1'b0, WIN_H_12}));

    wire signed [12:0] raw_wx     = $signed({1'b0, ctu_base_x_r}) - 13'sd32;
    wire [11:0]        clamped_wx = (raw_wx < 13'sd0) ? 12'd0 :
                                    ((raw_wx > $signed({1'b0, MAX_WIN_X_12})) ? MAX_WIN_X_12 : raw_wx[11:0]);
    wire [11:0]        cand_win_x = {clamped_wx[11:4], 4'd0};

    wire signed [12:0] raw_wy     = $signed({1'b0, ctu_base_y_r}) - 13'sd32;
    wire [11:0]        cand_win_y = (raw_wy < 13'sd0) ? 12'd0 :
                                    ((raw_wy > $signed({1'b0, MAX_WIN_Y_12})) ? MAX_WIN_Y_12 : raw_wy[11:0]);

    wire               cand_win_covers = (min_x >= cand_win_x) && ({1'b0, max_x} < ({1'b0, cand_win_x} + {1'b0, WIN_W_12})) &&
                                         (min_y >= cand_win_y) && ({1'b0, max_y} < ({1'b0, cand_win_y} + {1'b0, WIN_H_12}));

    // =========================================================================
    // Hit Column Offsets & Read Sequencer State
    // =========================================================================
    wire [11:0] cl_x  [0:BLK_EXT_Y-1];
    wire [6:0]  rel_x [0:BLK_EXT_Y-1];
    wire [4:0]  off_c [0:BLK_EXT_Y-1];
    wire [2:0]  w0    = rel_x[0][6:4];
    wire [2:0]  w_last = is_4x4_r ? rel_x[3][6:4] : rel_x[BLK_EXT_Y-1][6:4];
    wire        two_words = (w_last != w0);
    wire        fast_4x4  = is_4x4_r && !two_words;

    genvar gc;
    generate
        for (gc = 0; gc < BLK_EXT_Y; gc = gc + 1) begin : gen_col_off
            wire [11:0] rx_tmp = cl_x[gc] - cache_win_x;
            wire [6:0]  off_tmp = rel_x[gc] - {w0, 4'd0};
            assign cl_x[gc]  = clamp_coord(req_x_r + $signed(gc), F_W_Y_12);
            assign rel_x[gc] = rx_tmp[6:0];
            assign off_c[gc] = off_tmp[4:0];
        end
    endgenerate

    reg  [2:0]  w0_r;
    reg         two_words_r;
    reg         fast_4x4_r;
    reg  [4:0]  off_c_r [0:BLK_EXT_Y-1];
    reg  [3:0]  rd_step;
    reg  [3:0]  wr_step;

    wire [3:0]  issue_step   = (state == S_CHECK) ? 4'd0 : rd_step;
    wire        cur_two_words = (state == S_CHECK) ? two_words : two_words_r;
    wire        cur_fast_4x4  = (state == S_CHECK) ? fast_4x4  : fast_4x4_r;
    wire [2:0]  cur_w0        = (state == S_CHECK) ? w0        : w0_r;
    wire [3:0]  total_steps   = fast_4x4_r ? 4'd2 : (is_4x4_r ? 4'd4 : 4'd12);

    wire [3:0]  req_dy_a = cur_fast_4x4 ? {issue_step[2:0], 1'b0} : issue_step;
    wire [3:0]  req_dy_b = cur_fast_4x4 ? {issue_step[2:0], 1'b1} : issue_step;
    wire [11:0] cl_y_a   = clamp_coord(req_y_r + $signed({9'd0, req_dy_a}), F_H_Y_12);
    wire [11:0] cl_y_b   = clamp_coord(req_y_r + $signed({9'd0, req_dy_b}), F_H_Y_12);
    wire [11:0] dy_win_a = cl_y_a - cache_win_y;
    wire [11:0] dy_win_b = cl_y_b - cache_win_y;
    wire [9:0]  rd_addr_a = {dy_win_a[6:0], cur_w0};
    wire [9:0]  rd_addr_b = {dy_win_b[6:0], (!cur_fast_4x4 && cur_two_words) ? (cur_w0 + 3'd1) : cur_w0};

    // =========================================================================
    // True Dual-Port Block RAM: 1024 x 160 bits (16 pixels x 10-bit)
    // =========================================================================
    (* ram_style = "block" *) reg [159:0] cache_ram [0:1023];
    reg [159:0] ram_rdata_a;
    reg [159:0] ram_rdata_b;

    wire [159:0] axi_pixels_160;
    genvar pk;
    generate
        for (pk = 0; pk < 16; pk = pk + 1) begin : gen_axi_pack
            assign axi_pixels_160[pk*10 +: 10] = axi_rdata[pk*16 +: 10];
        end
    endgenerate

    wire       ram_we_a   = (state == S_FILL_R) && axi_rvalid && axi_rready;
    wire [9:0] ram_addr_a = (state == S_FILL_R) ? {fill_row_y, fill_beat_x[2:0]} : rd_addr_a;

    always @(posedge clk) begin
        if (ram_we_a) begin
            cache_ram[ram_addr_a] <= axi_pixels_160;
        end
        ram_rdata_a <= cache_ram[ram_addr_a];
        ram_rdata_b <= cache_ram[rd_addr_b];
    end

    // =========================================================================
    // Row Pixel Extraction from 2x16-Pixel Cache Words
    // =========================================================================
    wire [319:0]           pair_320 = {ram_rdata_b, ram_rdata_a};
    wire [PIXEL_WIDTH-1:0] extr_a [0:BLK_EXT_Y-1];
    wire [PIXEL_WIDTH-1:0] extr_b [0:3];

    generate
        for (gc = 0; gc < BLK_EXT_Y; gc = gc + 1) begin : gen_extr_a
            assign extr_a[gc] = pair_320[off_c_r[gc]*10 +: PIXEL_WIDTH];
        end
        for (gc = 0; gc < 4; gc = gc + 1) begin : gen_extr_b
            assign extr_b[gc] = ram_rdata_b[off_c_r[gc][3:0]*10 +: PIXEL_WIDTH];
        end
    endgenerate

    // =========================================================================
    // Output Block Accumulator & Response Mux
    // =========================================================================
    reg [PIXEL_WIDTH-1:0] ext_buf [0:BLK_EXT_Y-1][0:BLK_EXT_Y-1];
    reg                   cache_resp_valid;
    wire [PX_EXT_Y-1:0]   cache_resp_y_flat;

    genvar gr;
    generate
        for (gr = 0; gr < BLK_EXT_Y; gr = gr + 1) begin : gen_out_r
            for (gc = 0; gc < BLK_EXT_Y; gc = gc + 1) begin : gen_out_c
                assign cache_resp_y_flat[PIXEL_WIDTH*(BLK_EXT_Y*gr + gc) +: PIXEL_WIDTH] = ext_buf[gr][gc];
            end
        end
    endgenerate

    assign resp_valid   = cache_resp_valid | buf_resp_valid;
    assign resp_y_flat  = cache_resp_valid ? cache_resp_y_flat : buf_resp_y_flat;
    assign resp_cb_flat = buf_resp_cb_flat;
    assign resp_cr_flat = buf_resp_cr_flat;

    // =========================================================================
    // Main FSM
    // =========================================================================
    integer ir, ic;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= S_IDLE;
            req_ready        <= 1'b1;
            buf_req_valid    <= 1'b0;
            axi_arvalid      <= 1'b0;
            axi_araddr       <= {AXI_AW{1'b0}};
            axi_arlen        <= 8'd0;
            cache_valid      <= 1'b0;
            inv_during_fill  <= 1'b0;
            cache_slot       <= 3'd0;
            cache_win_x      <= 12'd0;
            cache_win_y      <= 12'd0;
            comp_r           <= 2'd0;
            slot_r           <= 3'd0;
            req_x_r          <= 13'sd0;
            req_y_r          <= 13'sd0;
            is_4x4_r         <= 1'b0;
            force_bypass_r   <= 1'b0;
            ctu_base_x_r     <= 12'd0;
            ctu_base_y_r     <= 12'd0;
            fill_row_y       <= 7'd0;
            fill_beat_x      <= 4'd0;
            fill_row_addr    <= 33'd0;
            fill_cur_addr    <= 33'd0;
            w0_r             <= 3'd0;
            two_words_r      <= 1'b0;
            fast_4x4_r       <= 1'b0;
            rd_step          <= 4'd0;
            wr_step          <= 4'd0;
            cache_resp_valid <= 1'b0;
            for (ic = 0; ic < BLK_EXT_Y; ic = ic + 1) begin
                off_c_r[ic] <= 5'd0;
            end
            for (ir = 0; ir < BLK_EXT_Y; ir = ir + 1) begin
                for (ic = 0; ic < BLK_EXT_Y; ic = ic + 1) begin
                    ext_buf[ir][ic] <= {PIXEL_WIDTH{1'b0}};
                end
            end
        end else begin
            cache_resp_valid <= 1'b0;
            if (cache_invalidate) begin
                cache_valid     <= 1'b0;
                inv_during_fill <= 1'b1;
            end

            case (state)
                S_IDLE: begin
                    req_ready <= 1'b1;
                    if (req_valid && req_ready) begin
                        req_ready      <= 1'b0;
                        comp_r         <= req_comp;
                        slot_r         <= req_slot;
                        req_x_r        <= {req_x[11], req_x};
                        req_y_r        <= {req_y[11], req_y};
                        is_4x4_r       <= req_is_4x4;
                        force_bypass_r <= req_force_bypass;
                        ctu_base_x_r   <= ctu_base_x;
                        ctu_base_y_r   <= ctu_base_y;
                        state          <= S_CHECK;
                    end
                end

                S_CHECK: begin
                    if (force_bypass_r || (comp_r != 2'd0)) begin
                        buf_req_valid <= 1'b1;
                        state         <= S_BYPASS_REQ;
                    end else if (cache_hit) begin
                        w0_r        <= w0;
                        two_words_r <= two_words;
                        fast_4x4_r  <= fast_4x4;
                        for (ic = 0; ic < BLK_EXT_Y; ic = ic + 1) begin
                            off_c_r[ic] <= off_c[ic];
                        end
                        if (is_4x4_r) begin
                            for (ir = 4; ir < BLK_EXT_Y; ir = ir + 1) begin
                                for (ic = 0; ic < BLK_EXT_Y; ic = ic + 1) begin
                                    ext_buf[ir][ic] <= {PIXEL_WIDTH{1'b0}};
                                end
                            end
                        end
                        rd_step <= 4'd1;
                        wr_step <= 4'd0;
                        state   <= S_RD;
                    end else if (cand_win_covers) begin
                        cache_valid     <= 1'b0;
                        inv_during_fill <= cache_invalidate;
                        cache_slot      <= slot_r;
                        cache_win_x     <= cand_win_x;
                        cache_win_y     <= cand_win_y;
                        state           <= S_FILL_INIT;
                    end else begin
                        buf_req_valid <= 1'b1;
                        state         <= S_BYPASS_REQ;
                    end
                end

                S_FILL_INIT: begin
                    fill_row_y    <= 7'd0;
                    fill_beat_x   <= 4'd0;
                    fill_row_addr <= fill_base_addr;
                    fill_cur_addr <= fill_base_addr;
                    axi_arvalid   <= 1'b1;
                    axi_araddr    <= fill_base_addr;
                    axi_arlen     <= calc_burst_arlen(4'd0, fill_base_addr);
                    state         <= S_FILL_AR;
                end

                S_FILL_AR: begin
                    if (axi_arvalid && axi_arready) begin
                        axi_arvalid <= 1'b0;
                        state       <= S_FILL_R;
                    end
                end

                S_FILL_R: begin
                    if (axi_rvalid && axi_rready) begin
                        if (axi_rlast) begin
                            if (fill_beat_x == (BEATS_PER_ROW_4 - 4'd1)) begin
                                if (fill_row_y == (WIN_H_7 - 7'd1)) begin
                                    cache_valid <= !(cache_invalidate || inv_during_fill);
                                    state       <= S_CHECK;
                                end else begin
                                    fill_row_y    <= fill_row_y + 7'd1;
                                    fill_beat_x   <= 4'd0;
                                    fill_row_addr <= fill_row_addr + ROW_STRIDE_33;
                                    fill_cur_addr <= fill_row_addr + ROW_STRIDE_33;
                                    axi_arvalid   <= 1'b1;
                                    axi_araddr    <= fill_row_addr + ROW_STRIDE_33;
                                    axi_arlen     <= calc_burst_arlen(4'd0, fill_row_addr + ROW_STRIDE_33);
                                    state         <= S_FILL_AR;
                                end
                            end else begin
                                fill_beat_x   <= fill_beat_x + 4'd1;
                                fill_cur_addr <= fill_cur_addr + 33'd32;
                                axi_arvalid   <= 1'b1;
                                axi_araddr    <= fill_cur_addr + 33'd32;
                                axi_arlen     <= calc_burst_arlen(fill_beat_x + 4'd1, fill_cur_addr + 33'd32);
                                state         <= S_FILL_AR;
                            end
                        end else begin
                            fill_beat_x   <= fill_beat_x + 4'd1;
                            fill_cur_addr <= fill_cur_addr + 33'd32;
                        end
                    end
                end

                S_RD: begin
                    if (fast_4x4_r) begin
                        for (ic = 0; ic < 4; ic = ic + 1) begin
                            ext_buf[{wr_step[2:0], 1'b0}][ic] <= extr_a[ic];
                            ext_buf[{wr_step[2:0], 1'b1}][ic] <= extr_b[ic];
                        end
                        for (ic = 4; ic < BLK_EXT_Y; ic = ic + 1) begin
                            ext_buf[{wr_step[2:0], 1'b0}][ic] <= {PIXEL_WIDTH{1'b0}};
                            ext_buf[{wr_step[2:0], 1'b1}][ic] <= {PIXEL_WIDTH{1'b0}};
                        end
                    end else begin
                        for (ic = 0; ic < BLK_EXT_Y; ic = ic + 1) begin
                            if (!is_4x4_r || (ic < 4))
                                ext_buf[wr_step][ic] <= extr_a[ic];
                            else
                                ext_buf[wr_step][ic] <= {PIXEL_WIDTH{1'b0}};
                        end
                    end
                    wr_step <= wr_step + 4'd1;
                    if (rd_step == (total_steps - 4'd1)) begin
                        state <= S_RD_LAST;
                    end else begin
                        rd_step <= rd_step + 4'd1;
                    end
                end

                S_RD_LAST: begin
                    if (fast_4x4_r) begin
                        for (ic = 0; ic < 4; ic = ic + 1) begin
                            ext_buf[{wr_step[2:0], 1'b0}][ic] <= extr_a[ic];
                            ext_buf[{wr_step[2:0], 1'b1}][ic] <= extr_b[ic];
                        end
                        for (ic = 4; ic < BLK_EXT_Y; ic = ic + 1) begin
                            ext_buf[{wr_step[2:0], 1'b0}][ic] <= {PIXEL_WIDTH{1'b0}};
                            ext_buf[{wr_step[2:0], 1'b1}][ic] <= {PIXEL_WIDTH{1'b0}};
                        end
                    end else begin
                        for (ic = 0; ic < BLK_EXT_Y; ic = ic + 1) begin
                            if (!is_4x4_r || (ic < 4))
                                ext_buf[wr_step][ic] <= extr_a[ic];
                            else
                                ext_buf[wr_step][ic] <= {PIXEL_WIDTH{1'b0}};
                        end
                    end
                    cache_resp_valid <= 1'b1;
                    req_ready        <= 1'b1;
                    state            <= S_IDLE;
                end

                S_BYPASS_REQ: begin
                    if (buf_req_valid && buf_req_ready) begin
                        buf_req_valid <= 1'b0;
                        state         <= S_BYPASS_WAIT;
                    end
                end

                S_BYPASS_WAIT: begin
                    if (buf_resp_valid) begin
                        req_ready <= 1'b1;
                        state     <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
