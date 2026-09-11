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
        raw_i = '10101100' + qb + '01'
        pad_i = (8 - (len(raw_i) % 8)) % 8
        tot_i = len(raw_i) + pad_i
        hex_i = f"{int(raw_i + '0'*pad_i, 2):0{tot_i//4}X}"
        
        # B-Slice: 3 + 8 + 6 = 17 prefix
        tot_b = len('111' + '0'*8 + '100001' + qb + '01')
        pad_b = (8 - (tot_b % 8)) % 8
        bits_b = tot_b + pad_b
        
        # P-Slice: 5 + 8 + 5 = 18 prefix
        tot_p = len('11010' + '0'*8 + '10001' + qb + '01')
        pad_p = (8 - (tot_p % 8)) % 8
        bits_p = tot_p + pad_p
        
        pad_b_str = f", {pad_b}'d0" if pad_b > 0 else ""
        pad_p_str = f", {pad_p}'d0" if pad_p > 0 else ""
        
        lines.append(f"            6'd{qp}: begin // QP={qp}, delta={v:+d}")
        lines.append(f"                if (latched_slice_type == SLICE_I) begin")
        lines.append(f"                    hdr_shift_reg[63:{64-tot_i}] <= {tot_i}'h{hex_i};")
        lines.append(f"                    hdr_bits_left <= 7'd{tot_i};")
        lines.append(f"                end else if (latched_slice_type == SLICE_B) begin")
        lines.append(f"                    hdr_shift_reg[63:{64-bits_b}] <= {{3'b111, latched_poc[7:0], 6'b100001, {ql}'b{qb}, 2'b01{pad_b_str}}};")
        lines.append(f"                    hdr_bits_left <= 7'd{bits_b};")
        lines.append(f"                end else begin")
        lines.append(f"                    hdr_shift_reg[63:{64-bits_p}] <= {{5'b11010, latched_poc[7:0], 5'b10001, {ql}'b{qb}, 2'b01{pad_p_str}}};")
        lines.append(f"                    hdr_bits_left <= 7'd{bits_p};")
        lines.append(f"                end")
        lines.append(f"            end")
    lines.append("            default: begin // Default QP=29")
    lines.append("                if (latched_slice_type == SLICE_I) begin")
    lines.append("                    hdr_shift_reg[63:48] <= 16'hAC32;")
    lines.append("                    hdr_bits_left <= 7'd16;")
    lines.append("                end else if (latched_slice_type == SLICE_B) begin")
    lines.append("                    hdr_shift_reg[63:40] <= {3'b111, latched_poc[7:0], 6'b100001, 5'b00110, 2'b01};")
    lines.append("                    hdr_bits_left <= 7'd24;")
    lines.append("                end else begin")
    lines.append("                    hdr_shift_reg[63:32] <= {5'b11010, latched_poc[7:0], 5'b10001, 5'b00110, 2'b01, 7'd0};")
    lines.append("                    hdr_bits_left <= 7'd32;")
    lines.append("                end")
    lines.append("            end")
    lines.append("        endcase")
    
    with open("slice_cases.vh", "w") as f:
        f.write("\n".join(lines))
    print(f"Generated {len(lines)} lines in slice_cases.vh")

if __name__ == "__main__":
    gen()
