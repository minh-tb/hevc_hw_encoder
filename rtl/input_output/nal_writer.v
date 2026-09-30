//=============================================================================
// nal_writer.v
// NAL Unit Framer — Annex B Start Codes + RBSP Byte Stuffing
//
// Mapped from HM source:
//   TLibEncoder/TEncGOP.cpp    writeAllRBSPData() / xWriteNalUnit()
//   TLibCommon/TComBitStream.cpp  convertRBSPToPayload()
//
// HEVC spec:
//   Section 7.4.1   NAL unit structure
//   Annex B         Byte stream NAL unit syntax
//
// Function:
//   Takes raw RBSP bytes from output_fifo and:
//   1. Prepends Annex B start code:
//        Slice NAL:         00 00 00 01  (4-byte start code)
//        VPS/SPS/PPS/AUD:  00 00 00 01  (always 4-byte for parameter sets)
//   2. Writes NAL unit header (2 bytes, HEVC spec 7.3.1.2):
//        nal_unit_type[5:0] at bits [14:9]
//        nuh_layer_id[5:0]  at bits [8:3]  (always 0 for main profile)
//        nuh_temporal_id[2:0] at bits [2:0] minus 1 (temporal_id+1)
//   3. Applies RBSP byte stuffing (emulation prevention):
//        If 3-byte sequence 00 00 03 would appear in RBSP, insert 03
//        (emulation_prevention_three_byte)
//   4. Writes RBSP payload bytes
//
// NAL types generated (from parameter_pkg.vh):
//   NAL_VPS_NUT  (32) — once at stream start
//   NAL_SPS_NUT  (33) — once per IDR/CRA (ReWriteParamSetsFlag=1)
//   NAL_PPS_NUT  (34) — same as SPS
//   NAL_AUD_NUT  (35) — Access Unit Delimiter (optional)
//   NAL_CRA_NUT  (21) — CRA IRAP (DecodingRefreshType=1)
//   NAL_TRAIL_R  (1)  — regular trailing slice
//
// Pipeline:
//   State machine processes one byte per cycle.
//   Emulation prevention inserts an extra byte when needed (stalls 1 cycle).
//   Output: byte stream to str.bin via external DMA/FIFO.
//=============================================================================

`include "parameter_pkg.vh"
`include "hevc_interfaces.vh"

module nal_writer (
    input  wire         clk,
    input  wire         rst_n,

    //=========================================================================
    // Control — called once per NAL unit
    //=========================================================================
    input  wire         nal_start,          // pulse: begin new NAL unit
    input  wire [5:0]   nal_type,           // NAL_VPS_NUT, NAL_SPS_NUT, etc.
    input  wire [2:0]   temporal_id,        // 0..6 (nuh_temporal_id_plus1 = +1)
    input  wire         nal_end,            // pulse: all RBSP bytes sent

    //=========================================================================
    // RBSP input — from output_fifo
    //=========================================================================
    input  wire         rbsp_valid,
    output wire         rbsp_ready,
    input  wire [7:0]   rbsp_byte,
    input  wire         rbsp_last,          // last byte of this NAL

    //=========================================================================
    // Byte stream output — to external DMA / str.bin
    //=========================================================================
    output reg          out_valid,
    input  wire         out_ready,
    output reg  [7:0]   out_byte,
    output reg          out_last_in_nal,    // last byte of current NAL

    //=========================================================================
    // Status
    //=========================================================================
    output reg  [31:0]  nal_byte_count,     // bytes written in current NAL
    output reg  [31:0]  total_nal_count     // total NAL units written
);

    //-------------------------------------------------------------------------
    // FSM states
    //-------------------------------------------------------------------------
    localparam S_IDLE        = 4'd0;
    localparam S_START_CODE  = 4'd1;   // write 00 00 00 01
    localparam S_NAL_HDR0    = 4'd2;   // write NAL header byte 0
    localparam S_NAL_HDR1    = 4'd3;   // write NAL header byte 1
    localparam S_RBSP        = 4'd4;   // write RBSP payload bytes
    localparam S_EPB         = 4'd5;   // insert emulation prevention byte 03
    localparam S_DONE        = 4'd6;

    reg [3:0]  state;
    reg [1:0]  sc_cnt;      // start code byte counter (0=0x00, 1=0x00, 2=0x00, 3=0x01)
    reg [5:0]  cur_nal_type;
    reg [2:0]  cur_temp_id;

    //-------------------------------------------------------------------------
    // NAL unit header (HEVC spec 7.3.1.2)
    // forbidden_zero_bit   [15]     = 0
    // nal_unit_type        [14:9]   = nal_type (6 bits)
    // nuh_layer_id         [8:3]    = 0 (main profile)
    // nuh_temporal_id_plus1[2:0]    = temporal_id + 1
    //
    // Byte 0: bits[15:8] = {0, nal_type[5:0], 1'b0} — first bit of layer_id
    // Byte 1: bits[7:0]  = {5'b0, temporal_id+1[2:0]}
    //-------------------------------------------------------------------------
    wire [15:0] nal_header = {1'b0, cur_nal_type, 6'b000000, (cur_temp_id + 3'd1)};
    wire [7:0]  nal_hdr_b0 = nal_header[15:8];
    wire [7:0]  nal_hdr_b1 = nal_header[7:0];

    //-------------------------------------------------------------------------
    // Emulation prevention detection
    // Track last two bytes written to RBSP output.
    // If the sequence 0x00 0x00 would be followed by 0x00, 0x01, 0x02, 0x03:
    // insert 0x03 before the third byte.
    //
    // HM: TComBitStream.cpp convertRBSPToPayload()
    //   if (prev_prev == 0x00 && prev == 0x00 && cur <= 0x03) insert 0x03
    //-------------------------------------------------------------------------
    reg [7:0]  prev0, prev1;    // two most recently written payload bytes
    reg        inserting_epb;   // 1 while inserting emulation prevention byte

    wire need_epb = (prev0 == 8'h00) && (prev1 == 8'h00) &&
                    (rbsp_byte <= 8'h03) && rbsp_valid;

    //-------------------------------------------------------------------------
    // rbsp_ready: accept RBSP byte when in RBSP state and not inserting EPB
    //-------------------------------------------------------------------------
    assign rbsp_ready = (state == S_RBSP) && !need_epb &&
                        (out_ready || !out_valid);

    //-------------------------------------------------------------------------
    // Main FSM
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            sc_cnt        <= 2'd0;
            out_valid     <= 1'b0;
            out_byte      <= 8'h00;
            out_last_in_nal <= 1'b0;
            nal_byte_count<= 32'd0;
            total_nal_count<=32'd0;
            prev0         <= 8'hFF;
            prev1         <= 8'hFF;
            inserting_epb <= 1'b0;
            cur_nal_type  <= 6'd0;
            cur_temp_id   <= 3'd0;
        end else begin
            case (state)
                //--------------------------------------------------------------
                S_IDLE: begin
                    out_valid       <= 1'b0;
                    out_last_in_nal <= 1'b0;
                    if (nal_start) begin
                        cur_nal_type   <= nal_type;
                        cur_temp_id    <= temporal_id;
                        sc_cnt         <= 2'd0;
                        nal_byte_count <= 32'd0;
                        prev0          <= 8'hFF;   // reset EPB history
                        prev1          <= 8'hFF;
                        state          <= S_START_CODE;
                    end
                end

                //--------------------------------------------------------------
                // Write 4-byte start code: 0x00 0x00 0x00 0x01
                //--------------------------------------------------------------
                S_START_CODE: begin
                    if (out_ready || !out_valid) begin
                        out_valid <= 1'b1;
                        case (sc_cnt)
                            2'd0: out_byte <= 8'h00;
                            2'd1: out_byte <= 8'h00;
                            2'd2: out_byte <= 8'h00;
                            2'd3: out_byte <= 8'h01;
                        endcase
                        out_last_in_nal <= 1'b0;
                        nal_byte_count  <= nal_byte_count + 32'd1;

                        if (sc_cnt == 2'd3) begin
                            sc_cnt <= 2'd0;
                            state  <= S_NAL_HDR0;
                        end else begin
                            sc_cnt <= sc_cnt + 2'd1;
                        end
                    end
                end

                //--------------------------------------------------------------
                // NAL header byte 0
                //--------------------------------------------------------------
                S_NAL_HDR0: begin
                    if (out_ready || !out_valid) begin
                        out_valid      <= 1'b1;
                        out_byte       <= nal_hdr_b0;
                        out_last_in_nal<= 1'b0;
                        nal_byte_count <= nal_byte_count + 32'd1;
                        state          <= S_NAL_HDR1;
                    end
                end

                //--------------------------------------------------------------
                // NAL header byte 1
                //--------------------------------------------------------------
                S_NAL_HDR1: begin
                    if (out_ready || !out_valid) begin
                        out_valid      <= 1'b1;
                        out_byte       <= nal_hdr_b1;
                        out_last_in_nal<= 1'b0;
                        nal_byte_count <= nal_byte_count + 32'd1;
                        state          <= S_RBSP;
                    end
                end

                //--------------------------------------------------------------
                // RBSP payload — with emulation prevention
                //--------------------------------------------------------------
                S_RBSP: begin
                    if (nal_end && !rbsp_valid && (!out_valid || out_ready)) begin
                        total_nal_count <= total_nal_count + 32'd1;
                        state <= S_DONE;
                    end else if (out_ready || !out_valid) begin
                        if (need_epb && !inserting_epb) begin
                            // Insert emulation prevention byte 0x03 first
                            out_valid      <= 1'b1;
                            out_byte       <= 8'h03;
                            out_last_in_nal<= 1'b0;
                            nal_byte_count <= nal_byte_count + 32'd1;
                            prev1          <= prev0;
                            prev0          <= 8'h03;
                            inserting_epb  <= 1'b1;
                            // Stay in S_RBSP, don't advance rbsp input
                        end else begin
                            // Write the actual RBSP byte
                            inserting_epb  <= 1'b0;
                            if (rbsp_valid) begin
                                out_valid      <= 1'b1;
                                out_byte       <= rbsp_byte;
                                out_last_in_nal<= rbsp_last;
                                nal_byte_count <= nal_byte_count + 32'd1;
                                prev1          <= prev0;
                                prev0          <= rbsp_byte;

                                if (rbsp_last) begin
                                    total_nal_count <= total_nal_count + 32'd1;
                                    state <= S_DONE;
                                end
                            end else begin
                                out_valid <= 1'b0;
                            end
                        end
                    end
                end

                //--------------------------------------------------------------
                S_DONE: begin
                    if (out_ready || !out_valid) begin
                        out_valid       <= 1'b0;
                        out_last_in_nal <= 1'b0;
                        state           <= S_IDLE;
                    end
                end

            endcase
        end
    end

    //-------------------------------------------------------------------------
    // Simulation checks
    //-------------------------------------------------------------------------
    // synthesis translate_off
    always @(posedge clk) begin
        if (rst_n && state == S_DONE)
            $display("INFO  [nal_writer] NAL done type=%0d bytes=%0d total_nals=%0d t=%0t",
                     cur_nal_type, nal_byte_count, total_nal_count, $time);
        if (rst_n && state == S_RBSP && inserting_epb)
            $display("INFO  [nal_writer] EPB inserted before 0x%02X at byte %0d",
                     rbsp_byte, nal_byte_count);
    end
    // synthesis translate_on

endmodule