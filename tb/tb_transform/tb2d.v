`timescale 1ns/1ps

module tb2d;

  reg clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  reg fwd = 1;
  reg [2:0] sz = 2;
  reg in_valid = 0;
  reg [16383:0] in_data = 0;
  reg out_ready = 0;

  wire in_ready, out_valid;
  wire [16383:0] out_data;
  wire [2:0] o_sz;
  wire o_fwd;

  dct_top dut (
    .clk              (clk),
    .rst_n            (rst_n),
    .fwd_inv_n        (fwd),
    .tu_size_log2     (sz),
    .in_valid         (in_valid),
    .in_ready         (in_ready),
    .in_data          (in_data),
    .out_valid        (out_valid),
    .out_ready        (out_ready),
    .out_data         (out_data),
    .out_tu_size_log2 (o_sz),
    .out_fwd_inv_n    (o_fwd)
  );

  integer fd, i, r, nmat, bad, sideband_bad, mism, cyc, maxcyc, pad;
  reg [15:0] w;
  reg [3:0] hf, hs;
  reg [16383:0] exp;
  reg [31:0] seed;
  integer RANDREADY;

  initial begin
    nmat = 0;
    bad = 0;
    sideband_bad = 0;
    maxcyc = 0;
    seed = 32'h1234abcd;

    if (!$value$plusargs("RR=%d", RANDREADY)) RANDREADY = 0;

    fd = $fopen("tb/tb_transform/vec2d.hex", "r");
    if (fd == 0) fd = $fopen("vec2d.hex", "r");
    if (fd == 0) begin
      $display("ERROR: Cannot open vec2d.hex");
      $finish;
    end

    #50 rst_n = 1;
    #20;

    while (!$feof(fd)) begin
      r = $fscanf(fd, "%h %h", hf, hs);
      if (r == 2) begin
        for (i = 0; i < 1024; i = i + 1) begin
          r = $fscanf(fd, "%h", w);
          in_data[i*16 +: 16] = w;
        end
        for (i = 0; i < 1024; i = i + 1) begin
          r = $fscanf(fd, "%h", w);
          exp[i*16 +: 16] = w;
        end

        // random gap before issuing
        repeat ($urandom % 3) @(posedge clk);
        @(posedge clk); #1;
        fwd = hf[0];
        sz = hs[2:0];
        in_valid = 1;

        while (!in_ready) begin
          @(posedge clk); #1;
        end

        @(posedge clk); #1;
        in_valid = 0;
        fwd = ~fwd;
        sz = 3'd7; // scramble controls after accept
        in_data = {$urandom, $urandom};

        cyc = 0;
        out_ready = RANDREADY ? 0 : 1;

        // wait for handshake
        begin : waitloop
          forever begin
            @(posedge clk);
            cyc = cyc + 1;
            if (RANDREADY) out_ready = ($urandom % 3 == 0);
            #0;
            if (out_valid && out_ready) disable waitloop;
            #1;
          end
        end

        // sampled at the edge where handshake occurs (pre-NBA values)
        mism = 0;
        for (i = 0; i < 1024; i = i + 1) begin
          if (out_data[i*16 +: 16] !== exp[i*16 +: 16]) mism = mism + 1;
        end

        if (mism) begin
          bad = bad + 1;
          if (bad < 6)
            $display("DATA MISMATCH fwd=%0d log2=%0d : %0d words", hf, hs, mism);
        end

        if (o_sz !== hs[2:0] || o_fwd !== hf[0]) begin
          sideband_bad = sideband_bad + 1;
          if (sideband_bad < 6)
            $display("SIDEBAND STALE at handshake: out_tu_size_log2=%0d (exp %0d) out_fwd_inv_n=%0d (exp %0d)", o_sz, hs, o_fwd, hf);
        end

        if (cyc > maxcyc) maxcyc = cyc;
        nmat = nmat + 1;
        out_ready = 0;
      end
    end

    $display("RESULT matrices=%0d data_fail=%0d sideband_fail=%0d max_cycles_to_valid=%0d (RR=%0d)", nmat, bad, sideband_bad, maxcyc, RANDREADY);
    $finish;
  end

  initial begin
    #400000000;
    $display("TIMEOUT");
    $finish;
  end

endmodule
