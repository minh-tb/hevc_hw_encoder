#!/usr/bin/env python3
import sys
import os
import runpy

if __name__ == "__main__":
    target = os.path.join(os.path.dirname(__file__), "visualize_and_evaluate_foreman.py")
    runpy.run_path(target, run_name="__main__")
