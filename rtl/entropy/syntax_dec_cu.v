`timescale 1ns / 1ps
//=============================================================================
// syntax_dec_cu.v
// CU-Level CABAC Syntax Element Decoder
//
// Inverts the operations of syntax_cu.v.
// Requests bins from bin_decoder.v and reconstructs CU syntax flags.
//=============================================================================

`include "parameter_pkg.vh"

module syntax_dec_cu #(
    parameter CTX_ID_W = 8
)(
    input  wire        clk,
    input  wire        rst_n,

    // ── CU decoding request ───────────────────────────────────────────────
    input  wire        cu_req,         // start decoding this CU
    output reg         cu_done,        // all CU bins received
    
    // ── Input context parameters ──────────────────────────────────────────
    input  wire [1:0]  cu_depth,       // quad-tree depth 0..3
    input  wire        slice_is_intra, // 1 = I-slice
    input  wire [1:0]  cu_skip_ctx,    // neighbor context for skip_flag

    // ── Decoded CU parameters (valid when cu_done=1) ──────────────────────
    output reg         cu_is_split,
    output reg         cu_skip,
    output reg         cu_merge,
    output reg [2:0]   cu_merge_idx,
    output reg         cu_pred_intra,
    output reg [1:0]   cu_part_mode,
    output reg         cu_cbf,

    // ── Bin request → bin_decoder ─────────────────────────────────────────
    output reg                  dec_req,
    output reg [CTX_ID_W-1:0]   dec_ctx_id,
    output reg                  is_ep,
    input  wire                 dec_ready,
    input  wire                 dec_valid,
    input  wire                 dec_bin
);

    // =========================================================================
    // FSM state encoding
    // =========================================================================
    localparam [4:0]
        S_IDLE        = 5'd0,
        S_SPLIT       = 5'd1,   // decode split_cu_flag
        S_SKIP        = 5'd2,   // decode cu_skip_flag
        S_MERGE_FLAG  = 5'd3,   // decode merge_flag
        S_MERGE_IDX0  = 5'd4,   // decode merge_idx first bin
        S_MERGE_IDX1  = 5'd5,   // decode merge_idx[1]
        S_MERGE_IDX2  = 5'd6,   // decode merge_idx[2]
        S_MERGE_IDX3  = 5'd7,   // decode merge_idx[3]
        S_PRED_MODE   = 5'd8,   // decode pred_mode_flag
        S_PART0       = 5'd9,   // decode part_mode bin 0
        S_PART1       = 5'd10,  // decode part_mode bin 1
        S_PART2       = 5'd11,  // decode part_mode bin 2
        S_CBF         = 5'd12,  // decode rqt_root_cbf
        S_DONE        = 5'd13;

    reg [4:0] state;

    // =========================================================================
    // Context ID constants
    // =========================================================================
    localparam CTX_SPLIT_0  = 8'd0;
    localparam CTX_SKIP_0   = 8'd4;
    localparam CTX_MERGE    = 8'd7;
    localparam CTX_MERGE_IDX= 8'd8;
    localparam CTX_PRED     = 8'd9;
    localparam CTX_PART_0   = 8'd10;
    localparam CTX_PART_1   = 8'd11;
    localparam CTX_PART_2   = 8'd12;
    localparam CTX_CBF      = 8'd14;

    wire [CTX_ID_W-1:0] skip_ctx_id = CTX_SKIP_0 + {6'd0, cu_skip_ctx};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            dec_req       <= 1'b0;
            cu_done       <= 1'b0;
            cu_is_split   <= 1'b0;
            cu_skip       <= 1'b0;
            cu_merge      <= 1'b0;
            cu_merge_idx  <= 3'd0;
            cu_pred_intra <= 1'b0;
            cu_part_mode  <= 2'd0;
            cu_cbf        <= 1'b0;
            dec_ctx_id    <= 8'd0;
            is_ep         <= 1'b0;
        end else begin
            cu_done <= 1'b0;

            case (state)
            S_IDLE: begin
                if (cu_req) begin
                    state <= S_SPLIT;
                    dec_req <= 1'b1;
                    dec_ctx_id <= CTX_SPLIT_0 + {6'd0, cu_depth[1:0]};
                    is_ep <= 1'b0;
                    
                    // Reset fields
                    cu_is_split <= 1'b0; cu_skip <= 1'b0; cu_merge <= 1'b0;
                    cu_merge_idx <= 3'd0; cu_pred_intra <= 1'b0; 
                    cu_part_mode <= 2'd0; cu_cbf <= 1'b0;
                end
            end

            S_SPLIT: begin
                if (dec_valid) begin
                    cu_is_split <= dec_bin;
                    if (dec_bin) begin
                        state <= S_DONE;
                        dec_req <= 1'b0;
                    end else if (slice_is_intra) begin
                        cu_pred_intra <= 1'b1; // Forced intra for I-slice
                        if (cu_depth == 2'd3) begin
                            state <= S_PART0;
                            dec_ctx_id <= CTX_PART_0;
                        end else begin
                            cu_part_mode <= 2'd0; // 2Nx2N
                            cu_cbf <= 1'b1;
                            state <= S_DONE;
                            dec_req <= 1'b0;
                        end
                    end else begin
                        state <= S_SKIP;
                        dec_ctx_id <= skip_ctx_id;
                    end
                end else if (dec_ready) begin
                    dec_req <= 1'b1;
                end
            end

            S_SKIP: begin
                if (dec_valid) begin
                    cu_skip <= dec_bin;
                    if (dec_bin) begin
                        cu_merge <= 1'b1;
                        cu_pred_intra <= 1'b0;
                        cu_part_mode <= 2'd0; // skip is 2Nx2N
                        cu_cbf <= 1'b0;       // skip has no residual
                        state <= S_MERGE_IDX0;
                        dec_ctx_id <= CTX_MERGE_IDX;
                    end else begin
                        state <= S_MERGE_FLAG;
                        dec_ctx_id <= CTX_MERGE;
                    end
                end
            end

            S_MERGE_FLAG: begin
                if (dec_valid) begin
                    cu_merge <= dec_bin;
                    cu_pred_intra <= 1'b0;
                    if (dec_bin) begin
                        cu_part_mode <= 2'd0;
                        state <= S_MERGE_IDX0;
                        dec_ctx_id <= CTX_MERGE_IDX;
                    end else begin
                        state <= S_PRED_MODE;
                        dec_ctx_id <= CTX_PRED;
                    end
                end
            end

            S_MERGE_IDX0: begin
                if (dec_valid) begin
                    if (dec_bin == 1'b0) begin
                        cu_merge_idx <= 3'd0;
                        state <= cu_skip ? S_DONE : S_CBF;
                        if (cu_skip) dec_req <= 1'b0;
                        else begin dec_ctx_id <= CTX_CBF; is_ep <= 1'b0; end
                    end else begin
                        cu_merge_idx <= 3'd1;
                        state <= S_MERGE_IDX1;
                        is_ep <= 1'b1;
                    end
                end
            end

            S_MERGE_IDX1: begin
                if (dec_valid) begin
                    if (dec_bin == 1'b0) begin
                        state <= cu_skip ? S_DONE : S_CBF;
                        if (cu_skip) dec_req <= 1'b0;
                        else begin dec_ctx_id <= CTX_CBF; is_ep <= 1'b0; end
                    end else begin
                        cu_merge_idx <= 3'd2;
                        state <= S_MERGE_IDX2;
                    end
                end
            end

            S_MERGE_IDX2: begin
                if (dec_valid) begin
                    if (dec_bin == 1'b0) begin
                        state <= cu_skip ? S_DONE : S_CBF;
                        if (cu_skip) dec_req <= 1'b0;
                        else begin dec_ctx_id <= CTX_CBF; is_ep <= 1'b0; end
                    end else begin
                        cu_merge_idx <= 3'd3;
                        state <= S_MERGE_IDX3;
                    end
                end
            end

            S_MERGE_IDX3: begin
                if (dec_valid) begin
                    if (dec_bin == 1'b1) cu_merge_idx <= 3'd4;
                    state <= cu_skip ? S_DONE : S_CBF;
                    if (cu_skip) dec_req <= 1'b0;
                    else begin dec_ctx_id <= CTX_CBF; is_ep <= 1'b0; end
                end
            end

            S_PRED_MODE: begin
                if (dec_valid) begin
                    cu_pred_intra <= dec_bin;
                    if (dec_bin) begin
                        if (cu_depth == 2'd3) begin
                            state <= S_PART0;
                            dec_ctx_id <= CTX_PART_0;
                        end else begin
                            cu_part_mode <= 2'd0;
                            cu_cbf <= 1'b1;
                            state <= S_DONE;
                            dec_req <= 1'b0;
                        end
                    end else begin
                        state <= S_PART0;
                        dec_ctx_id <= CTX_PART_0;
                    end
                end
            end

            S_PART0: begin
                if (dec_valid) begin
                    if (dec_bin) begin
                        cu_part_mode <= 2'd0;
                        if (cu_pred_intra) begin
                            cu_cbf <= 1'b1;
                            state <= S_DONE;
                            dec_req <= 1'b0;
                        end else begin
                            state <= S_CBF;
                            dec_ctx_id <= CTX_CBF;
                        end
                    end else begin
                        state <= S_PART1;
                        dec_ctx_id <= CTX_PART_1;
                    end
                end
            end

            S_PART1: begin
                if (dec_valid) begin
                    if (dec_bin) begin
                        cu_part_mode <= 2'd1;
                        state <= S_CBF;
                        dec_ctx_id <= CTX_CBF;
                    end else begin
                        state <= S_PART2;
                        dec_ctx_id <= CTX_PART_2;
                    end
                end
            end

            S_PART2: begin
                if (dec_valid) begin
                    cu_part_mode <= dec_bin ? 2'd2 : 2'd3;
                    state <= S_CBF;
                    dec_ctx_id <= CTX_CBF;
                end
            end

            S_CBF: begin
                if (dec_valid) begin
                    cu_cbf <= dec_bin;
                    state <= S_DONE;
                    dec_req <= 1'b0;
                end
            end

            S_DONE: begin
                cu_done <= 1'b1;
                state <= S_IDLE;
                dec_req <= 1'b0;
            end
            
            default: state <= S_IDLE;
            endcase

            // Deassert dec_req immediately when a bin is decoded to avoid double-requesting
            if (dec_valid) begin
                dec_req <= 1'b0;
            end else if (state != S_IDLE && state != S_DONE && !dec_req && dec_ready) begin
                dec_req <= 1'b1;
            end
        end
    end

endmodule
