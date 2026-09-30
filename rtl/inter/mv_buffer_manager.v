//=============================================================================
// mv_buffer_manager.v
// BRAM Cache and AXI Flush Controller for Collocated Motion Vectors (TMVP Phase 1)
//=============================================================================

`include "parameter_pkg.vh"

module mv_buffer_manager #(
    parameter MV_W = `MV_TOTAL_BITS,
    parameter AXI_DW = 256
)(
    input  wire        clk,
    input  wire        rst_n,

    // Interface from Mode Decision
    input  wire        cu_valid,
    input  wire [5:0]  cu_x,
    input  wire [5:0]  cu_y,
    input  wire [6:0]  cu_size,
    input  wire        is_intra,
    input  wire [11:0] inter_mv_x, // 12-bit quarter pel
    input  wire [11:0] inter_mv_y,
    input  wire [2:0]  ref_idx_l0,
    input  wire [2:0]  ref_idx_l1,
    
    // Interface from CTU Top Level
    input  wire        ctu_done,
    input  wire [15:0] ctu_addr,
    input  wire [2:0]  target_slot,
    input  wire [32:0] base_mv_addr, // The absolute AXI address for this slot's MV buffer
    
    // AXI Write Interface
    output reg         flush_req,
    input  wire        flush_grant,
    output reg         axi_awvalid,
    input  wire        axi_awready,
    output reg  [32:0] axi_awaddr,
    output reg  [7:0]  axi_awlen,
    output reg         axi_wvalid,
    input  wire        axi_wready,
    output reg  [AXI_DW-1:0] axi_wdata,
    output reg         axi_wlast,
    input  wire        axi_bvalid,
    
    // Interface for Collocated MV Prefetch
    input  wire        ctu_start,
    input  wire [32:0] col_base_mv_addr, // AXI address for collocated slot's MV buffer
    output reg         col_prefetch_done,
    input  wire [3:0]  col_lookup_idx,   // 0 to 15 (based on PU coordinates)
    output wire [63:0] col_lookup_data,
    
    // AXI Read Interface
    output reg         prefetch_req,
    input  wire        prefetch_grant,
    output reg         axi_arvalid,
    input  wire        axi_arready,
    output reg  [32:0] axi_araddr,
    output reg  [7:0]  axi_arlen,
    input  wire        axi_rvalid,
    output reg         axi_rready,
    input  wire [AXI_DW-1:0] axi_rdata,
    input  wire        axi_rlast
);

    // CTU is 64x64, meaning 16 blocks of 16x16.
    // 16 entries * 64 bits = 1024 bits.
    reg [63:0] ctu_mv_cache [0:15];
    
    wire signed [MV_W-1:0] mvx = inter_mv_x; // Full quarter-pel precision
    wire signed [MV_W-1:0] mvy = inter_mv_y;
    
    wire [63:0] pack_mv = { 
        7'd0,  // padding (64 - 1 - 4 - 12 - 12 - 4 - 12 - 12 = 7)
        1'b1,  // is_inter = !is_intra
        {1'b0, ref_idx_l1},
        mvy,
        mvx,
        {1'b0, ref_idx_l0},
        mvy,
        mvx
    };
    
    integer i, j;
    reg [6:0] blocks_w;
    reg [2:0] sx, sy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i=0; i<16; i=i+1) ctu_mv_cache[i] <= 64'd0;
        end else if (cu_valid && !is_intra) begin
            // Replicate the MV across all 16x16 blocks covered by this CU
            // CU size can be 8, 16, 32, 64
            // Number of 16x16 blocks is (cu_size/16)^2, minimum 1
            blocks_w = (cu_size >= 16) ? (cu_size >> 4) : 1;
            sx = cu_x[5:4];
            sy = cu_y[5:4];
            
            for (j = 0; j < 4; j = j + 1) begin
                for (i = 0; i < 4; i = i + 1) begin
                    if (i < blocks_w && j < blocks_w) begin
                        ctu_mv_cache[ ((sy + j)<<2) + (sx + i) ] <= pack_mv;
                    end
                end
            end
        end else if (cu_valid && is_intra) begin
            blocks_w = (cu_size >= 16) ? (cu_size >> 4) : 1;
            sx = cu_x[5:4];
            sy = cu_y[5:4];
            for (j = 0; j < 4; j = j + 1) begin
                for (i = 0; i < 4; i = i + 1) begin
                    if (i < blocks_w && j < blocks_w) begin
                        ctu_mv_cache[ ((sy + j)<<2) + (sx + i) ] <= 64'd0; // Clear for intra
                    end
                end
            end
        end
    end

    // FSM for AXI Flush
    localparam S_IDLE  = 3'd0;
    localparam S_REQ   = 3'd1;
    localparam S_AW    = 3'd2;
    localparam S_BURST = 3'd3;
    localparam S_WAIT_B= 3'd4;
    
    reg [2:0] state, next_state;
    reg [2:0] beat_cnt; // 0 to 3 (since 4 beats of 256-bit cover 1024 bits)
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_IDLE;
        else        state <= next_state;
    end
    
    always @(*) begin
        next_state = state;
        case (state)
            S_IDLE: begin
                if (ctu_done) next_state = S_REQ;
            end
            S_REQ: begin
                if (flush_grant) next_state = S_AW;
            end
            S_AW: begin
                if (axi_awready) next_state = S_BURST;
            end
            S_BURST: begin
                if (axi_wready && axi_wlast) next_state = S_WAIT_B;
            end
            S_WAIT_B: begin
                if (axi_bvalid) next_state = S_IDLE;
            end
        endcase
    end
    
    // Address calculation based on CTU index
    // 1 CTU = 128 bytes
    wire [32:0] ctu_offset = {16'd0, ctu_addr, 7'd0}; 
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            flush_req  <= 1'b0;
            axi_awvalid<= 1'b0;
            axi_awaddr <= 33'd0;
            axi_awlen  <= 8'd0;
            axi_wvalid <= 1'b0;
            axi_wlast  <= 1'b0;
            axi_wdata  <= {AXI_DW{1'b0}};
            beat_cnt   <= 3'd0;
        end else begin
            flush_req  <= 1'b0;
            axi_awvalid<= 1'b0;
            axi_wvalid <= 1'b0;
            axi_wlast  <= 1'b0;
            
            case (state)
                S_IDLE: begin
                    if (ctu_done) begin
                        flush_req  <= 1'b1;
                        axi_awaddr <= base_mv_addr + ctu_offset;
                        axi_awlen  <= 8'd3; // 4 beats
                        beat_cnt   <= 3'd0;
                    end
                end
                S_REQ: begin
                    flush_req <= 1'b1;
                    if (flush_grant) begin
                        flush_req <= 1'b0;
                        axi_awvalid <= 1'b1;
                    end
                end
                S_AW: begin
                    axi_awvalid <= 1'b1;
                    if (axi_awready) begin
                        axi_awvalid <= 1'b0;
                        axi_wvalid <= 1'b1;
                        axi_wdata <= {ctu_mv_cache[{beat_cnt, 2'b11}], 
                                      ctu_mv_cache[{beat_cnt, 2'b10}], 
                                      ctu_mv_cache[{beat_cnt, 2'b01}], 
                                      ctu_mv_cache[{beat_cnt, 2'b00}]};
                        if (beat_cnt == 3'd3) axi_wlast <= 1'b1;
                    end
                end
                S_BURST: begin
                    axi_wvalid <= 1'b1;
                    if (axi_wready) begin
                        if (beat_cnt < 3'd3) begin
                            beat_cnt <= beat_cnt + 3'd1;
                            axi_wdata <= {ctu_mv_cache[{beat_cnt + 3'd1, 2'b11}], 
                                          ctu_mv_cache[{beat_cnt + 3'd1, 2'b10}], 
                                          ctu_mv_cache[{beat_cnt + 3'd1, 2'b01}], 
                                          ctu_mv_cache[{beat_cnt + 3'd1, 2'b00}]};
                        end
                        if (beat_cnt == 3'd2) axi_wlast <= 1'b1;
                        if (beat_cnt == 3'd3) begin
                            axi_wvalid <= 1'b0;
                            axi_wlast <= 1'b0;
                        end
                    end else begin
                        // Hold data
                        if (beat_cnt == 3'd3) axi_wlast <= 1'b1;
                    end
                end
                S_WAIT_B: begin
                    // Wait for BVALID
                end
            endcase
        end
    end

    //=========================================================================
    // AXI Read Prefetch FSM
    //=========================================================================
    reg [63:0] col_mv_cache [0:15];
    assign col_lookup_data = col_mv_cache[col_lookup_idx];

    localparam R_IDLE  = 3'd0;
    localparam R_REQ   = 3'd1;
    localparam R_AR    = 3'd2;
    localparam R_BURST = 3'd3;

    reg [2:0] r_state, r_next_state;
    reg [2:0] r_beat_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) r_state <= R_IDLE;
        else        r_state <= r_next_state;
    end

    always @(*) begin
        r_next_state = r_state;
        case (r_state)
            R_IDLE: begin
                if (ctu_start) r_next_state = R_REQ;
            end
            R_REQ: begin
                if (prefetch_grant) begin
                    r_next_state = R_AR;
                    $display("Time=%0t: [mv_buffer_manager] prefetch_grant received. Moving to R_AR.", $time);
                end
            end
            R_AR: begin
                if (axi_arready) begin
                    r_next_state = R_BURST;
                    $display("Time=%0t: [mv_buffer_manager] axi_arready received. Moving to R_BURST.", $time);
                end
            end
            R_BURST: begin
                if (axi_rvalid && axi_rlast) r_next_state = R_IDLE;
            end
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prefetch_req <= 1'b0;
            axi_arvalid  <= 1'b0;
            axi_araddr   <= 33'd0;
            axi_arlen    <= 8'd0;
            axi_rready   <= 1'b0;
            col_prefetch_done <= 1'b1;
            r_beat_cnt   <= 3'd0;
        end else begin
            prefetch_req <= 1'b0;
            axi_arvalid  <= 1'b0;
            axi_rready   <= 1'b0;
            col_prefetch_done <= 1'b0;

            case (r_state)
                R_IDLE: begin
                    if (ctu_start) begin
                        prefetch_req <= 1'b1;
                        axi_araddr   <= col_base_mv_addr + ctu_offset;
                        axi_arlen    <= 8'd3; // 4 beats
                        r_beat_cnt   <= 3'd0;
                    end else begin
                        col_prefetch_done <= 1'b1;
                    end
                end
                R_REQ: begin
                    prefetch_req <= 1'b1;
                    if (prefetch_grant) begin
                        prefetch_req <= 1'b0;
                        axi_arvalid  <= 1'b1;
                    end
                end
                R_AR: begin
                    axi_arvalid <= 1'b1;
                    if (axi_arready) begin
                        axi_arvalid <= 1'b0;
                        axi_rready  <= 1'b1;
                    end
                end
                R_BURST: begin
                    axi_rready <= 1'b1;
                    if (axi_rvalid) begin
                        col_mv_cache[{r_beat_cnt, 2'b00}] <= axi_rdata[63:0];
                        col_mv_cache[{r_beat_cnt, 2'b01}] <= axi_rdata[127:64];
                        col_mv_cache[{r_beat_cnt, 2'b10}] <= axi_rdata[191:128];
                        col_mv_cache[{r_beat_cnt, 2'b11}] <= axi_rdata[255:192];
                        r_beat_cnt <= r_beat_cnt + 3'd1;
                        if (axi_rlast) begin
                            axi_rready <= 1'b0;
                        end
                    end
                end
            endcase
        end
    end

endmodule
