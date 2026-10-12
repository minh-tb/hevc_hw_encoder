with open("transcript_run.txt", "r", errors="ignore") as f:
    for line in f:
        try:
            parts = line.split(":")
            t = int(parts[0].replace("Time=", "").replace("#", "").strip())
            if 7484000000 <= t <= 7530000000:
                if any(k in line for k in ["trigger_cu", "leaf_cu_start", "cu_pred_intra", "BEST=", "pred_req", "cu_req"]):
                    print(line.strip())
        except:
            pass
