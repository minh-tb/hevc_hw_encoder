//=============================================================================
// tb_sao_stats.sv
// Comprehensive Verification Testbench for sao_stats Multi-Mode RDO Decision
// Tests:
//   - 2D 1-cycle-latency SRAM pipeline alignment (d1 -> d2)
//   - Non-last CTU border skip (Y: x>=60||y>=60, C: x>=28||y>=30) & {OFF, BO} causality
//   - Safeguard #1 offset clamp [-15, +15] & cyclic BO 32-band sweep
//   - Independent Y vs joint Cb+Cr decision (syntax_sao conformance)
//   - Last CTU (1,1) all 4 EO classes (0, 1, 2, 3) RDO & sign constraints
//   - ctu_qp lambda scaling sensitivity (low QP accepts tiny gain, high QP picks OFF)
//=============================================================================

`timescale 1ns/1ps
`include "parameter_pkg.vh"

module tb_sao_stats;

    logic        clk;
    logic        rst_n;
    logic        start;
    logic        done;

    logic [5:0]  ctu_x;
    logic [5:0]  ctu_y;
    logic [11:0] frame_width_px;
    logic [11:0] frame_height_px;
    logic [5:0]  ctu_qp;

    logic        rec_rd_valid;
    logic [5:0]  rec_rd_x;
    logic [5:0]  rec_rd_y;
    logic [1:0]  rec_rd_comp;
    logic [9:0]  rec_resp_data;

    logic        org_rd_valid;
    logic [5:0]  org_rd_x;
    logic [5:0]  org_rd_y;
    logic [1:0]  org_rd_comp;
    logic [9:0]  org_resp_data;

    logic [5:0]  sao_type;
    logic [5:0]  eo_class;
    logic [74:0] eo_offset;
    logic [14:0] band_pos;
    logic [59:0] bo_offset;

    sao_stats #(
        .SINGLE_PASS_CAUSAL_SYNC(0)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .done(done),
        .ctu_x(ctu_x),
        .ctu_y(ctu_y),
        .frame_width_px(frame_width_px),
        .frame_height_px(frame_height_px),
        .ctu_qp(ctu_qp),
        .rec_rd_valid(rec_rd_valid),
        .rec_rd_x(rec_rd_x),
        .rec_rd_y(rec_rd_y),
        .rec_rd_comp(rec_rd_comp),
        .rec_resp_data(rec_resp_data),
        .org_rd_valid(org_rd_valid),
        .org_rd_x(org_rd_x),
        .org_rd_y(org_rd_y),
        .org_rd_comp(org_rd_comp),
        .org_resp_data(org_resp_data),
        .sao_type(sao_type),
        .eo_class(eo_class),
        .eo_offset(eo_offset),
        .band_pos(band_pos),
        .bo_offset(bo_offset)
    );

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // True 2D 1-cycle latency SRAM arrays
    logic [9:0] mem_rec_y  [0:63][0:63], mem_org_y  [0:63][0:63];
    logic [9:0] mem_rec_cb [0:31][0:31], mem_org_cb [0:31][0:31];
    logic [9:0] mem_rec_cr [0:31][0:31], mem_org_cr [0:31][0:31];

    always @(posedge clk) begin
        if (rec_rd_valid) begin
            if      (rec_rd_comp == 2'd0) rec_resp_data <= mem_rec_y [rec_rd_y][rec_rd_x];
            else if (rec_rd_comp == 2'd1) rec_resp_data <= mem_rec_cb[rec_rd_y[4:0]][rec_rd_x[4:0]];
            else                          rec_resp_data <= mem_rec_cr[rec_rd_y[4:0]][rec_rd_x[4:0]];
        end
        if (org_rd_valid) begin
            if      (org_rd_comp == 2'd0) org_resp_data <= mem_org_y [org_rd_y][org_rd_x];
            else if (org_rd_comp == 2'd1) org_resp_data <= mem_org_cb[org_rd_y[4:0]][org_rd_x[4:0]];
            else                          org_resp_data <= mem_org_cr[org_rd_y[4:0]][org_rd_x[4:0]];
        end
    end

    int total_errors = 0;

    task automatic fill_flat(input logic [9:0] v_rec, input logic [9:0] v_org);
        for (int y = 0; y < 64; y++) for (int x = 0; x < 64; x++) begin
            mem_rec_y[y][x] = v_rec;
            mem_org_y[y][x] = v_org;
        end
        for (int y = 0; y < 32; y++) for (int x = 0; x < 32; x++) begin
            mem_rec_cb[y][x] = v_rec; mem_org_cb[y][x] = v_org;
            mem_rec_cr[y][x] = v_rec; mem_org_cr[y][x] = v_org;
        end
    endtask

    task automatic run_dut(input string label);
        int cyc = 0;
        @(posedge clk);
        start = 1'b1;
        @(posedge clk);
        start = 1'b0;
        while (!done && cyc < 30000) begin
            @(posedge clk);
            cyc++;
        end
        @(posedge clk);
        if (!done && cyc >= 30000) begin
            $display("[FAIL] %s: TIMEOUT!", label);
            total_errors++;
        end
        // Mandatory norm checks across all tests
        if (sao_type[5:4] !== sao_type[3:2]) begin
            $display("[FAIL] %s: Cb/Cr sao_type mismatch %b vs %b", label, sao_type[3:2], sao_type[5:4]);
            total_errors++;
        end
        if (eo_class[5:4] !== eo_class[3:2]) begin
            $display("[FAIL] %s: Cb/Cr eo_class mismatch %b vs %b", label, eo_class[3:2], eo_class[5:4]);
            total_errors++;
        end
        for (int c = 0; c < 3; c++) begin
            for (int i = 0; i < 4; i++) begin
                logic signed [4:0] o = bo_offset[c*20 + i*5 +: 5];
                if (o < -15 || o > 15) begin
                    $display("[FAIL] %s: BO offset out of Safeguard #1 range [-15,15]: %0d", label, o);
                    total_errors++;
                end
            end
            if (eo_offset[c*25 + 10 +: 5] !== 5'sd0) begin
                $display("[FAIL] %s: EO cat2 offset != 0", label);
                total_errors++;
            end
        end
    endtask

    // Build zero-mean EO pattern orthogonal to other EO classes & BO
    // so only the target eo_class gets coherent valleys/peaks while other classes & BO gain 0.
    task automatic fill_eo_pattern(input int cls);
        fill_flat(10'd500, 10'd500);
        for (int y = 0; y < 64; y++) begin
            for (int x = 0; x < 64; x++) begin
                int u, v, d_sig, base_v;
                if (cls == 0 || cls == 1) begin
                    int phase = (cls == 0) ? (x % 3) : (y % 3);
                    mem_rec_y[y][x] = (phase == 1) ? 10'd494 : ((phase == 2) ? 10'd506 : 10'd500);
                    mem_org_y[y][x] = 10'd500;
                end else begin
                    // cls==2 (135 deg TL-BR): u=x+y varies by 2 along EO_2; v=x-y constant along EO_2
                    // cls==3 (45 deg TR-BL):  u=x-y varies by 2 along EO_3; v=x+y constant along EO_3
                    u = (cls == 2) ? (x + y) : (x - y + 96);
                    v = (cls == 2) ? (x - y + 96) : (x + y);
                    base_v = 500 + (((v & 1) != 0) ? 100 : -100);
                    d_sig  = ((u & 2) != 0) ? 10 : -10;
                    mem_rec_y[y][x] = base_v + d_sig;
                    mem_org_y[y][x] = base_v;
                end
            end
        end
        for (int y = 0; y < 32; y++) begin
            for (int x = 0; x < 32; x++) begin
                int u, v, d_sig, base_v;
                if (cls == 0 || cls == 1) begin
                    int phase = (cls == 0) ? (x % 3) : (y % 3);
                    mem_rec_cb[y][x] = (phase == 1) ? 10'd494 : ((phase == 2) ? 10'd506 : 10'd500);
                    mem_rec_cr[y][x] = mem_rec_cb[y][x];
                    mem_org_cb[y][x] = 10'd500;
                    mem_org_cr[y][x] = 10'd500;
                end else begin
                    u = (cls == 2) ? (x + y) : (x - y + 96);
                    v = (cls == 2) ? (x - y + 96) : (x + y);
                    base_v = 500 + (((v & 1) != 0) ? 100 : -100);
                    d_sig  = ((u & 2) != 0) ? 10 : -10;
                    mem_rec_cb[y][x] = base_v + d_sig;
                    mem_rec_cr[y][x] = base_v + d_sig;
                    mem_org_cb[y][x] = base_v;
                    mem_org_cr[y][x] = base_v;
                end
            end
        end
    endtask

    initial begin
        rst_n = 0;
        start = 0;
        ctu_x = 0; ctu_y = 0;
        frame_width_px = 12'd128; frame_height_px = 12'd128;
        ctu_qp = 6'd29;
        rec_resp_data = 0; org_resp_data = 0;
        fill_flat(10'd512, 10'd512);
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        $display("=== Starting Comprehensive SAO Stats RDO Verification ===");

        // Test 1: Zero distortion -> OFF
        ctu_x = 0; ctu_y = 0; ctu_qp = 6'd29;
        fill_flat(10'd512, 10'd512);
        run_dut("T1: Zero Distortion (OFF)");
        if (sao_type !== 6'b00_00_00) begin
            $display("[FAIL] T1: Exp sao_type=000000 got %b", sao_type);
            total_errors++;
        end else $display("[PASS] T1: Zero distortion selected OFF");

        // Test 2: Non-last CTU (0,0) -> BO clamped +15 on Y, ignores poisoned un-deblocked borders, C=OFF
        ctu_x = 0; ctu_y = 0; ctu_qp = 6'd29;
        fill_flat(10'd500, 10'd500); // C has 0 diff -> OFF
        for (int y = 0; y < 64; y++) for (int x = 0; x < 64; x++) begin
            if (x >= 60 || y >= 60) begin
                mem_rec_y[y][x] = 10'd500;
                mem_org_y[y][x] = 10'd100; // -400 poison in un-deblocked border
            end else begin
                mem_rec_y[y][x] = 10'd500; // band 15
                mem_org_y[y][x] = 10'd540; // +40 -> clamped +15
            end
        end
        run_dut("T2: CTU(0,0) Y=BO(+15) border-skip, C=OFF");
        begin
            logic [4:0]  bp_y;
            logic [4:0]  bdiff;
            logic signed [4:0] yoff;
            bp_y  = band_pos[4:0];
            bdiff = 5'd15 - bp_y;
            yoff  = bo_offset[(bdiff[1:0])*5 +: 5];
            if (sao_type !== 6'b00_00_10 || bdiff >= 5'd4 || yoff !== 5'sd15) begin
                $display("[FAIL] T2: Exp sao_type=000010, band15=+15; got type=%b bp=%0d off=%0d",
                         sao_type, bp_y, yoff);
                total_errors++;
            end else $display("[PASS] T2: Non-last Y BO=+15 (clamped, border ignored) & joint C=OFF");
        end

        // Test 3: Non-last CTU (0,1) -> EO pattern suppressed to {OFF,BO}, cyclic band 31/0 + C border skip
        ctu_x = 0; ctu_y = 1; ctu_qp = 6'd29;
        fill_eo_pattern(0); // Would love EO_0, but is_last_col==0 so must NOT pick EO
        for (int y = 0; y < 32; y++) for (int x = 0; x < 32; x++) begin
            if (x >= 28) begin // un-deblocked right col of C since ctu_x=0
                mem_rec_cb[y][x] = 10'd995; mem_org_cb[y][x] = 10'd700;
                mem_rec_cr[y][x] = 10'd10;  mem_org_cr[y][x] = 10'd300;
            end else begin
                mem_rec_cb[y][x] = 10'd995; mem_org_cb[y][x] = 10'd1003; // band 31 -> +8
                mem_rec_cr[y][x] = 10'd10;  mem_org_cr[y][x] = 10'd4;    // band 0  -> -6
            end
        end
        run_dut("T3: CTU(0,1) causal no-EO + Cb/Cr BO");
        begin
            logic [4:0] dcb;
            logic [4:0] dcr;
            logic signed [4:0] off_cb;
            logic signed [4:0] off_cr;
            dcb = 5'd31 - band_pos[9:5];
            dcr = 5'd0  - band_pos[14:10];
            off_cb = bo_offset[20 + dcb[1:0]*5 +: 5];
            off_cr = bo_offset[40 + dcr[1:0]*5 +: 5];
            if (sao_type[1:0] == 2'd1 || sao_type[5:2] !== 4'b10_10 ||
                dcb >= 5'd4 || dcr >= 5'd4 || off_cb !== 5'sd8 || off_cr !== -5'sd6) begin
                $display("[FAIL] T3: Exp no-EO Y and Cb/Cr BO (+8,-6); got type=%b cb_bp=%0d(%0d) cr_bp=%0d(%0d)",
                         sao_type, band_pos[9:5], off_cb, band_pos[14:10], off_cr);
                total_errors++;
            end else $display("[PASS] T3: CTU(0,1) suppressed EO & solved distinct Cb(+8)/Cr(-6) BO");
        end

        // Test 4..7: Last CTU (1,1) -> All 4 EO classes (0, 1, 2, 3)
        ctu_x = 1; ctu_y = 1; ctu_qp = 6'd29;
        for (int cls = 0; cls < 4; cls++) begin
            fill_eo_pattern(cls);
            run_dut($sformatf("T4.%0d: Last CTU(1,1) EO_class=%0d", cls, cls));
            if (sao_type !== 6'b01_01_01 ||
                eo_class[1:0] !== cls[1:0] || eo_class[3:2] !== cls[1:0]) begin
                $display("[FAIL] T4.%0d: Exp sao_type=010101 eo_class=%0d, got type=%b cls_y=%0d cls_c=%0d",
                         cls, cls, sao_type, eo_class[1:0], eo_class[3:2]);
                total_errors++;
            end else begin
                logic signed [4:0] o0;
                logic signed [4:0] o1;
                logic signed [4:0] o3;
                logic signed [4:0] o4;
                o0 = eo_offset[4:0];
                o1 = eo_offset[9:5];
                o3 = eo_offset[19:15];
                o4 = eo_offset[24:20];
                if (o0 < 0 || o1 < 0 || o3 > 0 || o4 > 0 || (o0 == 0 && o4 == 0)) begin
                    $display("[FAIL] T4.%0d: Unexpected EO offsets {o4,o3,o1,o0}={%0d,%0d,%0d,%0d}",
                             cls, o4, o3, o1, o0);
                    total_errors++;
                end else begin
                    $display("[PASS] T4.%0d: Last CTU selected EO_%0d offsets={%0d,%0d,0,%0d,%0d}",
                             cls, cls, o4, o3, o1, o0);
                end
            end
        end

        // Test 8: QP Lambda sensitivity on weak 1-LSB BO signal
        ctu_x = 0; ctu_y = 0;
        fill_flat(10'd500, 10'd501); // diff=+1 on all pixels -> SSD gain = -3600 on Y
        ctu_qp = 6'd10; // low lambda=5.75 -> BO wins
        run_dut("T8a: Low QP=10 weak BO accepts");
        if (sao_type !== 6'b10_10_10) begin
            $display("[FAIL] T8a: Low QP=10 should accept 1-LSB BO, got %b", sao_type);
            total_errors++;
        end else $display("[PASS] T8a: Low QP=10 accepted weak BO");

        ctu_qp = 6'd51; // high lambda=74711 -> OFF wins
        run_dut("T8b: High QP=51 weak BO rejected to OFF");
        if (sao_type !== 6'b00_00_00) begin
            $display("[FAIL] T8b: High QP=51 should reject weak BO to OFF, got %b", sao_type);
            total_errors++;
        end else $display("[PASS] T8b: High QP=51 rejected weak BO to OFF");

        $display("=== SAO Stats Verification Completed ===");
        if (total_errors == 0)
            $display(">> SUCCESS: All SAO Stats RDO tests passed with 0 errors!");
        else
            $display(">> FAILURE: %0d errors detected.", total_errors);

        $finish(total_errors != 0);
    end

endmodule
