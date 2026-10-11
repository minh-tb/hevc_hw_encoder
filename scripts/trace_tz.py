with open("transcript_run.txt", "r", errors="ignore") as f:
    for line in f:
        try:
            parts = line.split(":")
            t = int(parts[0].replace("Time=", "").replace("#", "").strip())
            if 7450000000 <= t <= 7485000000:
                if any(k in line for k in ["tz_search", "fme_search", "MODE_DECISION"]):
                    print(line.strip())
        except:
            pass
