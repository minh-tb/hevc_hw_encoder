//=============================================================================
// param_set_writer.v
// Standard HEVC NAL Header & Parameter Set Writer (VPS / SPS / PPS)
// Main 10 Profile, 10-bit Depth, 64x64 CTU, SAO=1, MinCB=8, MaxCB=64
// Supports 64x64 (1 CTU), 128x128 (4 CTUs), and 256x256 (16 CTUs)
//=============================================================================

`timescale 1ns / 1ps

`include "parameter_pkg.vh"

module param_set_writer #(
    parameter FRAME_WIDTH  = `DEFAULT_FRAME_WIDTH,
    parameter FRAME_HEIGHT = `DEFAULT_FRAME_HEIGHT
)(
    input  wire        clk,
    input  wire        rst_n,
    
    input  wire        vps_req,
    input  wire        sps_req,
    input  wire        pps_req,
    output reg         vps_done,
    output reg         sps_done,
    output reg         pps_done,
    
    output reg         rbsp_valid,
    input  wire        rbsp_ready,
    output reg  [7:0]  rbsp_byte,
    output reg         rbsp_last
);

    // Defensive Elaboration Check
    initial begin
        if (FRAME_WIDTH != 64 && FRAME_WIDTH != 128 && FRAME_WIDTH != 256 && FRAME_WIDTH != 1920 && FRAME_WIDTH != 3840) begin
            $fatal(1, "[ROM MISSING] param_set_writer requires generating an SPS ROM for FRAME_WIDTH=%0d!", FRAME_WIDTH);
        end
        if (FRAME_HEIGHT != 64 && FRAME_HEIGHT != 128 && FRAME_HEIGHT != 256 && FRAME_HEIGHT != 1080 && FRAME_HEIGHT != 1088 && FRAME_HEIGHT != 2160) begin
            $fatal(1, "[ROM MISSING] param_set_writer requires generating an SPS ROM for FRAME_HEIGHT=%0d!", FRAME_HEIGHT);
        end
    end

    localparam VPS_LEN = 18;
    localparam MAX_SPS_LEN = 27;
    localparam SPS_LEN = (FRAME_WIDTH == 64 && FRAME_HEIGHT == 64) ? 24 :
                         (FRAME_WIDTH == 3840 && FRAME_HEIGHT == 2160) ? 27 :
                         ((FRAME_WIDTH == 1920 && FRAME_HEIGHT == 1080) || (FRAME_WIDTH == 1920 && FRAME_HEIGHT == 1088)) ? 26 : 25;
    localparam PPS_LEN = 4;
    
    reg [7:0] vps_rom [0:VPS_LEN-1];
    reg [7:0] sps_rom [0:MAX_SPS_LEN-1];
    reg [7:0] pps_rom [0:PPS_LEN-1];
    
    integer rom_i;
    initial begin
        // Initialize SPS ROM buffer to zero
        for (rom_i = 0; rom_i < MAX_SPS_LEN; rom_i = rom_i + 1) begin
            sps_rom[rom_i] = 8'd0;
        end

        // VPS: NAL Type 32 (Raw RBSP) — Main10 profile, 10-bit
        vps_rom[0]  = 8'h0C; vps_rom[1]  = 8'h01; vps_rom[2]  = 8'hFF; vps_rom[3]  = 8'hFF; vps_rom[4]  = 8'h02; vps_rom[5]  = 8'h20;
        vps_rom[6]  = 8'h00; vps_rom[7]  = 8'h00; vps_rom[8]  = 8'h00; vps_rom[9]  = 8'h90; vps_rom[10] = 8'h00; vps_rom[11] = 8'h00;
        vps_rom[12] = 8'h00; vps_rom[13] = 8'h00; vps_rom[14] = 8'h00; vps_rom[15] = 8'h00; vps_rom[16] = 8'hAC; vps_rom[17] = 8'h09;

        // PPS: NAL Type 34 (Raw RBSP) — init_qp=26, no SDH, no TS
        pps_rom[0] = 8'hC0; pps_rom[1] = 8'h71; pps_rom[2] = 8'h81; pps_rom[3] = 8'h12;

        if (FRAME_WIDTH == 128 && FRAME_HEIGHT == 128) begin
            // SPS 128x128 (25 bytes) — strong_intra_smoothing_enable_flag = 1 (byte 23: 8'hE4)
            sps_rom[0]  = 8'h01; sps_rom[1]  = 8'h02; sps_rom[2]  = 8'h20; sps_rom[3]  = 8'h00; sps_rom[4]  = 8'h00; sps_rom[5]  = 8'h00;
            sps_rom[6]  = 8'h90; sps_rom[7]  = 8'h00; sps_rom[8]  = 8'h00; sps_rom[9]  = 8'h00; sps_rom[10] = 8'h00; sps_rom[11] = 8'h00;
            sps_rom[12] = 8'h00; sps_rom[13] = 8'hA0; sps_rom[14] = 8'h10; sps_rom[15] = 8'h20; sps_rom[16] = 8'h20; sps_rom[17] = 8'h4D;
            sps_rom[18] = 8'h96; sps_rom[19] = 8'hB9; sps_rom[20] = 8'h24; sps_rom[21] = 8'h6C; sps_rom[22] = 8'h92; sps_rom[23] = 8'hE4;
            sps_rom[24] = 8'h80;
        end else if (FRAME_WIDTH == 256 && FRAME_HEIGHT == 256) begin
            // SPS 256x256 (25 bytes)
            sps_rom[0]  = 8'h01; sps_rom[1]  = 8'h02; sps_rom[2]  = 8'h20; sps_rom[3]  = 8'h00; sps_rom[4]  = 8'h00; sps_rom[5]  = 8'h00;
            sps_rom[6]  = 8'h90; sps_rom[7]  = 8'h00; sps_rom[8]  = 8'h00; sps_rom[9]  = 8'h00; sps_rom[10] = 8'h00; sps_rom[11] = 8'h00;
            sps_rom[12] = 8'h00; sps_rom[13] = 8'hA0; sps_rom[14] = 8'h08; sps_rom[15] = 8'h08; sps_rom[16] = 8'h04; sps_rom[17] = 8'h04;
            sps_rom[18] = 8'hD9; sps_rom[19] = 8'h6B; sps_rom[20] = 8'h92; sps_rom[21] = 8'h46; sps_rom[22] = 8'hC9; sps_rom[23] = 8'h2E;
            sps_rom[24] = 8'h48;
        end else if (FRAME_WIDTH == 1920 && FRAME_HEIGHT == 1080) begin
            // SPS 1920x1080 Full HD (26 bytes) — strong_intra_smoothing_enable_flag = 1
            sps_rom[0]  = 8'h01; sps_rom[1]  = 8'h02; sps_rom[2]  = 8'h20; sps_rom[3]  = 8'h00; sps_rom[4]  = 8'h00; sps_rom[5]  = 8'h00;
            sps_rom[6]  = 8'h90; sps_rom[7]  = 8'h00; sps_rom[8]  = 8'h00; sps_rom[9]  = 8'h00; sps_rom[10] = 8'h00; sps_rom[11] = 8'h00;
            sps_rom[12] = 8'h00; sps_rom[13] = 8'hA0; sps_rom[14] = 8'h03; sps_rom[15] = 8'hC0; sps_rom[16] = 8'h80; sps_rom[17] = 8'h10;
            sps_rom[18] = 8'hE4; sps_rom[19] = 8'hD9; sps_rom[20] = 8'h6B; sps_rom[21] = 8'h92; sps_rom[22] = 8'h46; sps_rom[23] = 8'hC9;
            sps_rom[24] = 8'h2E; sps_rom[25] = 8'h48;
        end else if (FRAME_WIDTH == 1920 && FRAME_HEIGHT == 1088) begin
            // SPS 1920x1088 CTU-Aligned Full HD (26 bytes) — strong_intra_smoothing_enable_flag = 1
            sps_rom[0]  = 8'h01; sps_rom[1]  = 8'h02; sps_rom[2]  = 8'h20; sps_rom[3]  = 8'h00; sps_rom[4]  = 8'h00; sps_rom[5]  = 8'h00;
            sps_rom[6]  = 8'h90; sps_rom[7]  = 8'h00; sps_rom[8]  = 8'h00; sps_rom[9]  = 8'h00; sps_rom[10] = 8'h00; sps_rom[11] = 8'h00;
            sps_rom[12] = 8'h00; sps_rom[13] = 8'hA0; sps_rom[14] = 8'h03; sps_rom[15] = 8'hC0; sps_rom[16] = 8'h80; sps_rom[17] = 8'h11;
            sps_rom[18] = 8'h04; sps_rom[19] = 8'hD9; sps_rom[20] = 8'h6B; sps_rom[21] = 8'h92; sps_rom[22] = 8'h46; sps_rom[23] = 8'hC9;
            sps_rom[24] = 8'h2E; sps_rom[25] = 8'h48;
        end else if (FRAME_WIDTH == 3840 && FRAME_HEIGHT == 2160) begin
            // SPS 3840x2160 4K UHD (27 bytes) — strong_intra_smoothing_enable_flag = 1
            sps_rom[0]  = 8'h01; sps_rom[1]  = 8'h02; sps_rom[2]  = 8'h20; sps_rom[3]  = 8'h00; sps_rom[4]  = 8'h00; sps_rom[5]  = 8'h00;
            sps_rom[6]  = 8'h90; sps_rom[7]  = 8'h00; sps_rom[8]  = 8'h00; sps_rom[9]  = 8'h00; sps_rom[10] = 8'h00; sps_rom[11] = 8'h00;
            sps_rom[12] = 8'h00; sps_rom[13] = 8'hA0; sps_rom[14] = 8'h01; sps_rom[15] = 8'hE0; sps_rom[16] = 8'h20; sps_rom[17] = 8'h02;
            sps_rom[18] = 8'h1C; sps_rom[19] = 8'h4D; sps_rom[20] = 8'h96; sps_rom[21] = 8'hB9; sps_rom[22] = 8'h24; sps_rom[23] = 8'h6C;
            sps_rom[24] = 8'h92; sps_rom[25] = 8'hE4; sps_rom[26] = 8'h80;
        end else begin
            // SPS 64x64 (24 bytes)
            sps_rom[0]  = 8'h01; sps_rom[1]  = 8'h02; sps_rom[2]  = 8'h20; sps_rom[3]  = 8'h00; sps_rom[4]  = 8'h00; sps_rom[5]  = 8'h00;
            sps_rom[6]  = 8'h90; sps_rom[7]  = 8'h00; sps_rom[8]  = 8'h00; sps_rom[9]  = 8'h00; sps_rom[10] = 8'h00; sps_rom[11] = 8'h00;
            sps_rom[12] = 8'h00; sps_rom[13] = 8'hA0; sps_rom[14] = 8'h20; sps_rom[15] = 8'h81; sps_rom[16] = 8'h04; sps_rom[17] = 8'hD9;
            sps_rom[18] = 8'h6B; sps_rom[19] = 8'h92; sps_rom[20] = 8'h46; sps_rom[21] = 8'hC9; sps_rom[22] = 8'h2E; sps_rom[23] = 8'h48;
        end
    end
    
    reg [2:0] state;
    localparam S_IDLE = 3'd0;
    localparam S_VPS  = 3'd1;
    localparam S_SPS  = 3'd2;
    localparam S_PPS  = 3'd3;
    
    reg [6:0] ptr;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            ptr        <= 7'd0;
            vps_done   <= 1'b0;
            sps_done   <= 1'b0;
            pps_done   <= 1'b0;
            rbsp_valid <= 1'b0;
            rbsp_last  <= 1'b0;
        end else begin
            vps_done   <= 1'b0;
            sps_done   <= 1'b0;
            pps_done   <= 1'b0;
            rbsp_valid <= 1'b0;
            rbsp_last  <= 1'b0;
            
            case (state)
                S_IDLE: begin
                    if (vps_req) begin
                        state <= S_VPS;
                        ptr   <= 7'd0;
                    end else if (sps_req) begin
                        state <= S_SPS;
                        ptr   <= 7'd0;
                    end else if (pps_req) begin
                        state <= S_PPS;
                        ptr   <= 7'd0;
                    end
                end
                
                S_VPS: begin
                    if (rbsp_valid && rbsp_ready) begin
                        if (ptr == VPS_LEN - 1) begin
                            state      <= S_IDLE;
                            vps_done   <= 1'b1;
                            rbsp_valid <= 1'b0;
                        end else begin
                            ptr        <= ptr + 7'd1;
                            rbsp_valid <= 1'b1;
                        end
                    end else begin
                        rbsp_valid <= 1'b1;
                    end
                end
                
                S_SPS: begin
                    if (rbsp_valid && rbsp_ready) begin
                        if (ptr == SPS_LEN - 1) begin
                            state      <= S_IDLE;
                            sps_done   <= 1'b1;
                            rbsp_valid <= 1'b0;
                        end else begin
                            ptr        <= ptr + 7'd1;
                            rbsp_valid <= 1'b1;
                        end
                    end else begin
                        rbsp_valid <= 1'b1;
                    end
                end
                
                S_PPS: begin
                    if (rbsp_valid && rbsp_ready) begin
                        if (ptr == PPS_LEN - 1) begin
                            state      <= S_IDLE;
                            pps_done   <= 1'b1;
                            rbsp_valid <= 1'b0;
                        end else begin
                            ptr        <= ptr + 7'd1;
                            rbsp_valid <= 1'b1;
                        end
                    end else begin
                        rbsp_valid <= 1'b1;
                    end
                end
            endcase
        end
    end
    
    always @(*) begin
        rbsp_byte = 8'd0;
        if (state == S_VPS) rbsp_byte = vps_rom[ptr];
        if (state == S_SPS) rbsp_byte = sps_rom[ptr];
        if (state == S_PPS) rbsp_byte = pps_rom[ptr];
    end

endmodule
