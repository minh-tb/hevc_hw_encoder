with open("transcript_run.txt", "r", errors="ignore") as f:
    for line in f:
        try:
            parts = line.split(":")
            t = int(parts[0].replace("Time=", "").replace("#", "").strip())
            if 4600000000 <= t <= 4635000000:
                print(line.strip())
        except:
            pass
