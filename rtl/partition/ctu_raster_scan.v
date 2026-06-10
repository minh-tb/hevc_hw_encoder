//=============================================================================
// ctu_raster_scan.v
// CTU Address Generator — Raster Scan Order
//
// Mapped from HM source:
//   TLibEncoder/TEncSlice.cpp
//   Void TEncSlice::encodeCtus() — outer CTU loop, raster scan
//   TLibCommon/TComPic.cpp       getCtu(ctuRsAddr) — raster address
//
// HEVC spec: Section 6.5.1 (CTU raster scan)
//
// Function:
//   Generates sequential CTU addresses in raster scan order
//   (left-to-right, top-to-bottom) across the frame.
//   Outputs CTU position in both linear (raster addr) and
//   2D (ctu_x, ctu_y) coordinates for downstream modules.
//
// HM raster address formula:
//   ctuRsAddr = ctu_y * frame_width_in_ctus + ctu_x
//   ctu_x = ctuRsAddr % frame_width_in_ctus
//   ctu_y = ctuRsAddr / frame_width_in_ctus
//
// Config:
//   CTU_SIZE = 64px (MaxCUWidth=64 in config)
//   4K frame: 3840×2160 → 60×34 = 2040 CTUs per frame
//   Frame dimensions passed as parameters for flexibility
//
// Pipeline:
//   Generates one CTU address per valid/ready handshake.
//   Downstream (ctu_partitioner) asserts ready when done with current CTU.
//   New frame starts on frame_start pulse.
//
// Outputs also include:
//   - is_first_ctu_in_row: for SAO/deblock row triggers
//   - is_last_ctu_in_row:  for CTU-row flush
//   - is_last_ctu:         for end-of-frame signal to slice controller
//=============================================================================

`include "parameter_pkg.vh"
`include "hevc_interfaces.vh"

module ctu_raster_scan #(
    parameter FRAME_WIDTH  = 3840,
    parameter FRAME_HEIGHT = 2160
)(
    input  wire         clk,
    input  wire         rst_n,

    // Frame control
    input  wire         frame_start,    // pulse: begin new frame scan
    input  wire [9:0]   frame_poc,      // POC for this frame
    input  wire [1:0]   frame_slice_type, // SLICE_B/P/I

    // CTU output stream
    output reg          ctu_valid,
    input  wire         ctu_ready,

    // CTU address outputs (CTU_INFO_BUS_SIGNALS subset)
    output reg  [15:0]  ctu_addr,       // linear raster address
    output reg  [9:0]   ctu_x,          // CTU column (unit: CTU = 64px)
    output reg  [9:0]   ctu_y,          // CTU row
    output reg  [13:0]  frame_width_px, // frame width in pixels
    output reg  [13:0]  frame_height_px,// frame height in pixels
    output reg  [9:0]   poc,
    output reg  [1:0]   slice_type,
    output reg  [5:0]   qp,             // base QP from parameter_pkg

    // Position flags
    output reg          is_first_in_row,
    output reg          is_last_in_row,
    output reg          is_last_ctu,    // last CTU of frame

    // Frame-level status
    output reg          frame_active,   // 1 while scanning a frame
    output reg          frame_done      // pulse when last CTU accepted
);

    //-------------------------------------------------------------------------
    // Frame dimension derivation
    // CTU size = 64px (CTU_SIZE from parameter_pkg)
    // Width  in CTUs = ceil(FRAME_WIDTH  / 64)
    // Height in CTUs = ceil(FRAME_HEIGHT / 64)
    //-------------------------------------------------------------------------
    localparam CTU_LOG2   = `CTU_SIZE_LOG2;                      // 6
    localparam W_CTUS     = (FRAME_WIDTH  + `CTU_SIZE - 1) >> CTU_LOG2;  // 60 for 3840
    localparam H_CTUS     = (FRAME_HEIGHT + `CTU_SIZE - 1) >> CTU_LOG2;  // 34 for 2160
    localparam TOTAL_CTUS = W_CTUS * H_CTUS;                    // 2040 for 4K

    // Width/height fit in 10-bit (max 4096/64=64 CTUs per dim for 4K, easily 10-bit)
    localparam [9:0] W_CTUS_10 = W_CTUS[9:0];
    localparam [9:0] H_CTUS_10 = H_CTUS[9:0];
    localparam [15:0] TOTAL_16 = TOTAL_CTUS[15:0];

    //-------------------------------------------------------------------------
    // Counters
    //-------------------------------------------------------------------------
    reg [9:0]  cur_x;       // current CTU column 0..W_CTUS-1
    reg [9:0]  cur_y;       // current CTU row    0..H_CTUS-1
    reg [15:0] cur_addr;    // linear raster addr 0..TOTAL_CTUS-1

    //-------------------------------------------------------------------------
    // Fire condition
    //-------------------------------------------------------------------------
    wire fire = ctu_valid && ctu_ready;

    //-------------------------------------------------------------------------
    // Main FSM
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            ctu_valid      <= 1'b0;
            frame_active   <= 1'b0;
            frame_done     <= 1'b0;
            cur_x          <= 10'd0;
            cur_y          <= 10'd0;
            cur_addr       <= 16'd0;
            ctu_addr       <= 16'd0;
            ctu_x          <= 10'd0;
            ctu_y          <= 10'd0;
            frame_width_px <= 14'd0;
            frame_height_px<= 14'd0;
            poc            <= 10'd0;
            slice_type     <= `SLICE_B;
            qp             <= `QP_DEFAULT;
            is_first_in_row<= 1'b0;
            is_last_in_row <= 1'b0;
            is_last_ctu    <= 1'b0;
        end else begin
            frame_done <= 1'b0;   // default pulse-low

            if (frame_start && !frame_active) begin
                // Latch frame parameters and begin scan
                frame_active    <= 1'b1;
                cur_x           <= 10'd0;
                cur_y           <= 10'd0;
                cur_addr        <= 16'd0;
                poc             <= frame_poc;
                slice_type      <= frame_slice_type;
                qp              <= `QP_DEFAULT;
                frame_width_px  <= FRAME_WIDTH[13:0];
                frame_height_px <= FRAME_HEIGHT[13:0];

                // Present first CTU immediately
                ctu_valid       <= 1'b1;
                ctu_addr        <= 16'd0;
                ctu_x           <= 10'd0;
                ctu_y           <= 10'd0;
                is_first_in_row <= 1'b1;
                is_last_in_row  <= (W_CTUS_10 == 10'd1);
                is_last_ctu     <= (TOTAL_16  == 16'd1);
            end else if (frame_active && fire) begin
                // Current CTU accepted — advance to next
                if (cur_addr == TOTAL_16 - 16'd1) begin
                    // Last CTU just accepted → frame complete
                    frame_active <= 1'b0;
                    frame_done   <= 1'b1;
                    ctu_valid    <= 1'b0;
                    cur_x        <= 10'd0;
                    cur_y        <= 10'd0;
                    cur_addr     <= 16'd0;
                end else begin
                    // Advance raster position
                    cur_addr <= cur_addr + 16'd1;

                    if (cur_x == W_CTUS_10 - 10'd1) begin
                        cur_x <= 10'd0;
                        cur_y <= cur_y + 10'd1;
                    end else begin
                        cur_x <= cur_x + 10'd1;
                    end

                    // Register next CTU outputs (one cycle after fire)
                    // Output reflects the NEXT CTU (the one now being presented)
                    ctu_valid <= 1'b1;
                end
            end

            // Update output registers to reflect current (cur_x, cur_y)
            // These are combinational from the updated counters via a
            // registered stage — driven from cur_x/cur_y after increment
            if (frame_active && fire && cur_addr < TOTAL_16 - 16'd1) begin
                ctu_addr <= cur_addr + 16'd1;
                is_last_ctu <= ((cur_addr + 16'd1) == TOTAL_16 - 16'd1);
                
                if (cur_x == W_CTUS_10 - 10'd1) begin
                    ctu_x           <= 10'd0;
                    ctu_y           <= cur_y + 10'd1;
                    is_first_in_row <= 1'b1;
                    is_last_in_row  <= (W_CTUS_10 == 10'd1);
                end else begin
                    ctu_x           <= cur_x + 10'd1;
                    ctu_y           <= cur_y;
                    is_first_in_row <= 1'b0;
                    is_last_in_row  <= ((cur_x + 10'd1) == W_CTUS_10 - 10'd1);
                end
            end
        end
    end

    //-------------------------------------------------------------------------
    // Simulation checks
    //-------------------------------------------------------------------------
    // synthesis translate_off
    always @(posedge clk) begin
        if (rst_n) begin
            if (frame_start && frame_active)
                $display("WARN  [ctu_raster_scan] frame_start during active scan (POC=%0d) at time=%0t",
                         poc, $time);
            if (frame_done)
                $display("INFO  [ctu_raster_scan] frame done POC=%0d total CTUs=%0d at time=%0t",
                         poc, TOTAL_CTUS, $time);
        end
    end
    // synthesis translate_on

endmodule