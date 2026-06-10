# HEVC Hardware Encoder — Complete Port-to-Port Connection Map

## How to read this table
| Source Module | Source Port | → | Destination Module | Destination Port | Notes |
|---|---|---|---|---|---|

---

## 1. INPUT STAGE → PARTITIONING

| Source | Source Port | → | Destination | Destination Port | Notes |
|---|---|---|---|---|---|
| input_buffer | rd_resp_valid | → | residual_sub | orig_valid | Original pixel for residual |
| input_buffer | rd_resp_data | → | residual_sub | orig_pixel | |
| input_buffer | rd_resp_valid | → | tz_search | orig_valid | Original block for SAD |
| input_buffer | rd_resp_data | → | tz_search | cu_orig_flat | |
| ctu_raster_scan | ctu_valid | → | ctu_partitioner | ctu_valid | CTU_INFO_BUS |
| ctu_raster_scan | ctu_addr | → | ctu_partitioner | ctu_addr | |
| ctu_raster_scan | ctu_x | → | ctu_partitioner | ctu_x | |
| ctu_raster_scan | ctu_y | → | ctu_partitioner | ctu_y | |
| ctu_raster_scan | poc | → | ctu_partitioner | poc | |
| ctu_raster_scan | qp | → | ctu_partitioner | qp | |
| ctu_raster_scan | slice_type | → | ctu_partitioner | slice_type | |
| ctu_partitioner | ctu_ready | → | ctu_raster_scan | ctu_ready | Backpressure |

---

## 2. PARTITIONING → PARTITIONING

| Source | Source Port | → | Destination | Destination Port | Notes |
|---|---|---|---|---|---|
| ctu_partitioner | cu_valid | → | pu_cu_splitter | cu_valid | CU_INFO_BUS |
| ctu_partitioner | cu_x | → | pu_cu_splitter | cu_x | |
| ctu_partitioner | cu_y | → | pu_cu_splitter | cu_y | |
| ctu_partitioner | cu_size | → | pu_cu_splitter | cu_size | |
| ctu_partitioner | cu_depth | → | pu_cu_splitter | cu_depth | |
| ctu_partitioner | cu_ctu_addr | → | pu_cu_splitter | cu_ctu_addr | |
| ctu_partitioner | cu_poc | → | pu_cu_splitter | cu_poc | |
| ctu_partitioner | cu_slice_type | → | pu_cu_splitter | cu_slice_type | |
| ctu_partitioner | cu_qp | → | pu_cu_splitter | qp | |
| pu_cu_splitter | cu_ready | → | ctu_partitioner | cu_ready | Backpressure |
| **mode_decision** | split_valid | → | ctu_partitioner | split_valid | Split feedback |
| **mode_decision** | split_flag | → | ctu_partitioner | split_flag | |
| ctu_partitioner | split_ready | → | **mode_decision** | split_ready | |

---

## 3. PARTITIONING → PREDICTION

| Source | Source Port | → | Destination | Destination Port | Notes |
|---|---|---|---|---|---|
| pu_cu_splitter | pu_valid | → | intra_pred_top | (via mode_decision) | Intra PUs only |
| pu_cu_splitter | pu_size_log2 | → | intra_pred_top | pu_size_log2 | |
| pu_cu_splitter | pu_valid | → | tz_search | search_valid | Inter PUs only |
| pu_cu_splitter | pu_x | → | tz_search | cu_x | |
| pu_cu_splitter | pu_y | → | tz_search | cu_y | |
| pu_cu_splitter | pu_w | → | tz_search | cu_w | |
| pu_cu_splitter | pu_h | → | tz_search | cu_h | |
| pu_cu_splitter | pu_valid | → | mc_unit | mc_start | After ME finds best MV |
| pu_cu_splitter | tu_valid | → | dct_top | in_valid | TU_INFO_BUS |
| pu_cu_splitter | tu_size_log2 | → | dct_top | tu_size_log2 | |
| pu_cu_splitter | tu_comp | → | dct_top | (sideband) | |

---

## 4. FRAME STORE → INTRA PRED (neighbor samples)

| Source | Source Port | → | Destination | Destination Port | Notes |
|---|---|---|---|---|---|
| frame_store | cache_valid | → | intra_pred_top | ref_valid | Reconstructed neighbors |
| frame_store | cache_pixel | → | intra_pred_top | ref_sample | From CTU line cache |
| frame_store | cache_x | → | intra_pred_top | ref_idx (derived) | |
| frame_store | cache_comp | → | intra_pred_top | is_luma | |

---

## 5. PREDICTION → RESIDUAL SUBTRACTOR

| Source | Source Port | → | Destination | Destination Port | Notes |
|---|---|---|---|---|---|
| intra_pred_top | out_valid | → | residual_sub | pred_valid | Intra prediction |
| intra_pred_top | out_pixel | → | residual_sub | pred_pixel | |
| intra_pred_top | out_x | → | residual_sub | pred_x | |
| intra_pred_top | out_y | → | residual_sub | pred_y | |
| mc_unit | mc_done | → | residual_sub | pred_valid | Inter prediction |
| mc_unit | pred_y_flat | → | residual_sub | pred_pixel | |
| input_buffer | rd_resp_data | → | residual_sub | orig_pixel | |
| residual_sub | residual | → | dct_top | in_data | Signed residual |

---

## 6. MOTION ESTIMATION

| Source | Source Port | → | Destination | Destination Port | Notes |
|---|---|---|---|---|---|
| mvp_predictor | amvp_mv_x_flat | → | tz_search | mvp_x | MVP hint |
| mvp_predictor | amvp_mv_y_flat | → | tz_search | mvp_y | |
| mvp_predictor | merge_mv_x_flat | → | mc_unit | mc_mv_x | Merge candidate |
| mvp_predictor | merge_mv_y_flat | → | mc_unit | mc_mv_y | |
| tz_search | best_mv_x | → | mc_unit | mc_mv_x | Best MV from ME |
| tz_search | best_mv_y | → | mc_unit | mc_mv_y | |
| tz_search | ref_req_valid | → | ref_frame_buffer | ref_req_valid | Reference fetch |
| tz_search | ref_req_x | → | ref_frame_buffer | ref_req_x | |
| tz_search | ref_req_y | → | ref_frame_buffer | ref_req_y | |
| ref_frame_buffer | ref_resp_valid | → | tz_search | ref_resp_valid | |
| ref_frame_buffer | ref_resp_data | → | tz_search | ref_resp_data | |
| mc_unit | ref_req_valid | → | ref_frame_buffer | ref_req_valid | |
| mc_unit | ref_req_x | → | ref_frame_buffer | ref_req_x | |
| mc_unit | ref_req_y | → | ref_frame_buffer | ref_req_y | |
| mc_unit | ref_req_comp | → | ref_frame_buffer | ref_req_comp | |
| ref_frame_buffer | ref_resp_valid | → | mc_unit | ref_resp_valid | |
| ref_frame_buffer | ref_resp_y_flat | → | mc_unit | ref_resp_y_flat | |

---

## 7. FRAME STORE → REF FRAME BUFFER

| Source | Source Port | → | Destination | Destination Port | Notes |
|---|---|---|---|---|---|
| frame_store | rd_resp_valid | → | ref_frame_buffer | (internal cache fill) | frame_store SERVES ref_frame_buffer |
| frame_store | rd_resp_pixel | → | ref_frame_buffer | axi_rdata (via DRAM) | ref_frame_buffer reads DRAM directly |
| ref_frame_buffer | axi_arvalid | → | DRAM | axi_arvalid | ref_frame_buffer has own AXI4 to DRAM |
| ref_frame_buffer | axi_araddr | → | DRAM | axi_araddr | |
| DRAM | axi_rvalid | → | ref_frame_buffer | axi_rvalid | |
| DRAM | axi_rdata | → | ref_frame_buffer | axi_rdata | |

---

## 8. TRANSFORM → QUANTIZATION → ENTROPY

| Source | Source Port | → | Destination | Destination Port | Notes |
|---|---|---|---|---|---|
| dct_top | out_valid | → | fwd_quant | in_valid | COEFF_BUS |
| dct_top | out_data[scan] | → | fwd_quant | in_coeff | Serial scan |
| dct_top | out_tu_size_log2 | → | fwd_quant | tu_size_log2 | |
| fwd_quant | out_valid | → | cabac_enc_top | in_valid | Levels straight to entropy |
| fwd_quant | out_level | → | cabac_enc_top | in_level | |
| fwd_quant | out_scan_idx | → | cabac_enc_top | in_scan_idx | |
| fwd_quant | out_last | → | cabac_enc_top | in_last | |
| fwd_quant | out_cbf | → | cabac_enc_top | in_cbf | |

---

## 9. RECONSTRUCTION LOOP (Encoder internal decoder)

| Source | Source Port | → | Destination | Destination Port | Notes |
|---|---|---|---|---|---|
| fwd_quant | out_level | → | inv_quant | in_level | Parallel path |
| fwd_quant | out_scan_idx | → | inv_quant | in_scan_idx | |
| fwd_quant | out_last | → | inv_quant | in_last | |
| inv_quant | out_valid | → | dct_top | in_valid | fwd_inv_n=0 (IDCT) |
| inv_quant | out_coeff | → | dct_top | in_data | |
| dct_top | out_valid | → | recon_unit | res_valid | IDCT residual |
| dct_top | out_data | → | recon_unit | res_coeff | |
| dct_top | out_x | → | recon_unit | res_x | |
| dct_top | out_y | → | recon_unit | res_y | |
| intra_pred_top | out_valid | → | recon_unit | pred_valid | Prediction |
| intra_pred_top | out_pixel | → | recon_unit | pred_pixel | |
| intra_pred_top | out_x | → | recon_unit | pred_x | |
| intra_pred_top | out_y | → | recon_unit | pred_y | |
| mc_unit | pred_y_flat | → | recon_unit | pred_pixel | Inter pred |
| recon_unit | out_valid | → | deblock_top | (via frame_store) | Unfiltered recon |
| recon_unit | out_pixel | → | frame_store | wr_pixel | Write to DPB |
| recon_unit | out_x | → | frame_store | wr_x | |
| recon_unit | out_y | → | frame_store | wr_y | |
| recon_unit | out_comp | → | frame_store | wr_comp | |

---

## 10. IN-LOOP FILTERS

| Source | Source Port | → | Destination | Destination Port | Notes |
|---|---|---|---|---|---|
| frame_store | cache_valid | → | deblock_top | pix_resp_valid | Line cache pixels |
| frame_store | cache_pixel | → | deblock_top | pix_resp_data | |
| deblock_top | pix_rd_valid | → | frame_store | (cache read req) | Request neighbor pixels |
| deblock_top | pix_rd_x | → | frame_store | cache_x | |
| deblock_top | pix_rd_y | → | frame_store | cache_y | |
| deblock_top | pix_wr_valid | → | frame_store | wr_valid | Write deblocked pixels |
| deblock_top | pix_wr_data | → | frame_store | wr_pixel | |
| deblock_top | pix_wr_x | → | frame_store | wr_x | |
| deblock_top | pix_wr_y | → | frame_store | wr_y | |
| deblock_top | ctu_done | → | sao_top | ctu_valid | Chain trigger |
| frame_store | cache_pixel | → | sao_top | pix_resp_data | Post-deblock pixels |
| sao_top | pix_rd_valid | → | frame_store | (cache read req) | |
| sao_top | pix_rd_x | → | frame_store | cache_x | |
| sao_top | pix_rd_y | → | frame_store | cache_y | |
| sao_top | n0_rd_valid | → | frame_store | (cache read req) | EO neighbors |
| sao_top | n1_rd_valid | → | frame_store | (cache read req) | |
| sao_top | pix_wr_valid | → | frame_store | wr_valid | Final filtered pixels |
| sao_top | pix_wr_data | → | frame_store | wr_pixel | |

---

## 11. ENTROPY → OUTPUT

| Source | Source Port | → | Destination | Destination Port | Notes |
|---|---|---|---|---|---|
| cabac_enc_top | out_valid | → | output_fifo | wr_valid | Byte stream |
| cabac_enc_top | out_byte | → | output_fifo | wr_byte | |
| cabac_enc_top | out_last_au | → | output_fifo | wr_last_in_au | |
| output_fifo | rd_valid | → | nal_writer | rbsp_valid | |
| output_fifo | rd_byte | → | nal_writer | rbsp_byte | |
| output_fifo | rd_last_in_au | → | nal_writer | rbsp_last | |
| nal_writer | rbsp_ready | → | output_fifo | rd_ready | Backpressure |
| nal_writer | out_valid | → | [DMA/file] | - | str.bin |
| nal_writer | out_byte | → | [DMA/file] | - | |

---

## 12. TOP-LEVEL CONTROL (gop_controller → everything)

| Source | Source Port | → | Destination | Destination Port | Notes |
|---|---|---|---|---|---|
| gop_controller | frame_start | → | ctu_raster_scan | frame_start | |
| gop_controller | frame_poc | → | ctu_raster_scan | frame_poc | |
| gop_controller | frame_slice_type | → | ctu_raster_scan | frame_slice_type | |
| gop_controller | ref_l0[0..4] | → | frame_store | ref_l0[0..4] | RPL management |
| gop_controller | ref_l1[0..4] | → | frame_store | ref_l1[0..4] | |
| gop_controller | alloc_poc | → | frame_store | alloc_poc | DPB slot alloc |
| gop_controller | alloc_valid | → | frame_store | alloc_valid | |
| gop_controller | nal_type | → | nal_writer | nal_type | |
| gop_controller | nal_start | → | nal_writer | nal_start | |
| gop_controller | temporal_id | → | nal_writer | temporal_id | |
| slice_controller | qp | → | ctu_raster_scan | (QP_DEFAULT) | |
| slice_controller | sao_type[0:2] | → | sao_top | sao_type | |
| slice_controller | eo_offset | → | sao_top | eo_offset | |
| slice_controller | bo_offset | → | sao_top | bo_offset | |