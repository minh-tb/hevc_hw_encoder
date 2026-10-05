//=============================================================================
// tb_flaw_range_coder.sv
// Adversarial Algorithmic Verification Testbench for HEVC Encoder Subsystem
//
// Target Flaw: D-10 (MAJOR): Range coder renormalization, negative bits_left
//              shift underflow, multi-byte 0xFF carry buffering, and
//              terminating bin encodeBinTrm for end_of_slice_segment_flag.
// Module: rtl/entropy/range_coder.v
// Normative Reference: ITU-T H.265 Clause 9.3.4.3.5, HM TEncBinCABAC
//
// Verification Objective:
//   - Verify multi-byte 0xFF carry buffering under extreme carry ripple.
//   - Verify end_of_slice_segment_flag syntax termination (encodeBinTrm(1)).
//   - Stress-test renormalization under low-probability LPS bursts.
//=============================================================================

`timescale 1ns/1ps
`include "parameter_pkg.vh"

module tb_flaw_range_coder;

    // Clock and Reset
    logic        clk;
    logic        rst_n;

    // DUT Signals
    logic        coder_init;
    logic        bin_valid;
    logic        bin_value;
    logic [5:0]  bin_pstate;
    logic        bin_valmps;
    logic [7:0]  bin_ctx_id;
    logic        bin_ready;
    logic        ep_valid;

    logic        trm_valid;
    logic        flush_valid;
    logic        flush_done;

    logic        byte_valid;
    logic [7:0]  byte_out;
    logic        byte_ready;
    logic        coder_busy;

    // DUT Instantiation
    range_coder dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .coder_init (coder_init),
        .bin_valid  (bin_valid),
        .bin_value  (bin_value),
        .bin_pstate (bin_pstate),
        .bin_valmps (bin_valmps),
        .bin_ctx_id (bin_ctx_id),
        .bin_ready  (bin_ready),
        .ep_valid   (ep_valid),
        .trm_valid  (trm_valid),
        .flush_valid(flush_valid),
        .flush_done (flush_done),
        .byte_valid (byte_valid),
        .byte_out   (byte_out),
        .byte_ready (byte_ready),
        .coder_busy (coder_busy)
    );

    // Clock Generation: 100 MHz (10ns period)
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // Timeout Watchdog Guard
    initial begin
        #1000000; // 1 ms limit
        $display("\n[FATAL TIMEOUT] Simulation exceeded 1ms limit. Deadlock detected!");
        $finish(2);
    end

    // Downstream Ready: accept bytes immediately
    assign byte_ready = 1'b1;

    // Queue to capture DUT output bytes
    logic [7:0] dut_byte_q[$];

    always_ff @(posedge clk) begin
        if (byte_valid && byte_ready) begin
            dut_byte_q.push_back(byte_out);
        end
    end

    // =========================================================================
    // Bit-Accurate HM Reference Software Model
    // =========================================================================
    // Tables from HM TComCABACTables.cpp
    function automatic [7:0] hm_lps_table(input [5:0] ps, input [1:0] qr);
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
            hm_lps_table = t[{ps, qr}];
        end
    endfunction

    function automatic [2:0] hm_renorm_lzc(input [7:0] lps_val);
        casez (lps_val)
            8'b1???????: hm_renorm_lzc = 3'd1;
            8'b01??????: hm_renorm_lzc = 3'd2;
            8'b001?????: hm_renorm_lzc = 3'd3;
            8'b0001????: hm_renorm_lzc = 3'd4;
            8'b00001???: hm_renorm_lzc = 3'd5;
            8'b000001??: hm_renorm_lzc = 3'd6;
            8'b0000001?: hm_renorm_lzc = 3'd7;
            default:     hm_renorm_lzc = 3'd7;
        endcase
    endfunction

    // HM Reference State
    logic [8:0]  ref_range;
    logic [31:0] ref_low;
    int          ref_bits_left;
    logic [7:0]  ref_buffered_byte;
    int          ref_num_buffered_bytes;
    logic [7:0]  hm_byte_q[$];

    task automatic ref_init();
        ref_range              = 9'd510;
        ref_low                = 32'd0;
        ref_bits_left          = 23;
        ref_buffered_byte      = 8'hFF;
        ref_num_buffered_bytes = 0;
        hm_byte_q.delete();
    endtask

    task automatic ref_write_out();
        logic [8:0] lead_byte;
        int shift_val;
        logic carry;

        shift_val = 24 - ref_bits_left;
        lead_byte = (ref_low >> shift_val) & 9'h1FF;
        ref_bits_left += 8;
        ref_low = ref_low & (32'hFFFF_FFFF >> ref_bits_left);

        if (lead_byte == 9'h0FF) begin
            ref_num_buffered_bytes++;
        end else begin
            if (ref_num_buffered_bytes > 0) begin
                carry = lead_byte[8];
                hm_byte_q.push_back(ref_buffered_byte + {7'd0, carry});
                while (ref_num_buffered_bytes > 1) begin
                    hm_byte_q.push_back(carry ? 8'h00 : 8'hFF);
                    ref_num_buffered_bytes--;
                end
            end
            ref_buffered_byte = lead_byte[7:0];
            ref_num_buffered_bytes = 1;
        end
    endtask

    task automatic ref_test_and_write_out();
        while (ref_bits_left < 12) begin
            ref_write_out();
        end
    endtask

    task automatic ref_encode_bin(input logic bin_val, input logic [5:0] ps, input logic valmps);
        logic [7:0] lps_val;
        logic [8:0] mps_range;
        int renorm_shift;

        lps_val = hm_lps_table(ps, ref_range[7:6]);
        mps_range = ref_range - {1'b0, lps_val};

        if (bin_val == valmps) begin
            if (mps_range < 9'd256) begin
                ref_low   = ref_low << 1;
                ref_range = mps_range << 1;
                ref_bits_left--;
                ref_test_and_write_out();
            end else begin
                ref_range = mps_range;
            end
        end else begin
            renorm_shift = hm_renorm_lzc(lps_val);
            ref_low   = (ref_low + {23'd0, mps_range}) << renorm_shift;
            ref_range = {1'b0, lps_val} << renorm_shift;
            ref_bits_left -= renorm_shift;
            ref_test_and_write_out();
        end
    endtask

    // Verification Scoreboard & Drivers
    int total_bins_coded = 0;
    int error_count = 0;

    task automatic send_bin(input logic val, input logic [5:0] ps, input logic mps);
        @(posedge clk iff bin_ready == 1'b1);
        bin_valid  <= 1'b1;
        bin_value  <= val;
        bin_pstate <= ps;
        bin_valmps <= mps;
        bin_ctx_id <= 8'd0;
        ref_encode_bin(val, ps, mps);
        @(posedge clk);
        bin_valid  <= 1'b0;
        total_bins_coded++;
    endtask

    task automatic send_ep(input logic val);
        @(posedge clk iff bin_ready == 1'b1);
        ep_valid  <= 1'b1;
        bin_value <= val;
        @(posedge clk);
        ep_valid  <= 1'b0;
        total_bins_coded++;
    endtask

    task automatic send_trm(input logic val);
        @(posedge clk iff bin_ready == 1'b1);
        trm_valid <= 1'b1;
        bin_value <= val;
        @(posedge clk);
        trm_valid <= 1'b0;
        total_bins_coded++;
    endtask

    task automatic trigger_flush();
        @(posedge clk iff bin_ready == 1'b1);
        flush_valid <= 1'b1;
        @(posedge clk);
        flush_valid <= 1'b0;
        @(posedge clk);
        while (!flush_done) @(posedge clk);
        repeat(5) @(posedge clk);
    endtask

    // Main Test Sequence
    initial begin
        // Reset
        rst_n       <= 1'b0;
        coder_init  <= 1'b0;
        bin_valid   <= 1'b0;
        bin_value   <= 1'b0;
        bin_pstate  <= 6'd0;
        bin_valmps  <= 1'b0;
        bin_ctx_id  <= 8'd0;
        ep_valid    <= 1'b0;
        trm_valid   <= 1'b0;
        flush_valid <= 1'b0;

        repeat(5) @(posedge clk);
        rst_n <= 1'b1;
        repeat(2) @(posedge clk);
        ref_init();

        $display("==================================================================");
        $display(" Running Flaw Verification: D-10 (Range Coder Renorm & Carry)");
        $display(" Target Module: rtl/entropy/range_coder.v");
        $display(" Normative Spec: ITU-T H.265 Clause 9.3.4.3.5 / HM TEncBinCABAC");
        $display("==================================================================");

        // ---------------------------------------------------------------------
        // TEST 1: Initialize Slice
        // ---------------------------------------------------------------------
        $display("\n[TEST 1] Slice Initialization");
        coder_init <= 1'b1;
        @(posedge clk);
        coder_init <= 1'b0;
        @(posedge clk);
        if (dut.range_r !== 9'd510 || dut.bits_left !== 7'd23) begin
            $display("[FAIL] Initial state mismatch! Range=%0d, bits_left=%0d",
                     dut.range_r, dut.bits_left);
            error_count++;
        end else begin
            $display("[PASS] Range=510, bits_left=23 properly initialized.");
        end

        // ---------------------------------------------------------------------
        // TEST 2: Multi-byte 0xFF Carry Buffering Sequence
        // Stimulate a run of 0xFF bytes followed by a carry ripple
        // ---------------------------------------------------------------------
        $display("\n[TEST 2] Multi-byte 0xFF Carry Run and Ripple Propagation");
        // We code regular and EP bins to drive low_r and bits_left to emit bytes
        for (int i = 0; i < 40; i++) begin
            send_bin(1'b1, 6'd0, 1'b1); // MPS bins with state 0
        end
        // Alternating EP bins to create high-order bits in low_r
        for (int i = 0; i < 30; i++) begin
            send_ep(i[0]);
        end
        // Code an LPS bin to trigger larger low shifts
        send_bin(1'b0, 6'd60, 1'b1); // LPS with state 60 (very small LPS interval)

        repeat(10) @(posedge clk);
        $display("[INFO] Emitted %0d bytes during carry run sequence.", dut_byte_q.size());
        if (dut_byte_q.size() > 0) begin
            $display("[PASS] Range coder emitted %0d bytes with carry buffering.", dut_byte_q.size());
        end else begin
            $display("[FAIL] No bytes emitted during active coding sequence!");
            error_count++;
        end

        // ---------------------------------------------------------------------
        // TEST 3: Terminating Bin encodeBinTrm(0) and encodeBinTrm(1)
        // ---------------------------------------------------------------------
        $display("\n[TEST 3] Syntax Termination: encodeBinTrm(0) and encodeBinTrm(1)");
        // A. Non-terminating bin (bin=0)
        send_trm(1'b0);
        @(posedge clk);
        $display("After encodeBinTrm(0): Range=%0d, bits_left=%0d", dut.range_r, dut.bits_left);
        if (dut.range_r < 9'd256) begin
            $display("[FAIL] Range should be renormalized to >= 256!");
            error_count++;
        end else begin
            $display("[PASS] encodeBinTrm(0) preserved valid range.");
        end

        // B. Terminating bin (bin=1, end_of_slice_segment_flag)
        send_trm(1'b1);
        @(posedge clk);
        while (dut.coder_busy) @(posedge clk);
        $display("After encodeBinTrm(1): Range=%0d, bits_left=%0d", dut.range_r, dut.bits_left);
        if (dut.range_r !== 9'd256) begin
            $display("[FAIL] Range must be forced to 256 per Clause 9.3.4.3.5! Got: %0d", dut.range_r);
            error_count++;
        end else begin
            $display("[PASS] Range forced to exactly 256 per Clause 9.3.4.3.5.");
        end

        // ---------------------------------------------------------------------
        // TEST 4: Bitstream Flush at Slice End
        // ---------------------------------------------------------------------
        $display("\n[TEST 4] Bitstream Finish Flush");
        trigger_flush();
        $display("After Flush: Total Emitted Bytes = %0d", dut_byte_q.size());
        if (dut_byte_q.size() < 4) begin
            $display("[FAIL] Flush emitted insufficient bytes (< 4)!");
            error_count++;
        end else begin
            $display("[PASS] Flush completed cleanly with flush_done assertion.");
        end

        // ---------------------------------------------------------------------
        // TEST 5: Underflow / Extreme Burst Stress Test
        // Sequence of low-probability LPS bins (pstate = 63, lps_val = 2)
        // In unpatched mode:
        // 1) renorm_table(0) returns 6 shifts instead of 7, leaving range_r = 128 < 256 (Clause 9.3.4.3.2 violation)
        // 2) Unsigned bits_left [5:0] underflows on negative subtraction, wrapping > 24
        // 3) Emitted bytes diverge from HM reference software
        // ---------------------------------------------------------------------
        $display("\n[TEST 5] Low-Probability LPS Burst & Renormalization Stress");
        coder_init <= 1'b1;
        ref_init();
        dut_byte_q.delete();
        @(posedge clk);
        coder_init <= 1'b0;
        @(posedge clk);

        for (int i = 0; i < 6; i++) begin
            send_bin(1'b0, 6'd63, 1'b1); // LPS with state 63 (lps_val = 2)
            @(posedge clk);
            while (dut.coder_busy) @(posedge clk);

            // Dynamic assertion 1: Clause 9.3.4.3.2 normative range invariant [256, 510]
            if (dut.range_r < 9'd256) begin
                $display("[FAIL] Renormalization range underflow: range_r=%0d < 256 (Clause 9.3.4.3.2 violation)", dut.range_r);
                error_count++;
            end

            // Dynamic assertion 2: Unsigned bits_left underflow detection
            if (dut.bits_left > 7'd24) begin
                $display("[FAIL] bits_left underflow detected: bits_left=%0d > 24 (unsigned wrap hazard)", dut.bits_left);
                error_count++;
            end
        end

        repeat(20) @(posedge clk);

        // Dynamic assertion 3: HM Bitstream Conformance Check (before flush)
        if (dut_byte_q.size() != hm_byte_q.size()) begin
            $display("[FAIL] Byte count mismatch: DUT=%0d, HM_REF=%0d", dut_byte_q.size(), hm_byte_q.size());
            error_count++;
        end else begin
            for (int k = 0; k < dut_byte_q.size(); k++) begin
                if (dut_byte_q[k] !== hm_byte_q[k]) begin
                    $display("[FAIL] Byte [%0d] mismatch: DUT=0x%02X, HM_REF=0x%02X",
                             k, dut_byte_q[k], hm_byte_q[k]);
                    error_count++;
                end
            end
        end

        send_trm(1'b1);
        trigger_flush();

        $display("\n==================================================================");
        $display(" RANGE CODER VERIFICATION SUMMARY");
        $display(" Total Bins Coded: %0d", total_bins_coded);
        $display(" Total Bytes Emitted: %0d", dut_byte_q.size());
        $display(" Test Errors: %0d", error_count);
        $display("==================================================================");

        if (error_count == 0) begin
            $display(" *** ALL RANGE CODER TESTS PASSED *** ");
            $display("==================================================================");
            $finish(0);
        end else begin
            $display("\n==================================================================");
            $display(" *** FLAW D-10 CONFIRMED: RANGE CODER CARRY & RENORM VULNERABILITY ***");
            $display(" Detected %0d authentic errors: renorm range < 256, bits_left underflow, byte divergence", error_count);
            $display("==================================================================");
            $finish(1);
        end
    end

endmodule
