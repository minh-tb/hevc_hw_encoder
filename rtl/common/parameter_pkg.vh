//=============================================================================
// parameter_pkg.vh
// HEVC Hardware Encoder/Decoder — Global Parameter Package
//
// Formalized Three-Tier Configuration Hierarchy:
// +-------------------------------------------------------------------------+
// | Configuration Tier        | Mutability           | Implementation       |
// +-------------------------------------------------------------------------+
// | Tier 1: System Parameters | Fully Reconfigurable | Verilog Parameters   |
// | Tier 2: Silicon Invariants| Fixed Physical Core  | Hardwired Gates      |
// | Tier 3: Pre-computed ROMs | Discrete Enumeration | Case-Selected Arrays |
// +-------------------------------------------------------------------------+
//
// Include this in every RTL module:  `include "parameter_pkg.vh"
//=============================================================================

`ifndef PARAMETER_PKG_VH
`define PARAMETER_PKG_VH

//=============================================================================
// TIER 1: USER-CONFIGURABLE SYSTEM PARAMETERS
// Modify these to retarget pipeline operating conditions.
//=============================================================================

//-----------------------------------------------------------------------------
// 1. BIT DEPTH & SAMPLE WIDTH
//-----------------------------------------------------------------------------
`define PIXEL_WIDTH         10          // Bus width for one sample (8 or 10)
`define BIT_DEPTH           10          // Internal codec luma bit depth (8 or 10)
`define BIT_DEPTH_CHROMA    10          // Internal codec chroma bit depth (8 or 10)
`define MID_GRAY_SAMPLE     (1 << (`PIXEL_WIDTH - 1)) // 512 for 10-bit, 128 for 8-bit

//-----------------------------------------------------------------------------
// 2. DEFAULT FRAME DIMENSIONS & TOP-LEVEL DEFAULTS
//-----------------------------------------------------------------------------
`ifndef DEFAULT_FRAME_WIDTH
`define DEFAULT_FRAME_WIDTH      128    // Default frame width (64, 128, 256, 1920, 3840 in ROM)
`endif
`ifndef DEFAULT_FRAME_HEIGHT
`define DEFAULT_FRAME_HEIGHT     128    // Default frame height
`endif
`define DEFAULT_GOP_STRUCTURE    1      // 0: IPP, 1: Low-Delay B (IPBB), 2: Hierarchical B
`define TARGET_BITRATE_DEFAULT   16'd5000 // Target bitrate in kbps
`define TARGET_FPS_DEFAULT       8'd30    // Target frame rate

//-----------------------------------------------------------------------------
// 3. SIMULATION & VERIFICATION STALL WATCHDOG LIMITS
//-----------------------------------------------------------------------------
`define STALL_WATCHDOG_LIMIT     32'd25000  // Consecutive stall cycles before watchdog trip
`define CTU_WATCHDOG_LIMIT       32'd150000 // Max cycles per CTU before timeout
`define HEARTBEAT_INTERVAL       32'd25000  // Heartbeat output interval in cycles

//=============================================================================
// TIER 2: HEVC STANDARD & SILICON ARCHITECTURE INVARIANTS (DO NOT MODIFY)
// Physical datapath geometries. Altering these requires rebuilding dedicated
// hardware pipeline stages, line buffers, and arithmetic cores.
//=============================================================================

//-----------------------------------------------------------------------------
// 3. CTU / CU STRUCTURE
//    Config: MaxCUWidth=64, MaxCUHeight=64, MaxPartitionDepth=3
//            (HW-limited: min CU = 8x8; depth 0..3 → 64,32,16,8)
//-----------------------------------------------------------------------------
`define CTU_SIZE            64          // Largest coding unit size in pixels
`define CTU_SIZE_LOG2       6           // log2(64)
`define MIN_CU_SIZE         8           // 64 >> 3 = 8 — smallest CU (limited to 8x8 for FPGA HW simplicity)
`define MIN_CU_SIZE_LOG2    3
`define MAX_PART_DEPTH      3           // Quadtree max split depth: 0..3 → 64,32,16,8
`define NUM_CU_DEPTHS       4           // Depth 0=64, 1=32, 2=16, 3=8

// CU sizes at each depth
`define CU_SIZE_D0          64
`define CU_SIZE_D1          32
`define CU_SIZE_D2          16
`define CU_SIZE_D3          8

//-----------------------------------------------------------------------------
// 3. TRANSFORM UNIT STRUCTURE
//    Config: QuadtreeTULog2MaxSize=5, QuadtreeTULog2MinSize=2
//            QuadtreeTUMaxDepthInter=3, QuadtreeTUMaxDepthIntra=3
//-----------------------------------------------------------------------------
`define TU_LOG2_MAX         5           // Max TU = 2^5 = 32x32
`define TU_LOG2_MIN         2           // Min TU = 2^2 = 4x4
`define TU_SIZE_MAX         32
`define TU_SIZE_MIN         4
`define TU_MAX_DEPTH_INTER  3
`define TU_MAX_DEPTH_INTRA  3

// Number of valid TU sizes: 4, 8, 16, 32
`define NUM_TU_SIZES        4
`define COEFF_WIDTH         16          // Transform coefficient bus width (signed)
`define COEFF_WIDTH_EXT     22          // Extended width inside butterfly stages (22 bits safe for 32x32 DCT)

//-----------------------------------------------------------------------------
// 4. GOP / CODING STRUCTURE
//    Config: IntraPeriod=-32, DecodingRefreshType=1 (CRA),
//            GOPSize=16, ReWriteParamSetsFlag=1
//-----------------------------------------------------------------------------
`define GOP_SIZE            16          // Frames per GOP
`define GOP_SIZE_LOG2       4
`define INTRA_PERIOD        32          // |IntraPeriod|; open-GOP CRA every 32
`define DECODING_REFRESH    1           // 1=CRA (Clean Random Access)
`define REWRITE_PARAM_SETS  1          // Write SPS/PPS with every IRAP
`define MAX_TEMPORAL_LAYERS 5          // Temporal IDs 0..4 used in B-frame hier.

// Hierarchical B-frame temporal IDs from config Frame1..Frame16
// temporal_id 0 = anchor (Frame1: POC16)
// temporal_id 1 = Frame2: POC8
// temporal_id 2 = Frame3/10: POC4/12
// temporal_id 3 = Frame4/7/11/14: POC2/6/10/14
// temporal_id 4 = Frame5/6/8/9/12/13/15/16: POC1/3/5/7/9/11/13/15
`define TEMP_ID_ANCHOR      0
`define TEMP_ID_HALF        1
`define TEMP_ID_QUARTER     2
`define TEMP_ID_EIGHTH      3
`define TEMP_ID_LEAF        4

//-----------------------------------------------------------------------------
// 5. QUANTIZATION
//    Config: QP=32, MaxDeltaQP=0, MaxCuDQPDepth=0,
//            RDOQ=0, RDOQTS=0, IntraQPOffset=-3
//            LambdaFromQpEnable=1
//-----------------------------------------------------------------------------
`define QP_DEFAULT          29          // Hardcoded to 29 to match HM I-slice QP (32 - 3 offset)
`define QP_WIDTH            6           // QP range 0–51 needs 6 bits
`define QP_MAX              51
`define QP_MIN              0
`define INTRA_QP_OFFSET    -3          // signed offset for intra frames
`define MAX_DELTA_QP        0           // No per-CU delta QP → simplifies HW
`define MAX_CU_DQP_DEPTH    0
`define RDOQ_ENABLE         0
`define RDOQTS_ENABLE       0
// Flat quantization matrix (ScalingList=0 → all MF entries same per QP)
// MF(QP) = flat_scale[QP%6], right-shift by (29 + QP/6)
// flat_scale for QP%6 = 0..5:
`define FLAT_SCALE_0        26214       // QP%6==0
`define FLAT_SCALE_1        23302       // QP%6==1
`define FLAT_SCALE_2        20560       // QP%6==2
`define FLAT_SCALE_3        18396       // QP%6==3
`define FLAT_SCALE_4        16384       // QP%6==4
`define FLAT_SCALE_5        14564       // QP%6==5

//-----------------------------------------------------------------------------
// 6. MOTION ESTIMATION
//    Config: FastSearch=1 (TZ), SearchRange=32, ASR=1,
//            MinSearchWindow=64, BipredSearchRange=2,
//            HadamardME=0, FEN=1, FDM=1
//-----------------------------------------------------------------------------
`define ME_SEARCH_RANGE     32          // Integer pel search range
`define ME_SEARCH_LOG2      6           // ceil(log2(64+1)) = 7 → use 6 for ±32 signed
`define ME_MV_WIDTH         8           // TZ search engine internal MV width (±32 → 6+sign=7; use 8)
`define ME_BIPRED_RANGE     2           // Bi-pred refinement range
`define ME_MIN_WIN          64          // ASR minimum window (MinSearchWindow=64 from config)
`define ME_USE_HADAMARD     0           // SATD cost for fractional ME
`define ME_FEN              1           // Fast encoder decision
`define ME_FDM              1           // Fast merge RD
`define MV_FRAC_BITS        2           // Quarter-pel: 2 fractional bits
`define MV_INT_BITS         6           // Integer part bits: ±32 needs 6 bits signed
                                        // NOTE: AMVP/merge candidates from neighbours may
                                        // have larger MVs; use MV_TOTAL_BITS=12 for the bus
`define MV_TOTAL_BITS       12          // Total MV component bits (int+frac, signed)
                                        // = MV_INT_BITS(6) + MV_FRAC_BITS(2) + 4 headroom
                                        // Matches mvx/mvy width in hevc_interfaces.vh

// TZ search parameters
`define TZ_IMAX             8           // Max step iterations
`define TZ_RASTER_STEP      5           // Raster scan step when best > threshold

//-----------------------------------------------------------------------------
// 7. INTRA PREDICTION
//    Config: (main10 profile — 35 modes: Planar=0, DC=1, Angular=2..34)
//-----------------------------------------------------------------------------
`define NUM_INTRA_MODES     35
`define INTRA_PLANAR        0
`define INTRA_DC            1
`define INTRA_ANG_FIRST     2
`define INTRA_ANG_LAST      34
`define INTRA_MODE_WIDTH    6           // 6 bits to encode mode 0..34
`define NUM_MPM             3           // Most probable modes list size

//-----------------------------------------------------------------------------
// 8. DEBLOCKING FILTER
//    Config: LoopFilterOffsetInPPS=1, LoopFilterDisable=0,
//            LoopFilterBetaOffset_div2=0, LoopFilterTcOffset_div2=0
//-----------------------------------------------------------------------------
`define DB_ENABLE           1           // Deblocking ON
`define DB_OFFSET_IN_PPS    1           // Constant offsets in PPS
`define DB_BETA_OFFSET      0           // Beta offset div2 = 0
`define DB_TC_OFFSET        0           // Tc offset div2 = 0

//-----------------------------------------------------------------------------
// 9. SAO
//    Config: SAO=1, SAOLcuBoundary=0
//-----------------------------------------------------------------------------
`define SAO_ENABLE          1
`define SAO_LCU_BOUNDARY    0           // Use deblocked pixels at boundary
`define SAO_NUM_EO_TYPES    4           // Edge offset directions
`define SAO_NUM_EO_CATS     5           // EO categories: -2,-1,0,+1,+2
`define SAO_NUM_BO_BANDS    32          // Band offset bands
`define SAO_OFFSET_WIDTH    5           // Total bits per offset (1 sign + 4 magnitude)
`define SAO_OFFSET_MAX      15          // Max magnitude (HEVC spec: offset_abs 4-bit → 0..15)

//-----------------------------------------------------------------------------
// 10. CODING TOOLS
//    Config: AMP=0, TransformSkip=0, TransformSkipFast=0
//            SAOLcuBoundary=0
//-----------------------------------------------------------------------------
`define AMP_ENABLE          0           // Asymmetric motion partitions
`define TRANSFORM_SKIP      0           // Transform skip flag allowed
`define TRANSFORM_SKIP_FAST 0

//-----------------------------------------------------------------------------
// 11. IN-LOOP DISABLED FEATURES
//    (keep these as 0 — used as guards in RTL to tie off logic)
//-----------------------------------------------------------------------------
`define RATE_CONTROL        0           // RateControl=0 → fixed QP only
`define RATE_CONTROL_ENABLE `RATE_CONTROL
`define PCM_ENABLE          0           // PCMEnabledFlag=0
`define WAVEFRONT_ENABLE    0           // WaveFrontSynchro=0
`define SCALING_LIST        0           // ScalingList=0 → flat matrix
`define TRANSQUANT_BYPASS   0           // TransquantBypassEnableFlag=0
`define SLICE_MODE          0           // SliceMode=0 → no slice partitioning
`define TILES_ENABLE        0           // NumTileColumnsMinus1=0 → 1 tile

//-----------------------------------------------------------------------------
// 12. PROFILE / LEVEL (for SPS writing)
//-----------------------------------------------------------------------------
`define PROFILE_MAIN10      2           // profile_idc = 2
`define LEVEL_IDC           51          // Level 5.1 (covers 4K @ 60fps headroom)
`define TIER_FLAG           0           // Main tier

//-----------------------------------------------------------------------------
// 13. CABAC / ENTROPY
//-----------------------------------------------------------------------------
`define NUM_CTX_MODELS      154         // HEVC main10 context model count
`define CTX_STATE_WIDTH     7           // 64-state MPS: 6-bit state + 1-bit MPS
`define CABAC_REG_WIDTH     16          // Range/offset register width

//-----------------------------------------------------------------------------
// 14. REFERENCE PICTURE BUFFER (DPB)
//    From GOP structure: max 5 refs needed (see Frame4/5 lines in config)
//-----------------------------------------------------------------------------
`define MAX_REF_PICS        8           // DPB slots (covers GOP16 needing up to 5 active refs)
`define MAX_REF_ACTIVE      5           // Max #ref_pics in lists (from config GOP table)
`define DPB_SLOTS           `MAX_REF_PICS // Alias — always keep equal to MAX_REF_PICS

//-----------------------------------------------------------------------------
// 15. PIPELINE / TIMING
//-----------------------------------------------------------------------------
`define CTU_PIPELINE_DEPTH  4           // CTU processing pipeline stages
`define ME_PIPELINE_DEPTH   6           // Motion estimation pipeline stages
`define DCT_PIPELINE_DEPTH  4           // DCT pipeline stages (4x4 baseline)

//-----------------------------------------------------------------------------
// 16. MEMORY LAYOUT HELPERS
//-----------------------------------------------------------------------------
// One 10-bit luma sample = 10 bits → pack 2 per 32-bit word (12 bits padding)
// NOTE: 2 samples/word chosen for AXI power-of-2 alignment; avoids modulo-3 counter logic
`define SAMPLES_PER_WORD    2
`define WORD_WIDTH          32

// Frame / CTU address widths — must stay in sync with hevc_interfaces.vh
`define FRAME_DIM_WIDTH     12          // Bits for frame_width/height in pixels (covers 4K: 3840/2160 < 4095)
`define CTU_ADDR_WIDTH      13          // Linear CTU address bits (4K needs 11-bit; 13 gives 8K headroom)
`define CTU_COORD_WIDTH     6           // CTU x/y column/row index (max 4096/64=64 → 6-bit exact)

// CTU luma sample count
`define CTU_LUMA_SAMPLES    4096        // 64*64
`define CTU_CB_SAMPLES      1024        // 32*32 (4:2:0)
`define CTU_CR_SAMPLES      1024

//=============================================================================
// TIER 3: PRE-COMPUTED PARAMETER SET SELECTORS
// Supported pre-compiled bitstream headers in param_set_writer.v
//=============================================================================
`define SPS_RES_64X64       3'd0
`define SPS_RES_128X128     3'd1
`define SPS_RES_256X256     3'd2
`define SPS_RES_1080P       3'd3    // 1920x1080 Full HD
`define SPS_RES_1088P       3'd4    // 1920x1088 (CTU-aligned Full HD)
`define SPS_RES_4K          3'd5    // 3840x2160 4K UHD

`endif // PARAMETER_PKG_VH
