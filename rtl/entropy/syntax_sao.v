//=============================================================================
// syntax_sao.v
// SAO CABAC Syntax Element Encoder
//=============================================================================

`include "parameter_pkg.vh"

module syntax_sao #(
    parameter CTX_ID_W = 8
)(
    input  wire        clk,
    input  wire        rst_n,

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
            // For EO, category is 1..4 (which we map to 0..3 here).
            // Actually, in SAO stats, eo_offset is packed as: cat4, cat3, cat2 (always 0), cat1, cat0.
            // Wait, for signaling, we only signal 4 offsets: cat0, cat1, cat3, cat4.
            // And in SAO stats, they were stored at indices [0], [1], [3], [4].
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
            state <= S_IDLE;
            sao_done <= 0;
            bin_valid <= 0;
            bin_value <= 0;
            bin_ctx_id <= 0;
            bin_is_ep <= 0;
            cur_comp <= 0; cur_cat <= 0;
            tr_count <= 0; fl_count <= 0;
        end else begin
            sao_done <= 0;
            if (bin_valid && !bin_rdy) begin
                // stall
            end else begin
                bin_valid <= 0;
                case (state)
                    S_IDLE: begin
                        if (sao_req) begin
                            state <= S_MERGE_LEFT;
                            cur_comp <= 0;
                        end
                    end
                    S_MERGE_LEFT: begin
                        bin_valid <= 1; bin_value <= 0; bin_ctx_id <= 181; bin_is_ep <= 0; // Hardcoded merge_left = 0
                        state <= S_MERGE_UP;
                    end
                    S_MERGE_UP: begin
                        bin_valid <= 1; bin_value <= 0; bin_ctx_id <= 181; bin_is_ep <= 0; // Hardcoded merge_up = 0
                        state <= S_TYPE;
                    end
                    S_TYPE: begin
                        // sao_type_idx_luma / chroma
                        // TR cMax=2. 0=OFF(0), 1=BO(10), 2=EO(11)
                        // Actually HM SAO type encoding: 
                        // cMax=2. cRiceParam=0.
                        // OFF (0): 0
                        // BO (2): 10
                        // EO (1): 11 (Wait! In HEVC spec, BO is 1, EO is 2!)
                        // Let's remap my types: My types: 1=EO, 2=BO.
                        // Spec types: 0=OFF, 1=BO, 2=EO.
                        // So my type 1 (EO) -> spec 2.
                        // My type 2 (BO) -> spec 1.
                        // Spec TR: 
                        // 0 -> bin=0 (ctx 182)
                        // 1 (BO) -> bin0=1 (ctx 182), bin1=0 (bypass)
                        // 2 (EO) -> bin0=1 (ctx 182), bin1=1 (bypass)
                        
                        if (tr_count == 0) begin
                            bin_valid <= 1; 
                            bin_value <= (cur_type == 0) ? 0 : 1; 
                            bin_ctx_id <= 182; 
                            bin_is_ep <= 0;
                            if (cur_type == 0) begin
                                // Done with this component
                                if (cur_comp == 0) begin cur_comp <= 1; tr_count <= 0; end // Next comp
                                else if (cur_comp == 1) begin cur_comp <= 2; tr_count <= 0; end
                                else state <= S_DONE;
                            end else begin
                                tr_count <= 1;
                            end
                        end else begin
                            bin_valid <= 1;
                            bin_value <= (cur_type == 1) ? 1 : 0; // My EO=1 -> Spec EO=2 -> bin1=1. My BO=2 -> Spec BO=1 -> bin1=0.
                            bin_is_ep <= 1;
                            
                            cur_cat <= 0;
                            tr_count <= 0;
                            state <= S_OFFSET_ABS;
                        end
                    end
                    S_OFFSET_ABS: begin
                        bin_valid <= 1;
                        bin_is_ep <= 1;
                        if (tr_count < abs_offset) begin
                            bin_value <= 1;
                            tr_count <= tr_count + 1;
                        end else begin
                            if (tr_count < 31) bin_value <= 0;
                            else bin_value <= 1; // Unary ends with 1 if max
                            tr_count <= 0;
                            state <= S_OFFSET_SIGN;
                        end
                    end
                    S_OFFSET_SIGN: begin
                        if (abs_offset == 0) begin
                            // No sign if offset is 0
                            if (cur_cat == 3) begin
                                if (cur_type == 1) begin state <= S_EO_CLASS; fl_count <= 0; end
                                else begin state <= S_BAND_POS; fl_count <= 0; end
                            end else begin
                                cur_cat <= cur_cat + 1;
                                state <= S_OFFSET_ABS;
                            end
                        end else begin
                            // Wait, EO offset sign is NOT encoded!
                            // Spec 7.3.8.3: "if( sao_type_idx == 1 ) { sao_offset_sign }" (which means BO!)
                            // For EO, the sign is implicitly defined by the category!
                            if (cur_type == 1) begin // EO
                                // Skip sign
                                if (cur_cat == 3) begin
                                    state <= S_EO_CLASS; fl_count <= 0;
                                end else begin
                                    cur_cat <= cur_cat + 1;
                                    state <= S_OFFSET_ABS;
                                end
                            end else begin // BO
                                bin_valid <= 1;
                                bin_is_ep <= 1;
                                bin_value <= sign_offset;
                                if (cur_cat == 3) begin
                                    state <= S_BAND_POS; fl_count <= 0;
                                end else begin
                                    cur_cat <= cur_cat + 1;
                                    state <= S_OFFSET_ABS;
                                end
                            end
                        end
                    end
                    S_BAND_POS: begin
                        // 5 bits FL
                        bin_valid <= 1;
                        bin_is_ep <= 1;
                        bin_value <= cur_band_pos[4 - fl_count];
                        if (fl_count == 4) begin
                            // Component done
                            if (cur_comp == 0) begin cur_comp <= 1; state <= S_TYPE; tr_count <= 0; end
                            else if (cur_comp == 1) begin cur_comp <= 2; state <= S_TYPE; tr_count <= 0; end
                            else state <= S_DONE;
                        end else fl_count <= fl_count + 1;
                    end
                    S_EO_CLASS: begin
                        // Wait, for Chroma, eo_class is NOT coded for Cr! It is shared with Cb!
                        // Spec: if( cIdx != 2 ) { sao_eo_class }
                        if (cur_comp == 2) begin
                            state <= S_DONE;
                        end else begin
                            // 2 bits FL
                            bin_valid <= 1;
                            bin_is_ep <= 1;
                            bin_value <= cur_eo_class[1 - fl_count];
                            if (fl_count == 1) begin
                                if (cur_comp == 0) begin cur_comp <= 1; state <= S_TYPE; tr_count <= 0; end
                                else if (cur_comp == 1) begin cur_comp <= 2; state <= S_TYPE; tr_count <= 0; end
                                else state <= S_DONE; // Should not happen since comp 2 skips
                            end else fl_count <= fl_count + 1;
                        end
                    end
                    S_DONE: begin
                        sao_done <= 1;
                        state <= S_IDLE;
                    end
                endcase
            end
        end
    end

endmodule
