import glob
import re
import os
import sys
import io

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

md_files = glob.glob('docs/**/*.md', recursive=True) + glob.glob('docs/*.md') + ['README.md']
md_files = sorted(list(set(md_files)))

print(f"Total markdown files evaluated: {len(md_files)}")
issues = []
total_diagrams = 0

for fpath in md_files:
    with open(fpath, encoding='utf-8') as f:
        text = f.read()

    # 1. Code fence balance check
    fence_count = text.count('```')
    if fence_count % 2 != 0:
        issues.append(f"{fpath}: Unbalanced code fences (``` count = {fence_count})")

    # 2. Extract Mermaid blocks
    blocks = re.findall(r'```mermaid\s*\n([\s\S]*?)```', text)
    total_diagrams += len(blocks)
    for b_idx, block in enumerate(blocks):
        lines = block.splitlines()
        header = lines[0].strip() if lines else ''
        if not (header.startswith('flowchart') or header.startswith('graph') or header.startswith('stateDiagram')):
            issues.append(f"{fpath} Block {b_idx}: Unknown diagram type '{header}'")
        subgraphs = 0
        ends = 0
        for line_num, line in enumerate(lines, 1):
            s = line.strip()
            if not s or s.startswith('%%'):
                continue
            if s.startswith('subgraph'):
                subgraphs += 1
            if s == 'end':
                ends += 1
            
            # Check quotes balance
            q_count = len(re.findall(r'(?<!\\)"', s))
            if q_count % 2 != 0:
                issues.append(f"{fpath} Block {b_idx} Line {line_num}: Unbalanced quotes: {s}")

            # Check edge pipe labels |...|
            edge_pipes = re.findall(r'\|([^|\n]+)\|', s)
            for p in edge_pipes:
                lbl = p.strip()
                if not (lbl.startswith('"') and lbl.endswith('"')):
                    if any(c in lbl for c in ['(', ')', '[', ']', '{', '}', '<', '>', '&']):
                        issues.append(f"{fpath} Block {b_idx} Line {line_num}: Unquoted special chars in edge label: |{p}|")

            # Extract labels inside double quotes
            labels = re.findall(r'"([^"]*)"', s)
            for lbl in labels:
                if '|' in lbl:
                    issues.append(f"{fpath} Block {b_idx} Line {line_num}: Raw pipe '|' inside label: {lbl}")
                # Check for nested brackets inside label which can confuse some Mermaid parsers
                if '[' in lbl or ']' in lbl:
                    issues.append(f"{fpath} Block {b_idx} Line {line_num}: Raw brackets '[' or ']' inside label: {lbl}")
                # Check for raw '<' or '>' in label that is not a known safe tag like <br/>
                cleaned_lbl = re.sub(r'</?(?:br|b|sub|sup|span)[^>]*>', '', lbl)
                if '<' in cleaned_lbl or '>' in cleaned_lbl:
                    issues.append(f"{fpath} Block {b_idx} Line {line_num}: Raw unescaped angle brackets in label: {lbl}")

        if subgraphs != ends:
            issues.append(f"{fpath} Block {b_idx}: Subgraph mismatch: {subgraphs} subgraphs vs {ends} ends")

print(f"Total diagrams validated: {total_diagrams}")
print(f"Total syntax / lint issues found: {len(issues)}")
for issue in issues:
    print(" - " + issue)

if len(issues) == 0:
    print("\n>>> ALL MARKDOWN AND MERMAID CHECKS PASSED PERFECTLY! <<<")

