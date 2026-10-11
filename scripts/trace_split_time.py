with open("transcript_run.txt", "r", errors="ignore") as f:
    for line in f:
        if "[SPLIT_CTX]" in line:
            parts = line.split(":")
            t = int(parts[0].replace("Time=", "").replace("#", "").strip())
            if 7000000000 <= t <= 8500000000:
                print(line.strip())
