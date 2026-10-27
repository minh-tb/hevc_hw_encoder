//=============================================================================
// syntax_sao.v
// SAO CABAC Syntax Element Encoder (ITU-T H.265 Clause 7.3.8.3)
//=============================================================================

`include "parameter_pkg.vh"

module syntax_sao #(
    parameter CTX_ID_W = 8
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire [5:0]  ctu_x,       // CTU column index
    input  wire [5:0]  ctu_y,       // CTU row index

    input  wire        sao_req,
    output reg         sao_done,

    // SAO Parameters from sao_stats
    input  wire [5:0]  sao_type,    // [1:0]=Luma, [3:2]=Cb, [5:4]=Cr (0=OFF, 1=EO, 2=BO)
    input  wire [5:0]  eo_class,    // [1:0]=Luma, [3:2]=Cb, [5:4]=Cr
    input  wire [74:0] eo_offset,   // 3 comps * 5 cats * 5 bits (signed)
    input  wire [14:0] band_pos,    // 3 comps * 5 bits
    input  wire [59:0] bo_offset,   // 3 comps * 4 cats * 5 bits (signed)

    output reg                  bin_valid,
    output reg                  bin_value,
    output reg [CTX_ID_W-1:0]   bin_ctx_id,
    output reg                  bin_is_ep,
    input  wire                 bin_rdy
);

    localparam S_IDLE        = 4'd0;
    localparam S_MERGE_LEFT  = 4'd1;
    localparam S_MERGE_UP    = 4'd2;
    localparam S_TYPE        = 4'd3;
    localparam S_OFFSET_ABS  = 4'd4;
    localparam S_OFFSET_SIGN = 4'd5;
    localparam S_BAND_POS    = 4'd6;
    localparam S_EO_CLASS    = 4'd7;
    localparam S_DONE        = 4'd8;

    reg [3:0] state;
    reg [1:0] cur_comp; // 0=Luma, 1=Cb, 2=Cr
    reg [2:0] cur_cat;  // 0..3 (4 categories)

    // X/Z safe neighbor availability detection (handles unconnected ports in unit testbenches)
    wire has_left = (|ctu_x === 1'b1);
    wire has_up   = (|ctu_y === 1'b1);

    wire [1:0] cur_type = (cur_comp == 0) ? sao_type[1:0] :
                          (cur_comp == 1) ? sao_type[3:2] : sao_type[5:4];

    wire [1:0] cur_eo_class = (cur_comp == 0) ? eo_class[1:0] :
                              (cur_comp == 1) ? eo_class[3:2] : eo_class[5:4];

    wire [4:0] cur_band_pos = (cur_comp == 0) ? band_pos[4:0] :
                              (cur_comp == 1) ? band_pos[9:5] : band_pos[14:10];

    // Select the correct offset (signed)
    reg signed [4:0] sel_offset;
    always @(*) begin
        if (cur_type == 1) begin // EO
            if (cur_comp == 0) begin
                if (cur_cat == 0) sel_offset = eo_offset[4:0];
                else if (cur_cat == 1) sel_offset = eo_offset[9:5];
                else if (cur_cat == 2) sel_offset = eo_offset[19:15]; // cat3
                else sel_offset = eo_offset[24:20]; // cat4
            end else if (cur_comp == 1) begin
                if (cur_cat == 0) sel_offset = eo_offset[29:25];
                else if (cur_cat == 1) sel_offset = eo_offset[34:30];
                else if (cur_cat == 2) sel_offset = eo_offset[44:40];
                else sel_offset = eo_offset[49:45];
            end else begin
                if (cur_cat == 0) sel_offset = eo_offset[54:50];
                else if (cur_cat == 1) sel_offset = eo_offset[59:55];
                else if (cur_cat == 2) sel_offset = eo_offset[69:65];
                else sel_offset = eo_offset[74:70];
            end
        end else begin // BO
            if (cur_comp == 0) begin
                if (cur_cat == 0) sel_offset = bo_offset[4:0];
                else if (cur_cat == 1) sel_offset = bo_offset[9:5];
                else if (cur_cat == 2) sel_offset = bo_offset[14:10];
                else sel_offset = bo_offset[19:15];
            end else if (cur_comp == 1) begin
                if (cur_cat == 0) sel_offset = bo_offset[24:20];
                else if (cur_cat == 1) sel_offset = bo_offset[29:25];
                else if (cur_cat == 2) sel_offset = bo_offset[34:30];
                else sel_offset = bo_offset[39:35];
            end else begin
                if (cur_cat == 0) sel_offset = bo_offset[44:40];
                else if (cur_cat == 1) sel_offset = bo_offset[49:45];
                else if (cur_cat == 2) sel_offset = bo_offset[54:50];
                else sel_offset = bo_offset[59:55];
            end
        end
    end

    wire [4:0] abs_offset = (sel_offset < 0) ? -sel_offset : sel_offset;
    wire sign_offset = (sel_offset < 0) ? 1'b1 : 1'b0;

    reg [4:0] tr_count; // Unary counter for offset_abs
    reg [2:0] fl_count; // Counter for band_pos or eo_class (fixed length)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            sao_done   <= 1'b0;
            bin_valid  <= 1'b0;
            bin_value  <= 1'b0;
            bin_ctx_id <= {CTX_ID_W{1'b0}};
            bin_is_ep  <= 1'b0;
            cur_comp   <= 2'd0;
            cur_cat    <= 3'd0;
            tr_count   <= 5'd0;
            fl_count   <= 3'd0;
        end else begin
            sao_done <= 1'b0;
            if (bin_valid && !bin_rdy) begin
                // stall
            end else begin
                bin_valid <= 1'b0;
                case (state)
                    S_IDLE: begin
                        if (sao_req) begin
                            cur_comp <= 2'd0;
                            cur_cat  <= 3'd0;
                            tr_count <= 5'd0;
                            fl_count <= 3'd0;
                            if (has_left) begin
                                state <= S_MERGE_LEFT;
                            end else if (has_up) begin
                                state <= S_MERGE_UP;
                            end else begin
                                state <= S_TYPE;
                            end
                        end
                    end

                    S_MERGE_LEFT: begin
                        bin_valid  <= 1'b1;
                        bin_value  <= 1'b0;
                        bin_ctx_id <= 8'd181;
                        bin_is_ep  <= 1'b0; // Hardcoded merge_left = 0
                        if (has_up) state <= S_MERGE_UP;
                        else        state <= S_TYPE;
                    end

                    S_MERGE_UP: begin
                        bin_valid  <= 1'b1;
                        bin_value  <= 1'b0;
                        bin_ctx_id <= 8'd181;
                        bin_is_ep  <= 1'b0; // Hardcoded merge_up = 0
                        state      <= S_TYPE;
                    end

                    S_TYPE: begin
                        // ITU-T H.265 Clause 7.3.8.3 / HM parseSaoTypeIdx:
                        // 0 (OFF): bin=0 (ctx 182)
                        // 1 (BO):  bin0=1 (ctx 182), bin1=0 (bypass)
                        // 2 (EO):  bin0=1 (ctx 182), bin1=1 (bypass)
                        if (tr_count == 5'd0) begin
                            bin_valid  <= 1'b1;
                            bin_value  <= (cur_type == 2'd0) ? 1'b0 : 1'b1;
                            bin_ctx_id <= 8'd182;
                            bin_is_ep  <= 1'b0;
                            if (cur_type == 2'd0) begin
                                if (cur_comp == 2'd0) begin
                                    // Luma is OFF -> next is Cb
                                    cur_comp <= 2'd1;
                                    tr_count <= 5'd0;
                                end else begin
                                    // Cb is OFF -> Cr inherits OFF, entire CTU SAO is done
                                    state <= S_DONE;
                                end
                            end else begin
                                tr_count <= 5'd1;
                            end
                        end else begin
                            bin_valid  <= 1'b1;
                            bin_value  <= (cur_type == 2'd1) ? 1'b1 : 1'b0; // EO=1, BO=0
                            bin_is_ep  <= 1'b1;
                            cur_cat    <= 3'd0;
                            tr_count   <= 5'd0;
                            state      <= S_OFFSET_ABS;
                        end
                    end

                    S_OFFSET_ABS: begin
                        // Emit all 4 truncated unary absolute offsets first
                        bin_valid <= 1'b1;
                        bin_is_ep <= 1'b1;
                        if (tr_count < abs_offset) begin
                            bin_value <= 1'b1;
                            tr_count  <= tr_count + 5'd1;
                        end else begin
                            if (tr_count < 5'd31) bin_value <= 1'b0;
                            else                  bin_value <= 1'b1; // maxSymbol reached
                            tr_count  <= 5'd0;
                            if (cur_cat == 3'd3) begin
                                cur_cat <= 3'd0;
                                if (cur_type == 2'd1) begin // EO has no signs
                                    if (cur_comp != 2'd2) begin
                                        state    <= S_EO_CLASS;
                                        fl_count <= 3'd0;
                                    end else begin
                                        // Cr inherits Cb eo_class
                                        state <= S_DONE;
                                    end
                                end else begin // BO
                                    state <= S_OFFSET_SIGN;
                                end
                            end else begin
                                cur_cat <= cur_cat + 3'd1;
                            end
                        end
                    end

                    S_OFFSET_SIGN: begin
                        // For BO, loop through signs for non-zero offsets
                        if (abs_offset == 5'd0) begin
                            // Skip sign bin for zero offset
                            bin_valid <= 1'b0;
                            if (cur_cat == 3'd3) begin
                                state    <= S_BAND_POS;
                                fl_count <= 3'd0;
                            end else begin
                                cur_cat  <= cur_cat + 3'd1;
                            end
                        end else begin
                            bin_valid <= 1'b1;
                            bin_is_ep <= 1'b1;
                            bin_value <= sign_offset;
                            if (cur_cat == 3'd3) begin
                                state    <= S_BAND_POS;
                                fl_count <= 3'd0;
                            end else begin
                                cur_cat  <= cur_cat + 3'd1;
                            end
                        end
                    end

                    S_BAND_POS: begin
                        // 5-bit fixed length band_position
                        bin_valid <= 1'b1;
                        bin_is_ep <= 1'b1;
                        bin_value <= cur_band_pos[4 - fl_count];
                        if (fl_count == 3'd4) begin
                            if (cur_comp == 2'd0) begin
                                // Luma done -> Cb codes sao_type_idx_chroma
                                cur_comp <= 2'd1;
                                state    <= S_TYPE;
                                tr_count <= 5'd0;
                            end else if (cur_comp == 2'd1) begin
                                // Cb done -> Cr inherits sao_type_idx_chroma, bypasses S_TYPE directly to S_OFFSET_ABS
                                cur_comp <= 2'd2;
                                cur_cat  <= 3'd0;
                                tr_count <= 5'd0;
                                state    <= S_OFFSET_ABS;
                            end else begin
                                // Cr done -> CTU SAO complete
                                state    <= S_DONE;
                            end
                        end else begin
                            fl_count <= fl_count + 3'd1;
                        end
                    end

                    S_EO_CLASS: begin
                        // 2-bit fixed length eo_class (coded for Luma and Cb; Cr inherits Cb)
                        bin_valid <= 1'b1;
                        bin_is_ep <= 1'b1;
                        bin_value <= cur_eo_class[1 - fl_count];
                        if (fl_count == 3'd1) begin
                            if (cur_comp == 2'd0) begin
                                cur_comp <= 2'd1;
                                state    <= S_TYPE;
                                tr_count <= 5'd0;
                            end else if (cur_comp == 2'd1) begin
                                // Cb done -> Cr inherits sao_type and sao_class, goes directly to S_OFFSET_ABS
                                cur_comp <= 2'd2;
                                cur_cat  <= 3'd0;
                                tr_count <= 5'd0;
                                state    <= S_OFFSET_ABS;
                            end else begin
                                state    <= S_DONE;
                            end
                        end else begin
                            fl_count <= fl_count + 3'd1;
                        end
                    end

                    S_DONE: begin
                        sao_done <= 1'b1;
                        state    <= S_IDLE;
                    end

                    default: state <= S_IDLE;
                endcase
            end
        end
    end

endmodule
