`timescale 1ns / 1ps
//=============================================================================
// gop_controller.v
// Top-Level GOP Controller (Random Access Main10)
//
// Function:
//   Orchestrates the encoding of a 16-frame GOP according to 
//   encoder_randomaccess_main10.cfg hierarchical B-frame order.
//   Manages POC generation, Slice Types, Temporal IDs, and 
//   Reference Picture List (RPL0 / RPL1) physical slot mapping.
//=============================================================================

`include "parameter_pkg.vh"
`include "hevc_interfaces.vh"

module gop_controller #(
    parameter GOP_STRUCTURE = 0  // 0: IPP, 1: IPBB (Low-Delay B), 2: Hierarchical B
)(
    input  wire                     clk,
    input  wire                     rst_n,

    // Global control
    input  wire                     encode_start,
    input  wire [15:0]              total_frames,
    output reg                      encode_done,

    // Interface to CTU Raster Scan (Frame Start Trigger)
    output reg                      frame_start,
    input  wire                     frame_done,
    output reg  [9:0]               frame_poc,
    output reg  [1:0]               frame_slice_type,
    
    // NAL Writer Info
    output reg  [2:0]               temporal_id,
    output reg  [5:0]               nal_type,

    // Interface to frame_store (DPB Slot Management)
    output reg                      alloc_valid,
    input  wire                     alloc_ready,
    output reg  [9:0]               alloc_poc,
    input  wire [2:0]               alloc_slot,

    output reg                      free_valid,
    output reg  [2:0]               free_slot,

    // Reference Picture Lists to frame_store
    output wire [14:0]              ref_l0,
    output wire [14:0]              ref_l1,
    output reg  [2:0]               ref_l0_count,
    output reg  [2:0]               ref_l1_count
);

    // SLICE TYPES
    localparam SLICE_B = 2'd0;
    localparam SLICE_P = 2'd1;
    localparam SLICE_I = 2'd2;

    // NAL TYPES (Subset of HEVC Spec)
    localparam NAL_TRAIL_R    = 6'd1;
    localparam NAL_IDR_W_RADL = 6'd19;
    localparam NAL_CRA_NUT    = 6'd21;

    // FSM States
    localparam S_IDLE       = 3'd0;
    localparam S_CRA        = 3'd1;
    localparam S_ALLOC      = 3'd2;
    localparam S_START      = 3'd3;
    localparam S_WAIT_FRAME = 3'd4;
    localparam S_NEXT       = 3'd5;
    localparam S_DONE       = 3'd6;

    reg [2:0] state, next_state;

    // GOP Tracking
    reg [9:0] base_poc;         // POC of the last I-frame (0, 32, 64...)
    reg [4:0] gop_idx;          // 0 to 15 (Index into the 16-frame ROM)
    reg [15:0] frames_encoded;
    
    // Internal POC to Slot Mapping (DPB Cache)
    reg [9:0] slot_map_poc [0:7];
    reg       slot_map_valid [0:7];

    // Internal 2D arrays for Reference Picture Lists
    reg [2:0] int_ref_l0 [0:`MAX_REF_ACTIVE-1];
    reg [2:0] int_ref_l1 [0:`MAX_REF_ACTIVE-1];

    assign ref_l0 = {int_ref_l0[4], int_ref_l0[3], int_ref_l0[2], int_ref_l0[1], int_ref_l0[0]};
    assign ref_l1 = {int_ref_l1[4], int_ref_l1[3], int_ref_l1[2], int_ref_l1[1], int_ref_l1[0]};

    //-------------------------------------------------------------------------
    // GOP ROM Definition (encoder_randomaccess_main10.cfg)
    // Structure: {POC Offset, TempID, L0 Count, L1 Count,
    //             L0 Delta 0, 1, 2, 3, 4, L1 Delta 0, 1, 2, 3, 4}
    // Note: Deltas are signed 6-bit (-32 to +31)
    //-------------------------------------------------------------------------
    reg [4:0]  rom_poc_offset;
    reg [2:0]  rom_temp_id;
    reg [2:0]  rom_l0_cnt;
    reg [2:0]  rom_l1_cnt;
    
    reg signed [5:0] rom_l0_d0, rom_l0_d1, rom_l0_d2, rom_l0_d3, rom_l0_d4;
    reg signed [5:0] rom_l1_d0, rom_l1_d1, rom_l1_d2, rom_l1_d3, rom_l1_d4;

    always @(*) begin
        // Defaults to avoid latches
        rom_poc_offset = 0; rom_temp_id = 0;
        rom_l0_cnt = 0; rom_l1_cnt = 0;
        rom_l0_d0 = 0; rom_l0_d1 = 0; rom_l0_d2 = 0; rom_l0_d3 = 0; rom_l0_d4 = 0;
        rom_l1_d0 = 0; rom_l1_d1 = 0; rom_l1_d2 = 0; rom_l1_d3 = 0; rom_l1_d4 = 0;

        case (gop_idx)
            // Frame1: B 16 1  ... 2 2  -16 -32 
            0: begin
                rom_poc_offset=16; rom_temp_id=1; rom_l0_cnt=2; rom_l1_cnt=2;
                rom_l0_d0=-16; rom_l0_d1=-32;
                rom_l1_d0=-16; rom_l1_d1=-32; // In HM, if L1 empty, copies L0
            end
            // Frame2: B 8 1 ... 2 3  -8 -24 8
            1: begin
                rom_poc_offset=8; rom_temp_id=1; rom_l0_cnt=2; rom_l1_cnt=3;
                rom_l0_d0=-8;  rom_l0_d1=-24;
                rom_l1_d0=8;   rom_l1_d1=-8;  rom_l1_d2=-24;
            end
            // Frame3: B 4 4 ... 2 4  -4 -20 4 12
            2: begin
                rom_poc_offset=4; rom_temp_id=4; rom_l0_cnt=2; rom_l1_cnt=4;
                rom_l0_d0=-4;  rom_l0_d1=-20;
                rom_l1_d0=4;   rom_l1_d1=12;  rom_l1_d2=-4; rom_l1_d3=-20;
            end
            // Frame4: B 2 5 ... 2 5  -2 -18 2 6 14
            3: begin
                rom_poc_offset=2; rom_temp_id=5; rom_l0_cnt=2; rom_l1_cnt=5;
                rom_l0_d0=-2;  rom_l0_d1=-18;
                rom_l1_d0=2;   rom_l1_d1=6;   rom_l1_d2=14; rom_l1_d3=-2; rom_l1_d4=-18;
            end
            // Frame5: B 1 6 ... 2 5  -1 1 3 7 15
            4: begin
                rom_poc_offset=1; rom_temp_id=6; rom_l0_cnt=2; rom_l1_cnt=5;
                rom_l0_d0=-1;  rom_l0_d1=1;
                rom_l1_d0=1;   rom_l1_d1=3;   rom_l1_d2=7;  rom_l1_d3=15; rom_l1_d4=-1;
            end
            // Frame6: B 3 6 ... 2 5  -1 -3 1 5 13
            5: begin
                rom_poc_offset=3; rom_temp_id=6; rom_l0_cnt=2; rom_l1_cnt=5;
                rom_l0_d0=-1;  rom_l0_d1=-3;
                rom_l1_d0=1;   rom_l1_d1=5;   rom_l1_d2=13; rom_l1_d3=-1; rom_l1_d4=-3;
            end
            // Frame7: B 6 5 ... 2 4  -2 -6 2 10
            6: begin
                rom_poc_offset=6; rom_temp_id=5; rom_l0_cnt=2; rom_l1_cnt=4;
                rom_l0_d0=-2;  rom_l0_d1=-6;
                rom_l1_d0=2;   rom_l1_d1=10;  rom_l1_d2=-2; rom_l1_d3=-6;
            end
            // Frame8: B 5 6 ... 2 5  -1 -5 1 3 11
            7: begin
                rom_poc_offset=5; rom_temp_id=6; rom_l0_cnt=2; rom_l1_cnt=5;
                rom_l0_d0=-1;  rom_l0_d1=-5;
                rom_l1_d0=1;   rom_l1_d1=3;   rom_l1_d2=11; rom_l1_d3=-1; rom_l1_d4=-5;
            end
            // Frame9: B 7 6 ... 2 4  -1 -7 1 9
            8: begin
                rom_poc_offset=7; rom_temp_id=6; rom_l0_cnt=2; rom_l1_cnt=4;
                rom_l0_d0=-1;  rom_l0_d1=-7;
                rom_l1_d0=1;   rom_l1_d1=9;   rom_l1_d2=-1; rom_l1_d3=-7;
            end
            // Frame10: B 12 4 ... 2 3  -4 -12 4
            9: begin
                rom_poc_offset=12; rom_temp_id=4; rom_l0_cnt=2; rom_l1_cnt=3;
                rom_l0_d0=-4;  rom_l0_d1=-12;
                rom_l1_d0=4;   rom_l1_d1=-4;  rom_l1_d2=-12;
            end
            // Frame11: B 10 5 ... 2 4  -2 -10 2 6
            10: begin
                rom_poc_offset=10; rom_temp_id=5; rom_l0_cnt=2; rom_l1_cnt=4;
                rom_l0_d0=-2;  rom_l0_d1=-10;
                rom_l1_d0=2;   rom_l1_d1=6;   rom_l1_d2=-2; rom_l1_d3=-10;
            end
            // Frame12: B 9 6 ... 2 5  -1 -9 1 3 7
            11: begin
                rom_poc_offset=9; rom_temp_id=6; rom_l0_cnt=2; rom_l1_cnt=5;
                rom_l0_d0=-1;  rom_l0_d1=-9;
                rom_l1_d0=1;   rom_l1_d1=3;   rom_l1_d2=7;  rom_l1_d3=-1; rom_l1_d4=-9;
            end
            // Frame13: B 11 6 ... 2 4  -1 -11 1 5
            12: begin
                rom_poc_offset=11; rom_temp_id=6; rom_l0_cnt=2; rom_l1_cnt=4;
                rom_l0_d0=-1;  rom_l0_d1=-11;
                rom_l1_d0=1;   rom_l1_d1=5;   rom_l1_d2=-1; rom_l1_d3=-11;
            end
            // Frame14: B 14 5 ... 2 3  -2 -14 2
            13: begin
                rom_poc_offset=14; rom_temp_id=5; rom_l0_cnt=2; rom_l1_cnt=3;
                rom_l0_d0=-2;  rom_l0_d1=-14;
                rom_l1_d0=2;   rom_l1_d1=-2;  rom_l1_d2=-14;
            end
            // Frame15: B 13 6 ... 2 4  -1 -13 1 3
            14: begin
                rom_poc_offset=13; rom_temp_id=6; rom_l0_cnt=2; rom_l1_cnt=4;
                rom_l0_d0=-1;  rom_l0_d1=-13;
                rom_l1_d0=1;   rom_l1_d1=3;   rom_l1_d2=-1; rom_l1_d3=-13;
            end
            // Frame16: B 15 6 ... 2 4  -1 -3 -15 1
            15: begin
                rom_poc_offset=15; rom_temp_id=6; rom_l0_cnt=2; rom_l1_cnt=4;
                rom_l0_d0=-1;  rom_l0_d1=-3;
                rom_l1_d0=1;   rom_l1_d1=-1;  rom_l1_d2=-3; rom_l1_d3=-15; // Adjusted delta logic
            end
        endcase
    end

    //-------------------------------------------------------------------------
    // Function: Find physical slot for a given POC
    // Maps the calculated target reference POC to the slot index (0-7)
    //-------------------------------------------------------------------------
    function [2:0] find_slot;
        input [9:0] target_poc;
        integer i;
        begin
            find_slot = 3'd0; // Default
            for (i = 0; i < 8; i = i + 1) begin
                if (slot_map_valid[i] && slot_map_poc[i] == target_poc) begin
                    find_slot = i[2:0];
                end
            end
        end
    endfunction

    // FSM State Register
    wire [9:0] target_frame_poc = base_poc + {5'b0, rom_poc_offset};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_IDLE;
        else        state <= next_state;
    end

    // FSM Next State Logic
    always @(*) begin
        next_state = state;
        case (state)
            S_IDLE: begin
                if (encode_start) next_state = S_CRA;
            end
            S_CRA: begin
                next_state = S_ALLOC;
            end
            S_ALLOC: begin
                if (alloc_ready) next_state = S_START;
            end
            S_START: begin
                next_state = S_WAIT_FRAME;
            end
            S_WAIT_FRAME: begin
                if (frame_done) next_state = S_NEXT;
            end
            S_NEXT: begin
                if (frames_encoded + 16'd1 >= total_frames) begin
                    next_state = S_DONE;
                end else begin
                    // IP pattern: next frame is P (go to S_ALLOC)
                    next_state = S_ALLOC;
                end
            end
            S_DONE: begin
                next_state = S_IDLE;
            end
            default: next_state = S_IDLE;
        endcase
    end

    reg is_intra;

    // FSM Output & Datapath
    integer idx;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_start      <= 1'b0;
            encode_done      <= 1'b0;
            alloc_valid      <= 1'b0;
            free_valid       <= 1'b0;
            is_intra         <= 1'b0;
            
            base_poc         <= 10'd0;
            gop_idx          <= 5'd0;
            frames_encoded   <= 16'd0;
            
            for (idx = 0; idx < 8; idx = idx + 1) begin
                slot_map_valid[idx] <= 1'b0;
                slot_map_poc[idx]   <= 10'd0;
            end
        end else begin
            // Default pulse clears
            frame_start <= 1'b0;
            encode_done <= 1'b0;
            alloc_valid <= 1'b0;
            free_valid  <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (encode_start) begin
                        base_poc       <= 10'd0;
                        gop_idx        <= 5'd0;
                        frames_encoded <= 16'd0;
                        is_intra       <= 1'b1;
                    end
                end

                S_CRA: begin
                    // Setup IDR Intra Frame
                    frame_slice_type <= SLICE_I;
                    frame_poc        <= base_poc;
                    temporal_id      <= 3'd0;
                    nal_type         <= NAL_IDR_W_RADL;
                    
                    alloc_poc        <= base_poc;
                    is_intra         <= 1'b1;
                    
                    // I-frames don't have reference lists
                    ref_l0_count     <= 3'd0;
                    ref_l1_count     <= 3'd0;
                end

                S_ALLOC: begin
                    if (!is_intra) begin
                        if (GOP_STRUCTURE == 1 && frames_encoded >= 16'd2) begin
                            // B-Slice for IPBB pattern
                            frame_slice_type <= SLICE_B;
                            frame_poc        <= base_poc;
                            temporal_id      <= 3'd0;
                            nal_type         <= NAL_TRAIL_R;
                            alloc_poc        <= base_poc;
                            
                            ref_l0_count     <= 3'd1;
                            ref_l1_count     <= 3'd1;
                            int_ref_l0[0]    <= find_slot(base_poc - 10'd1);
                            int_ref_l1[0]    <= find_slot(base_poc - 10'd1); // Aligned with HM RefPicList1 (RPS delta=-1)
                        end else begin
                            // P-Frame for IP pattern
                            frame_slice_type <= SLICE_P;
                            frame_poc        <= base_poc;
                            temporal_id      <= 3'd0;
                            nal_type         <= NAL_TRAIL_R;
                            alloc_poc        <= base_poc;
                            
                            ref_l0_count     <= 3'd1;
                            ref_l1_count     <= 3'd0;
                            int_ref_l0[0]    <= find_slot(base_poc - 10'd1);
                            int_ref_l1[0]    <= 3'd0;
                        end
                    end

                    // DPB Slot Recycling: Free POC - 2 when base_poc >= 2 (sliding window RPS delta=-1)
                    if (base_poc >= 10'd2) begin
                        free_valid <= 1'b1;
                        free_slot  <= find_slot(base_poc - 10'd2);
                        slot_map_valid[find_slot(base_poc - 10'd2)] <= 1'b0;
                        $display("Time=%0t: [GOP] FREE slot=%0d poc=%0d", 
                                 $time, find_slot(base_poc - 10'd2), base_poc - 10'd2);
                    end

                    // Fire allocation to frame_store
                    alloc_valid <= 1'b1;
                    if (alloc_ready) begin
                        // Map the physical slot so we can use it in the future
                        slot_map_valid[alloc_slot] <= 1'b1;
                        slot_map_poc[alloc_slot]   <= base_poc;
                        $display("Time=%0t: [GOP] ALLOC slot=%0d poc=%0d is_intra=%0b ref_l0[0]=%0d find_slot(%0d)=%0d", 
                                 $time, alloc_slot, base_poc, is_intra, find_slot(base_poc - 10'd1), base_poc - 10'd1, find_slot(base_poc - 10'd1));
                        $display("Time=%0t: [GOP] slot_map: v[0]=%b p[0]=%0d, v[1]=%b p[1]=%0d, v[2]=%b p[2]=%0d, v[3]=%b p[3]=%0d",
                                 $time, slot_map_valid[0], slot_map_poc[0], slot_map_valid[1], slot_map_poc[1],
                                 slot_map_valid[2], slot_map_poc[2], slot_map_valid[3], slot_map_poc[3]);
                    end
                end

                S_START: begin
                    frame_start <= 1'b1;
                    $display("Time=%0t: [GOP_CONTROLLER] Started frame POC=%0d, gop_idx=%0d", $time, frame_poc, gop_idx);
                end

                S_NEXT: begin
                    frames_encoded <= frames_encoded + 16'd1;
                    
                    // Advance POC
                    base_poc  <= base_poc + 10'd1;
                    alloc_poc <= base_poc + 10'd1;
                    frame_poc <= base_poc + 10'd1;
                    is_intra  <= 1'b0;
                    gop_idx   <= gop_idx + 5'd1;
                end

                S_DONE: begin
                    encode_done <= 1'b1;
                end
            endcase
        end
    end

endmodule
