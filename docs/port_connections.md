# Port Connections & Interface Specifications

Please refer to the comprehensive top-level port and interconnect documentation:
- **[HEVC Top-Level Port Connection & Interface Specification](file:///d:/UIT_Doc/hevc_hw_encoder/docs/port_connections_hevc_top.md)** (`docs/port_connections_hevc_top.md`)

This document provides:
1. Detailed parameter specifications (`FRAME_WIDTH`, `FRAME_HEIGHT`, `GOP_STRUCTURE`, `BASE_QP`, `RC_ENABLE`, `TARGET_BITRATE_KBPS`).
2. Core top-level port map for [`hevc_encoder_top`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/top/hevc_encoder_top.v) (Host Control, YUV 4:2:0 Video Stream, Annex B Bitstream, AXI4 DRAM Master, and Dynamic Runtime Configuration).
3. SoC wrapper port map and 32-bit register address map for [`hevc_encoder_axi_top`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/top/hevc_encoder_axi_top.v) (AXI4-Lite CSRs, AXI4-Stream Video, AXI4-Stream Bitstream, AXI4 Master, IRQ).
4. Subsystem Interconnect Matrix across all 27 instantiated hardware module instances (23 distinct module architectures).
