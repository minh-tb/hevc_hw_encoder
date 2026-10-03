//=============================================================================
// deblock_top.sv
// Deblocking Filter — Top Level Orchestrator (SystemVerilog Translation)
//
// Mapped from HM source:
//   TLibCommon/TComLoopFilter.cpp
//   xDeblockCTU()          — per-CTU entry point
//   xEdgeFilterLuma()      — iterate over luma edges
//   xEdgeFilterChroma()    — iterate over chroma edges
//
// HEVC spec: Section 8.7.2 (deblocking filter process)
//=============================================================================

`include "parameter_pkg.vh"
`include "hevc_interfaces.vh"

module deblock_top (
    input  wire         clk,
    input  wire         rst_n,

    //=========================================================================
    // CTU control — one CTU at a time
    //=========================================================================
    input  wire         ctu_valid,          // new CTU ready for deblocking
    output wire         ctu_ready,
    input  wire [15:0]  ctu_addr,
    input  wire [9:0]   ctu_x,              // CTU position in frame
    input  wire [9:0]   ctu_y,
    input  wire [11:0]  frame_width_px,
    input  wire [11:0]  frame_height_px,

    //=========================================================================
    // CU info shadow map — filled by encoder as CUs are encoded
    // Indexed by 4×4 block within CTU: [row4][col4], 0..15 each
    // Total: 16×16 = 256 entries per CTU
    //=========================================================================
    input  wire [255:0]  cu_map_pred_mode,  // 0=inter, 1=intra
    input  wire [255:0]  cu_map_cbf_luma,
    input  wire [255:0]  cu_map_cbf_chroma,
    input  wire [767:0]  cu_map_ref_l0,
    input  wire [767:0]  cu_map_ref_l1,
    input  wire [255:0]  cu_map_bi_pred,
    input  wire [4095:0] cu_map_mvx_l0,
    input  wire [4095:0] cu_map_mvy_l0,
    input  wire [4095:0] cu_map_mvx_l1,
    input  wire [4095:0] cu_map_mvy_l1,
    input  wire [1535:0] cu_map_qp,

    //=========================================================================
    // Pixel buffer interface
    // Read reconstructed pixels, write deblocked pixels back
    // Luma:   64×64 pixels, row-major
    // Chroma: 32×32 pixels each (Cb, Cr)
    //=========================================================================
    // Read request
    output reg            pix_rd_valid,
    input  wire           pix_rd_ready,
    output reg    [5:0]   pix_rd_x,          // pixel x within CTU (luma coords)
    output reg    [5:0]   pix_rd_y,
    output reg    [1:0]   pix_rd_comp,

    // Read response
    input  wire           pix_resp_valid,
    output wire           pix_resp_ready,
    input  wire [`PIXEL_WIDTH-1:0] pix_resp_data,

    // Write back
    output reg            pix_wr_valid,
    input  wire           pix_wr_ready,
    output reg    [5:0]   pix_wr_x,
    output reg    [5:0]   pix_wr_y,
    output reg    [1:0]   pix_wr_comp,
    output reg    [`PIXEL_WIDTH-1:0] pix_wr_data,

    //=========================================================================
    // Done signal
    //=========================================================================
    output reg            ctu_done          // pulse when CTU deblocking complete
);

    //-------------------------------------------------------------------------
    // Processing pass encoding: 6 passes per CTU (Luma V/H, Cb V/H, Cr V/H)
    //-------------------------------------------------------------------------
    localparam [2:0] PASS_LUMA_VERT  = 3'd0;
    localparam [2:0] PASS_LUMA_HORIZ = 3'd1;
    localparam [2:0] PASS_CB_VERT    = 3'd2;
    localparam [2:0] PASS_CB_HORIZ   = 3'd3;
    localparam [2:0] PASS_CR_VERT    = 3'd4;
    localparam [2:0] PASS_CR_HORIZ   = 3'd5;

    //-------------------------------------------------------------------------
    // FSM states
    //-------------------------------------------------------------------------
    localparam [3:0]
        S_IDLE        = 4'd0,
        S_BS_REQ      = 4'd1,   // drive boundary_strength inputs
        S_BS_WAIT     = 4'd2,   // wait for BS result
        S_PIX_LOAD    = 4'd3,   // load 8 samples (luma) or 4 (chroma)
        S_FILT_PUSH   = 4'd9,   // push luma line to db_filter_luma
        S_FILT_WAIT   = 4'd4,   // wait for filter output
        S_PIX_WRITE   = 4'd5,   // write filtered samples back
        S_NEXT_EDGE   = 4'd6,   // advance to next edge
        S_NEXT_PASS   = 4'd7,   // advance to next pass
        S_DONE        = 4'd8;

    reg [3:0]    state;
    reg [2:0]    pass;            // current processing pass (0..5)
    reg [3:0]    edge_col;        // 0..15 (4×4 edge column within CTU)
    reg [3:0]    edge_row;        // 0..15
    reg [2:0]    sample_grp;      // which 4-sample group along the edge (0..3 luma, 0..1 chroma)
    reg [2:0]    resp_cnt;        // sample read response counter
    reg [2:0]    write_cnt;       // which sample we're writing back (0..5 luma, 0..1 chroma)

    // Latch current CTU info
    reg [15:0]   cur_ctu_addr;
    reg [9:0]    cur_ctu_x, cur_ctu_y;
    reg [11:0]   cur_frame_w, cur_frame_h;

    assign ctu_ready      = (state == S_IDLE);
    assign pix_resp_ready = (state == S_PIX_LOAD);

    //-------------------------------------------------------------------------
    // Edge geometry helpers
    //-------------------------------------------------------------------------
    wire is_luma, is_vert, is_chroma;
    wire [1:0] cur_comp;
    
    assign is_luma   = (pass == PASS_LUMA_VERT || pass == PASS_LUMA_HORIZ);
    assign is_vert   = (pass == PASS_LUMA_VERT || pass == PASS_CB_VERT || pass == PASS_CR_VERT);
    assign is_chroma = !is_luma;
    assign cur_comp  = is_luma ? 2'd0 :
                       (pass == PASS_CB_VERT || pass == PASS_CB_HORIZ) ? 2'd1 : 2'd2;

    wire [3:0] max_col, max_row;
    assign max_col = is_luma ? 4'd15 : 4'd7;
    assign max_row = is_luma ? 4'd15 : 4'd7;

    wire [2:0] max_grp;
    assign max_grp = 3'd3;

    // CU Map coordinates (Scale chroma 8x8 grid to 16x16 luma grid)
    wire [3:0] edge_col_cu;
    wire [3:0] edge_row_cu;
    assign edge_col_cu = is_chroma ? {edge_col[2:0], 1'b0} : edge_col;
    assign edge_row_cu = is_chroma ? {edge_row[2:0], 1'b0} : edge_row;

    // P-side and Q-side 4×4 block indices
    wire [3:0] p_col, p_row, q_col, q_row;
    assign p_col = is_vert  ? (edge_col_cu > 4'd0 ? edge_col_cu - 4'd1 : 4'd0) : edge_col_cu;
    assign p_row = !is_vert ? (edge_row_cu > 4'd0 ? edge_row_cu - 4'd1 : 4'd0) : edge_row_cu;
    assign q_col = edge_col_cu;
    assign q_row = edge_row_cu;

    // In HEVC Clause 8.7.2, deblocking is applied on an 8x8 sample grid across all internal TU/PU boundaries.
    // In our single-CTU local memory architecture:
    // - Luma 64x64 with 32x32 TUs: internal TU boundary is at x=32 (edge_col=8) or y=32 (edge_row=8).
    // - Chroma 32x32 with 16x16 TUs: internal TU boundary is at x=16 (edge_col=4) or y=16 (edge_row=4).
    // Internal 8x8 block lines within 32x32 TUs that are NOT TU boundaries must NOT be filtered.
    wire [3:0] tu_edge_target = is_luma ? 4'd8 : 4'd4;
    wire is_valid_edge;
    assign is_valid_edge = is_vert ? (edge_col == tu_edge_target)
                                   : (edge_row == tu_edge_target);

    wire is_ctu_boundary, skip_edge;
    assign is_ctu_boundary = is_vert ? (edge_col == 4'd0) : (edge_row == 4'd0);
    assign skip_edge       = !is_valid_edge;

    //-------------------------------------------------------------------------
    // boundary_strength instance
    //-------------------------------------------------------------------------
    reg          bs_in_valid, bs_out_ready;
    wire         bs_in_ready, bs_out_valid;
    wire [1:0]   bs_result;
    wire [5:0]   bs_edge_qp;

    boundary_strength u_bs (
        .clk             (clk),
        .rst_n           (rst_n),
        .in_valid        (bs_in_valid),
        .in_ready        (bs_in_ready),
        .is_vertical     (is_vert),
        .is_ctu_boundary (is_ctu_boundary),
        
        .p_is_intra      (cu_map_pred_mode[(p_row*16)+p_col]),
        .p_qp            (cu_map_qp[((p_row*16)+p_col)*6 +: 6]),
        .p_cbf_luma      (cu_map_cbf_luma[(p_row*16)+p_col]),
        .p_cbf_chroma    (cu_map_cbf_chroma[(p_row*16)+p_col]),
        .p_ref_idx_l0    (cu_map_ref_l0[((p_row*16)+p_col)*3 +: 3]),
        .p_ref_idx_l1    (cu_map_ref_l1[((p_row*16)+p_col)*3 +: 3]),
        .p_bi_pred       (cu_map_bi_pred[(p_row*16)+p_col]),
        .p_mvx_l0        (cu_map_mvx_l0[((p_row*16)+p_col)*16 +: 16]),
        .p_mvy_l0        (cu_map_mvy_l0[((p_row*16)+p_col)*16 +: 16]),
        .p_mvx_l1        (cu_map_mvx_l1[((p_row*16)+p_col)*16 +: 16]),
        .p_mvy_l1        (cu_map_mvy_l1[((p_row*16)+p_col)*16 +: 16]),
        
        .q_is_intra      (cu_map_pred_mode[(q_row*16)+q_col]),
        .q_qp            (cu_map_qp[((q_row*16)+q_col)*6 +: 6]),
        .q_cbf_luma      (cu_map_cbf_luma[(q_row*16)+q_col]),
        .q_cbf_chroma    (cu_map_cbf_chroma[(q_row*16)+q_col]),
        .q_ref_idx_l0    (cu_map_ref_l0[((q_row*16)+q_col)*3 +: 3]),
        .q_ref_idx_l1    (cu_map_ref_l1[((q_row*16)+q_col)*3 +: 3]),
        .q_bi_pred       (cu_map_bi_pred[(q_row*16)+q_col]),
        .q_mvx_l0        (cu_map_mvx_l0[((q_row*16)+q_col)*16 +: 16]),
        .q_mvy_l0        (cu_map_mvy_l0[((q_row*16)+q_col)*16 +: 16]),
        .q_mvx_l1        (cu_map_mvx_l1[((q_row*16)+q_col)*16 +: 16]),
        .q_mvy_l1        (cu_map_mvy_l1[((q_row*16)+q_col)*16 +: 16]),
        
        .edge_qp         (bs_edge_qp),
        .out_valid       (bs_out_valid),
        .out_ready       (bs_out_ready),
        .bs              (bs_result)
    );

    //-------------------------------------------------------------------------
    // Pixel sample registers and Filters
    //-------------------------------------------------------------------------
    reg [`PIXEL_WIDTH-1:0] px_p [0:3];
    reg [`PIXEL_WIDTH-1:0] px_q [0:3];
    reg [1:0]  latched_bs;
    reg [5:0]  latched_edge_qp;

    reg luma_in_valid;
    wire luma_out_ready;
    wire luma_in_ready, luma_out_valid;
    wire [`PIXEL_WIDTH-1:0] luma_p0f, luma_p1f, luma_p2f, luma_q0f, luma_q1f, luma_q2f;
    wire luma_mod_p, luma_mod_q;

    assign luma_out_ready = (state == S_PIX_WRITE) && is_luma && pix_wr_ready && (write_cnt == 3'd5);

    db_filter_luma u_luma (
        .clk(clk), .rst_n(rst_n),
        .in_valid(luma_in_valid), .in_ready(luma_in_ready),
        .bs(latched_bs), .edge_qp(latched_edge_qp),
        .p0(px_p[0]), .p1(px_p[1]), .p2(px_p[2]), .p3(px_p[3]),
        .q0(px_q[0]), .q1(px_q[1]), .q2(px_q[2]), .q3(px_q[3]),
        .out_valid(luma_out_valid), .out_ready(luma_out_ready),
        .p0_f(luma_p0f), .p1_f(luma_p1f), .p2_f(luma_p2f),
        .q0_f(luma_q0f), .q1_f(luma_q1f), .q2_f(luma_q2f),
        .modified_p(luma_mod_p), .modified_q(luma_mod_q)
    );

    reg chr_in_valid, chr_out_ready;
    wire chr_in_ready, chr_out_valid, chr_modified;
    wire [`PIXEL_WIDTH-1:0] chr_p0f, chr_q0f, chr_p1p, chr_q1p;

    db_filter_chroma u_chroma (
        .clk(clk), .rst_n(rst_n),
        .in_valid(chr_in_valid), .in_ready(chr_in_ready),
        .bs(latched_bs), .edge_qp(latched_edge_qp),
        .comp(cur_comp),
        .p0(px_p[0]), .p1(px_p[1]), .q0(px_q[0]), .q1(px_q[1]),
        .out_valid(chr_out_valid), .out_ready(chr_out_ready),
        .p0_f(chr_p0f), .q0_f(chr_q0f), .p1_pass(chr_p1p), .q1_pass(chr_q1p),
        .modified(chr_modified)
    );

    //-------------------------------------------------------------------------
    // Main FSM
    //-------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            pass         <= PASS_LUMA_VERT;
            edge_col     <= 4'd0;
            edge_row     <= 4'd0;
            sample_grp   <= 3'd0;
            resp_cnt     <= 3'd0;
            write_cnt    <= 3'd0;
            ctu_done     <= 1'b0;
            bs_in_valid  <= 1'b0;
            bs_out_ready <= 1'b0;
            luma_in_valid<= 1'b0;
            chr_in_valid <= 1'b0;
            chr_out_ready<= 1'b0;
            pix_rd_valid <= 1'b0;
        end else begin
            ctu_done       <= 1'b0;
            bs_in_valid    <= 1'b0;
            luma_in_valid  <= 1'b0;
            chr_in_valid   <= 1'b0;
            chr_out_ready  <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (ctu_valid) begin
                        cur_ctu_addr <= ctu_addr;
                        cur_ctu_x    <= ctu_x;
                        cur_ctu_y    <= ctu_y;
                        cur_frame_w  <= frame_width_px;
                        cur_frame_h  <= frame_height_px;
                        pass         <= PASS_LUMA_VERT;
                        edge_col     <= 4'd0;
                        edge_row     <= 4'd0;
                        sample_grp   <= 3'd0;
                        state        <= S_BS_REQ;
                    end
                end
                S_BS_REQ: begin
                    if (skip_edge) begin
                        sample_grp <= 3'd3;
                        state      <= S_NEXT_EDGE;
                    end else begin
                        bs_in_valid  <= 1'b1;
                        bs_out_ready <= 1'b1;
                        if (bs_in_valid && bs_in_ready)
                            state <= S_BS_WAIT;
                    end
                end
                S_BS_WAIT: begin
                    if (bs_out_valid) begin
                        latched_bs      <= bs_result;
                        latched_edge_qp <= bs_edge_qp;
                        bs_out_ready    <= 1'b1;
                        if (bs_result == 2'd0) begin
                            sample_grp <= 3'd3;
                            state      <= S_NEXT_EDGE;
                        end else begin
                            resp_cnt     <= 3'd0;
                            sample_grp   <= is_luma ? 3'd0 : sample_grp;
                            pix_rd_valid <= 1'b1;
                            pix_rd_comp  <= cur_comp;
                            state        <= S_PIX_LOAD;
                        end
                    end
                end
                S_PIX_LOAD: begin
                    bs_out_ready <= 1'b0;
                    if (pix_rd_valid && pix_rd_ready) begin
                        pix_rd_valid <= 1'b0;
                    end

                    if (pix_resp_valid && pix_resp_ready) begin
                        if (resp_cnt < (is_luma ? 3'd4 : 3'd2)) px_p[resp_cnt[1:0]] <= pix_resp_data;
                        else                                    px_q[resp_cnt[1:0] - (is_luma ? 2'd0 : 2'd2)] <= pix_resp_data;

                        if (resp_cnt < (is_luma ? 3'd7 : 3'd3)) begin
                            resp_cnt     <= resp_cnt + 3'd1;
                            pix_rd_valid <= 1'b1;
                            pix_rd_comp  <= cur_comp;
                        end else begin
                            resp_cnt     <= 3'd0;
                            pix_rd_valid <= 1'b0;
                            if (is_luma) begin
                                luma_in_valid <= 1'b1;
                                state         <= S_FILT_PUSH;
                            end else begin
                                chr_in_valid  <= 1'b1;
                                state         <= S_FILT_WAIT;
                            end
                        end
                    end
                end
                S_FILT_PUSH: begin
                    if (is_luma) begin
                        if (luma_in_ready) begin
                            luma_in_valid <= 1'b0;
                            if (sample_grp < 3'd3) begin
                                sample_grp   <= sample_grp + 3'd1;
                                resp_cnt     <= 3'd0;
                                pix_rd_valid <= 1'b1;
                                pix_rd_comp  <= cur_comp;
                                state        <= S_PIX_LOAD;
                            end else begin
                                sample_grp   <= 3'd0;
                                state        <= S_FILT_WAIT;
                            end
                        end else begin
                            luma_in_valid <= 1'b1;
                        end
                    end
                end
                S_FILT_WAIT: begin
                    if (is_luma) begin
                        if (luma_out_valid) begin
                            write_cnt <= 3'd0;
                            state     <= S_PIX_WRITE;
                        end
                    end else begin
                        chr_out_ready <= 1'b1;
                        if (chr_out_valid) begin
                            chr_out_ready <= 1'b0;
                            write_cnt     <= 3'd0;
                            state         <= S_PIX_WRITE;
                        end
                    end
                end
                S_PIX_WRITE: begin
                    if (pix_wr_ready) begin
                        if (write_cnt == (is_luma ? 3'd5 : 3'd1)) begin
                            write_cnt <= 3'd0;
                            if (is_luma) begin
                                if (sample_grp < 3'd3) begin
                                    sample_grp <= sample_grp + 3'd1;
                                end else begin
                                    sample_grp <= 3'd3;
                                    state      <= S_NEXT_EDGE;
                                end
                            end else begin
                                state <= S_NEXT_EDGE;
                            end
                        end else begin
                            write_cnt <= write_cnt + 3'd1;
                        end
                    end
                end
                S_NEXT_EDGE: begin
                    if (sample_grp < max_grp) begin
                        sample_grp <= sample_grp + 3'd1;
                        state      <= S_BS_REQ;
                    end else begin
                        sample_grp <= 3'd0;
                        if (edge_col < max_col) begin
                            edge_col <= edge_col + 4'd1;
                            state    <= S_BS_REQ;
                        end else begin
                            edge_col <= 4'd0;
                            if (edge_row < max_row) begin
                                edge_row <= edge_row + 4'd1;
                                state    <= S_BS_REQ;
                            end else begin
                                edge_row <= 4'd0;
                                state    <= S_NEXT_PASS;
                            end
                        end
                    end
                end
                S_NEXT_PASS: begin
                    if (pass == PASS_CR_HORIZ) begin
                        state    <= S_DONE;
                    end else begin
                        pass     <= pass + 3'd1;
                        edge_col <= 4'd0;
                        edge_row <= 4'd0;
                        sample_grp <= 3'd0;
                        state    <= S_BS_REQ;
                    end
                end
                S_DONE: begin
                    ctu_done <= 1'b1;
                    state    <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    //-------------------------------------------------------------------------
    // Pixel combinational address and data generation
    //-------------------------------------------------------------------------
    wire [2:0] px_idx;
    wire       loading_q;
    wire [2:0] q_idx;
    wire [5:0] ec, er;
    wire [2:0] sg;
    wire [2:0] wr_q_idx;

    assign px_idx    = resp_cnt;
    assign loading_q = is_luma ? (px_idx >= 3'd4) : (px_idx >= 3'd2);
    assign q_idx     = is_luma ? (px_idx - 3'd4) : (px_idx - 3'd2);
    assign wr_q_idx  = is_luma ? (write_cnt - 3'd3) : (write_cnt - 3'd1);

    assign ec = edge_col;
    assign er = edge_row;
    assign sg = sample_grp;

    always @(*) begin
        // Defaults to prevent latches
        pix_rd_x = 6'd0;
        pix_rd_y = 6'd0;
        
        if (is_vert) begin
            pix_rd_y = {er, 2'b00} + {3'b0, sg};
            if (loading_q) pix_rd_x = {ec, 2'b00} + {3'b0, q_idx};
            else           pix_rd_x = {ec, 2'b00} - 6'd1 - {3'b0, px_idx};
        end else begin
            pix_rd_x = {ec, 2'b00} + {3'b0, sg};
            if (loading_q) pix_rd_y = {er, 2'b00} + {3'b0, q_idx};
            else           pix_rd_y = {er, 2'b00} - 6'd1 - {3'b0, px_idx};
        end
    end

    always @(*) begin
        pix_wr_valid = (state == S_PIX_WRITE);
        pix_wr_comp  = cur_comp;

        // Combinational write data
        if (is_luma) begin
            case (write_cnt)
                3'd0: pix_wr_data = luma_p0f;
                3'd1: pix_wr_data = luma_p1f;
                3'd2: pix_wr_data = luma_p2f;
                3'd3: pix_wr_data = luma_q0f;
                3'd4: pix_wr_data = luma_q1f;
                3'd5: pix_wr_data = luma_q2f;
                default: pix_wr_data = {`PIXEL_WIDTH{1'b0}};
            endcase
        end else begin
            case (write_cnt)
                3'd0: pix_wr_data = chr_p0f;
                3'd1: pix_wr_data = chr_q0f;
                default: pix_wr_data = {`PIXEL_WIDTH{1'b0}};
            endcase
        end

        // Combinational write address
        pix_wr_x = 6'd0;
        pix_wr_y = 6'd0;
        if (is_vert) begin
            pix_wr_y = {er, 2'b00} + {3'b0, sg};
            if (write_cnt <= (is_luma ? 3'd2 : 3'd0)) pix_wr_x = {ec, 2'b00} - 6'd1 - {3'b0, write_cnt};
            else                                      pix_wr_x = {ec, 2'b00} + {3'b0, wr_q_idx};
        end else begin
            pix_wr_x = {ec, 2'b00} + {3'b0, sg};
            if (write_cnt <= (is_luma ? 3'd2 : 3'd0)) pix_wr_y = {er, 2'b00} - 6'd1 - {3'b0, write_cnt};
            else                                      pix_wr_y = {er, 2'b00} + {3'b0, wr_q_idx};
        end
    end

    //-------------------------------------------------------------------------
    // Simulation checks
    //-------------------------------------------------------------------------
    // synthesis translate_off
    always @(posedge clk) begin
        if (rst_n && ctu_done)
            $display("INFO  [deblock_top] CTU done addr=%0d (%0d,%0d) at time=%0t",
                     cur_ctu_addr, cur_ctu_x, cur_ctu_y, $time);
    end
    // synthesis translate_on

endmodule