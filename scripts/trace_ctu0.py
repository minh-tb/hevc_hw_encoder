with open("transcript_run.txt", "r", errors="ignore") as f:
    for line in f:
        if "Started frame POC=1" in line:
            print("--- STARTED FRAME POC=1 ---")
        if "ctu=(0,0) cu=(32,0)" in line:
            print(line.strip())
