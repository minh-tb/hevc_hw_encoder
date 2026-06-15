import sys
import os

def parse_hevc_bitstream(filename):
    if not os.path.exists(filename):
        print(f"Error: File '{filename}' not found.")
        return
        
    with open(filename, 'rb') as f:
        data = f.read()

    print(f"Parsing {filename} ({len(data)} bytes)...\n")

    start_codes = []
    i = 0
    while i < len(data) - 3:
        if data[i] == 0 and data[i+1] == 0:
            if data[i+2] == 1:
                start_codes.append((i, 3))
                i += 3
            elif data[i+2] == 0 and data[i+3] == 1:
                start_codes.append((i, 4))
                i += 4
            else:
                i += 1
        else:
            i += 1

    if not start_codes:
        print("No NAL units found!")
        return

    nal_types = {
        1: "TRAIL_R (Inter B/P Slice)",
        21: "CRA_NUT (Intra Slice)",
    }

    for idx, (offset, sc_len) in enumerate(start_codes):
        next_offset = start_codes[idx+1][0] if idx + 1 < len(start_codes) else len(data)
        nal_payload = data[offset + sc_len : next_offset]
        nal_size = len(nal_payload)
        
        if nal_size >= 2:
            hdr0, hdr1 = nal_payload[0], nal_payload[1]
            nal_unit_type = (hdr0 >> 1) & 0x3F
            type_name = nal_types.get(nal_unit_type, f"UNKNOWN ({nal_unit_type})")
            print(f"NALU {idx}: Offset 0x{offset:04X}, Size {nal_size:4d} bytes | Type: {nal_unit_type:2d} {type_name}")

if __name__ == "__main__":
    default_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), "test_out.bin")
    parse_hevc_bitstream(sys.argv[1] if len(sys.argv) > 1 else default_file)