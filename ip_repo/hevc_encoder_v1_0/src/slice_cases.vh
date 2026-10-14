        case (frame_qp)
            6'd16: begin // QP=16, delta=-10
                if (latched_slice_type == SLICE_I) begin
                    hdr_shift_reg[63:40] <= 24'hAC0AA0;
                    hdr_bits_left <= 7'd24;
                end else if (latched_slice_type == SLICE_B) begin
                    hdr_shift_reg[63:32] <= {3'b111, latched_poc[7:0], 6'b100001, 9'b000010101, 2'b01, 4'd0};
                    hdr_bits_left <= 7'd32;
                end else begin
                    hdr_shift_reg[63:32] <= {5'b11010, latched_poc[7:0], 5'b10001, 9'b000010101, 2'b01, 3'd0};
                    hdr_bits_left <= 7'd32;
                end
            end
            6'd17: begin // QP=17, delta=-9
                if (latched_slice_type == SLICE_I) begin
                    hdr_shift_reg[63:40] <= 24'hAC09A0;
                    hdr_bits_left <= 7'd24;
                end else if (latched_slice_type == SLICE_B) begin
                    hdr_shift_reg[63:32] <= {3'b111, latched_poc[7:0], 6'b100001, 9'b000010011, 2'b01, 4'd0};
                    hdr_bits_left <= 7'd32;
                end else begin
                    hdr_shift_reg[63:32] <= {5'b11010, latched_poc[7:0], 5'b10001, 9'b000010011, 2'b01, 3'd0};
                    hdr_bits_left <= 7'd32;
                end
            end
            6'd18: begin // QP=18, delta=-8
                if (latched_slice_type == SLICE_I) begin
                    hdr_shift_reg[63:40] <= 24'hAC08A0;
                    hdr_bits_left <= 7'd24;
                end else if (latched_slice_type == SLICE_B) begin
                    hdr_shift_reg[63:32] <= {3'b111, latched_poc[7:0], 6'b100001, 9'b000010001, 2'b01, 4'd0};
                    hdr_bits_left <= 7'd32;
                end else begin
                    hdr_shift_reg[63:32] <= {5'b11010, latched_poc[7:0], 5'b10001, 9'b000010001, 2'b01, 3'd0};
                    hdr_bits_left <= 7'd32;
                end
            end
            6'd19: begin // QP=19, delta=-7
                if (latched_slice_type == SLICE_I) begin
                    hdr_shift_reg[63:40] <= 24'hAC1E80;
                    hdr_bits_left <= 7'd24;
                end else if (latched_slice_type == SLICE_B) begin
                    hdr_shift_reg[63:32] <= {3'b111, latched_poc[7:0], 6'b100001, 7'b0001111, 2'b01, 6'd0};
                    hdr_bits_left <= 7'd32;
                end else begin
                    hdr_shift_reg[63:32] <= {5'b11010, latched_poc[7:0], 5'b10001, 7'b0001111, 2'b01, 5'd0};
                    hdr_bits_left <= 7'd32;
                end
            end
            6'd20: begin // QP=20, delta=-6
                if (latched_slice_type == SLICE_I) begin
                    hdr_shift_reg[63:40] <= 24'hAC1A80;
                    hdr_bits_left <= 7'd24;
                end else if (latched_slice_type == SLICE_B) begin
                    hdr_shift_reg[63:32] <= {3'b111, latched_poc[7:0], 6'b100001, 7'b0001101, 2'b01, 6'd0};
                    hdr_bits_left <= 7'd32;
                end else begin
                    hdr_shift_reg[63:32] <= {5'b11010, latched_poc[7:0], 5'b10001, 7'b0001101, 2'b01, 5'd0};
                    hdr_bits_left <= 7'd32;
                end
            end
            6'd21: begin // QP=21, delta=-5
                if (latched_slice_type == SLICE_I) begin
                    hdr_shift_reg[63:40] <= 24'hAC1680;
                    hdr_bits_left <= 7'd24;
                end else if (latched_slice_type == SLICE_B) begin
                    hdr_shift_reg[63:32] <= {3'b111, latched_poc[7:0], 6'b100001, 7'b0001011, 2'b01, 6'd0};
                    hdr_bits_left <= 7'd32;
                end else begin
                    hdr_shift_reg[63:32] <= {5'b11010, latched_poc[7:0], 5'b10001, 7'b0001011, 2'b01, 5'd0};
                    hdr_bits_left <= 7'd32;
                end
            end
            6'd22: begin // QP=22, delta=-4
                if (latched_slice_type == SLICE_I) begin
                    hdr_shift_reg[63:40] <= 24'hAC1280;
                    hdr_bits_left <= 7'd24;
                end else if (latched_slice_type == SLICE_B) begin
                    hdr_shift_reg[63:32] <= {3'b111, latched_poc[7:0], 6'b100001, 7'b0001001, 2'b01, 6'd0};
                    hdr_bits_left <= 7'd32;
                end else begin
                    hdr_shift_reg[63:32] <= {5'b11010, latched_poc[7:0], 5'b10001, 7'b0001001, 2'b01, 5'd0};
                    hdr_bits_left <= 7'd32;
                end
            end
            6'd23: begin // QP=23, delta=-3
                if (latched_slice_type == SLICE_I) begin
                    hdr_shift_reg[63:48] <= 16'hAC3A;
                    hdr_bits_left <= 7'd16;
                end else if (latched_slice_type == SLICE_B) begin
                    hdr_shift_reg[63:40] <= {3'b111, latched_poc[7:0], 6'b100001, 5'b00111, 2'b01};
                    hdr_bits_left <= 7'd24;
                end else begin
                    hdr_shift_reg[63:32] <= {5'b11010, latched_poc[7:0], 5'b10001, 5'b00111, 2'b01, 7'd0};
                    hdr_bits_left <= 7'd32;
                end
            end
            6'd24: begin // QP=24, delta=-2
                if (latched_slice_type == SLICE_I) begin
                    hdr_shift_reg[63:48] <= 16'hAC2A;
                    hdr_bits_left <= 7'd16;
                end else if (latched_slice_type == SLICE_B) begin
                    hdr_shift_reg[63:40] <= {3'b111, latched_poc[7:0], 6'b100001, 5'b00101, 2'b01};
                    hdr_bits_left <= 7'd24;
                end else begin
                    hdr_shift_reg[63:32] <= {5'b11010, latched_poc[7:0], 5'b10001, 5'b00101, 2'b01, 7'd0};
                    hdr_bits_left <= 7'd32;
                end
            end
            6'd25: begin // QP=25, delta=-1
                if (latched_slice_type == SLICE_I) begin
                    hdr_shift_reg[63:48] <= 16'hAC68;
                    hdr_bits_left <= 7'd16;
                end else if (latched_slice_type == SLICE_B) begin
                    hdr_shift_reg[63:40] <= {3'b111, latched_poc[7:0], 6'b100001, 3'b011, 2'b01, 2'd0};
                    hdr_bits_left <= 7'd24;
                end else begin
                    hdr_shift_reg[63:40] <= {5'b11010, latched_poc[7:0], 5'b10001, 3'b011, 2'b01, 1'd0};
                    hdr_bits_left <= 7'd24;
                end
            end
            6'd26: begin // QP=26, delta=+0
                if (latched_slice_type == SLICE_I) begin
                    hdr_shift_reg[63:48] <= 16'hACA0;
                    hdr_bits_left <= 7'd16;
                end else if (latched_slice_type == SLICE_B) begin
                    hdr_shift_reg[63:40] <= {3'b111, latched_poc[7:0], 6'b100001, 1'b1, 2'b01, 4'd0};
                    hdr_bits_left <= 7'd24;
                end else begin
                    hdr_shift_reg[63:40] <= {5'b11010, latched_poc[7:0], 5'b10001, 1'b1, 2'b01, 3'd0};
                    hdr_bits_left <= 7'd24;
                end
            end
            6'd27: begin // QP=27, delta=+1
                if (latched_slice_type == SLICE_I) begin
                    hdr_shift_reg[63:48] <= 16'hAC48;
                    hdr_bits_left <= 7'd16;
                end else if (latched_slice_type == SLICE_B) begin
                    hdr_shift_reg[63:40] <= {3'b111, latched_poc[7:0], 6'b100001, 3'b010, 2'b01, 2'd0};
                    hdr_bits_left <= 7'd24;
                end else begin
                    hdr_shift_reg[63:40] <= {5'b11010, latched_poc[7:0], 5'b10001, 3'b010, 2'b01, 1'd0};
                    hdr_bits_left <= 7'd24;
                end
            end
            6'd28: begin // QP=28, delta=+2
                if (latched_slice_type == SLICE_I) begin
                    hdr_shift_reg[63:48] <= 16'hAC22;
                    hdr_bits_left <= 7'd16;
                end else if (latched_slice_type == SLICE_B) begin
                    hdr_shift_reg[63:40] <= {3'b111, latched_poc[7:0], 6'b100001, 5'b00100, 2'b01};
                    hdr_bits_left <= 7'd24;
                end else begin
                    hdr_shift_reg[63:32] <= {5'b11010, latched_poc[7:0], 5'b10001, 5'b00100, 2'b01, 7'd0};
                    hdr_bits_left <= 7'd32;
                end
            end
            6'd29: begin // QP=29, delta=+3
                if (latched_slice_type == SLICE_I) begin
                    hdr_shift_reg[63:48] <= 16'hAC32;
                    hdr_bits_left <= 7'd16;
                end else if (latched_slice_type == SLICE_B) begin
                    hdr_shift_reg[63:40] <= {3'b111, latched_poc[7:0], 6'b100001, 5'b00110, 2'b01};
                    hdr_bits_left <= 7'd24;
                end else begin
                    hdr_shift_reg[63:32] <= {5'b11010, latched_poc[7:0], 5'b10001, 5'b00110, 2'b01, 7'd0};
                    hdr_bits_left <= 7'd32;
                end
            end
            6'd30: begin // QP=30, delta=+4
                if (latched_slice_type == SLICE_I) begin
                    hdr_shift_reg[63:40] <= 24'hAC1080;
                    hdr_bits_left <= 7'd24;
                end else if (latched_slice_type == SLICE_B) begin
                    hdr_shift_reg[63:32] <= {3'b111, latched_poc[7:0], 6'b100001, 7'b0001000, 2'b01, 6'd0};
                    hdr_bits_left <= 7'd32;
                end else begin
                    hdr_shift_reg[63:32] <= {5'b11010, latched_poc[7:0], 5'b10001, 7'b0001000, 2'b01, 5'd0};
                    hdr_bits_left <= 7'd32;
                end
            end
            6'd31: begin // QP=31, delta=+5
                if (latched_slice_type == SLICE_I) begin
                    hdr_shift_reg[63:40] <= 24'hAC1480;
                    hdr_bits_left <= 7'd24;
                end else if (latched_slice_type == SLICE_B) begin
                    hdr_shift_reg[63:32] <= {3'b111, latched_poc[7:0], 6'b100001, 7'b0001010, 2'b01, 6'd0};
                    hdr_bits_left <= 7'd32;
                end else begin
                    hdr_shift_reg[63:32] <= {5'b11010, latched_poc[7:0], 5'b10001, 7'b0001010, 2'b01, 5'd0};
                    hdr_bits_left <= 7'd32;
                end
            end
            6'd32: begin // QP=32, delta=+6
                if (latched_slice_type == SLICE_I) begin
                    hdr_shift_reg[63:40] <= 24'hAC1880;
                    hdr_bits_left <= 7'd24;
                end else if (latched_slice_type == SLICE_B) begin
                    hdr_shift_reg[63:32] <= {3'b111, latched_poc[7:0], 6'b100001, 7'b0001100, 2'b01, 6'd0};
                    hdr_bits_left <= 7'd32;
                end else begin
                    hdr_shift_reg[63:32] <= {5'b11010, latched_poc[7:0], 5'b10001, 7'b0001100, 2'b01, 5'd0};
                    hdr_bits_left <= 7'd32;
                end
            end
            6'd33: begin // QP=33, delta=+7
                if (latched_slice_type == SLICE_I) begin
                    hdr_shift_reg[63:40] <= 24'hAC1C80;
                    hdr_bits_left <= 7'd24;
                end else if (latched_slice_type == SLICE_B) begin
                    hdr_shift_reg[63:32] <= {3'b111, latched_poc[7:0], 6'b100001, 7'b0001110, 2'b01, 6'd0};
                    hdr_bits_left <= 7'd32;
                end else begin
                    hdr_shift_reg[63:32] <= {5'b11010, latched_poc[7:0], 5'b10001, 7'b0001110, 2'b01, 5'd0};
                    hdr_bits_left <= 7'd32;
                end
            end
            6'd34: begin // QP=34, delta=+8
                if (latched_slice_type == SLICE_I) begin
                    hdr_shift_reg[63:40] <= 24'hAC0820;
                    hdr_bits_left <= 7'd24;
                end else if (latched_slice_type == SLICE_B) begin
                    hdr_shift_reg[63:32] <= {3'b111, latched_poc[7:0], 6'b100001, 9'b000010000, 2'b01, 4'd0};
                    hdr_bits_left <= 7'd32;
                end else begin
                    hdr_shift_reg[63:32] <= {5'b11010, latched_poc[7:0], 5'b10001, 9'b000010000, 2'b01, 3'd0};
                    hdr_bits_left <= 7'd32;
                end
            end
            6'd35: begin // QP=35, delta=+9
                if (latched_slice_type == SLICE_I) begin
                    hdr_shift_reg[63:40] <= 24'hAC0920;
                    hdr_bits_left <= 7'd24;
                end else if (latched_slice_type == SLICE_B) begin
                    hdr_shift_reg[63:32] <= {3'b111, latched_poc[7:0], 6'b100001, 9'b000010010, 2'b01, 4'd0};
                    hdr_bits_left <= 7'd32;
                end else begin
                    hdr_shift_reg[63:32] <= {5'b11010, latched_poc[7:0], 5'b10001, 9'b000010010, 2'b01, 3'd0};
                    hdr_bits_left <= 7'd32;
                end
            end
            6'd36: begin // QP=36, delta=+10
                if (latched_slice_type == SLICE_I) begin
                    hdr_shift_reg[63:40] <= 24'hAC0A20;
                    hdr_bits_left <= 7'd24;
                end else if (latched_slice_type == SLICE_B) begin
                    hdr_shift_reg[63:32] <= {3'b111, latched_poc[7:0], 6'b100001, 9'b000010100, 2'b01, 4'd0};
                    hdr_bits_left <= 7'd32;
                end else begin
                    hdr_shift_reg[63:32] <= {5'b11010, latched_poc[7:0], 5'b10001, 9'b000010100, 2'b01, 3'd0};
                    hdr_bits_left <= 7'd32;
                end
            end
            6'd37: begin // QP=37, delta=+11
                if (latched_slice_type == SLICE_I) begin
                    hdr_shift_reg[63:40] <= 24'hAC0B20;
                    hdr_bits_left <= 7'd24;
                end else if (latched_slice_type == SLICE_B) begin
                    hdr_shift_reg[63:32] <= {3'b111, latched_poc[7:0], 6'b100001, 9'b000010110, 2'b01, 4'd0};
                    hdr_bits_left <= 7'd32;
                end else begin
                    hdr_shift_reg[63:32] <= {5'b11010, latched_poc[7:0], 5'b10001, 9'b000010110, 2'b01, 3'd0};
                    hdr_bits_left <= 7'd32;
                end
            end
            6'd38: begin // QP=38, delta=+12
                if (latched_slice_type == SLICE_I) begin
                    hdr_shift_reg[63:40] <= 24'hAC0C20;
                    hdr_bits_left <= 7'd24;
                end else if (latched_slice_type == SLICE_B) begin
                    hdr_shift_reg[63:32] <= {3'b111, latched_poc[7:0], 6'b100001, 9'b000011000, 2'b01, 4'd0};
                    hdr_bits_left <= 7'd32;
                end else begin
                    hdr_shift_reg[63:32] <= {5'b11010, latched_poc[7:0], 5'b10001, 9'b000011000, 2'b01, 3'd0};
                    hdr_bits_left <= 7'd32;
                end
            end
            6'd39: begin // QP=39, delta=+13
                if (latched_slice_type == SLICE_I) begin
                    hdr_shift_reg[63:40] <= 24'hAC0D20;
                    hdr_bits_left <= 7'd24;
                end else if (latched_slice_type == SLICE_B) begin
                    hdr_shift_reg[63:32] <= {3'b111, latched_poc[7:0], 6'b100001, 9'b000011010, 2'b01, 4'd0};
                    hdr_bits_left <= 7'd32;
                end else begin
                    hdr_shift_reg[63:32] <= {5'b11010, latched_poc[7:0], 5'b10001, 9'b000011010, 2'b01, 3'd0};
                    hdr_bits_left <= 7'd32;
                end
            end
            6'd40: begin // QP=40, delta=+14
                if (latched_slice_type == SLICE_I) begin
                    hdr_shift_reg[63:40] <= 24'hAC0E20;
                    hdr_bits_left <= 7'd24;
                end else if (latched_slice_type == SLICE_B) begin
                    hdr_shift_reg[63:32] <= {3'b111, latched_poc[7:0], 6'b100001, 9'b000011100, 2'b01, 4'd0};
                    hdr_bits_left <= 7'd32;
                end else begin
                    hdr_shift_reg[63:32] <= {5'b11010, latched_poc[7:0], 5'b10001, 9'b000011100, 2'b01, 3'd0};
                    hdr_bits_left <= 7'd32;
                end
            end
            6'd41: begin // QP=41, delta=+15
                if (latched_slice_type == SLICE_I) begin
                    hdr_shift_reg[63:40] <= 24'hAC0F20;
                    hdr_bits_left <= 7'd24;
                end else if (latched_slice_type == SLICE_B) begin
                    hdr_shift_reg[63:32] <= {3'b111, latched_poc[7:0], 6'b100001, 9'b000011110, 2'b01, 4'd0};
                    hdr_bits_left <= 7'd32;
                end else begin
                    hdr_shift_reg[63:32] <= {5'b11010, latched_poc[7:0], 5'b10001, 9'b000011110, 2'b01, 3'd0};
                    hdr_bits_left <= 7'd32;
                end
            end
            6'd42: begin // QP=42, delta=+16
                if (latched_slice_type == SLICE_I) begin
                    hdr_shift_reg[63:40] <= 24'hAC0408;
                    hdr_bits_left <= 7'd24;
                end else if (latched_slice_type == SLICE_B) begin
                    hdr_shift_reg[63:32] <= {3'b111, latched_poc[7:0], 6'b100001, 11'b00000100000, 2'b01, 2'd0};
                    hdr_bits_left <= 7'd32;
                end else begin
                    hdr_shift_reg[63:32] <= {5'b11010, latched_poc[7:0], 5'b10001, 11'b00000100000, 2'b01, 1'd0};
                    hdr_bits_left <= 7'd32;
                end
            end
            6'd43: begin // QP=43, delta=+17
                if (latched_slice_type == SLICE_I) begin
                    hdr_shift_reg[63:40] <= 24'hAC0448;
                    hdr_bits_left <= 7'd24;
                end else if (latched_slice_type == SLICE_B) begin
                    hdr_shift_reg[63:32] <= {3'b111, latched_poc[7:0], 6'b100001, 11'b00000100010, 2'b01, 2'd0};
                    hdr_bits_left <= 7'd32;
                end else begin
                    hdr_shift_reg[63:32] <= {5'b11010, latched_poc[7:0], 5'b10001, 11'b00000100010, 2'b01, 1'd0};
                    hdr_bits_left <= 7'd32;
                end
            end
            6'd44: begin // QP=44, delta=+18
                if (latched_slice_type == SLICE_I) begin
                    hdr_shift_reg[63:40] <= 24'hAC0488;
                    hdr_bits_left <= 7'd24;
                end else if (latched_slice_type == SLICE_B) begin
                    hdr_shift_reg[63:32] <= {3'b111, latched_poc[7:0], 6'b100001, 11'b00000100100, 2'b01, 2'd0};
                    hdr_bits_left <= 7'd32;
                end else begin
                    hdr_shift_reg[63:32] <= {5'b11010, latched_poc[7:0], 5'b10001, 11'b00000100100, 2'b01, 1'd0};
                    hdr_bits_left <= 7'd32;
                end
            end
            default: begin // Default QP=29
                if (latched_slice_type == SLICE_I) begin
                    hdr_shift_reg[63:48] <= 16'hAC32;
                    hdr_bits_left <= 7'd16;
                end else if (latched_slice_type == SLICE_B) begin
                    hdr_shift_reg[63:40] <= {3'b111, latched_poc[7:0], 6'b100001, 5'b00110, 2'b01};
                    hdr_bits_left <= 7'd24;
                end else begin
                    hdr_shift_reg[63:32] <= {5'b11010, latched_poc[7:0], 5'b10001, 5'b00110, 2'b01, 7'd0};
                    hdr_bits_left <= 7'd32;
                end
            end
        endcase