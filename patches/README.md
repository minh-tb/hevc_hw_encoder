# HM 18.0 Reference Software Patches

This directory contains verification and debug patches applied to the **HM 18.0** reference software decoder (`HM/source/Lib/TLibDecoder/`).

> [!NOTE]
> The `HM/` directory is external reference code ignored by git repository tracking. These patch files record all custom modifications made to HM 18.0 to enable bit-exact hardware conformance verification and hardware-software co-simulation debugging.
>
> **Notice**: These changes are debug and verification patches, **not** production software changes.

---

## Patch Index

### 1. `hm18_tDecGop_disable_loop_filters.patch.txt`
- **Target File**: `HM/source/Lib/TLibDecoder/TDecGop.cpp`
- **Target Function**: `Void TDecGop::filterPicture(TComPic* pcPic)`
- **Functionality**:
  1. **Pre-Deblock Reconstruction Dump**: Dumps uncompressed pre-filter reconstructed frames to `rec_before_filter.yuv` (16-bit little-endian samples, YUV 4:2:0 format). This allows bit-exact sample-by-sample conformance testing of the RTL reconstruction pipeline (intra/inter prediction + inverse transform + inverse quantization) prior to loop filtering.
  2. **Loop Filter Bypass via Environment Variable**: Inspects the `DISABLE_LOOP_FILTERS` environment variable. When set (e.g., `DISABLE_LOOP_FILTERS=1`), the decoder skips deblocking filter (`m_pcLoopFilter->loopFilterPic`) and Sample Adaptive Offset (`m_pcSAO->SAOProcess`), allowing direct decoder output comparison without loop filters.

### 2. `hm18_tDecCu_inter_debug.patch.txt`
- **Target File**: `HM/source/Lib/TLibDecoder/TDecCu.cpp`
- **Target Function**: `Void TDecCu::xReconInter(TComDataCU* pcCU, UInt uiDepth)`
- **Functionality**:
  1. **Inter CU Diagnostic Logging**: Injects an `[HM_INTER_DBG]` diagnostic `printf` statement at the entrance of `xReconInter()`.
  2. Logs picture POC, CTU raster scan address, merge flag, merge index, List-0 motion vector (`mv0.getHor()`, `mv0.getVer()`), and List-0 reference index (`ref0`) before motion compensation.
  3. Enables step-by-step cross-checking of motion vector resolution and merge mode selection against RTL hardware trace logs.

---

## Applying Patches

Each patch file contains the relevant context and modified lines formatted for manual application. Open the respective file in `HM/source/Lib/TLibDecoder/` and insert or update the indicated lines.
