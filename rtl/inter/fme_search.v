`timescale 1ns/1ps
`include "parameter_pkg.vh"

module fme_search #(
    parameter PIXEL_WIDTH  = `PIXEL_WIDTH,
    parameter CU_COORD_W   = 6,
    parameter MV_W         = `MV_TOTAL_BITS - `MV_FRAC_BITS, // 10
    parameter BEST_SAD_W   = 12,
    parameter MV_TOTAL_BITS= `MV_TOTAL_BITS // 12
)(
    input  wire clk,
    input  wire rst_n,
    
    // Control
    input  wire                         fme_start,
    output reg                          fme_done,
    
    // CU info
    input  wire [CU_COORD_W-1:0]        cu_x,
    input  wire [CU_COORD_W-1:0]        cu_y,
    input  wire [PIXEL_WIDTH*16-1:0]    cu_orig_flat,
    
    // From TZ Search (Integer precision)
    input  wire signed [MV_W-1:0]       tz_best_mv_x,
    input  wire signed [MV_W-1:0]       tz_best_mv_y,
    input  wire [BEST_SAD_W-1:0]        tz_best_sad,
    
    // To/From ref_frame_buffer (Fetching 12x12 window)
    output reg                          ref_req_valid,
    output reg  signed [11:0]           ref_req_x,
    output reg  signed [11:0]           ref_req_y,
    input  wire                         ref_req_ready,
    input  wire                         ref_resp_valid,
    input  wire [PIXEL_WIDTH*144-1:0]   ref_resp_y_flat, // 12x12
    
    // Output Quarter-Pel MV
    output reg  signed [MV_TOTAL_BITS-1:0] fme_mv_x,
    output reg  signed [MV_TOTAL_BITS-1:0] fme_mv_y,
    output reg  [BEST_SAD_W-1:0]           fme_sad
);

    // =========================================================================
    // FSM States
    // =========================================================================
    localparam [3:0]
        S_IDLE      = 4'd0,
        S_REQ       = 4'd1,
        S_WAIT_REF  = 4'd2,
        S_HPEL_FEED = 4'd3,
        S_HPEL_WAIT = 4'd4,
        S_QPEL_FEED = 4'd5,
        S_QPEL_WAIT = 4'd6,
        S_DONE      = 4'd7;
        
    reg [3:0] state;
    
    // Data storage
    reg [PIXEL_WIDTH*144-1:0] ref_12x12;
    reg signed [MV_W-1:0]     base_mv_x;
    reg signed [MV_W-1:0]     base_mv_y;
    reg [BEST_SAD_W-1:0]      best_sad;
    reg                       is_qpel;
    reg signed [MV_TOTAL_BITS-1:0] cur_best_mv_x;
    reg signed [MV_TOTAL_BITS-1:0] cur_best_mv_y;

    // Counters
    reg [3:0] pt_cnt;
    reg [3:0] sad_cnt;
    
    // =========================================================================
    // Dynamic Filter Coordinate Generator
    // =========================================================================
    // Let's generate the absolute target:
    wire signed [MV_TOTAL_BITS-1:0] target_mv_x = cur_best_mv_x + (is_qpel ? (
        (pt_cnt==0 || pt_cnt==1 || pt_cnt==2) ? 12'sd1 :
        (pt_cnt==3 || pt_cnt==5 || pt_cnt==7) ? -12'sd1 : 12'sd0
    ) : (
        (pt_cnt==0 || pt_cnt==1 || pt_cnt==2) ? 12'sd2 :
        (pt_cnt==3 || pt_cnt==5 || pt_cnt==7) ? -12'sd2 : 12'sd0
    ));
    
    wire signed [MV_TOTAL_BITS-1:0] target_mv_y = cur_best_mv_y + (is_qpel ? (
        (pt_cnt==1 || pt_cnt==2 || pt_cnt==5) ? 12'sd1 :
        (pt_cnt==4 || pt_cnt==6 || pt_cnt==7) ? -12'sd1 : 12'sd0
    ) : (
        (pt_cnt==1 || pt_cnt==2 || pt_cnt==5) ? 12'sd2 :
        (pt_cnt==4 || pt_cnt==6 || pt_cnt==7) ? -12'sd2 : 12'sd0
    ));
    
    // fractional part
    wire [1:0] t_frac_x = target_mv_x[1:0];
    wire [1:0] t_frac_y = target_mv_y[1:0];
    
    // Integer offset relative to the fetched `ref_12x12` base.
    wire signed [MV_W-1:0] t_int_x = target_mv_x >>> 2;
    wire signed [MV_W-1:0] t_int_y = target_mv_y >>> 2;
    
    wire signed [2:0] w_off_x = t_int_x - (base_mv_x - 1);
    wire signed [2:0] w_off_y = t_int_y - (base_mv_y - 1);
    
    // Filter selection
    wire [1:0] t_sel = (t_frac_x != 0 && t_frac_y != 0) ? 2'd2 :
                       (t_frac_x == 0 && t_frac_y != 0) ? 2'd1 : 2'd0; // H=0, V=1, HV=2
    
    // =========================================================================
    // Window Multiplexer (Extract 11x11 from 12x12)
    // =========================================================================
    reg [PIXEL_WIDTH*121-1:0] ext_11x11;
    integer r, c;
    always @(*) begin
        for (r = 0; r < 11; r = r + 1) begin
            for (c = 0; c < 11; c = c + 1) begin
                ext_11x11[PIXEL_WIDTH*(r*11 + c) +: PIXEL_WIDTH] = 
                    ref_12x12[PIXEL_WIDTH*((r + w_off_y)*12 + (c + w_off_x)) +: PIXEL_WIDTH];
            end
        end
    end
    
    // =========================================================================
    // Interpolation Filter
    // =========================================================================
    wire filter_valid_out;
    wire [PIXEL_WIDTH*16-1:0] h_out, v_out, hv_out;
    
    hpel_filter_luma u_filter (
        .clk         (clk),
        .rst_n       (rst_n),
        .valid_in    (state == S_HPEL_FEED || state == S_QPEL_FEED),
        .frac_x      (t_frac_x),
        .frac_y      (t_frac_y),
        .ref_ext_flat(ext_11x11),
        
        .valid_out   (filter_valid_out),
        .h_out_flat  (h_out),
        .v_out_flat  (v_out),
        .hv_out_flat (hv_out)
    );
    
    // Select filter output
    reg [PIXEL_WIDTH*16-1:0] filter_selected;
    
    reg [1:0] sel_delay [0:2];
    reg signed [MV_TOTAL_BITS-1:0] target_mv_x_delay [0:6];
    reg signed [MV_TOTAL_BITS-1:0] target_mv_y_delay [0:6];
    
    integer i;
    always @(posedge clk) begin
        sel_delay[0] <= t_sel;
        sel_delay[1] <= sel_delay[0];
        sel_delay[2] <= sel_delay[1];
        
        target_mv_x_delay[0] <= target_mv_x;
        target_mv_y_delay[0] <= target_mv_y;
        for (i=1; i<7; i=i+1) begin
            target_mv_x_delay[i] <= target_mv_x_delay[i-1];
            target_mv_y_delay[i] <= target_mv_y_delay[i-1];
        end
    end
    
    always @(*) begin
        if (sel_delay[2] == 2'd2) filter_selected = hv_out;
        else if (sel_delay[2] == 2'd1) filter_selected = v_out;
        else filter_selected = h_out;
    end
    
    // =========================================================================
    // SAD Calculation
    // =========================================================================
    wire sad_valid_out;
    wire [BEST_SAD_W-1:0] sad_val;
    
    sad_4x4 #(
        .PIXEL_WIDTH(PIXEL_WIDTH)
    ) u_sad (
        .clk        (clk),
        .rst_n      (rst_n),
        .valid_in   (filter_valid_out),
        .orig_flat  (cu_orig_flat),
        .ref_flat   (filter_selected),
        
        .valid_out  (sad_valid_out),
        .sad_out    (sad_val)
    );
    
    // =========================================================================
    // FSM Logic
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            fme_done <= 0;
            ref_req_valid <= 0;
            pt_cnt <= 0;
            sad_cnt <= 0;
            is_qpel <= 0;
            best_sad <= 0;
            cur_best_mv_x <= 0;
            cur_best_mv_y <= 0;
            fme_mv_x <= 0;
            fme_mv_y <= 0;
            fme_sad <= 0;
        end else begin
            fme_done <= 0;
            
            // Process SAD responses concurrently with FSM
            if (sad_valid_out) begin
                sad_cnt <= sad_cnt + 1;
                if (sad_val < best_sad) begin
                    best_sad <= sad_val;
                    cur_best_mv_x <= target_mv_x_delay[5];
                    cur_best_mv_y <= target_mv_y_delay[5];
                end
            end
            
            case (state)
                S_IDLE: begin
                    if (fme_start) begin
                        base_mv_x <= tz_best_mv_x;
                        base_mv_y <= tz_best_mv_y;
                        cur_best_mv_x <= {tz_best_mv_x, 2'b00};
                        cur_best_mv_y <= {tz_best_mv_y, 2'b00};
                        best_sad <= tz_best_sad;
                        
                        if (tz_best_sad == {BEST_SAD_W{1'b0}}) begin
                            fme_mv_x <= {tz_best_mv_x, 2'b00};
                            fme_mv_y <= {tz_best_mv_y, 2'b00};
                            fme_sad  <= 0;
                            fme_done <= 1'b1;
                            state    <= S_IDLE;
                        end else begin
                            ref_req_x <= $signed({1'b0, cu_x}) + tz_best_mv_x - 12'sd4;
                            ref_req_y <= $signed({1'b0, cu_y}) + tz_best_mv_y - 12'sd4;
                            ref_req_valid <= 1;
                            state <= S_REQ;
                        end
                    end
                end
                
                S_REQ: begin
                    if (ref_req_valid && ref_req_ready) begin
                        ref_req_valid <= 0;
                        state <= S_WAIT_REF;
                    end
                end
                
                S_WAIT_REF: begin
                    if (ref_resp_valid) begin
                        ref_12x12 <= ref_resp_y_flat;
                        pt_cnt <= 0;
                        sad_cnt <= 0;
                        is_qpel <= 0;
                        state <= S_HPEL_FEED;
                    end
                end
                
                S_HPEL_FEED, S_QPEL_FEED: begin
                    if (pt_cnt < 7) begin
                        pt_cnt <= pt_cnt + 1;
                    end else begin
                        state <= (state == S_HPEL_FEED) ? S_HPEL_WAIT : S_QPEL_WAIT;
                    end
                end
                
                S_HPEL_WAIT, S_QPEL_WAIT: begin
                    if (sad_valid_out && sad_cnt == 7) begin
                        if (state == S_HPEL_WAIT) begin
                            is_qpel <= 1;
                            pt_cnt <= 0;
                            sad_cnt <= 0;
                            state <= S_QPEL_FEED;
                        end else begin
                            fme_mv_x <= (sad_val < best_sad) ? target_mv_x_delay[5] : cur_best_mv_x;
                            fme_mv_y <= (sad_val < best_sad) ? target_mv_y_delay[5] : cur_best_mv_y;
                            fme_sad  <= (sad_val < best_sad) ? sad_val : best_sad;
                            fme_done <= 1;
                            state <= S_IDLE;
                        end
                    end
                end
            endcase
        end
    end

endmodule
