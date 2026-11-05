#!/usr/bin/env python3
"""
extract_h265_clauses.py
Normative ITU-T H.265 (V11 01/2026) specification clause & page extractor.
Calibrates 0-based PDF page index from printed footers/headers (Spec Page + 17).
"""

import os
import sys
import argparse
import json
import re
from pathlib import Path
import pypdf

# Default TOC mapping for major clauses -> (start_spec_page, end_spec_page)
CLAUSE_TOC_MAP = {
    "6.4.1": (26, 27),
    "6.5": (26, 30),
    "6.5.2": (27, 28),
    "6.5.3": (28, 29),
    "6.5.4": (29, 30),
    "6.5.5": (30, 30),
    "7.3.6.1": (46, 48),
    "7.3.8": (49, 61),
    "7.3.8.1": (49, 50),
    "7.3.8.3": (52, 53),
    "7.4.3.3.2": (86, 87),
    "8.4.4": (132, 141),
    "8.5.3.3.3": (165, 170),
    "8.6.1": (175, 176),
    "8.6.2": (177, 178),
    "8.6.3": (178, 179),
    "8.6.4": (180, 181),
    "8.7.1": (184, 185),
    "8.7.2": (185, 197),
    "8.7.3": (198, 200),
    "9.3": (203, 245),
    "9.3.1": (203, 204),
    "9.3.2": (204, 217),
    "9.3.3": (217, 234),
    "9.3.4": (234, 244),
    "9.3.5": (244, 245),
}

def extract_printed_page_number(text: str):
    """
    Finds printed page number from either:
    - Even page header/footer: <num> Rec. ITU-T H.265 (V11) (01/2026)
    - Odd page footer: Rec. ITU-T H.265 (V11) (01/2026) <num>
    """
    m_even = re.search(r'(\d+)\s+Rec\.\s*ITU-T\s*H\.265', text)
    if m_even:
        return int(m_even.group(1))
    m_odd = re.search(r'Rec\.\s*ITU-T\s*H\.265\s*\(V11\)\s*\(01/2026\)[^\S\r\n]+(\d+)', text)
    if m_odd:
        return int(m_odd.group(1))
    return None

def calibrate_offset(reader: pypdf.PdfReader) -> int:
    """
    Samples 5 representative pages in the specification body and verifies offset consistency.
    Returns: constant offset such that pdf_index = spec_page + offset.
    """
    sample_indices = [43, 69, 183, 202, 252]
    offsets = []
    for idx in sample_indices:
        text = reader.pages[idx].extract_text()
        page_num = extract_printed_page_number(text)
        if page_num is not None:
            off = idx - page_num
            offsets.append(off)
    if not offsets:
        raise ValueError("Failed to extract any printed page numbers from sample pages.")
    first_off = offsets[0]
    for off in offsets:
        if off != first_off:
            raise ValueError(f"Inconsistent page offset detected: expected {first_off}, found {off}")
    return first_off

def extract_pages(pdf_path: str, start_page: int, end_page: int, out_dir: str):
    Path(out_dir).mkdir(parents=True, exist_ok=True)
    reader = pypdf.PdfReader(pdf_path)
    offset = calibrate_offset(reader)
    print(f"[EXTRACT] Calibrated PDF index offset = {offset} (0-based PDF idx = Spec Page + {offset})")

    index_map = {}
    total_pages = len(reader.pages)

    for spec_p in range(start_page, end_page + 1):
        pdf_idx = spec_p + offset
        if pdf_idx < 0 or pdf_idx >= total_pages:
            print(f"[WARN] Spec page {spec_p} maps to pdf_idx {pdf_idx} which is out of bounds (0..{total_pages-1})")
            continue
        text = reader.pages[pdf_idx].extract_text()
        out_file = Path(out_dir) / f"spec_p{spec_p:03d}.txt"
        with open(out_file, "w", encoding="utf-8") as f:
            f.write(f"--- SPEC PRINTED PAGE {spec_p} (PDF INDEX {pdf_idx}) ---\n")
            f.write(text)
            f.write("\n")
        index_map[spec_p] = pdf_idx

    index_file = Path(out_dir) / "index.json"
    with open(index_file, "w", encoding="utf-8") as f:
        json.dump(index_map, f, indent=2)

    print(f"[EXTRACT] Extracted spec pages {start_page}..{end_page} ({len(index_map)} pages) into {out_dir}")
    return offset, index_map

def main():
    parser = argparse.ArgumentParser(description="Extract ITU-T H.265 V11 clauses/pages with footer calibration.")
    parser.add_argument("--pdf", default="T-REC-H.265-202601-I_PDF-E.pdf", help="Path to H.265 specification PDF")
    parser.add_argument("--spec-pages", help="Spec page range, e.g. 185-199 or single page 192")
    parser.add_argument("--clause", help="Clause number to extract, e.g. 8.7.2")
    parser.add_argument("--out", required=True, help="Output directory")

    args = parser.parse_args()

    start_page, end_page = None, None
    if args.spec_pages:
        if "-" in args.spec_pages:
            s, e = args.spec_pages.split("-")
            start_page, end_page = int(s), int(e)
        else:
            start_page = int(args.spec_pages)
            end_page = start_page
    elif args.clause:
        if args.clause in CLAUSE_TOC_MAP:
            start_page, end_page = CLAUSE_TOC_MAP[args.clause]
        else:
            print(f"Clause {args.clause} not found in TOC map. Known clauses: {list(CLAUSE_TOC_MAP.keys())}")
            sys.exit(1)
    else:
        print("Must specify either --spec-pages or --clause")
        sys.exit(1)

    extract_pages(args.pdf, start_page, end_page, args.out)

if __name__ == "__main__":
    main()
