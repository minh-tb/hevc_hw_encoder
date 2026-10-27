# CABAC Encoder Top-Level (`cabac_enc_top`) — Module Architecture & Flowchart

## 1. Architectural Scope & Module Hierarchy

[`cabac_enc_top.v`](file:///d:/UIT_Doc/hevc_hw_encoder/rtl/entropy/cabac_enc_top.v) coordinates the entropy compression pipeline for the HEVC encoder. It arbitrates syntax serialization across five dedicated syntax submodules, routes bin streams into the context dispatcher, drives the arithmetic range coder, and emits raw byte stream packets (RBSP) to the NAL writer.

```
cabac_enc_top
 ├── ctx_model_store    (154 × 7-bit dual-port SRAM, slice init, context read/write)
 ├── bin_encoder        (Context address lookup, MPS/LPS dispatch, bypass multiplexer)
 ├── range_coder        (M-coder arithmetic engine, renormalization, byte accumulation)
 ├── syntax_cu          (split_flag, skip_flag, merge_flag, pred_mode, part_mode)
 ├── syntax_pred        (inter_dir, ref_idx, mvp_flag, MVD binarization)
 ├── syntax_coeff       (last_sig_pos, sig_coeff_map, gt1, gt2, signs, levels)
 └── syntax_sao         (sao_merge, sao_type, band_pos, bo_offsets, eo_classes)
```

---

## 2. Top-Level State Machine & Arbitration Flowchart (Mermaid)

```mermaid
flowchart TD
    %% Node Styling
    classDef startend fill:#ffcccb,stroke:#b71c1c,stroke-width:2px,color:#000;
    classDef process fill:#e1f5fe,stroke:#0277bd,stroke-width:1px,color:#000;
    classDef decision fill:#fff9c4,stroke:#fbc02d,stroke-width:1px,color:#000;
    classDef storage fill:#dcedc8,stroke:#33691e,stroke-width:1px,color:#000;

    Start(["Khởi tạo Slice mới (slice_init pulse)"])
    End(["Kết thúc NALU (flush_done asserted)"])

    %% State 0: Init
    InitSRAM["1. Khởi tạo Context SRAM (ctx_model_store.v):<br/>Duyệt qua 154 địa chỉ context<br/>Tính pStateIdx & valMPS từ QP và Slice Type (154 chu kỳ)"]

    WaitReq{"Trạng thái CABAC FSM<br/>(cabac_state)"}

    %% Sub-FSM Transitions
    subgraph CU_Stage ["2. Mã hóa Cú pháp CU (syntax_cu.v)"]
        ReqCU["Nhận cu_req từ CTU Partitioner"]
        EncodeCU["Mã hóa tuần tự các Bin:<br/>split_flag &rarr; skip_flag &rarr; merge_flag &rarr; pred_mode &rarr; part_mode"]
        DoneCU["Khẳng định cu_done"]
    end

    subgraph Pred_Stage ["3. Mã hóa Cú pháp Dự đoán (syntax_pred.v)"]
        ReqPred["Nhận pred_req từ Inter/Intra Unit"]
        EncodePred["Mã hóa MVD (Exp-Golomb), ref_idx, mvp_flag, intra_chroma"]
        DonePred["Khẳng định pred_done"]
    end

    subgraph Coeff_Stage ["4. Mã hóa Hệ số Biến đổi (syntax_coeff.v)"]
        ReqCoeff["Nhận coeff_req từ Transform/Quant Unit"]
        EncodeCoeff["Đọc hệ số từ CoeffBuffer SRAM:<br/>last_sig_xy &rarr; sig_map (4x4 sub-blocks) &rarr; gt1 &rarr; gt2 &rarr; signs &rarr; levels"]
        DoneCoeff["Khẳng định coeff_done"]
    end

    subgraph SAO_Stage ["5. Mã hóa Cú pháp SAO (syntax_sao.v)"]
        ReqSAO["Nhận sao_req từ SAO Unit"]
        EncodeSAO["Mã hóa sao_type, offsets, band_pos"]
        DoneSAO["Khẳng định sao_done"]
    end

    subgraph Term_Stage ["6. Terminating & Flush (range_coder.v)"]
        ReqTerm["Nhận trm_req (end_of_slice_flag = 1) hoặc flush_req"]
        ExecFlush["Xả sạch thanh ghi Low và Range:<br/>Đẩy các byte cuối cùng + bits_outstanding vào Output FIFO"]
    end

    %% Routing
    Start --> InitSRAM --> WaitReq

    WaitReq -- "cu_req" --> ReqCU --> EncodeCU --> DoneCU --> WaitReq
    WaitReq -- "pred_req" --> ReqPred --> EncodePred --> DonePred --> WaitReq
    WaitReq -- "coeff_req" --> ReqCoeff --> EncodeCoeff --> DoneCoeff --> WaitReq
    WaitReq -- "sao_req" --> ReqSAO --> EncodeSAO --> DoneSAO --> WaitReq
    WaitReq -- "trm_req / flush_req" --> ReqTerm --> ExecFlush --> End

    %% Styling
    class Start,End startend;
    class InitSRAM,ReqCU,EncodeCU,DoneCU,ReqPred,EncodePred,DonePred,ReqCoeff,EncodeCoeff,DoneCoeff,ReqSAO,EncodeSAO,DoneSAO,ReqTerm,ExecFlush process;
    class WaitReq decision;
```

---

## 3. Bin-by-Bin Serialization Protocol

Arbitration across the syntax modules guarantees **zero bus conflict**:
1. Only one `syntax_*` engine asserts `bin_valid` at any given cycle.
2. `bin_rdy` from `range_coder` is broadcast back to all syntax units; when deasserted (e.g. during multi-cycle renormalization), the active syntax module stalls its internal bit pointer.
3. Quantized coefficient reading from `coeff_buffer.v` uses an asynchronous prefetch address `coeff_rd_addr[11:0]` with single-cycle read latency.

---

## 4. Hardware Port Map (`cabac_enc_top.v`)

| Port Group | Port Name | Dir | Width | Description |
|:---|:---|:---:|:---:|:---|
| **Global** | `clk`, `rst_n` | In | 1 | Clock and active-low reset. |
| **Slice Init** | `slice_init` | In | 1 | Pulse to trigger 154-cycle context initialization. |
| | `slice_type` | In | 2 | 0: I, 1: P, 2: B. |
| | `qp_in` | In | 7 | Quantization parameter for context initialization. |
| **CU Interface**| `cu_req`, `cu_done`| In/Out | 1 | Handshake for CU syntax generation. |
| | `cu_depth`, `cu_is_split` | In | 2, 1 | CU depth and split status. |
| | `cu_skip`, `cu_merge` | In | 1, 1 | Skip and Merge flags. |
| | `cu_merge_idx` | In | 3 | Merge candidate index ($0..4$). |
| | `cu_pred_intra`, `cu_intra_mode` | In | 1, 6 | Intra mode flag and 6-bit direction. |
| **Pred Interface**| `pred_req`, `pred_done`| In/Out | 1 | Handshake for motion vector syntax. |
| | `mvd_l0/l1_x/y` | In | 12 | Motion vector differences (quarter-pel). |
| | `mvp_flag_l0/l1`| In | 1 | AMVP candidate index chosen ($0$ or $1$). |
| **Coeff Interface**| `coeff_req`, `coeff_done`| In/Out | 1 | Handshake for transform coefficient syntax. |
| | `coeff_tu_size_log2` | In | 3 | TU size ($2=4\times 4..5=32\times 32$). |
| | `coeff_tu_cbf` | In | 1 | Coded Block Flag. |
| | `coeff_last_sig_pos` | In | 10 | Raster position of last non-zero coefficient. |
| | `coeff_rd_addr`, `coeff_rd_data` | Out/In | 12, 16 | SRAM interface to on-chip `coeff_buffer.v`. |
| **SAO Interface** | `sao_req`, `sao_done` | In/Out | 1 | Handshake for SAO parameters. |
| **Term/Flush** | `trm_req`, `flush_req` | In | 1 | Terminating bin request and end-of-slice flush. |
| | `flush_done` | Out | 1 | Strobe asserted when range coder completes final byte flush. |
| **Byte Output** | `byte_valid`, `byte_out` | Out | 1, 8 | Encoded byte stream to `nal_writer.v`. |
