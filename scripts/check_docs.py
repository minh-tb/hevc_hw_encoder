import argparse
import glob
import io
import os
import re
import sys

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')


def check_local_path_exists(fpath, target, repo_root, check_build_outputs=False):
    """Resolve a markdown link or repo-relative path and report if missing."""
    norm = re.sub(r'^file:///[A-Za-z]:/.*?/hevc_hw_encoder/', '', target)
    if norm.startswith(('http://', 'https://', 'mailto:', '#', 'file:///')):
        return True
    norm = norm.split('#', 1)[0].strip()
    if not norm or norm.endswith('.orig'):
        return True
    if not check_build_outputs and norm.replace('\\', '/').startswith('synth/vivado_output'):
        return True

    rel_dir = os.path.dirname(fpath)
    cand_rel = os.path.normpath(os.path.join(rel_dir, norm)) if rel_dir else os.path.normpath(norm)
    cand_root = os.path.normpath(os.path.join(repo_root, norm))
    return os.path.exists(cand_rel) or os.path.exists(cand_root)


def main():
    parser = argparse.ArgumentParser(description="Validate Markdown, Mermaid diagrams, local links, and stale doc claims.")
    parser.add_argument("--strict", action="store_true", help="Exit non-zero if broken local paths or stale-claim warnings are found.")
    parser.add_argument("--check-build-outputs", action="store_true", help="Also verify generated synth/vivado_output/* paths exist.")
    args = parser.parse_args()

    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    os.chdir(repo_root)

    md_files = (
        glob.glob('docs/**/*.md', recursive=True)
        + glob.glob('docs/*.md')
        + glob.glob('*.md')
    )
    md_files = sorted(list(set(md_files)))

    print(f"Total markdown files evaluated: {len(md_files)}")
    issues = []
    warnings = []
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

        # 3. Broken local markdown links and explicit repo file paths
        for m in re.finditer(r'\[[^\]]+\]\(([^)\s]+)\)', text):
            tgt = m.group(1)
            if not check_local_path_exists(fpath, tgt, repo_root, check_build_outputs=args.check_build_outputs):
                warnings.append(f"{fpath}: Broken local link target '{tgt}'")

        for line_num, line in enumerate(text.splitlines(), 1):
            if not re.search(r'\b(?:deleted|removed|obsolete)\b', line, re.I):
                for m in re.finditer(r'(?<![A-Za-z0-9_./\\])((?:rtl|tb|scripts|docs|patches)/[A-Za-z0-9_./-]+\.[A-Za-z0-9]+)', line):
                    ref_path = m.group(1)
                    if not check_local_path_exists(fpath, ref_path, repo_root, check_build_outputs=args.check_build_outputs):
                        warnings.append(f"{fpath}:{line_num}: Missing referenced path '{ref_path}'")

            # 4. Stale claim checks (154 CABAC contexts, dead TB paths, 35-mode RMD)
            if re.search(r'\b154\b.{0,40}(?:context|probab|cycle|state|sram|model|init)|(?:context|model|init|0\.\.)\D{0,20}\b154\b', line, re.I):
                warnings.append(f"{fpath}:{line_num}: Stale 154-context reference")
            if re.search(r'\btb_axi_top\.sv\b|\btb_hevc_encoder_top\.sv\b', line):
                warnings.append(f"{fpath}:{line_num}: Dead testbench path reference")
            if re.search(r'(?:intra_rmd|\bRMD\b).{0,50}\b35\b|\b35\b.{0,25}(?:mode|angular|intra).{0,30}\bRMD\b', line, re.I):
                warnings.append(f"{fpath}:{line_num}: Possible 35-mode RMD claim")

    print(f"Total diagrams validated: {total_diagrams}")
    print(f"Total syntax / lint issues found: {len(issues)}")
    for issue in issues:
        print(" - " + issue)

    print(f"Total broken path / stale-claim warnings found: {len(warnings)}")
    for warn in warnings:
        print(" [WARN] " + warn)

    if len(issues) > 0:
        sys.exit(1)
    if args.strict and len(warnings) > 0:
        print("\n[FAIL] --strict enabled and broken path / stale-claim warnings exist.")
        sys.exit(1)

    print("\n>>> ALL MARKDOWN AND MERMAID CHECKS PASSED PERFECTLY! <<<")


if __name__ == "__main__":
    main()

