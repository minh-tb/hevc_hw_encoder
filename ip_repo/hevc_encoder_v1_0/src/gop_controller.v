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

    // Runtime configuration
    input  wire [1:0]               cfg_gop_structure, // 0: IPP, 1: IPBB, 2: Hierarchical B

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

    // Active reference slot 0 registers (upper unused slots tied to 0)
    reg [2:0] int_ref_l0_0;
    reg [2:0] int_ref_l1_0;

    assign ref_l0 = {12'd0, int_ref_l0_0};
    assign ref_l1 = {12'd0, int_ref_l1_0};

    // Active sequential IP / Low-Delay IPBB control; hierarchical-B ROM removed
    // (can be reconstructed from git history if B-frame reordering is added later).

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
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_IDLE;
        else        state <= next_state;
    end

    // FSM Next State Logic
    always @(*) begin
        next_state = state;
        case (state)
            S_IDLE: begin
                if (encode_start) next_state = (total_frames == 16'd0) ? S_DONE : S_CRA;
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
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_start      <= 1'b0;
            encode_done      <= 1'b0;
            alloc_valid      <= 1'b0;
            free_valid       <= 1'b0;
            is_intra         <= 1'b0;
            frame_slice_type <= SLICE_I;
            frame_poc        <= 10'd0;
            temporal_id      <= 3'd0;
            nal_type         <= NAL_IDR_W_RADL;
            alloc_poc        <= 10'd0;
            free_slot        <= 3'd0;
            ref_l0_count     <= 3'd0;
            ref_l1_count     <= 3'd0;
            int_ref_l0_0     <= 3'd0;
            int_ref_l1_0     <= 3'd0;
            
            base_poc         <= 10'd0;
            gop_idx          <= 5'd0;
            frames_encoded   <= 16'd0;
            
            slot_map_valid[0] <= 1'b0; slot_map_poc[0] <= 10'd0;
            slot_map_valid[1] <= 1'b0; slot_map_poc[1] <= 10'd0;
            slot_map_valid[2] <= 1'b0; slot_map_poc[2] <= 10'd0;
            slot_map_valid[3] <= 1'b0; slot_map_poc[3] <= 10'd0;
            slot_map_valid[4] <= 1'b0; slot_map_poc[4] <= 10'd0;
            slot_map_valid[5] <= 1'b0; slot_map_poc[5] <= 10'd0;
            slot_map_valid[6] <= 1'b0; slot_map_poc[6] <= 10'd0;
            slot_map_valid[7] <= 1'b0; slot_map_poc[7] <= 10'd0;
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
                        if (cfg_gop_structure == 2'd1 && frames_encoded >= 16'd2) begin
                            // B-Slice for IPBB pattern
                            frame_slice_type <= SLICE_B;
                            frame_poc        <= base_poc;
                            temporal_id      <= 3'd0;
                            nal_type         <= NAL_TRAIL_R;
                            alloc_poc        <= base_poc;
                            
                            ref_l0_count     <= 3'd1;
                            ref_l1_count     <= 3'd1;
                            int_ref_l0_0     <= find_slot(base_poc - 10'd1);
                            int_ref_l1_0     <= find_slot(base_poc - 10'd1); // Aligned with HM RefPicList1 (RPS delta=-1)
                        end else begin
                            // P-Frame for IP pattern
                            frame_slice_type <= SLICE_P;
                            frame_poc        <= base_poc;
                            temporal_id      <= 3'd0;
                            nal_type         <= NAL_TRAIL_R;
                            alloc_poc        <= base_poc;
                            
                            ref_l0_count     <= 3'd1;
                            ref_l1_count     <= 3'd0;
                            int_ref_l0_0     <= find_slot(base_poc - 10'd1);
                            int_ref_l1_0     <= 3'd0;
                        end
                    end

                    // DPB Slot Recycling: Free POC - 2 when base_poc >= 2 (sliding window RPS delta=-1)
                    if (alloc_ready && base_poc >= 10'd2) begin
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
                    if (gop_idx == (`GOP_SIZE - 1)) begin
                        gop_idx <= 5'd0;
                    end else begin
                        gop_idx <= gop_idx + 5'd1;
                    end
                end

                S_DONE: begin
                    encode_done <= 1'b1;
                end
            endcase
        end
    end

endmodule
