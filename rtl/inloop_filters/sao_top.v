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
    input  wire [5:0]   sao_type,    // 0=none,1=EO,2=BO (packed 3 x 2-bit)
    input  wire [5:0]   eo_class,    // (packed 3 x 2-bit)
    input  wire [(3*5*`SAO_OFFSET_WIDTH)-1:0] eo_offset, // (packed 3 x 5 x 5-bit)
    input  wire [14:0]  band_pos,    // (packed 3 x 5-bit)
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

    localparam SAO_NONE = 2'd0, SAO_EO = 2'd1, SAO_BO = 2'd2;

    localparam S_IDLE    = 3'd0;
    localparam S_START   = 3'd1;
    localparam S_FETCH   = 3'd2;
    localparam S_FILT    = 3'd3;
    localparam S_WRITE   = 3'd4;
    localparam S_NCOMP   = 3'd5;
    localparam S_DONE    = 3'd6;

    reg [2:0] state;
    reg [1:0] cur_comp;
    reg [5:0] px, py;
    reg [9:0] cur_ctu_x, cur_ctu_y;

    wire [5:0] max_p;
    assign max_p = (cur_comp != 2'd0) ? 6'd31 : 6'd63;

    wire [1:0] cur_type;
    wire [1:0] cur_eocls;
    wire [4:0] cur_bandpos;
    wire [24:0] cur_eo_offset;
    wire [19:0] cur_bo_offset;
    
    assign cur_type      = (cur_comp == 2'd0) ? sao_type[1:0] : (cur_comp == 2'd1) ? sao_type[3:2] : sao_type[5:4];
    assign cur_eocls     = (cur_comp == 2'd0) ? eo_class[1:0] : (cur_comp == 2'd1) ? eo_class[3:2] : eo_class[5:4];
    assign cur_bandpos   = (cur_comp == 2'd0) ? band_pos[4:0] : (cur_comp == 2'd1) ? band_pos[9:5] : band_pos[14:10];
    assign cur_eo_offset = (cur_comp == 2'd0) ? eo_offset[24:0] : (cur_comp == 2'd1) ? eo_offset[49:25] : eo_offset[74:50];
    assign cur_bo_offset = (cur_comp == 2'd0) ? bo_offset[19:0] : (cur_comp == 2'd1) ? bo_offset[39:20] : bo_offset[59:40];

    // EO neighbour offsets
    wire signed [7:0] n0dx, n0dy, n1dx, n1dy;
    assign n0dx = (cur_eocls==0) ? -8'sd1 : (cur_eocls==1) ?  8'sd0 :
                              (cur_eocls==2) ? -8'sd1 :  8'sd1;
    assign n0dy = (cur_eocls==0) ?  8'sd0 : (cur_eocls==1) ? -8'sd1 :
                              (cur_eocls==2) ? -8'sd1 : -8'sd1;
    assign n1dx = (cur_eocls==0) ?  8'sd1 : (cur_eocls==1) ?  8'sd0 :
                              (cur_eocls==2) ?  8'sd1 : -8'sd1;
    assign n1dy = (cur_eocls==0) ?  8'sd0 : (cur_eocls==1) ?  8'sd1 :
                              (cur_eocls==2) ?  8'sd1 :  8'sd1;

    wire signed [7:0] n0x, n0y, n1x, n1y;
    assign n0x = $signed({2'b0, px}) + n0dx;
    assign n0y = $signed({2'b0, py}) + n0dy;
    assign n1x = $signed({2'b0, px}) + n1dx;
    assign n1y = $signed({2'b0, py}) + n1dy;

    reg [`PIXEL_WIDTH-1:0] cur_samp, cur_n0, cur_n1;
    reg samp_got, n0_got, n1_got;

    assign ctu_ready      = (state == S_IDLE);
    assign pix_resp_ready = (state == S_FETCH);
    assign n0_resp_ready  = (state == S_FETCH);
    assign n1_resp_ready  = (state == S_FETCH);

    // EO instance
    wire eo_in_rdy, eo_out_vld;
    reg eo_in_vld, eo_out_rdy;
    wire [`PIXEL_WIDTH-1:0] eo_res;

    sao_edge_offset u_eo (
        .clk(clk),.rst_n(rst_n),
        .edge_type(cur_eocls),.offset(cur_eo_offset),
        .in_valid(eo_in_vld),.in_ready(eo_in_rdy),
        .pixel_in(cur_samp),.neigh0(cur_n0),.neigh1(cur_n1),
        .in_last(1'b0),
        .out_valid(eo_out_vld),.out_ready(eo_out_rdy),.pixel_out(eo_res),.out_last()
    );

    // BO instance
    wire bo_in_rdy, bo_out_vld;
    reg bo_in_vld, bo_out_rdy;
    wire [`PIXEL_WIDTH-1:0] bo_res;

    sao_band_offset u_bo (
        .clk(clk),.rst_n(rst_n),
        .band_position(cur_bandpos),.offset(cur_bo_offset),
        .in_valid(bo_in_vld),.in_ready(bo_in_rdy),
        .pixel_in(cur_samp),
        .in_last(1'b0),
        .out_valid(bo_out_vld),.out_ready(bo_out_rdy),.pixel_out(bo_res),.out_last()
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=S_IDLE; cur_comp<=0; px<=0; py<=0;
            ctu_done<=0; eo_in_vld<=0; bo_in_vld<=0;
            eo_out_rdy<=1; bo_out_rdy<=1; // Init to 1
            pix_rd_valid<=0; n0_rd_valid<=0; n1_rd_valid<=0;
            pix_wr_valid<=0; samp_got<=0; n0_got<=0; n1_got<=0;
        end else begin
            ctu_done<=0; 
            case (state)
                S_IDLE: if (ctu_valid) begin
                    cur_ctu_x<=ctu_x; cur_ctu_y<=ctu_y;
                    cur_comp<=0; px<=0; py<=0; state<=S_START;
                end
                S_START: begin
                    px<=0; py<=0; samp_got<=0; n0_got<=0; n1_got<=0;
                    state <= (cur_type==SAO_NONE) ? S_NCOMP : S_FETCH;
                end
                S_FETCH: begin
                    if (!samp_got && pix_rd_ready) begin
                        pix_rd_valid<=1; pix_rd_x<=px; pix_rd_y<=py; pix_rd_comp<=cur_comp;
                    end
                    if (cur_type==SAO_EO) begin
                    if (!n0_got && n0_rd_ready) begin
                        n0_rd_valid<=1; n0_rd_x<=n0x; n0_rd_y<=n0y; n0_rd_comp<=cur_comp;
                        end
                    if (!n1_got && n1_rd_ready) begin
                        n1_rd_valid<=1; n1_rd_x<=n1x; n1_rd_y<=n1y; n1_rd_comp<=cur_comp;
                        end
                    end
                    if (pix_resp_valid) begin cur_samp<=pix_resp_data; samp_got<=1; pix_rd_valid<=0; end
                    if (n0_resp_valid)  begin cur_n0<=n0_resp_data;    n0_got<=1;   n0_rd_valid<=0; end
                    if (n1_resp_valid)  begin cur_n1<=n1_resp_data;    n1_got<=1;   n1_rd_valid<=0; end

                if (samp_got && (cur_type==SAO_BO || (cur_type==SAO_EO && n0_got && n1_got))) begin
                        samp_got<=0; n0_got<=0; n1_got<=0;
                        if (cur_type==SAO_EO) eo_in_vld<=1; else bo_in_vld<=1;
                        state<=S_FILT;
                    end
                end
                S_FILT: begin
                    if (cur_type==SAO_EO && eo_in_rdy) eo_in_vld<=0; // Hold until ready
                    if (cur_type==SAO_BO && bo_in_rdy) bo_in_vld<=0;

                    if ((cur_type==SAO_EO&&eo_out_vld)||(cur_type==SAO_BO&&bo_out_vld)) begin
                        eo_in_vld<=0; bo_in_vld<=0; // Safety clear
                        eo_out_rdy<=0; bo_out_rdy<=0; // Lower when data is consumed
                        pix_wr_valid<=1; pix_wr_x<=px; pix_wr_y<=py; pix_wr_comp<=cur_comp;
                        pix_wr_data<=(cur_type==SAO_EO)?eo_res:bo_res;
                        state<=S_WRITE;
                    end
                end
                S_WRITE: if (pix_wr_ready) begin
                    pix_wr_valid<=0;
                    eo_out_rdy<=1; bo_out_rdy<=1; // Raise again for the next pixel
                    if (px==max_p) begin
                        px<=0;
                        if (py==max_p) begin py<=0; state<=S_NCOMP; end
                        else begin py<=py+1; state<=S_FETCH; end
                    end else begin px<=px+1; state<=S_FETCH; end
                end
                S_NCOMP: begin
                    if (cur_comp==2'd2) state<=S_DONE;
                    else begin cur_comp<=cur_comp+2'd1; state<=S_START; end
                end
                S_DONE: begin ctu_done<=1; state<=S_IDLE; end
            endcase
        end
    end

    // synthesis translate_off
    always @(posedge clk)
        if (rst_n && ctu_done)
            $display("INFO [sao_top] CTU (%0d,%0d) done t=%0t", cur_ctu_x, cur_ctu_y, $time);
    // synthesis translate_on

endmodule