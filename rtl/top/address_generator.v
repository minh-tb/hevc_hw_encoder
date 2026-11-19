`timescale 1ns / 1ps

module address_generator (
    input  wire [2:0]   tu_size_log2, // 2=4x4, 3=8x8, 4=16x16, 5=32x32
    input  wire [1:0]   scan_mode,    // 0=Diag, 1=Horiz, 2=Vert
    input  wire [9:0]   scan_idx,     // 0 to 1023
    output reg  [4:0]   addr_x,
    output reg  [4:0]   addr_y
);

    // Pure case/bit-slice lookup functions (no unpacked local arrays in functions,
    // ensuring complete sensitivity lists across xsim, QuestaSim, ModelSim, and Vivado).
    function automatic [1:0] diag_4_row;
        input [3:0] pos;
        begin
            case (pos)
                4'd0:  diag_4_row = 2'd0; 4'd1:  diag_4_row = 2'd1; 4'd2:  diag_4_row = 2'd0; 4'd3:  diag_4_row = 2'd2;
                4'd4:  diag_4_row = 2'd1; 4'd5:  diag_4_row = 2'd0; 4'd6:  diag_4_row = 2'd3; 4'd7:  diag_4_row = 2'd2;
                4'd8:  diag_4_row = 2'd1; 4'd9:  diag_4_row = 2'd0; 4'd10: diag_4_row = 2'd3; 4'd11: diag_4_row = 2'd2;
                4'd12: diag_4_row = 2'd1; 4'd13: diag_4_row = 2'd3; 4'd14: diag_4_row = 2'd2; default: diag_4_row = 2'd3;
            endcase
        end
    endfunction

    function automatic [1:0] diag_4_col;
        input [3:0] pos;
        begin
            case (pos)
                4'd0:  diag_4_col = 2'd0; 4'd1:  diag_4_col = 2'd0; 4'd2:  diag_4_col = 2'd1; 4'd3:  diag_4_col = 2'd0;
                4'd4:  diag_4_col = 2'd1; 4'd5:  diag_4_col = 2'd2; 4'd6:  diag_4_col = 2'd0; 4'd7:  diag_4_col = 2'd1;
                4'd8:  diag_4_col = 2'd2; 4'd9:  diag_4_col = 2'd3; 4'd10: diag_4_col = 2'd1; 4'd11: diag_4_col = 2'd2;
                4'd12: diag_4_col = 2'd3; 4'd13: diag_4_col = 2'd2; 4'd14: diag_4_col = 2'd3; default: diag_4_col = 2'd3;
            endcase
        end
    endfunction

    function automatic [3:0] diag_8_row;
        input [5:0] pos;
        begin
            case (pos)
                6'd0:  diag_8_row = 4'd0; 6'd1:  diag_8_row = 4'd1; 6'd2:  diag_8_row = 4'd0; 6'd3:  diag_8_row = 4'd2;
                6'd4:  diag_8_row = 4'd1; 6'd5:  diag_8_row = 4'd0; 6'd6:  diag_8_row = 4'd3; 6'd7:  diag_8_row = 4'd2;
                6'd8:  diag_8_row = 4'd1; 6'd9:  diag_8_row = 4'd0; 6'd10: diag_8_row = 4'd4; 6'd11: diag_8_row = 4'd3;
                6'd12: diag_8_row = 4'd2; 6'd13: diag_8_row = 4'd1; 6'd14: diag_8_row = 4'd0; 6'd15: diag_8_row = 4'd5;
                6'd16: diag_8_row = 4'd4; 6'd17: diag_8_row = 4'd3; 6'd18: diag_8_row = 4'd2; 6'd19: diag_8_row = 4'd1;
                6'd20: diag_8_row = 4'd0; 6'd21: diag_8_row = 4'd6; 6'd22: diag_8_row = 4'd5; 6'd23: diag_8_row = 4'd4;
                6'd24: diag_8_row = 4'd3; 6'd25: diag_8_row = 4'd2; 6'd26: diag_8_row = 4'd1; 6'd27: diag_8_row = 4'd0;
                6'd28: diag_8_row = 4'd7; 6'd29: diag_8_row = 4'd6; 6'd30: diag_8_row = 4'd5; 6'd31: diag_8_row = 4'd4;
                6'd32: diag_8_row = 4'd3; 6'd33: diag_8_row = 4'd2; 6'd34: diag_8_row = 4'd1; 6'd35: diag_8_row = 4'd0;
                6'd36: diag_8_row = 4'd7; 6'd37: diag_8_row = 4'd6; 6'd38: diag_8_row = 4'd5; 6'd39: diag_8_row = 4'd4;
                6'd40: diag_8_row = 4'd3; 6'd41: diag_8_row = 4'd2; 6'd42: diag_8_row = 4'd1; 6'd43: diag_8_row = 4'd7;
                6'd44: diag_8_row = 4'd6; 6'd45: diag_8_row = 4'd5; 6'd46: diag_8_row = 4'd4; 6'd47: diag_8_row = 4'd3;
                6'd48: diag_8_row = 4'd2; 6'd49: diag_8_row = 4'd7; 6'd50: diag_8_row = 4'd6; 6'd51: diag_8_row = 4'd5;
                6'd52: diag_8_row = 4'd4; 6'd53: diag_8_row = 4'd3; 6'd54: diag_8_row = 4'd7; 6'd55: diag_8_row = 4'd6;
                6'd56: diag_8_row = 4'd5; 6'd57: diag_8_row = 4'd4; 6'd58: diag_8_row = 4'd7; 6'd59: diag_8_row = 4'd6;
                6'd60: diag_8_row = 4'd5; 6'd61: diag_8_row = 4'd7; 6'd62: diag_8_row = 4'd6; default: diag_8_row = 4'd7;
            endcase
        end
    endfunction

    function automatic [3:0] diag_8_col;
        input [5:0] pos;
        begin
            case (pos)
                6'd0:  diag_8_col = 4'd0; 6'd1:  diag_8_col = 4'd0; 6'd2:  diag_8_col = 4'd1; 6'd3:  diag_8_col = 4'd0;
                6'd4:  diag_8_col = 4'd1; 6'd5:  diag_8_col = 4'd2; 6'd6:  diag_8_col = 4'd0; 6'd7:  diag_8_col = 4'd1;
                6'd8:  diag_8_col = 4'd2; 6'd9:  diag_8_col = 4'd3; 6'd10: diag_8_col = 4'd0; 6'd11: diag_8_col = 4'd1;
                6'd12: diag_8_col = 4'd2; 6'd13: diag_8_col = 4'd3; 6'd14: diag_8_col = 4'd4; 6'd15: diag_8_col = 4'd0;
                6'd16: diag_8_col = 4'd1; 6'd17: diag_8_col = 4'd2; 6'd18: diag_8_col = 4'd3; 6'd19: diag_8_col = 4'd4;
                6'd20: diag_8_col = 4'd5; 6'd21: diag_8_col = 4'd0; 6'd22: diag_8_col = 4'd1; 6'd23: diag_8_col = 4'd2;
                6'd24: diag_8_col = 4'd3; 6'd25: diag_8_col = 4'd4; 6'd26: diag_8_col = 4'd5; 6'd27: diag_8_col = 4'd6;
                6'd28: diag_8_col = 4'd0; 6'd29: diag_8_col = 4'd1; 6'd30: diag_8_col = 4'd2; 6'd31: diag_8_col = 4'd3;
                6'd32: diag_8_col = 4'd4; 6'd33: diag_8_col = 4'd5; 6'd34: diag_8_col = 4'd6; 6'd35: diag_8_col = 4'd7;
                6'd36: diag_8_col = 4'd1; 6'd37: diag_8_col = 4'd2; 6'd38: diag_8_col = 4'd3; 6'd39: diag_8_col = 4'd4;
                6'd40: diag_8_col = 4'd5; 6'd41: diag_8_col = 4'd6; 6'd42: diag_8_col = 4'd7; 6'd43: diag_8_col = 4'd2;
                6'd44: diag_8_col = 4'd3; 6'd45: diag_8_col = 4'd4; 6'd46: diag_8_col = 4'd5; 6'd47: diag_8_col = 4'd6;
                6'd48: diag_8_col = 4'd7; 6'd49: diag_8_col = 4'd3; 6'd50: diag_8_col = 4'd4; 6'd51: diag_8_col = 4'd5;
                6'd52: diag_8_col = 4'd6; 6'd53: diag_8_col = 4'd7; 6'd54: diag_8_col = 4'd4; 6'd55: diag_8_col = 4'd5;
                6'd56: diag_8_col = 4'd6; 6'd57: diag_8_col = 4'd7; 6'd58: diag_8_col = 4'd5; 6'd59: diag_8_col = 4'd6;
                6'd60: diag_8_col = 4'd7; 6'd61: diag_8_col = 4'd6; 6'd62: diag_8_col = 4'd7; default: diag_8_col = 4'd7;
            endcase
        end
    endfunction

    function automatic [1:0] horiz_4_row;
        input [3:0] pos;
        begin
            horiz_4_row = pos[3:2];
        end
    endfunction

    function automatic [1:0] horiz_4_col;
        input [3:0] pos;
        begin
            horiz_4_col = pos[1:0];
        end
    endfunction

    function automatic [1:0] vert_4_row;
        input [3:0] pos;
        begin
            vert_4_row = pos[1:0];
        end
    endfunction

    function automatic [1:0] vert_4_col;
        input [3:0] pos;
        begin
            vert_4_col = pos[3:2];
        end
    endfunction

    wire [5:0] cg_idx     = scan_idx[9:4];
    wire [3:0] sub_idx    = scan_idx[3:0];

    reg [2:0] cg_x, cg_y;
    reg [1:0] sub_x, sub_y;

    always @(tu_size_log2 or scan_mode or cg_idx or sub_idx) begin
        // By default, assume 4x4 Diagonal
        cg_x = 3'd0;
        cg_y = 3'd0;
        sub_x = diag_4_col(sub_idx);
        sub_y = diag_4_row(sub_idx);

        if (tu_size_log2 == 3'd2) begin
            // 4x4 TU
            if (scan_mode == 2'd1) begin
                sub_x = horiz_4_col(sub_idx);
                sub_y = horiz_4_row(sub_idx);
            end else if (scan_mode == 2'd2) begin
                sub_x = vert_4_col(sub_idx);
                sub_y = vert_4_row(sub_idx);
            end
        end else if (tu_size_log2 == 3'd3) begin
            // 8x8 TU (2x2 CGs)
            case (cg_idx[1:0])
                2'd0: begin cg_x = 3'd0; cg_y = 3'd0; end
                2'd1: begin
                    if (scan_mode == 2'd1) begin cg_x = 3'd1; cg_y = 3'd0; end
                    else                   begin cg_x = 3'd0; cg_y = 3'd1; end
                end
                2'd2: begin
                    if (scan_mode == 2'd1) begin cg_x = 3'd0; cg_y = 3'd1; end
                    else                   begin cg_x = 3'd1; cg_y = 3'd0; end
                end
                2'd3: begin cg_x = 3'd1; cg_y = 3'd1; end
            endcase

            if (scan_mode == 2'd1) begin
                sub_x = horiz_4_col(sub_idx);
                sub_y = horiz_4_row(sub_idx);
            end else if (scan_mode == 2'd2) begin
                sub_x = vert_4_col(sub_idx);
                sub_y = vert_4_row(sub_idx);
            end else begin
                sub_x = diag_4_col(sub_idx);
                sub_y = diag_4_row(sub_idx);
            end
        end else if (tu_size_log2 == 3'd4) begin
            // 16x16 TU (Diag only)
            cg_x = diag_4_col(cg_idx[3:0]);
            cg_y = diag_4_row(cg_idx[3:0]);
        end else if (tu_size_log2 == 3'd5) begin
            // 32x32 TU (Diag only, uses 8x8 CG LUT)
            cg_x = diag_8_col(cg_idx[5:0]);
            cg_y = diag_8_row(cg_idx[5:0]);
        end

        addr_x = {cg_x, sub_x};
        addr_y = {cg_y, sub_y};
    end

endmodule
