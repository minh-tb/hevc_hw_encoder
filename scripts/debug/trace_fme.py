with open("transcript_run.txt", "r", errors="ignore") as f:
    for line in f:
        try:
            parts = line.split(":")
            t = int(parts[0].replace("Time=", "").replace("#", "").strip())
            if 7480000000 <= t <= 7485000000:
                if "fme" in line.lower():
                    print(line.strip())
        except:
            pass
