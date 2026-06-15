`timescale 1ns / 1ps

module address_generator (
    input  wire [2:0]   tu_size_log2, // 2=4x4, 3=8x8, 4=16x16, 5=32x32
    input  wire [1:0]   scan_mode,    // 0=Diag, 1=Horiz, 2=Vert
    input  wire [9:0]   scan_idx,     // 0 to 1023
    output reg  [4:0]   addr_x,
    output reg  [4:0]   addr_y
);

    function automatic [1:0] diag_4_row;
        input [3:0] pos;
        reg [1:0] lut [0:15];
        begin
lut[ 0]=2'd0; lut[ 1]=2'd1; lut[ 2]=2'd0; lut[ 3]=2'd2;
lut[ 4]=2'd1; lut[ 5]=2'd0; lut[ 6]=2'd3; lut[ 7]=2'd2;
lut[ 8]=2'd1; lut[ 9]=2'd0; lut[10]=2'd3; lut[11]=2'd2;
lut[12]=2'd1; lut[13]=2'd3; lut[14]=2'd2; lut[15]=2'd3;
            diag_4_row = lut[pos];
        end
    endfunction
    function automatic [1:0] diag_4_col;
        input [3:0] pos;
        reg [1:0] lut [0:15];
        begin
lut[ 0]=2'd0; lut[ 1]=2'd0; lut[ 2]=2'd1; lut[ 3]=2'd0;
lut[ 4]=2'd1; lut[ 5]=2'd2; lut[ 6]=2'd0; lut[ 7]=2'd1;
lut[ 8]=2'd2; lut[ 9]=2'd3; lut[10]=2'd1; lut[11]=2'd2;
lut[12]=2'd3; lut[13]=2'd2; lut[14]=2'd3; lut[15]=2'd3;
            diag_4_col = lut[pos];
        end
    endfunction
    function automatic [3:0] diag_8_row;
        input [5:0] pos;
        reg [3:0] lut [0:63];
        begin
lut[ 0]=4'd0; lut[ 1]=4'd1; lut[ 2]=4'd0; lut[ 3]=4'd2;
lut[ 4]=4'd1; lut[ 5]=4'd0; lut[ 6]=4'd3; lut[ 7]=4'd2;
lut[ 8]=4'd1; lut[ 9]=4'd0; lut[10]=4'd4; lut[11]=4'd3;
lut[12]=4'd2; lut[13]=4'd1; lut[14]=4'd0; lut[15]=4'd5;
lut[16]=4'd4; lut[17]=4'd3; lut[18]=4'd2; lut[19]=4'd1;
lut[20]=4'd0; lut[21]=4'd6; lut[22]=4'd5; lut[23]=4'd4;
lut[24]=4'd3; lut[25]=4'd2; lut[26]=4'd1; lut[27]=4'd0;
lut[28]=4'd7; lut[29]=4'd6; lut[30]=4'd5; lut[31]=4'd4;
lut[32]=4'd3; lut[33]=4'd2; lut[34]=4'd1; lut[35]=4'd0;
lut[36]=4'd7; lut[37]=4'd6; lut[38]=4'd5; lut[39]=4'd4;
lut[40]=4'd3; lut[41]=4'd2; lut[42]=4'd1; lut[43]=4'd7;
lut[44]=4'd6; lut[45]=4'd5; lut[46]=4'd4; lut[47]=4'd3;
lut[48]=4'd2; lut[49]=4'd7; lut[50]=4'd6; lut[51]=4'd5;
lut[52]=4'd4; lut[53]=4'd3; lut[54]=4'd7; lut[55]=4'd6;
lut[56]=4'd5; lut[57]=4'd4; lut[58]=4'd7; lut[59]=4'd6;
lut[60]=4'd5; lut[61]=4'd7; lut[62]=4'd6; lut[63]=4'd7;
            diag_8_row = lut[pos];
        end
    endfunction
    function automatic [3:0] diag_8_col;
        input [5:0] pos;
        reg [3:0] lut [0:63];
        begin
lut[ 0]=4'd0; lut[ 1]=4'd0; lut[ 2]=4'd1; lut[ 3]=4'd0;
lut[ 4]=4'd1; lut[ 5]=4'd2; lut[ 6]=4'd0; lut[ 7]=4'd1;
lut[ 8]=4'd2; lut[ 9]=4'd3; lut[10]=4'd0; lut[11]=4'd1;
lut[12]=4'd2; lut[13]=4'd3; lut[14]=4'd4; lut[15]=4'd0;
lut[16]=4'd1; lut[17]=4'd2; lut[18]=4'd3; lut[19]=4'd4;
lut[20]=4'd5; lut[21]=4'd0; lut[22]=4'd1; lut[23]=4'd2;
lut[24]=4'd3; lut[25]=4'd4; lut[26]=4'd5; lut[27]=4'd6;
lut[28]=4'd0; lut[29]=4'd1; lut[30]=4'd2; lut[31]=4'd3;
lut[32]=4'd4; lut[33]=4'd5; lut[34]=4'd6; lut[35]=4'd7;
lut[36]=4'd1; lut[37]=4'd2; lut[38]=4'd3; lut[39]=4'd4;
lut[40]=4'd5; lut[41]=4'd6; lut[42]=4'd7; lut[43]=4'd2;
lut[44]=4'd3; lut[45]=4'd4; lut[46]=4'd5; lut[47]=4'd6;
lut[48]=4'd7; lut[49]=4'd3; lut[50]=4'd4; lut[51]=4'd5;
lut[52]=4'd6; lut[53]=4'd7; lut[54]=4'd4; lut[55]=4'd5;
lut[56]=4'd6; lut[57]=4'd7; lut[58]=4'd5; lut[59]=4'd6;
lut[60]=4'd7; lut[61]=4'd6; lut[62]=4'd7; lut[63]=4'd7;
            diag_8_col = lut[pos];
        end
    endfunction
    function automatic [1:0] horiz_4_row;
        input [3:0] pos;
        reg [1:0] lut [0:15];
        begin
lut[ 0]=2'd0; lut[ 1]=2'd0; lut[ 2]=2'd0; lut[ 3]=2'd0;
lut[ 4]=2'd1; lut[ 5]=2'd1; lut[ 6]=2'd1; lut[ 7]=2'd1;
lut[ 8]=2'd2; lut[ 9]=2'd2; lut[10]=2'd2; lut[11]=2'd2;
lut[12]=2'd3; lut[13]=2'd3; lut[14]=2'd3; lut[15]=2'd3;
            horiz_4_row = lut[pos];
        end
    endfunction
    function automatic [1:0] horiz_4_col;
        input [3:0] pos;
        reg [1:0] lut [0:15];
        begin
lut[ 0]=2'd0; lut[ 1]=2'd1; lut[ 2]=2'd2; lut[ 3]=2'd3;
lut[ 4]=2'd0; lut[ 5]=2'd1; lut[ 6]=2'd2; lut[ 7]=2'd3;
lut[ 8]=2'd0; lut[ 9]=2'd1; lut[10]=2'd2; lut[11]=2'd3;
lut[12]=2'd0; lut[13]=2'd1; lut[14]=2'd2; lut[15]=2'd3;
            horiz_4_col = lut[pos];
        end
    endfunction
    function automatic [3:0] horiz_8_row;
        input [5:0] pos;
        reg [3:0] lut [0:63];
        begin
lut[ 0]=4'd0; lut[ 1]=4'd0; lut[ 2]=4'd0; lut[ 3]=4'd0;
lut[ 4]=4'd0; lut[ 5]=4'd0; lut[ 6]=4'd0; lut[ 7]=4'd0;
lut[ 8]=4'd1; lut[ 9]=4'd1; lut[10]=4'd1; lut[11]=4'd1;
lut[12]=4'd1; lut[13]=4'd1; lut[14]=4'd1; lut[15]=4'd1;
lut[16]=4'd2; lut[17]=4'd2; lut[18]=4'd2; lut[19]=4'd2;
lut[20]=4'd2; lut[21]=4'd2; lut[22]=4'd2; lut[23]=4'd2;
lut[24]=4'd3; lut[25]=4'd3; lut[26]=4'd3; lut[27]=4'd3;
lut[28]=4'd3; lut[29]=4'd3; lut[30]=4'd3; lut[31]=4'd3;
lut[32]=4'd4; lut[33]=4'd4; lut[34]=4'd4; lut[35]=4'd4;
lut[36]=4'd4; lut[37]=4'd4; lut[38]=4'd4; lut[39]=4'd4;
lut[40]=4'd5; lut[41]=4'd5; lut[42]=4'd5; lut[43]=4'd5;
lut[44]=4'd5; lut[45]=4'd5; lut[46]=4'd5; lut[47]=4'd5;
lut[48]=4'd6; lut[49]=4'd6; lut[50]=4'd6; lut[51]=4'd6;
lut[52]=4'd6; lut[53]=4'd6; lut[54]=4'd6; lut[55]=4'd6;
lut[56]=4'd7; lut[57]=4'd7; lut[58]=4'd7; lut[59]=4'd7;
lut[60]=4'd7; lut[61]=4'd7; lut[62]=4'd7; lut[63]=4'd7;
            horiz_8_row = lut[pos];
        end
    endfunction
    function automatic [3:0] horiz_8_col;
        input [5:0] pos;
        reg [3:0] lut [0:63];
        begin
lut[ 0]=4'd0; lut[ 1]=4'd1; lut[ 2]=4'd2; lut[ 3]=4'd3;
lut[ 4]=4'd4; lut[ 5]=4'd5; lut[ 6]=4'd6; lut[ 7]=4'd7;
lut[ 8]=4'd0; lut[ 9]=4'd1; lut[10]=4'd2; lut[11]=4'd3;
lut[12]=4'd4; lut[13]=4'd5; lut[14]=4'd6; lut[15]=4'd7;
lut[16]=4'd0; lut[17]=4'd1; lut[18]=4'd2; lut[19]=4'd3;
lut[20]=4'd4; lut[21]=4'd5; lut[22]=4'd6; lut[23]=4'd7;
lut[24]=4'd0; lut[25]=4'd1; lut[26]=4'd2; lut[27]=4'd3;
lut[28]=4'd4; lut[29]=4'd5; lut[30]=4'd6; lut[31]=4'd7;
lut[32]=4'd0; lut[33]=4'd1; lut[34]=4'd2; lut[35]=4'd3;
lut[36]=4'd4; lut[37]=4'd5; lut[38]=4'd6; lut[39]=4'd7;
lut[40]=4'd0; lut[41]=4'd1; lut[42]=4'd2; lut[43]=4'd3;
lut[44]=4'd4; lut[45]=4'd5; lut[46]=4'd6; lut[47]=4'd7;
lut[48]=4'd0; lut[49]=4'd1; lut[50]=4'd2; lut[51]=4'd3;
lut[52]=4'd4; lut[53]=4'd5; lut[54]=4'd6; lut[55]=4'd7;
lut[56]=4'd0; lut[57]=4'd1; lut[58]=4'd2; lut[59]=4'd3;
lut[60]=4'd4; lut[61]=4'd5; lut[62]=4'd6; lut[63]=4'd7;
            horiz_8_col = lut[pos];
        end
    endfunction
    function automatic [1:0] vert_4_row;
        input [3:0] pos;
        reg [1:0] lut [0:15];
        begin
lut[ 0]=2'd0; lut[ 1]=2'd1; lut[ 2]=2'd2; lut[ 3]=2'd3;
lut[ 4]=2'd0; lut[ 5]=2'd1; lut[ 6]=2'd2; lut[ 7]=2'd3;
lut[ 8]=2'd0; lut[ 9]=2'd1; lut[10]=2'd2; lut[11]=2'd3;
lut[12]=2'd0; lut[13]=2'd1; lut[14]=2'd2; lut[15]=2'd3;
            vert_4_row = lut[pos];
        end
    endfunction
    function automatic [1:0] vert_4_col;
        input [3:0] pos;
        reg [1:0] lut [0:15];
        begin
lut[ 0]=2'd0; lut[ 1]=2'd0; lut[ 2]=2'd0; lut[ 3]=2'd0;
lut[ 4]=2'd1; lut[ 5]=2'd1; lut[ 6]=2'd1; lut[ 7]=2'd1;
lut[ 8]=2'd2; lut[ 9]=2'd2; lut[10]=2'd2; lut[11]=2'd2;
lut[12]=2'd3; lut[13]=2'd3; lut[14]=2'd3; lut[15]=2'd3;
            vert_4_col = lut[pos];
        end
    endfunction
    function automatic [3:0] vert_8_row;
        input [5:0] pos;
        reg [3:0] lut [0:63];
        begin
lut[ 0]=4'd0; lut[ 1]=4'd1; lut[ 2]=4'd2; lut[ 3]=4'd3;
lut[ 4]=4'd4; lut[ 5]=4'd5; lut[ 6]=4'd6; lut[ 7]=4'd7;
lut[ 8]=4'd0; lut[ 9]=4'd1; lut[10]=4'd2; lut[11]=4'd3;
lut[12]=4'd4; lut[13]=4'd5; lut[14]=4'd6; lut[15]=4'd7;
lut[16]=4'd0; lut[17]=4'd1; lut[18]=4'd2; lut[19]=4'd3;
lut[20]=4'd4; lut[21]=4'd5; lut[22]=4'd6; lut[23]=4'd7;
lut[24]=4'd0; lut[25]=4'd1; lut[26]=4'd2; lut[27]=4'd3;
lut[28]=4'd4; lut[29]=4'd5; lut[30]=4'd6; lut[31]=4'd7;
lut[32]=4'd0; lut[33]=4'd1; lut[34]=4'd2; lut[35]=4'd3;
lut[36]=4'd4; lut[37]=4'd5; lut[38]=4'd6; lut[39]=4'd7;
lut[40]=4'd0; lut[41]=4'd1; lut[42]=4'd2; lut[43]=4'd3;
lut[44]=4'd4; lut[45]=4'd5; lut[46]=4'd6; lut[47]=4'd7;
lut[48]=4'd0; lut[49]=4'd1; lut[50]=4'd2; lut[51]=4'd3;
lut[52]=4'd4; lut[53]=4'd5; lut[54]=4'd6; lut[55]=4'd7;
lut[56]=4'd0; lut[57]=4'd1; lut[58]=4'd2; lut[59]=4'd3;
lut[60]=4'd4; lut[61]=4'd5; lut[62]=4'd6; lut[63]=4'd7;
            vert_8_row = lut[pos];
        end
    endfunction
    function automatic [3:0] vert_8_col;
        input [5:0] pos;
        reg [3:0] lut [0:63];
        begin
lut[ 0]=4'd0; lut[ 1]=4'd0; lut[ 2]=4'd0; lut[ 3]=4'd0;
lut[ 4]=4'd0; lut[ 5]=4'd0; lut[ 6]=4'd0; lut[ 7]=4'd0;
lut[ 8]=4'd1; lut[ 9]=4'd1; lut[10]=4'd1; lut[11]=4'd1;
lut[12]=4'd1; lut[13]=4'd1; lut[14]=4'd1; lut[15]=4'd1;
lut[16]=4'd2; lut[17]=4'd2; lut[18]=4'd2; lut[19]=4'd2;
lut[20]=4'd2; lut[21]=4'd2; lut[22]=4'd2; lut[23]=4'd2;
lut[24]=4'd3; lut[25]=4'd3; lut[26]=4'd3; lut[27]=4'd3;
lut[28]=4'd3; lut[29]=4'd3; lut[30]=4'd3; lut[31]=4'd3;
lut[32]=4'd4; lut[33]=4'd4; lut[34]=4'd4; lut[35]=4'd4;
lut[36]=4'd4; lut[37]=4'd4; lut[38]=4'd4; lut[39]=4'd4;
lut[40]=4'd5; lut[41]=4'd5; lut[42]=4'd5; lut[43]=4'd5;
lut[44]=4'd5; lut[45]=4'd5; lut[46]=4'd5; lut[47]=4'd5;
lut[48]=4'd6; lut[49]=4'd6; lut[50]=4'd6; lut[51]=4'd6;
lut[52]=4'd6; lut[53]=4'd6; lut[54]=4'd6; lut[55]=4'd6;
lut[56]=4'd7; lut[57]=4'd7; lut[58]=4'd7; lut[59]=4'd7;
lut[60]=4'd7; lut[61]=4'd7; lut[62]=4'd7; lut[63]=4'd7;
            vert_8_col = lut[pos];
        end
    endfunction

    wire [5:0] cg_idx     = scan_idx[9:4];
    wire [3:0] sub_idx    = scan_idx[3:0];

    reg [2:0] cg_x, cg_y;
    reg [1:0] sub_x, sub_y;

    always @* begin
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
            // 8x8 TU
            if (scan_mode == 2'd1) begin
                // Horiz scan for 8x8 CGs and sub
                cg_x = horiz_4_col(cg_idx[3:0]);
                cg_y = horiz_4_row(cg_idx[3:0]);
                sub_x = horiz_4_col(sub_idx);
                sub_y = horiz_4_row(sub_idx);
            end else if (scan_mode == 2'd2) begin
                // Vert scan
                cg_x = vert_4_col(cg_idx[3:0]);
                cg_y = vert_4_row(cg_idx[3:0]);
                sub_x = vert_4_col(sub_idx);
                sub_y = vert_4_row(sub_idx);
            end else begin
                // Diag scan
                cg_x = diag_4_col(cg_idx[3:0]);
                cg_y = diag_4_row(cg_idx[3:0]);
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
