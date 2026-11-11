//=============================================================================
// sao_top.v
// SAO — Top Level Orchestrator
//
// Mapped from HM source:
//   TLibCommon/TComSampleAdaptiveOffset.cpp
//   processSaoBlock() — dispatch EO/BO per component per CTU
//   SaoLcuParam       — per-CTU SAO parameter struct
//
// HEVC spec: Section 8.7.3 (sample adaptive offset process)
//
// SAO applied AFTER deblocking, per CTU per component.
// Types: NONE(0), EO(1), BO(2) — independent per Y/Cb/Cr.
// Processing order: Y → Cb → Cr, raster scan within each component.
//
// Config: SAO=1, SAOLcuBoundary=0 (use deblocked pixels at boundary)
//=============================================================================

`include "parameter_pkg.vh"

module sao_top #(
    parameter SINGLE_PORT_BRAM_MODE = 0
)(
    input  wire         clk,
    input  wire         rst_n,

    // CTU control
    input  wire         ctu_valid,
    output wire         ctu_ready,
    input  wire [9:0]   ctu_x,
    input  wire [9:0]   ctu_y,
    input  wire [11:0]  frame_width_px,
    input  wire [11:0]  frame_height_px,

    // SAO parameters per component (from CABAC decoder/encoder decision)
    input  wire [5:0]   sao_type,    // 0=none,1=EO,2=BO (packed 3 x 2-bit: [1:0]=Y, [3:2]=Cb, [5:4]=Cr)
    input  wire [5:0]   eo_class,    // (packed 3 x 2-bit: [1:0]=Y, [3:2]=Cb, [5:4]=Cr)
    input  wire [(3*5*`SAO_OFFSET_WIDTH)-1:0] eo_offset, // (packed 3 x 5 x 5-bit)
    input  wire [14:0]  band_pos,    // (packed 3 x 5-bit: [4:0]=Y, [9:5]=Cb, [14:10]=Cr)
    input  wire [(3*4*`SAO_OFFSET_WIDTH)-1:0] bo_offset, // (packed 3 x 4 x 5-bit)

    // Pixel read (from deblocked frame buffer)
    output reg          pix_rd_valid,
    input  wire         pix_rd_ready,
    output reg  [5:0]   pix_rd_x,
    output reg  [5:0]   pix_rd_y,
    output reg  [1:0]   pix_rd_comp,
    input  wire         pix_resp_valid,
    output wire         pix_resp_ready,
    input  wire [`PIXEL_WIDTH-1:0] pix_resp_data,

    // Neighbour reads (EO only — n0 and n1)
    output reg          n0_rd_valid,
    input  wire         n0_rd_ready,
    output reg  signed [7:0] n0_rd_x,
    output reg  signed [7:0] n0_rd_y,
    output reg  [1:0]   n0_rd_comp,
    input  wire         n0_resp_valid,
    output wire         n0_resp_ready,
    input  wire [`PIXEL_WIDTH-1:0] n0_resp_data,

    output reg          n1_rd_valid,
    input  wire         n1_rd_ready,
    output reg  signed [7:0] n1_rd_x,
    output reg  signed [7:0] n1_rd_y,
    output reg  [1:0]   n1_rd_comp,
    input  wire         n1_resp_valid,
    output wire         n1_resp_ready,
    input  wire [`PIXEL_WIDTH-1:0] n1_resp_data,

    // Pixel write (back to frame buffer)
    output reg          pix_wr_valid,
    input  wire         pix_wr_ready,
    output reg  [5:0]   pix_wr_x,
    output reg  [5:0]   pix_wr_y,
    output reg  [1:0]   pix_wr_comp,
    output reg  [`PIXEL_WIDTH-1:0] pix_wr_data,

    output reg          ctu_done
);

    //-------------------------------------------------------------------------
    // FSM States
    //-------------------------------------------------------------------------
    localparam [2:0]
        S_IDLE     = 3'd0,
        S_REQ_PIX  = 3'd1,
        S_REQ_N1   = 3'd2,
        S_WAIT_PIX = 3'd3,
        S_APPLY    = 3'd4,
        S_FILTER   = 3'd5,
        S_WRITE    = 3'd6,
        S_DONE     = 3'd7;

    reg [2:0] state;

    assign ctu_ready      = (state == S_IDLE);
    assign pix_resp_ready = 1'b1;
    assign n0_resp_ready  = 1'b1;
    assign n1_resp_ready  = 1'b1;

    // Component and coordinate counters
    reg [1:0] comp_idx;      // 0=Y, 1=Cb, 2=Cr
    reg [5:0] scan_x, scan_y;
    reg [5:0] p_x_q1, p_y_q1, p_x_q2, p_y_q2;
    reg [1:0] p_comp_q1, p_comp_q2;
    wire [5:0] max_dim = (comp_idx == 2'd0) ? 6'd63 : 6'd31;

    // Picture boundary detection per ITU-T H.265 Clause 8.7.3.2
    wire has_geom = (|frame_width_px === 1'b1);
    wire [11:0] eff_frame_w = has_geom ? frame_width_px : 12'd128;
    wire [11:0] eff_frame_h = has_geom ? frame_height_px : 12'd128;

    wire [11:0] cur_abs_x = (comp_idx == 2'd0) ? (({2'd0, ctu_x} << 6) + {6'd0, p_x_q1}) :
                                                 (({2'd0, ctu_x} << 5) + {7'd0, p_x_q1[4:0]});
    wire [11:0] cur_abs_y = (comp_idx == 2'd0) ? (({2'd0, ctu_y} << 6) + {6'd0, p_y_q1}) :
                                                 (({2'd0, ctu_y} << 5) + {7'd0, p_y_q1[4:0]});
    wire [11:0] max_pic_x = (comp_idx == 2'd0) ? (eff_frame_w - 12'd1) : ((eff_frame_w >> 1) - 12'd1);
    wire [11:0] max_pic_y = (comp_idx == 2'd0) ? (eff_frame_h - 12'd1) : ((eff_frame_h >> 1) - 12'd1);

    // Active SAO params for current component
    wire [1:0] cur_sao_type = (comp_idx == 2'd0) ? sao_type[1:0] :
                              (comp_idx == 2'd1) ? sao_type[3:2] : sao_type[5:4];

    wire [1:0] cur_eo_class = (comp_idx == 2'd0) ? eo_class[1:0] :
                              (comp_idx == 2'd1) ? eo_class[3:2] : eo_class[5:4];

    wire [24:0] cur_eo_offset = (comp_idx == 2'd0) ? eo_offset[24:0] :
                               (comp_idx == 2'd1) ? eo_offset[49:25] : eo_offset[74:50];

    wire [4:0] cur_band_pos = (comp_idx == 2'd0) ? band_pos[4:0] :
                              (comp_idx == 2'd1) ? band_pos[9:5] : band_pos[14:10];

    wire [19:0] cur_bo_offset = (comp_idx == 2'd0) ? bo_offset[19:0] :
                               (comp_idx == 2'd1) ? bo_offset[39:20] : bo_offset[59:40];

    wire eo_pic_boundary =
        (cur_eo_class == 2'd0 && (cur_abs_x == 12'd0 || cur_abs_x == max_pic_x)) ||
        (cur_eo_class == 2'd1 && (cur_abs_y == 12'd0 || cur_abs_y == max_pic_y)) ||
        ((cur_eo_class == 2'd2 || cur_eo_class == 2'd3) &&
         (cur_abs_x == 12'd0 || cur_abs_y == 12'd0 || cur_abs_x == max_pic_x || cur_abs_y == max_pic_y));

    // Internal Row & Neighbor Buffers for 2-Phase Single-Port BRAM (Safeguard 4)
    reg [9:0] pre_sao_row_buf [0:63];
    reg [9:0] cur_row_left;
    reg [9:0] prev_row_left_d;
    reg [9:0] c_pix;
    reg [9:0] n0_pix;
    reg [9:0] n1_pix;

    // Sub-module instances
    reg         eo_in_valid;
    wire        eo_in_ready, eo_out_valid;
    wire [`PIXEL_WIDTH-1:0] eo_pixel_out;

    wire [`PIXEL_WIDTH-1:0] eo_in_pix_mux = (SINGLE_PORT_BRAM_MODE == 1) ? c_pix : pix_resp_data;
    wire [`PIXEL_WIDTH-1:0] eo_n0_mux     = eo_pic_boundary ? eo_in_pix_mux : ((SINGLE_PORT_BRAM_MODE == 1) ? n0_pix : n0_resp_data);
    wire [`PIXEL_WIDTH-1:0] eo_n1_mux     = eo_pic_boundary ? eo_in_pix_mux : ((SINGLE_PORT_BRAM_MODE == 1) ? n1_pix : n1_resp_data);

    sao_edge_offset u_sao_eo (
        .clk        (clk),
        .rst_n      (rst_n),
        .edge_type  (cur_eo_class),
        .offset     (cur_eo_offset),
        .in_valid   (eo_in_valid),
        .in_ready   (eo_in_ready),
        .pixel_in   (eo_in_pix_mux),
        .neigh0     (eo_n0_mux),
        .neigh1     (eo_n1_mux),
        .in_last    (1'b0),
        .out_valid  (eo_out_valid),
        .out_ready  (1'b1),
        .pixel_out  (eo_pixel_out),
        .out_last   ()
    );

    reg         bo_in_valid;
    wire        bo_in_ready, bo_out_valid;
    wire [`PIXEL_WIDTH-1:0] bo_pixel_out;

    sao_band_offset u_sao_bo (
        .clk        (clk),
        .rst_n      (rst_n),
        .band_position(cur_band_pos),
        .offset     (cur_bo_offset),
        .in_valid   (bo_in_valid),
        .in_ready   (bo_in_ready),
        .pixel_in   ((SINGLE_PORT_BRAM_MODE == 1) ? c_pix : pix_resp_data),
        .in_last    (1'b0),
        .out_valid  (bo_out_valid),
        .out_ready  (1'b1),
        .pixel_out  (bo_pixel_out),
        .out_last   ()
    );



    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            ctu_done     <= 1'b0;
            comp_idx     <= 2'd0;
            scan_x       <= 6'd0;
            scan_y       <= 6'd0;
            pix_rd_valid <= 1'b0;
            n0_rd_valid  <= 1'b0;
            n1_rd_valid  <= 1'b0;
            pix_wr_valid <= 1'b0;
            eo_in_valid  <= 1'b0;
            bo_in_valid  <= 1'b0;
            p_x_q1       <= 6'd0;
            p_y_q1       <= 6'd0;
            p_comp_q1    <= 2'd0;
            p_x_q2       <= 6'd0;
            p_y_q2       <= 6'd0;
            p_comp_q2    <= 2'd0;
            c_pix        <= 10'd0;
            n0_pix       <= 10'd0;
            n1_pix       <= 10'd0;
            cur_row_left <= 10'd0;
            prev_row_left_d <= 10'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    ctu_done     <= 1'b0;
                    pix_wr_valid <= 1'b0;
                    if (ctu_valid) begin
                        if (sao_type == 6'd0) begin
                            // Bypass SAO if all components are NONE
                            state    <= S_DONE;
                            ctu_done <= 1'b1;
                        end else begin
                            state    <= S_REQ_PIX;
                            comp_idx <= 2'd0;
                            scan_x   <= 6'd0;
                            scan_y   <= 6'd0;
                        end
                    end
                end

                S_REQ_PIX: begin
                    pix_wr_valid <= 1'b0;
                    if (cur_sao_type == 2'd0) begin
                        // Skip this component if NONE
                        if (comp_idx == 2'd2) begin
                            state    <= S_DONE;
                            ctu_done <= 1'b1;
                        end else begin
                            comp_idx <= comp_idx + 2'd1;
                            scan_x   <= 6'd0;
                            scan_y   <= 6'd0;
                        end
                    end else if (SINGLE_PORT_BRAM_MODE == 1) begin
                        pix_rd_valid <= 1'b1;
                        pix_rd_x     <= scan_x;
                        pix_rd_y     <= scan_y;
                        pix_rd_comp  <= comp_idx;
                        n1_rd_valid  <= 1'b0;

                        if (cur_sao_type == 2'd1) begin // EO
                            case (cur_eo_class)
                                2'd0: begin // (x-1, y)
                                    if (scan_x == 6'd0) begin
                                        n0_rd_valid <= 1'b1;
                                        n0_rd_comp  <= comp_idx;
                                        n0_rd_x     <= -8'sd1;
                                        n0_rd_y     <= $signed({2'b00, scan_y});
                                    end else begin
                                        n0_rd_valid <= 1'b0;
                                    end
                                end
                                2'd1: begin // (x, y-1)
                                    if (scan_y == 6'd0) begin
                                        n0_rd_valid <= 1'b1;
                                        n0_rd_comp  <= comp_idx;
                                        n0_rd_x     <= $signed({2'b00, scan_x});
                                        n0_rd_y     <= -8'sd1;
                                    end else begin
                                        n0_rd_valid <= 1'b0;
                                    end
                                end
                                2'd2: begin // (x-1, y-1)
                                    if (scan_x == 6'd0 && scan_y == 6'd0) begin
                                        n0_rd_valid <= 1'b1;
                                        n0_rd_comp  <= comp_idx;
                                        n0_rd_x     <= -8'sd1;
                                        n0_rd_y     <= -8'sd1;
                                    end else if (scan_x == 6'd0) begin
                                        n0_rd_valid <= 1'b1;
                                        n0_rd_comp  <= comp_idx;
                                        n0_rd_x     <= -8'sd1;
                                        n0_rd_y     <= $signed({2'b00, scan_y}) - 8'sd1;
                                    end else if (scan_y == 6'd0) begin
                                        n0_rd_valid <= 1'b1;
                                        n0_rd_comp  <= comp_idx;
                                        n0_rd_x     <= $signed({2'b00, scan_x}) - 8'sd1;
                                        n0_rd_y     <= -8'sd1;
                                    end else begin
                                        n0_rd_valid <= 1'b0;
                                    end
                                end
                                2'd3: begin // (x+1, y-1)
                                    if (scan_y == 6'd0) begin
                                        n0_rd_valid <= 1'b1;
                                        n0_rd_comp  <= comp_idx;
                                        n0_rd_x     <= $signed({2'b00, scan_x}) + 8'sd1;
                                        n0_rd_y     <= -8'sd1;
                                    end else begin
                                        n0_rd_valid <= 1'b0;
                                    end
                                end
                            endcase
                            state <= S_REQ_N1;
                        end else begin // BO
                            n0_rd_valid <= 1'b0;
                            state       <= S_REQ_N1;
                        end
                        p_x_q1    <= scan_x;
                        p_y_q1    <= scan_y;
                        p_comp_q1 <= comp_idx;
                    end else begin
                        // Legacy dual-port BRAM mode
                        pix_rd_valid <= 1'b1;
                        pix_rd_x     <= scan_x;
                        pix_rd_y     <= scan_y;
                        pix_rd_comp  <= comp_idx;

                        if (cur_sao_type == 2'd1) begin // EO
                            n0_rd_valid <= 1'b1;
                            n1_rd_valid <= 1'b1;
                            n0_rd_comp  <= comp_idx;
                            n1_rd_comp  <= comp_idx;
                            case (cur_eo_class)
                                2'd0: begin // Horizontal: (x-1,y) and (x+1,y)
                                    n0_rd_x <= $signed({2'b00, scan_x}) - 8'sd1;
                                    n0_rd_y <= $signed({2'b00, scan_y});
                                    n1_rd_x <= $signed({2'b00, scan_x}) + 8'sd1;
                                    n1_rd_y <= $signed({2'b00, scan_y});
                                end
                                2'd1: begin // Vertical: (x,y-1) and (x,y+1)
                                    n0_rd_x <= $signed({2'b00, scan_x});
                                    n0_rd_y <= $signed({2'b00, scan_y}) - 8'sd1;
                                    n1_rd_x <= $signed({2'b00, scan_x});
                                    n1_rd_y <= $signed({2'b00, scan_y}) + 8'sd1;
                                end
                                2'd2: begin // 135 deg: (x-1,y-1) and (x+1,y+1)
                                    n0_rd_x <= $signed({2'b00, scan_x}) - 8'sd1;
                                    n0_rd_y <= $signed({2'b00, scan_y}) - 8'sd1;
                                    n1_rd_x <= $signed({2'b00, scan_x}) + 8'sd1;
                                    n1_rd_y <= $signed({2'b00, scan_y}) + 8'sd1;
                                end
                                2'd3: begin // 45 deg: (x+1,y-1) and (x-1,y+1)
                                    n0_rd_x <= $signed({2'b00, scan_x}) + 8'sd1;
                                    n0_rd_y <= $signed({2'b00, scan_y}) - 8'sd1;
                                    n1_rd_x <= $signed({2'b00, scan_x}) - 8'sd1;
                                    n1_rd_y <= $signed({2'b00, scan_y}) + 8'sd1;
                                end
                            endcase
                        end

                        p_x_q1    <= scan_x;
                        p_y_q1    <= scan_y;
                        p_comp_q1 <= comp_idx;
                        state     <= S_WAIT_PIX;
                    end
                end

                S_REQ_N1: begin
                    pix_rd_valid <= 1'b0;
                    n0_rd_valid  <= 1'b0;

                    if (cur_sao_type == 2'd1) begin
                        n1_rd_valid <= 1'b1;
                        n1_rd_comp  <= p_comp_q1;
                        case (cur_eo_class)
                            2'd0: begin
                                n1_rd_x <= $signed({2'b00, p_x_q1}) + 8'sd1;
                                n1_rd_y <= $signed({2'b00, p_y_q1});
                            end
                            2'd1: begin
                                n1_rd_x <= $signed({2'b00, p_x_q1});
                                n1_rd_y <= $signed({2'b00, p_y_q1}) + 8'sd1;
                            end
                            2'd2: begin
                                n1_rd_x <= $signed({2'b00, p_x_q1}) + 8'sd1;
                                n1_rd_y <= $signed({2'b00, p_y_q1}) + 8'sd1;
                            end
                            2'd3: begin
                                n1_rd_x <= $signed({2'b00, p_x_q1}) - 8'sd1;
                                n1_rd_y <= $signed({2'b00, p_y_q1}) + 8'sd1;
                            end
                        endcase
                    end else begin
                        n1_rd_valid <= 1'b0;
                    end
                    state <= S_WAIT_PIX;
                end

                S_WAIT_PIX: begin
                    pix_rd_valid <= 1'b0;
                    n0_rd_valid  <= 1'b0;
                    n1_rd_valid  <= 1'b0;

                    c_pix <= pix_resp_data;
                    if (cur_sao_type == 2'd1) begin
                        pre_sao_row_buf[p_x_q1] <= pix_resp_data;
                        cur_row_left           <= pix_resp_data;
                        if (p_x_q1 == 6'd0)
                            prev_row_left_d    <= pre_sao_row_buf[0];
                        else
                            prev_row_left_d    <= pre_sao_row_buf[p_x_q1];

                        case (cur_eo_class)
                            2'd0: n0_pix <= (p_x_q1 > 6'd0) ? cur_row_left : n0_resp_data;
                            2'd1: n0_pix <= (p_y_q1 > 6'd0) ? pre_sao_row_buf[p_x_q1] : n0_resp_data;
                            2'd2: n0_pix <= (p_x_q1 > 6'd0 && p_y_q1 > 6'd0) ? prev_row_left_d : n0_resp_data;
                            2'd3: n0_pix <= (p_y_q1 > 6'd0 && p_x_q1 < max_dim) ? pre_sao_row_buf[p_x_q1 + 6'd1] : n0_resp_data;
                        endcase
                    end
                    state <= S_APPLY;
                end

                S_APPLY: begin
                    if (cur_sao_type == 2'd1) begin
                        eo_in_valid <= 1'b1;
                        n1_pix      <= n1_resp_data;
                    end
                    if (cur_sao_type == 2'd2) bo_in_valid <= 1'b1;
                    state <= S_FILTER;
                end

                S_FILTER: begin
                    eo_in_valid <= 1'b0;
                    bo_in_valid <= 1'b0;
                    state       <= S_WRITE;
                end

                S_WRITE: begin
                    eo_in_valid  <= 1'b0;
                    bo_in_valid  <= 1'b0;
                    pix_wr_valid <= 1'b1;
                    pix_wr_x     <= p_x_q1;
                    pix_wr_y     <= p_y_q1;
                    pix_wr_comp  <= p_comp_q1;

                    if (cur_sao_type == 2'd1) pix_wr_data <= eo_pixel_out;
                    else if (cur_sao_type == 2'd2) pix_wr_data <= bo_pixel_out;
                    else pix_wr_data <= (SINGLE_PORT_BRAM_MODE == 1) ? c_pix : pix_resp_data;

                    // Advance coordinates
                    if (scan_x == max_dim) begin
                        scan_x <= 6'd0;
                        if (scan_y == max_dim) begin
                            scan_y <= 6'd0;
                            if (comp_idx == 2'd2) begin
                                state    <= S_DONE;
                                ctu_done <= 1'b1;
                            end else begin
                                comp_idx <= comp_idx + 2'd1;
                                state    <= S_REQ_PIX;
                            end
                        end else begin
                            scan_y <= scan_y + 6'd1;
                            state  <= S_REQ_PIX;
                        end
                    end else begin
                        scan_x <= scan_x + 6'd1;
                        state  <= S_REQ_PIX;
                    end
                end

                S_DONE: begin
                    pix_wr_valid <= 1'b0;
                    ctu_done     <= 1'b0;
                    state        <= S_IDLE;
                end
            endcase
        end
    end

endmodule