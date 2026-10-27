def se(v):
    codeNum = -2*v if v <= 0 else 2*v - 1
    val = codeNum + 1
    l = val.bit_length()
    zeros = '0' * (l - 1)
    b = zeros + bin(val)[2:]
    return b

def gen():
    qps = list(range(16, 45))
    lines = []
    lines.append("        case (frame_qp)")
    for qp in qps:
        v = qp - 26
        qb = se(v)
        ql = len(qb)
        
        # I-Slice
        # Prefix: 6'b101011 (6 bits)
        # SAO flags: {2{latched_sao_enable}} (2 bits)
        # QP delta: {ql}'b{qb}
        # Suffix: 2'b01 (2 bits)
        tot_i = 10 + ql
        pad_i = (8 - (tot_i % 8)) % 8
        bits_i = tot_i + pad_i
        pad_i_str = f", {pad_i}'d0" if pad_i > 0 else ""
        
        # B-Slice: 3'b111, latched_poc[7:0], 1'b1, {2{latched_sao_enable}}, 3'b001, {ql}'b{qb}, 2'b01
        tot_b = 19 + ql
        pad_b = (8 - (tot_b % 8)) % 8
        bits_b = tot_b + pad_b
        pad_b_str = f", {pad_b}'d0" if pad_b > 0 else ""
        
        # P-Slice: 5'b11010, latched_poc[7:0], 1'b1, {2{latched_sao_enable}}, 2'b01, {ql}'b{qb}, 2'b01
        tot_p = 20 + ql
        pad_p = (8 - (tot_p % 8)) % 8
        bits_p = tot_p + pad_p
        pad_p_str = f", {pad_p}'d0" if pad_p > 0 else ""
        
        lines.append(f"            6'd{qp}: begin // QP={qp}, delta={v:+d}")
        lines.append(f"                if (latched_slice_type == SLICE_I) begin")
        lines.append(f"                    hdr_shift_reg[63:{64-bits_i}] <= {{6'b101011, {{2{{latched_sao_enable}}}}, {ql}'b{qb}, 2'b01{pad_i_str}}};")
        lines.append(f"                    hdr_bits_left <= 7'd{bits_i};")
        lines.append(f"                end else if (latched_slice_type == SLICE_B) begin")
        lines.append(f"                    hdr_shift_reg[63:{64-bits_b}] <= {{3'b111, latched_poc[7:0], 1'b1, {{2{{latched_sao_enable}}}}, 3'b001, {ql}'b{qb}, 2'b01{pad_b_str}}};")
        lines.append(f"                    hdr_bits_left <= 7'd{bits_b};")
        lines.append(f"                end else begin")
        lines.append(f"                    hdr_shift_reg[63:{64-bits_p}] <= {{5'b11010, latched_poc[7:0], 1'b1, {{2{{latched_sao_enable}}}}, 2'b01, {ql}'b{qb}, 2'b01{pad_p_str}}};")
        lines.append(f"                    hdr_bits_left <= 7'd{bits_p};")
        lines.append(f"                end")
        lines.append(f"            end")
    lines.append("            default: begin // Default QP=29")
    lines.append("                if (latched_slice_type == SLICE_I) begin")
    lines.append("                    hdr_shift_reg[63:48] <= {6'b101011, {2{latched_sao_enable}}, 5'b00110, 2'b01, 1'b0};")
    lines.append("                    hdr_bits_left <= 7'd16;")
    lines.append("                end else if (latched_slice_type == SLICE_B) begin")
    lines.append("                    hdr_shift_reg[63:40] <= {3'b111, latched_poc[7:0], 1'b1, {2{latched_sao_enable}}, 3'b001, 5'b00110, 2'b01};")
    lines.append("                    hdr_bits_left <= 7'd24;")
    lines.append("                end else begin")
    lines.append("                    hdr_shift_reg[63:32] <= {5'b11010, latched_poc[7:0], 1'b1, {2{latched_sao_enable}}, 2'b01, 5'b00110, 2'b01, 7'd0};")
    lines.append("                    hdr_bits_left <= 7'd32;")
    lines.append("                end")
    lines.append("            end")
    lines.append("        endcase")
    
    content = "\n".join(lines)
    for target_path in ["rtl/common/slice_cases.vh", "ip_repo/hevc_encoder_v1_0/src/slice_cases.vh"]:
        with open(target_path, "w") as f:
            f.write(content)
        print(f"Generated {len(lines)} lines in {target_path}")

if __name__ == "__main__":
    gen()

