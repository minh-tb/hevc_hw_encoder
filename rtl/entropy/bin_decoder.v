//=============================================================================
// bin_decoder.v
// HEVC CABAC Arithmetic Range Decoder
//
// Mapped from HM source:
//   TLibDecoder/TDecBinCABAC.cpp :: decodeBin(), decodeBinEP(), decodeBinTrm()
//                                   init(), initDecoderState()
//   TLibDecoder/TDecBinCABAC.h   :: m_uiRange, m_uiValue
//   TLibCommon/TComCABACTables.h :: g_aucLPSTable[64][4]
//
// HM decodeBin() core:
//
//   Uint uiLPS  = g_aucLPSTable[pStateIdx][(m_uiRange >> 6) & 3];
//   m_uiRange  -= uiLPS;
//
//   if (m_uiValue < m_uiRange) {        // MPS decoded
//     ruiBin = rcCtxModel.getMps();
//   } else {                             // LPS decoded
//     ruiBin       = 1 - rcCtxModel.getMps();
//     m_uiValue   -= m_uiRange;
//     m_uiRange    = uiLPS;
//   }
//   rcCtxModel.update(ruiBin);
//
//   Renormalize: while range < 256, shift in new bits from stream
//   while (m_uiRange < 256) {
//     m_uiRange <<= 1;
//     m_uiValue   = (m_uiValue << 1) | readBit();
//   }
//
// HM initialization (HEVC spec 9.3.2.6):
//   Read 9 bits from bitstream → codIValue
//   codIRange = 510
//
// HM decodeBinEP() bypass:
//   m_uiValue = (m_uiValue << 1) | readBit();
//   if (m_uiValue >= m_uiRange) { bin=1; m_uiValue -= m_uiRange; }
//   else                          { bin=0; }
//
// HM decodeBinTrm():
//   m_uiRange -= 2;
//   if (m_uiValue >= m_uiRange) bin=1;
//   else { bin=0; renorm(); }
//
// Architecture — 4-state FSM:
//
//   S_INIT   : Read 9 bits from bitstream to initialize codIValue (9 cycles)
//   S_READY  : Accept decode request; compute pLPS; determine MPS/LPS
//   S_RENORM : Shift codIRange/codIValue left, read one bit per cycle from
//              bit buffer until codIRange >= 256 (≤7 cycles, avg ~1.5)
//   S_FILL   : Stall while waiting for the byte input to refill bit buffer
//
// Bit buffer:
//   16-bit shift register filled from byte_in (MSB first, HEVC bit order)
//   bits_avail[4:0] tracks valid bits remaining
//   Stalls in S_FILL when bits_avail < renorm shift requirement
//
// Decoder-side ctx_model_store interface:
//   Read:  rd_ctx_id → rd_state    (combinational, same as bin_encoder)
//   Write: upd_valid, upd_ctx_id, upd_bin (1 cycle after decode)
//
// Output:
//   dec_valid   : 1 cycle pulse when bin has been decoded
//   dec_bin     : the decoded bin value (0 or 1)
//   (Syntax decoders read dec_bin only when dec_valid is high)
//
// Throughput:
//   MPS + no renorm : 1 cycle/bin
//   MPS + renorm    : 2 cycles/bin (one renorm step)
//   LPS             : 1 + renorm_steps cycles/bin (avg 2–4)
//   EP (bypass)     : 1 cycle/bin (reads 1 bit, no ctx)
//=============================================================================

`include "parameter_pkg.vh"

module bin_decoder #(
    parameter CTX_ID_W  = 8,    // context index width (covers 0..153)
    parameter BIT_BUF_W = 16    // bit-buffer depth (≥9 for init, 16 for safety)
)(
    input  wire                 clk,
    input  wire                 rst_n,

    // ── Slice init ────────────────────────────────────────────────────────
    // Triggers S_INIT to read 9 initialisation bits from bitstream
    input  wire                 coder_init,    // pulse: begin new slice/segment

    // ── ctx_model_store read port ─────────────────────────────────────────
    output wire [CTX_ID_W-1:0]  rd_ctx_id,
    input  wire [6:0]           rd_state,      // {pStateIdx[5:0], valMPS}

    // ── ctx_model_store write-back port ───────────────────────────────────
    output reg                  upd_valid,
    output reg  [CTX_ID_W-1:0]  upd_ctx_id,
    output reg                  upd_bin,

    // ── Bitstream byte input (from NAL parser) ────────────────────────────
    input  wire                 byte_valid,    // byte available from stream
    input  wire [7:0]           byte_in,       // next byte (MSB = first bit)
    output wire                 byte_ready,    // we can accept a byte

    // ── Decode request (from syntax_cu / syntax_pred / syntax_coeff) ──────
    input  wire                 dec_req,       // request one bin
    input  wire [CTX_ID_W-1:0]  dec_ctx_id,    // context index (ignored if is_ep)
    input  wire                 is_ep,         // 1 = bypass decode
    input  wire                 is_trm,        // 1 = terminating bin decode
    output wire                 dec_ready,     // can accept a request this cycle

    // ── Decoded output ────────────────────────────────────────────────────
    output reg                  dec_valid,     // decoded bin is ready
    output reg                  dec_bin        // decoded bin value (0 or 1)
);

    // =========================================================================
    // LPS probability table — g_aucLPSTable[64][4] (same as range_coder.v)
    // =========================================================================
    function automatic [7:0] lps_table;
        input [5:0] ps;
        input [1:0] qr;
        reg [7:0] t [0:255];
        begin
            t[  0]=8'd128; t[  1]=8'd176; t[  2]=8'd208; t[  3]=8'd240;
            t[  4]=8'd128; t[  5]=8'd167; t[  6]=8'd197; t[  7]=8'd227;
            t[  8]=8'd128; t[  9]=8'd158; t[ 10]=8'd187; t[ 11]=8'd216;
            t[ 12]=8'd123; t[ 13]=8'd150; t[ 14]=8'd178; t[ 15]=8'd205;
            t[ 16]=8'd116; t[ 17]=8'd142; t[ 18]=8'd169; t[ 19]=8'd195;
            t[ 20]=8'd111; t[ 21]=8'd135; t[ 22]=8'd160; t[ 23]=8'd185;
            t[ 24]=8'd105; t[ 25]=8'd128; t[ 26]=8'd152; t[ 27]=8'd175;
            t[ 28]=8'd100; t[ 29]=8'd122; t[ 30]=8'd144; t[ 31]=8'd166;
            t[ 32]= 8'd95; t[ 33]=8'd116; t[ 34]=8'd137; t[ 35]=8'd158;
            t[ 36]= 8'd90; t[ 37]=8'd110; t[ 38]=8'd130; t[ 39]=8'd150;
            t[ 40]= 8'd85; t[ 41]=8'd104; t[ 42]=8'd123; t[ 43]=8'd142;
            t[ 44]= 8'd81; t[ 45]= 8'd99; t[ 46]=8'd117; t[ 47]=8'd135;
            t[ 48]= 8'd77; t[ 49]= 8'd94; t[ 50]=8'd111; t[ 51]=8'd128;
            t[ 52]= 8'd73; t[ 53]= 8'd89; t[ 54]=8'd105; t[ 55]=8'd122;
            t[ 56]= 8'd69; t[ 57]= 8'd85; t[ 58]=8'd100; t[ 59]=8'd116;
            t[ 60]= 8'd66; t[ 61]= 8'd80; t[ 62]= 8'd95; t[ 63]=8'd110;
            t[ 64]= 8'd62; t[ 65]= 8'd76; t[ 66]= 8'd90; t[ 67]=8'd104;
            t[ 68]= 8'd59; t[ 69]= 8'd72; t[ 70]= 8'd86; t[ 71]= 8'd99;
            t[ 72]= 8'd56; t[ 73]= 8'd69; t[ 74]= 8'd81; t[ 75]= 8'd94;
            t[ 76]= 8'd53; t[ 77]= 8'd65; t[ 78]= 8'd77; t[ 79]= 8'd89;
            t[ 80]= 8'd51; t[ 81]= 8'd62; t[ 82]= 8'd73; t[ 83]= 8'd85;
            t[ 84]= 8'd48; t[ 85]= 8'd59; t[ 86]= 8'd69; t[ 87]= 8'd80;
            t[ 88]= 8'd46; t[ 89]= 8'd56; t[ 90]= 8'd66; t[ 91]= 8'd76;
            t[ 92]= 8'd43; t[ 93]= 8'd53; t[ 94]= 8'd63; t[ 95]= 8'd72;
            t[ 96]= 8'd41; t[ 97]= 8'd50; t[ 98]= 8'd59; t[ 99]= 8'd69;
            t[100]= 8'd39; t[101]= 8'd48; t[102]= 8'd56; t[103]= 8'd65;
            t[104]= 8'd37; t[105]= 8'd45; t[106]= 8'd54; t[107]= 8'd62;
            t[108]= 8'd35; t[109]= 8'd43; t[110]= 8'd51; t[111]= 8'd59;
            t[112]= 8'd33; t[113]= 8'd41; t[114]= 8'd48; t[115]= 8'd56;
            t[116]= 8'd32; t[117]= 8'd39; t[118]= 8'd46; t[119]= 8'd53;
            t[120]= 8'd30; t[121]= 8'd37; t[122]= 8'd43; t[123]= 8'd50;
            t[124]= 8'd29; t[125]= 8'd35; t[126]= 8'd41; t[127]= 8'd48;
            t[128]= 8'd27; t[129]= 8'd33; t[130]= 8'd39; t[131]= 8'd45;
            t[132]= 8'd26; t[133]= 8'd31; t[134]= 8'd37; t[135]= 8'd43;
            t[136]= 8'd24; t[137]= 8'd30; t[138]= 8'd35; t[139]= 8'd41;
            t[140]= 8'd23; t[141]= 8'd28; t[142]= 8'd33; t[143]= 8'd39;
            t[144]= 8'd22; t[145]= 8'd27; t[146]= 8'd32; t[147]= 8'd37;
            t[148]= 8'd21; t[149]= 8'd26; t[150]= 8'd30; t[151]= 8'd35;
            t[152]= 8'd20; t[153]= 8'd24; t[154]= 8'd29; t[155]= 8'd33;
            t[156]= 8'd19; t[157]= 8'd23; t[158]= 8'd27; t[159]= 8'd31;
            t[160]= 8'd18; t[161]= 8'd22; t[162]= 8'd26; t[163]= 8'd30;
            t[164]= 8'd17; t[165]= 8'd21; t[166]= 8'd25; t[167]= 8'd28;
            t[168]= 8'd16; t[169]= 8'd20; t[170]= 8'd23; t[171]= 8'd27;
            t[172]= 8'd15; t[173]= 8'd19; t[174]= 8'd22; t[175]= 8'd25;
            t[176]= 8'd14; t[177]= 8'd18; t[178]= 8'd21; t[179]= 8'd24;
            t[180]= 8'd14; t[181]= 8'd17; t[182]= 8'd20; t[183]= 8'd23;
            t[184]= 8'd13; t[185]= 8'd16; t[186]= 8'd19; t[187]= 8'd22;
            t[188]= 8'd12; t[189]= 8'd15; t[190]= 8'd18; t[191]= 8'd21;
            t[192]= 8'd12; t[193]= 8'd14; t[194]= 8'd17; t[195]= 8'd20;
            t[196]= 8'd11; t[197]= 8'd14; t[198]= 8'd16; t[199]= 8'd19;
            t[200]= 8'd11; t[201]= 8'd13; t[202]= 8'd15; t[203]= 8'd18;
            t[204]= 8'd10; t[205]= 8'd12; t[206]= 8'd15; t[207]= 8'd17;
            t[208]= 8'd10; t[209]= 8'd12; t[210]= 8'd14; t[211]= 8'd16;
            t[212]=  8'd9; t[213]= 8'd11; t[214]= 8'd13; t[215]= 8'd15;
            t[216]=  8'd9; t[217]= 8'd11; t[218]= 8'd12; t[219]= 8'd14;
            t[220]=  8'd8; t[221]= 8'd10; t[222]= 8'd12; t[223]= 8'd14;
            t[224]=  8'd8; t[225]=  8'd9; t[226]= 8'd11; t[227]= 8'd13;
            t[228]=  8'd7; t[229]=  8'd9; t[230]= 8'd11; t[231]= 8'd12;
            t[232]=  8'd7; t[233]=  8'd9; t[234]= 8'd10; t[235]= 8'd12;
            t[236]=  8'd7; t[237]=  8'd8; t[238]= 8'd10; t[239]= 8'd11;
            t[240]=  8'd6; t[241]=  8'd8; t[242]=  8'd9; t[243]= 8'd11;
            t[244]=  8'd6; t[245]=  8'd7; t[246]=  8'd9; t[247]= 8'd10;
            t[248]=  8'd6; t[249]=  8'd7; t[250]=  8'd8; t[251]=  8'd9;
            t[252]=  8'd2; t[253]=  8'd2; t[254]=  8'd2; t[255]=  8'd2;
            lps_table = t[{ps, qr}];
        end
    endfunction

    // =========================================================================
    // FSM state encoding
    // =========================================================================
    localparam [1:0]
        S_INIT   = 2'd0,   // reading 9 initialisation bits
        S_READY  = 2'd1,   // accepting decode requests
        S_RENORM = 2'd2;   // renormalising range/value

    reg [1:0] state;

    // =========================================================================
    // M-coder decoder registers (HM: m_uiRange, m_uiValue)
    // =========================================================================
    reg [8:0]  range_r;          // codIRange ∈ [256, 510] after renorm
    reg [8:0]  value_r;          // codIValue ∈ [0, range-1] after renorm

    // =========================================================================
    // Bit buffer — 16-bit shift register fed from byte input (MSB first)
    // =========================================================================
    reg [BIT_BUF_W-1:0] bit_buf;
    reg [4:0]            bits_avail;  // valid bits in bit_buf (0..16)

    // Pending write-back registers
    reg                  wb_pending;
    reg [CTX_ID_W-1:0]   wb_ctx_id;
    reg                  wb_bin;

    // Init counter (count 9 bits for codIValue init)
    reg [3:0] init_cnt;

    // =========================================================================
    // Readiness
    // =========================================================================
    assign dec_ready  = (state == S_READY) && (bits_avail >= 5'd1);
    assign rd_ctx_id  = dec_ctx_id;   // always route to ctx store (combinational)

    // =========================================================================
    // Context state fields (combinational from rd_state)
    // =========================================================================
    wire [5:0] cur_pstate = rd_state[6:1];
    wire        cur_valmps = rd_state[0];

    // =========================================================================
    // Bit buffer read helper — dynamically index LSB-fed shift register
    // =========================================================================
    wire        buf_has_bit = (bits_avail >= 5'd1);
    wire [3:0]  read_idx    = buf_has_bit ? (bits_avail[3:0] - 4'd1) : 4'd0;
    wire        buf_bit     = bit_buf[read_idx];
    wire consume_bit = !coder_init && buf_has_bit && (
                       (state == S_INIT) ||
                       (state == S_READY && dec_req && dec_ready && is_ep) ||
                       (state == S_RENORM)
                       );

    assign byte_ready = (bits_avail <= 5'd8);
    wire append_byte  = byte_valid && byte_ready;
    // =========================================================================
    // Main FSM
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_INIT;
            range_r     <= 9'd510;
            value_r     <= 9'd0;
            bit_buf     <= {BIT_BUF_W{1'b0}};
            bits_avail  <= 5'd0;
            init_cnt    <= 4'd0;
            dec_valid   <= 1'b0;
            dec_bin     <= 1'b0;
            upd_valid   <= 1'b0;
            upd_ctx_id  <= {CTX_ID_W{1'b0}};
            upd_bin     <= 1'b0;
            wb_pending  <= 1'b0;
            wb_ctx_id   <= {CTX_ID_W{1'b0}};
            wb_bin      <= 1'b0;
        end else begin
            // ── Default deassert ───────────────────────────────────────────
            dec_valid  <= 1'b0;
            upd_valid  <= 1'b0;

            // ── Pending ctx write-back ─────────────────────────────────────
            if (wb_pending) begin
                upd_valid  <= 1'b1;
                upd_ctx_id <= wb_ctx_id;
                upd_bin    <= wb_bin;
                wb_pending <= 1'b0;
            end

            // ── Bit buffer updates ─────────────────────────────────────────
            if (append_byte) begin
                bit_buf <= {bit_buf[7:0], byte_in};
            end

            // ── Slice / segment init ───────────────────────────────────────
            if (coder_init) begin
                state      <= S_INIT;
                range_r    <= 9'd510;
                value_r    <= 9'd0;
                init_cnt   <= 4'd0;
                bits_avail <= bits_avail + (append_byte ? 5'd8 : 5'd0);
            end else begin
                bits_avail <= bits_avail + (append_byte ? 5'd8 : 5'd0) - (consume_bit ? 5'd1 : 5'd0);

                case (state)

            // ── S_INIT: read 9 bits to initialise codIValue ────────────────
            // HM: initDecoderState() reads 9 bits into m_uiValue
            S_INIT: begin
                if (buf_has_bit) begin
                    value_r    <= {value_r[7:0], buf_bit};  // shift in MSB-first
                    init_cnt   <= init_cnt + 4'd1;
                    if (init_cnt == 4'd8)                   // 9 bits (0..8) done
                        state <= S_READY;
                end
                // else: stall until bit buffer filled from byte_in
            end

            // ── S_READY: decode one bin ────────────────────────────────────
            S_READY: begin
                if (dec_req && dec_ready) begin : decode_op
                    reg [7:0]  p_lps;
                    reg [8:0]  range_mps;
                    reg        decoded_bin;
                    reg        needs_renorm;

                    if (is_trm) begin
                        // ── Terminating bin (HM decodeBinTrm) ────────────
                        // range -= 2; bin=1 if value >= range; else bin=0
                        range_r     <= range_r - 9'd2;
                        decoded_bin  = (value_r >= (range_r - 9'd2)) ? 1'b1 : 1'b0;
                        needs_renorm = !decoded_bin && ((range_r - 9'd2) < 9'd256);
                        dec_bin     <= decoded_bin;
                        dec_valid   <= 1'b1;
                        // No ctx write-back for trm
                        if (needs_renorm) state <= S_RENORM;

                    end else if (is_ep) begin
                        // ── Bypass (EP) decode (HM decodeBinEP) ──────────
                        // value = (value<<1)|readBit; if value>=range: bin=1, value-=range
                        begin : ep_block
                            reg [9:0] new_val;
                            new_val      = {value_r[8:0], buf_bit};
                            if (new_val >= {1'b0, range_r}) begin
                                dec_bin  <= 1'b1;
                                value_r  <= new_val[8:0] - range_r;
                            end else begin
                                dec_bin  <= 1'b0;
                                value_r  <= new_val[8:0];
                            end
                            dec_valid <= 1'b1;
                            // No ctx write-back for EP
                        end

                    end else begin
                        // ── Regular context-coded decode ──────────────────
                        // HM decodeBin(): compare value to range thresholds
                        p_lps     = lps_table(cur_pstate, range_r[7:6]);
                        range_mps = range_r - {1'b0, p_lps};

                        if (value_r < range_mps) begin
                            // MPS decoded
                            decoded_bin  = cur_valmps;
                            range_r     <= range_mps;
                            // value unchanged
                        end else begin
                            // LPS decoded
                            decoded_bin  = ~cur_valmps;
                            value_r     <= value_r - range_mps;
                            range_r     <= {1'b0, p_lps};
                        end

                        dec_bin   <= decoded_bin;
                        dec_valid <= 1'b1;

                        // Schedule ctx write-back (T+1)
                        wb_pending <= 1'b1;
                        wb_ctx_id  <= dec_ctx_id;
                        wb_bin     <= decoded_bin;

                        // Renorm needed if new range < 256
                        needs_renorm = (value_r < range_mps)
                                       ? (range_mps < 9'd256)
                                       : ({1'b0, p_lps} < 9'd256);
                        if (needs_renorm) state <= S_RENORM;
                    end
                end
            end

            // ── S_RENORM: shift range/value, read one bit per cycle ────────
            // HM: while (range < 256) { range<<=1; value=(value<<1)|readBit(); }
            S_RENORM: begin
                if (buf_has_bit) begin
                    range_r    <= range_r << 1;
                    value_r    <= {value_r[7:0], buf_bit};  // shift in new bit
                    if ((range_r << 1) >= 9'd256)
                        state <= S_READY;
                    // else: continue renorming next cycle
                end
            end

            endcase
            end
            end
        end

    // =========================================================================
    // Simulation assertions
    // =========================================================================
    // synthesis translate_off
    always @(posedge clk) begin
        if (rst_n) begin
            if (state == S_READY && range_r > 9'd510)
                $display("ERROR [bin_decoder] range=%0d > 510 at t=%0t",
                         range_r, $time);
            if (state == S_READY && range_r < 9'd256)
                $display("ERROR [bin_decoder] range=%0d < 256 in READY state at t=%0t",
                         range_r, $time);
            if (dec_valid)
                $display("TRACE [bin_decoder] bin=%0d ctx=%0d range=%0d value=%0d t=%0t",
                         dec_bin, wb_ctx_id, range_r, value_r, $time);
            if (dec_req && !dec_ready)
                $display("WARN  [bin_decoder] dec_req while !dec_ready at t=%0t", $time);
        end
    end
    initial $display("INFO  [bin_decoder] BIT_BUF_W=%0d CTX_ID_W=%0d",
                     BIT_BUF_W, CTX_ID_W);
    // synthesis translate_on

endmodule