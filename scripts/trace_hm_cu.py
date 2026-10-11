with open("dec_with_inter.txt", "r", encoding="utf-8", errors="ignore") as f:
    lines = f.readlines()

for i, line in enumerate(lines):
    if "[HM_INTER]" in line and "POC=1" in line:
        print(f"Line {i}: {line.strip()}")
