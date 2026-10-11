with open("transcript_run.txt", "r", errors="ignore") as f:
    for line in f:
        try:
            parts = line.split(":")
            t = int(parts[0].replace("Time=", "").replace("#", "").strip())
            if 7484855000 <= t <= 7525000000:
                print(line.strip())
        except:
            pass
