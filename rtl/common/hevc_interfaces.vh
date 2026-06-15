//=============================================================================
// hevc_interfaces.vh
// HEVC Hardware Encoder/Decoder — Bus & Interface Definitions
//
// Mapped from HM source structures:
//   TComDataCU  → cu_info_if
//   TComMv      → mv_if
//   TComYuv     → pixel_bus_if
//   TComTU      → tu_info_if
//   TComPic     → ref_pic_if
//
// Include after parameter_pkg.vh:
//   `include "parameter_pkg.vh"
//   `include "hevc_interfaces.vh"
//=============================================================================

`ifndef HEVC_INTERFACES_VH
`define HEVC_INTERFACES_VH

//=============================================================================
// SECTION 1: PIXEL BUS
// Maps to: TComYuv (m_apiBuf)
// Used between: input_buffer → CTU partitioner → intra/inter pred → recon
//=============================================================================

// Component selector (matches HM ComponentID enum)
`define COMP_Y   2'b00   // Luma
`define COMP_CB  2'b01   // Chroma Cb
`define COMP_CR  2'b10   // Chroma Cr

// Pixel handshake bus (one sample per cycle, valid/ready)
// For block transfers use pixel_block_if below
//
// Signal        Width   Description
// pixel         10      One 10-bit sample (luma or chroma)
// comp          2       Component: Y=0, Cb=1, Cr=2
// x, y          7       Sample position within frame CTU grid (0..127)
// valid         1       Producer asserts when pixel is valid
// ready         1       Consumer asserts when ready to accept
`define PIXEL_BUS_SIGNALS \
    logic [`PIXEL_WIDTH-1:0]  pixel; \
    logic [1:0]                comp;  \
    logic [6:0]                x;     \
    logic [6:0]                y;     \
    logic                      valid; \
    logic                      ready;

//=============================================================================
// SECTION 2: PIXEL BLOCK BUS
// Maps to: TComYuv block copy (copyFromPicYuv, etc.)
// Used for: CTU → pred unit pixel block handoff (64×64 max)
//
// Signal        Width       Description
// data          10          One pixel (clocked out row by row)
// blk_x, blk_y 7           Top-left corner of block in CTU-relative coords
// blk_w, blk_h 7           Block width/height (4,8,16,32,64)
// comp          2           Component
// sof           1           Start of frame
// sob           1           Start of block
// eob           1           End of block
// valid         1
// ready         1
//=============================================================================
`define PIXEL_BLOCK_BUS_SIGNALS \
    logic [`PIXEL_WIDTH-1:0]  data;   \
    logic [6:0]                blk_x; \
    logic [6:0]                blk_y; \
    logic [6:0]                blk_w; \
    logic [6:0]                blk_h; \
    logic [1:0]                comp;  \
    logic                      sof;   \
    logic                      sob;   \
    logic                      eob;   \
    logic                      valid; \
    logic                      ready;

//=============================================================================
// SECTION 3: CTU INFO BUS
// Maps to: TComDataCU (top-level CTU descriptor)
// Used between: slice_controller → ctu_partitioner → all prediction units
//
// Signal            Width   Description
// ctu_addr          16      Linear CTU address (raster scan)
// ctu_x, ctu_y      10      CTU position in frame (unit: CTU = 64px)
// frame_width       11      Frame width  in CTUs (max 4096/64=64 → 7-bit, use 11 for px)
// frame_height      11      Frame height in CTUs
// slice_type        2       0=B, 1=P, 2=I  (matches HM SliceType)
// poc               10      Picture order count
// temporal_id       3       Temporal layer 0..4
// is_irap           1       1 if this frame is CRA/IDR
// qp                6       Base QP for this CTU (fixed at QP_DEFAULT=32)
// valid             1
// ready             1
//=============================================================================
`define CTU_INFO_BUS_SIGNALS \
    logic [15:0]  ctu_addr;     \
    logic [9:0]   ctu_x;        \
    logic [9:0]   ctu_y;        \
    logic [10:0]  frame_width;  \
    logic [10:0]  frame_height; \
    logic [1:0]   slice_type;   \
    logic [9:0]   poc;          \
    logic [2:0]   temporal_id;  \
    logic         is_irap;      \
    logic [5:0]   qp;           \
    logic         valid;        \
    logic         ready;

// Slice type encoding (matches HM SliceType enum)
`define SLICE_B   2'd0
`define SLICE_P   2'd1
`define SLICE_I   2'd2

//=============================================================================
// SECTION 4: CU INFO BUS
// Maps to: TComDataCU per-CU fields
// Used between: ctu_partitioner → mode_decision → pred units
//
// Signal            Width   Description
// cu_x, cu_y        6       CU top-left in CTU-relative pixels (0..63 → 6-bit)
// cu_size           7       CU size: 8, 16, 32, 64
// cu_depth          2       Quadtree depth 0..3 (MaxPartitionDepth=4 → 2-bit)
// pred_mode         1       0=inter, 1=intra  (PredMode in HM)
// part_mode         3       Partition mode (SIZE_2Nx2N=0 .. SIZE_nRx2N=7)
// skip_flag         1       Merge skip (no residual)
// merge_flag        1       Merge mode for inter
// merge_idx         3       Merge candidate index 0..4
// intra_mode_luma   6       Intra mode for luma (0..34)
// intra_mode_chroma 6       Intra mode for chroma (0..34 or 36=DM)
// qp                6       CU QP (= slice QP when MaxDeltaQP=0)
// cbf_luma          1       Coded block flag luma
// cbf_cb            1       Coded block flag Cb
// cbf_cr            1       Coded block flag Cr
// valid             1
// ready             1
//=============================================================================
`define CU_INFO_BUS_SIGNALS \
    logic [5:0]  cu_x;            \
    logic [5:0]  cu_y;            \
    logic [6:0]  cu_size;         \
    logic [1:0]  cu_depth;        \
    logic        pred_mode;       \
    logic [2:0]  part_mode;       \
    logic        skip_flag;       \
    logic        merge_flag;      \
    logic [2:0]  merge_idx;       \
    logic [5:0]  intra_mode_luma; \
    logic [5:0]  intra_mode_chroma; \
    logic [5:0]  qp;              \
    logic        cbf_luma;        \
    logic        cbf_cb;          \
    logic        cbf_cr;          \
    logic        valid;           \
    logic        ready;

// Partition mode encoding (matches HM PartSize enum)
`define PART_2Nx2N   3'd0   // Square (most common — always implement first)
`define PART_2NxN    3'd1   // Horizontal half
`define PART_NX2N    3'd2   // Vertical half
`define PART_NxN     3'd3   // Quarter (intra only)

// Prediction mode
`define PRED_INTER   1'b0
`define PRED_INTRA   1'b1

//=============================================================================
// SECTION 5: TU INFO BUS
// Maps to: TComTU (transform unit descriptor)
// Used between: pu_cu_splitter → dct_top → quant_unit → cabac
//
// Signal            Width   Description
// tu_x, tu_y        6       TU top-left in CTU-relative pixels
// tu_size_log2      3       log2 of TU size: 2=4x4, 3=8x8, 4=16x16, 5=32x32
// comp              2       Component Y/Cb/Cr
// is_luma           1       Convenience flag
// last_tu_in_cu     1       Final TU in this CU
// valid             1
// ready             1
//=============================================================================
`define TU_INFO_BUS_SIGNALS \
    logic [5:0]  tu_x;           \
    logic [5:0]  tu_y;           \
    logic [2:0]  tu_size_log2;   \
    logic [1:0]  comp;           \
    logic        is_luma;        \
    logic        last_tu_in_cu;  \
    logic        valid;          \
    logic        ready;

//=============================================================================
// SECTION 6: COEFFICIENT BUS
// Maps to: TCoeff* (post-transform, post-quant coefficients in HM)
// Used between: quant_unit → cabac_enc / inv_quant
//
// Carries one coefficient per cycle, with position embedded.
// Max TU = 32×32 = 1024 coefficients.
//
// Signal            Width   Description
// coeff             16      Signed quantized coefficient
// scan_idx          10      Scan position 0..1023 (diagonal scan order)
// tu_size_log2      3       log2 TU size (to interpret scan_idx)
// comp              2       Component
// last_sig          1       1 if this is last non-zero coeff (HM: lastSig)
// valid             1
// ready             1
//=============================================================================
`define COEFF_BUS_SIGNALS \
    logic signed [15:0]  coeff;        \
    logic [9:0]           scan_idx;    \
    logic [2:0]           tu_size_log2;\
    logic [1:0]           comp;        \
    logic                 last_sig;    \
    logic                 valid;       \
    logic                 ready;

//=============================================================================
// SECTION 7: MOTION VECTOR BUS
// Maps to: TComMv (m_iHor, m_iVer in HM — quarter-pel units)
// Used between: me_top → mc_unit → mvp_predictor → cabac
//
// HM convention: MV stored in quarter-pel units
//   integer pel (384) → stored as 384*4 = 1536 → needs 11 bits signed
//
// Signal            Width   Description
// mvx, mvy          16      MV components in qpel units (signed)
//                           Matches TComMv::m_iHor/m_iVer (Short = int16)
//                           Range: -32768..+32767 qpel = ±8191 integer pels
//                           Covers HEVC spec max log2_max_mv_length=15
//                           For this config SearchRange=384 → max qpel=1536
// ref_idx           3       Reference picture index 0..7
// list              1       RefPicList: 0=L0, 1=L1
// pu_x, pu_y        7       PU top-left in CTU-relative pixels
// pu_w, pu_h        7       PU width/height in pixels
// mvp_idx           1       MVP index (0 or 1) for MVD coding
// valid             1
// ready             1
//=============================================================================
`define MV_BUS_SIGNALS \
    logic signed [15:0]  mvx;     \
    logic signed [15:0]  mvy;     \
    logic [2:0]           ref_idx; \
    logic                 list;    \
    logic [6:0]           pu_x;   \
    logic [6:0]           pu_y;   \
    logic [6:0]           pu_w;   \
    logic [6:0]           pu_h;   \
    logic                 mvp_idx;\
    logic                 valid;  \
    logic                 ready;

// Reference list selector
`define REF_LIST_0   1'b0
`define REF_LIST_1   1'b1

//=============================================================================
// SECTION 8: REFERENCE PICTURE BUFFER ACCESS
// Maps to: TComPicYuv (reference frame store in HM)
// Used between: ref_frame_buffer → mc_unit / hpel_filter
//
// Request/response handshake for random-access reads of ref frames.
//
// REQUEST signals:
//   req_valid       1       Read request valid
//   req_ready       1       Buffer ready for request
//   ref_idx         3       Which reference frame slot
//   pel_x, pel_y    13      Pixel coords, signed for negative padding margin
//                           signed [12:0] → -4096..+4095
//                           Covers up to 4K (3840 + 96px pad = 3936 < 4095)
//                           Extend to signed [13:0] for 8K support
//   comp            2       Component
//   blk_w, blk_h    7       Block size to prefetch
//
// RESPONSE signals:
//   resp_valid      1       Data valid from buffer
//   resp_ready      1       Requester ready
//   data            10      One sample (streamed out row by row)
//=============================================================================
`define REF_PIC_REQ_SIGNALS \
    logic        req_valid;  \
    logic        req_ready;  \
    logic [2:0]  ref_idx;    \
    logic signed [12:0] pel_x; \
    logic signed [12:0] pel_y; \
    logic [1:0]  comp;       \
    logic [6:0]  blk_w;      \
    logic [6:0]  blk_h;

`define REF_PIC_RESP_SIGNALS \
    logic                    resp_valid; \
    logic                    resp_ready; \
    logic [`PIXEL_WIDTH-1:0] data;

//=============================================================================
// SECTION 9: CABAC BIN BUS
// Maps to: TEncBinIf::encodeBin() interface in HM
// Used between: syntax_* writers → bin_encoder → range_coder
//
// Signal            Width   Description
// bin               1       The binary symbol to encode
// ctx_idx           8       Context model index (0..153, or bypass flag)
// bypass            1       1 = bypass (equiprobable) mode
// term              1       1 = terminate (flush) bin
// valid             1
// ready             1
//=============================================================================
`define CABAC_BIN_BUS_SIGNALS \
    logic        bin;     \
    logic [7:0]  ctx_idx; \
    logic        bypass;  \
    logic        term;    \
    logic        valid;   \
    logic        ready;

// CABAC special context indices (matches HM ContextModel array layout)
`define CTX_BYPASS       8'd255   // sentinel: bypass mode
`define CTX_TERM         8'd254   // sentinel: terminate

//=============================================================================
// SECTION 10: BITSTREAM OUTPUT BUS
// Maps to: TComOutputBitstream in HM
// Used between: range_coder → output_fifo → nal_writer
//
// Signal            Width   Description
// byte_out          8       One output byte
// valid             1
// ready             1
// nal_start         1       Start of NAL unit
// nal_type          6       NAL unit type (matches HM NalUnitType enum)
//=============================================================================
`define BITSTREAM_BUS_SIGNALS \
    logic [7:0]  byte_out;  \
    logic        valid;     \
    logic        ready;     \
    logic        nal_start; \
    logic [5:0]  nal_type;

// NAL unit types (subset used — matches HM NalUnitType)
`define NAL_TRAIL_R      6'd1    // Regular trailing B/P slice
`define NAL_TRAIL_N      6'd0    // Non-reference trailing
`define NAL_CRA_NUT      6'd21   // CRA (our IRAP type, DecodingRefreshType=1)
`define NAL_SPS_NUT      6'd33   // SPS
`define NAL_PPS_NUT      6'd34   // PPS
`define NAL_AUD_NUT      6'd35   // Access unit delimiter

//=============================================================================
// SECTION 11: HANDSHAKE MACROS
// Standard valid/ready handshake used on all buses above
//=============================================================================

// Fire condition: both sides agree this cycle
`define HANDSHAKE_FIRE(valid, ready)   ((valid) && (ready))

// Stall condition: producer has data but consumer not ready
`define HANDSHAKE_STALL(valid, ready)  ((valid) && !(ready))

//=============================================================================
// SECTION 12: SCAN ORDER TABLES
// Maps to: HM g_auiSigLastScan (diagonal scan used for coefficients)
// These are used as ROM constants in cabac / coeff_syntax modules.
// Defined here so all modules share one definition.
//
// Diagonal scan order for 4x4 (16 entries):
//   HM: g_auiSigLastScan[SCAN_DIAG][log2-2][pos]
//   pos 0 = (0,0), 1 = (1,0), 2 = (0,1), 3 = (2,0) ...
//=============================================================================

// 4x4 diagonal scan: scan_pos → (col, row)
// Encoded as {col[1:0], row[1:0]} per entry
`define DIAG_SCAN_4x4_0   4'b0000  // (0,0)
`define DIAG_SCAN_4x4_1   4'b0100  // (1,0)
`define DIAG_SCAN_4x4_2   4'b0001  // (0,1)
`define DIAG_SCAN_4x4_3   4'b1000  // (2,0)
`define DIAG_SCAN_4x4_4   4'b0101  // (1,1)
`define DIAG_SCAN_4x4_5   4'b0010  // (0,2)
`define DIAG_SCAN_4x4_6   4'b1100  // (3,0)
`define DIAG_SCAN_4x4_7   4'b1001  // (2,1)
`define DIAG_SCAN_4x4_8   4'b0110  // (1,2)
`define DIAG_SCAN_4x4_9   4'b0011  // (0,3)
`define DIAG_SCAN_4x4_10  4'b1101  // (3,1)
`define DIAG_SCAN_4x4_11  4'b1010  // (2,2)
`define DIAG_SCAN_4x4_12  4'b0111  // (1,3)
`define DIAG_SCAN_4x4_13  4'b1110  // (3,2)
`define DIAG_SCAN_4x4_14  4'b1011  // (2,3)
`define DIAG_SCAN_4x4_15  4'b1111  // (3,3)

`endif // HEVC_INTERFACES_VH
