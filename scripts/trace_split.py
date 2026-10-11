with open("transcript_run.txt", "r", errors="ignore") as f:
    for line in f:
        if "[SPLIT_CTX]" in line and "ctu=(0,1)" in line:
            print(line.strip())
