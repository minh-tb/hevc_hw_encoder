//=============================================================================
// range_coder.v
// HEVC CABAC M-Coder Arithmetic Range Engine
//
// Mapped from HM source:
//   TLibEncoder/TEncBinCABAC.cpp  :: encodeBin(), testAndWriteOut(), writeOut()
//                                    encodeBinTrm(), finish(), init()
//   TLibEncoder/TEncBinCABAC.h    :: m_uiLow, m_uiRange, m_bitsLeft,
//                                    m_bufferedByte, m_numBufferedBytes
//   TLibCommon/TComCABACTables.h  :: g_aucLPSTable[64][4]
//
// HM encodeBin() core (simplified):
//   pLPS        = g_aucLPSTable[pStateIdx][(range >> 6) & 3]
//   range      -= pLPS                          // MPS range
//   if (bin == LPS):
//     low   += range                            // shift low by MPS range
//     range  = pLPS                             // range becomes LPS interval
//   testAndWriteOut():                          // renormalize if range < 256
//     while range < 256:
//       emit_bit_with_pending_carry(low)
//       range <<= 1;  low <<= 1
//
// Pending-bit carry propagation (HM writeOut / bufferedByte mechanism):
//   A "pending bit" is emitted when low ∈ [256,511] (ambiguous zone).
//   It resolves when low unambiguously drops below 256 or rises above 511:
//     Resolve 0: output 0, then n_pend 0s (pending=0)
//     Resolve 1: output 1, then n_pend 1s (pending=1), low -= 512
//   This is equivalent to HM's m_bufferedByte + m_numBufferedBytes approach.
//   Hardware carry never propagates more than 1 byte — the 0xFF-byte counter
//   serves the same purpose as the pending-bit counter in the spec formulation.
//
// LPS table (g_aucLPSTable[64][4]) — exact copy from HM TComCABACTables.cpp:
//   Row index:    pStateIdx  0..63
//   Column index: qRange = (range>>6)&3,   range ∈ [256,510]
//   Value:        pLPS probability ∈ [2,240]
//
// Renormalization:
//   After coding a bin, range ∈ [2, 509]. Renorm shifts until range ∈ [256,510].
//   Max shifts: 7 (when pLPS=2 → shifts: 2→4→8→16→32→64→128→256).
//   MPS always requires at most 1 shift (range ≥ 128 after MPS).
//   Each shift may output a bit (0, 1, or pending) based on low ∈ {<256,[256,511],≥512}.
//
// Architecture — 2-state FSM with sequential renorm (1 step/clock):
//
//   S_READY:  Accept new bin from bin_encoder.
//             Compute pLPS, update range/low, start renorm if range < 256.
//   S_RENORM: One renorm step per clock. Emit bit (or record pending).
//             Return to S_READY when range ≥ 256.
//
//   Throughput: MPS → 1-2 cycles/bin, LPS → 2-8 cycles/bin (~2.5 avg).
//   At 125 MHz: ~50 Mbins/sec (exceeds 4K@30fps requirement of ~20 Mbins/sec).
//
// Byte output:
//   Bits are accumulated into m_bufferedByte.
//   Complete bytes are emitted via byte_valid/byte_out with carry propagation.
//   Backpressure: bin_ready deasserted when output FIFO is full (stall_in=1).
//
// Special operations:
//   encode_trm: encode terminating bin (range halved, no context lookup)
//   flush:      complete the bitstream (output remaining low bits + stop bit)
//=============================================================================

`include "parameter_pkg.vh"

module range_coder (
    input  wire        clk,
    input  wire        rst_n,

    // ── Slice init ───────────────────────────────────────────────────────────
    // HM: TEncBinCABAC::init() — resets range=510, low=0, bitsLeft=11
    input  wire        coder_init,       // pulse: begin new slice

    // ── Bin input (from bin_encoder) ─────────────────────────────────────────
    input  wire        bin_valid,        // new regular bin to encode
    input  wire        bin_value,        // 0 or 1
    input  wire [5:0]  bin_pstate,       // pStateIdx from ctx_model_store
    input  wire        bin_valmps,       // valMPS    from ctx_model_store
    output reg         bin_ready,        // backpressure: accept when 1
    input  wire        ep_valid,         // Equi-probable (Bypass) bin

    // ── Terminating bin ───────────────────────────────────────────────────────
    // HM: encodeBinTrm(1) at end of slice segment
    input  wire        trm_valid,        // encode terminating bin (bin=1)

    // ── Flush ────────────────────────────────────────────────────────────────
    // HM: finish() — writes remaining low bits and stop bit
    input  wire        flush_valid,      // pulse: complete and flush bitstream
    output reg         flush_done,       // asserted for 1 cycle when flush complete

    // ── Byte output (to NAL writer / output FIFO) ────────────────────────────
    output reg         byte_valid,       // output byte available
    output reg  [7:0]  byte_out,         // byte value
    input  wire        byte_ready,       // downstream can accept (backpressure)

    // ── Status ───────────────────────────────────────────────────────────────
    output wire        coder_busy        // 0 = ready for new slice or bin
);

    // =========================================================================
    // LPS probability table — exact copy of HM g_aucLPSTable[64][4]
    // From TLibCommon/TComCABACTables.cpp
    // =========================================================================
    function automatic [7:0] lps_table;
        input [5:0] ps;   // pStateIdx  0..63
        input [1:0] qr;   // qRange = (range>>6)&3
        reg [7:0] t [0:255];
        begin
            // Row ps=0..63, col qr=0..3
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
    // Internal state
    // =========================================================================
    localparam S_READY         = 3'd0;
    localparam S_RENORM        = 3'd1;
    localparam S_WRITEOUT_LEAD = 3'd2;
    localparam S_WRITEOUT_FF   = 3'd3;
    localparam S_FLUSH_1       = 3'd4;
    localparam S_FLUSH_2       = 3'd5;
    localparam S_FLUSH_3       = 3'd6;
    localparam S_FLUSH_4       = 3'd7;

    reg [2:0]   state;
    reg [2:0]   ret_state;

    // M-coder registers (matching HM TEncBinCABAC exact width/logic)
    reg [8:0]        range_r;     // m_uiRange
    reg [31:0]       low_r;       // m_uiLow
    reg signed [6:0] bits_left;   // m_bitsLeft (starts at 23)
    reg [7:0]        buf_byte;    // m_bufferedByte
    reg [15:0]       num_ff;      // m_numBufferedBytes
    reg [7:0]        ff_byte;     // carry propagation byte (0x00 or 0xFF)

    assign coder_busy = (state != S_READY);

    // =========================================================================
    // Main FSM
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin : main_fsm
        reg [5:0] shift_val;
        reg [8:0] lead_byte;
        reg [6:0] next_bits;
        reg       carry;
        
        reg [4:0] L;
        reg [4:0] P;
        reg [15:0] V;
        reg [15:0] final_val;
        if (!rst_n) begin
            state        <= S_READY;
            ret_state    <= S_READY;
            range_r      <= 9'd510;
            low_r        <= 32'd0;
            bits_left    <= 7'd23;
            buf_byte     <= 8'hFF;
            num_ff       <= 16'd0;
            ff_byte      <= 8'd0;
            bin_ready    <= 1'b1;
            byte_valid   <= 1'b0;
            byte_out     <= 8'd0;
            flush_done   <= 1'b0;
        end else begin
            byte_valid <= 1'b0;   // default deassert
            flush_done <= 1'b0;

            // ── Slice init ─────────────────────────────────────────────────
            if (coder_init) begin
                state        <= S_READY;
                ret_state    <= S_READY;
                range_r      <= 9'd510;
                low_r        <= 32'd0;
                bits_left    <= 7'd23;
                buf_byte     <= 8'hFF;
                num_ff       <= 16'd0;
                bin_ready    <= 1'b1;
            end else case (state)

            S_READY: begin
                bin_ready <= 1'b1;
                if (trm_valid) begin
                    bin_ready <= 1'b0;
                    if (bin_value) begin
                        low_r     <= (low_r + range_r - 9'd2) << 7;
                        range_r   <= 9'd256;
                        bits_left <= bits_left - 7'd7;
                        if (bits_left - 7'd7 < 7'd12) begin
                            state     <= S_WRITEOUT_LEAD;
                            ret_state <= S_READY;
                        end else begin
                            bin_ready <= 1'b1;
                        end
                    end else begin
                        range_r <= range_r - 9'd2;
                        if (range_r - 9'd2 < 9'd256)
                            state <= S_RENORM;
                        else
                            bin_ready <= 1'b1;
                    end
                end else if (ep_valid) begin
                    bin_ready <= 1'b0;
                    low_r     <= (low_r << 1) + (bin_value ? {23'd0, range_r} : 32'd0);
                    bits_left <= bits_left - 7'd1;
                    if (bits_left - 7'd1 < 7'd12) begin
                        state     <= S_WRITEOUT_LEAD;
                        ret_state <= S_READY;
                    end else begin
                        bin_ready <= 1'b1;
                    end
                end else if (bin_valid) begin
                    bin_ready <= 1'b0;
                    if (bin_value == bin_valmps) begin
                        range_r <= range_r - lps_table(bin_pstate, range_r[7:6]);
                        if ((range_r - lps_table(bin_pstate, range_r[7:6])) < 9'd256)
                            state <= S_RENORM;
                        else
                            bin_ready <= 1'b1;
                    end else begin
                        low_r   <= low_r + range_r - lps_table(bin_pstate, range_r[7:6]);
                        range_r <= {1'b0, lps_table(bin_pstate, range_r[7:6])};
                        state   <= S_RENORM;
                    end
                end else if (flush_valid) begin
                    bin_ready <= 1'b0;
                    state     <= S_FLUSH_1;
                end
            end

            S_RENORM: begin
                if (bits_left < 7'd12) begin
                    state     <= S_WRITEOUT_LEAD;
                    if (range_r >= 9'd256)
                        ret_state <= S_READY;
                    else
                        ret_state <= S_RENORM;
                end else begin
                    range_r   <= range_r << 1;
                    low_r     <= low_r << 1;
                    bits_left <= bits_left - 7'd1;
                    if ((range_r << 1) >= 9'd256 && (bits_left - 7'd1 >= 7'd12)) begin
                        state     <= S_READY;
                        bin_ready <= 1'b1;
                    end
                end
            end

            S_WRITEOUT_LEAD: begin
                shift_val = 6'd24 - bits_left[5:0];
                lead_byte = (low_r >> shift_val) & 9'h1FF;
                next_bits = bits_left + 7'd8;
                
                bits_left <= next_bits;
                low_r     <= low_r & (32'hFFFF_FFFF >> next_bits);
                
                if (lead_byte == 9'h0FF) begin
                    num_ff <= num_ff + 16'd1;
                    state  <= ret_state;
                    if (ret_state == S_READY) bin_ready <= 1'b1;
                end else begin
                    if (num_ff > 0) begin
                        carry      = lead_byte[8];
                        byte_valid <= 1'b1;
                        byte_out   <= buf_byte + {7'd0, carry};
                        buf_byte   <= lead_byte[7:0];
                        ff_byte    <= carry ? 8'h00 : 8'hFF;
                        if (num_ff > 1) begin
                            state  <= S_WRITEOUT_FF;
                            num_ff <= num_ff - 16'd1;
                        end else begin
                            num_ff <= 16'd1; // The new lead_byte is now the buffered byte
                            state  <= ret_state;
                            if (ret_state == S_READY) bin_ready <= 1'b1;
                        end
                    end else begin
                        buf_byte <= lead_byte[7:0];
                        num_ff   <= 16'd1;
                        state    <= ret_state;
                        if (ret_state == S_READY) bin_ready <= 1'b1;
                    end
                end
            end

            S_WRITEOUT_FF: begin
                byte_valid <= 1'b1;
                byte_out   <= ff_byte;
                if (num_ff > 1) begin
                    num_ff <= num_ff - 16'd1;
                end else begin
                    num_ff <= 16'd1; // The new lead_byte is now the buffered byte
                    state  <= ret_state;
                    if (ret_state == S_READY) bin_ready <= 1'b1;
                end
            end

            S_FLUSH_1: begin
                shift_val = 6'd32 - bits_left[5:0];
                carry     = (low_r >> shift_val) & 1'b1;
                low_r     <= carry ? (low_r - (32'd1 << shift_val)) : low_r;
                
                if (num_ff > 0) begin
                    // Start trailing output sequence
                    byte_valid <= 1'b1;
                    byte_out   <= buf_byte + {7'd0, carry};
                    ff_byte    <= carry ? 8'h00 : 8'hFF;
                    state      <= S_FLUSH_2;
                end else begin
                    state <= S_FLUSH_3;
                end
            end

            S_FLUSH_2: begin
                 if (num_ff > 1) begin
                    byte_valid <= 1'b1;
                    byte_out   <= ff_byte;
                    num_ff     <= num_ff - 16'd1;
                end else begin
                    state      <= S_FLUSH_3;
                end
            end
             S_FLUSH_3: begin
                L = 5'd25 - bits_left[4:0];
                V = (low_r >> 8) & ((32'd1 << (5'd24 - bits_left[4:0])) - 1);
                
                if (L <= 5'd8) begin
                    P = 5'd8 - L;
                    final_val = (V << (P + 1)) | (16'd1 << P);
                    byte_valid <= 1'b1;
                    byte_out   <= final_val[7:0];
                    
                    state      <= S_READY;
                    range_r    <= 9'd510;
                    low_r      <= 32'd0;
                    bits_left  <= 7'd23;
                    buf_byte   <= 8'hFF;
                    num_ff     <= 16'd0;
                    
                    bin_ready  <= 1'b1;
                    flush_done <= 1'b1;
                end else begin
                    P = 5'd16 - L;
                    final_val = (V << (P + 1)) | (16'd1 << P);
                    byte_valid <= 1'b1;
                    byte_out   <= final_val[15:8]; // Output first byte
                    ff_byte    <= final_val[7:0];  // Reuse ff_byte to store second byte
                    state      <= S_FLUSH_4;
                end
            end
            S_FLUSH_4: begin
                byte_valid <= 1'b1;
                byte_out   <= ff_byte;
                
                state      <= S_READY;
                range_r    <= 9'd510;
                low_r      <= 32'd0;
                bits_left  <= 7'd23;
                buf_byte   <= 8'hFF;
                num_ff     <= 16'd0;
                
                bin_ready  <= 1'b1;
                flush_done <= 1'b1;
            end
            endcase
        end
    end

    // =========================================================================
    // Simulation assertions
    // =========================================================================
    // synthesis translate_off
    always @(posedge clk) begin
        if (rst_n && state == S_READY) begin
            // range must always be in [256,510] when not renorming
            if (!coder_busy && range_r > 9'd510)
                $display("ERROR [range_coder] range=%0d > 510 at t=%0t",
                         range_r, $time);
            if (!coder_busy && range_r < 9'd256 && !coder_init)
                $display("ERROR [range_coder] range=%0d < 256 at t=%0t (needs renorm)",
                         range_r, $time);
        end
        if (bin_valid && !bin_ready)
            $display("WARN  [range_coder] bin_valid asserted while !bin_ready at t=%0t",
                     $time);
    end
    // synthesis translate_on

endmodule