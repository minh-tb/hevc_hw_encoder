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

module sao_top (
    input  wire         clk,
    input  wire         rst_n,

    // CTU control
    input  wire         ctu_valid,
    output wire         ctu_ready,
    input  wire [9:0]   ctu_x,
    input  wire [9:0]   ctu_y,

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
        S_WAIT_PIX = 3'd2,
        S_APPLY    = 3'd3,
        S_WRITE    = 3'd4,
        S_DONE     = 3'd5;

    reg [2:0] state;

    assign ctu_ready      = (state == S_IDLE);
    assign pix_resp_ready = 1'b1;
    assign n0_resp_ready  = 1'b1;
    assign n1_resp_ready  = 1'b1;

    // Component and coordinate counters
    reg [1:0] comp_idx;      // 0=Y, 1=Cb, 2=Cr
    reg [5:0] scan_x, scan_y;
    wire [5:0] max_dim = (comp_idx == 2'd0) ? 6'd63 : 6'd31;

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

    // Sub-module instances
    reg         eo_in_valid;
    wire        eo_in_ready, eo_out_valid;
    wire [`PIXEL_WIDTH-1:0] eo_pixel_out;

    sao_edge_offset u_sao_eo (
        .clk        (clk),
        .rst_n      (rst_n),
        .edge_type  (cur_eo_class),
        .offset     (cur_eo_offset),
        .in_valid   (eo_in_valid),
        .in_ready   (eo_in_ready),
        .pixel_in   (pix_resp_data),
        .neigh0     (n0_resp_data),
        .neigh1     (n1_resp_data),
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
        .pixel_in   (pix_resp_data),
        .in_last    (1'b0),
        .out_valid  (bo_out_valid),
        .out_ready  (1'b1),
        .pixel_out  (bo_pixel_out),
        .out_last   ()
    );

    // Pipeline coordinate shift registers
    reg [5:0] p_x_q1, p_y_q1, p_x_q2, p_y_q2;
    reg [1:0] p_comp_q1, p_comp_q2;

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
                    end else begin
                        // Issue read for current pixel and neighbours
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

                S_WAIT_PIX: begin
                    pix_rd_valid <= 1'b0;
                    n0_rd_valid  <= 1'b0;
                    n1_rd_valid  <= 1'b0;

                    // Feed sub-modules when SRAM read returns
                    if (cur_sao_type == 2'd1) eo_in_valid <= 1'b1;
                    if (cur_sao_type == 2'd2) bo_in_valid <= 1'b1;

                    p_x_q2    <= p_x_q1;
                    p_y_q2    <= p_y_q1;
                    p_comp_q2 <= p_comp_q1;
                    state     <= S_APPLY;
                end

                S_APPLY: begin
                    eo_in_valid <= 1'b0;
                    bo_in_valid <= 1'b0;
                    state       <= S_WRITE;
                end

                S_WRITE: begin
                    // Write back filtered sample
                    pix_wr_valid <= 1'b1;
                    pix_wr_x     <= p_x_q2;
                    pix_wr_y     <= p_y_q2;
                    pix_wr_comp  <= p_comp_q2;

                    if (cur_sao_type == 2'd1) pix_wr_data <= eo_pixel_out;
                    else if (cur_sao_type == 2'd2) pix_wr_data <= bo_pixel_out;
                    else pix_wr_data <= pix_resp_data;

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