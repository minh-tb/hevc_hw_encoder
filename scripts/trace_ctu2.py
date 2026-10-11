with open("transcript_run.txt", "r", errors="ignore") as f:
    for line in f:
        t_m = False
        try:
            parts = line.split(":")
            t_str = parts[0].replace("Time=", "").replace("#", "").strip()
            t = int(t_str)
            if 7480000000 <= t <= 7580000000:
                t_m = True
        except:
            pass
        if t_m:
            if any(k in line for k in ["MODE_DECISION", "CABAC", "TZ_SEARCH", "RECON", "FME", "INTER", "mc_"]):
                print(line.strip())
