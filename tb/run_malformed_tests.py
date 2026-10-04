#!/usr/bin/env python3
"""Validation regression: every malformed / truncated file of tb/malformed (make_malformed.py) in
every build configuration, with and without 30 % random stalls.  Each run must end with
frame_done within the cycle limit and with the expected err bits; header errors must produce no
pixels.  The file's last byte carries in_last (the truncation cases depend on it).
usage: run_malformed_tests.py [--configs=a,b]"""
import os, sys, json, subprocess
HERE = os.path.dirname(os.path.abspath(__file__))
CONFIGS = ["mcu", "rbox", "rfancy", "ep2c5", "noyrgb", "fmcu", "frbox", "frfancy", "wmcu"]

def main():
    cfgs = CONFIGS
    for a in sys.argv[1:]:
        if a.startswith("--configs="): cfgs = a.split("=", 1)[1].split(",")
    cases = json.load(open(os.path.join(HERE, "malformed", "cases.json")))
    n = fails = 0
    for cfg in cfgs:
        exe = os.path.join(HERE, f"obj_{cfg}", "Vjpeg_decoder")
        raster = cfg not in ("mcu", "fmcu", "wmcu")
        for name, exp in sorted(cases.items()):
            for st in (0, 30):
                cmd = [exe, os.path.join(HERE, "malformed", name + ".jpg"), "/dev/null", "--quiet",
                       "--expect-err-mask", "%x" % exp["err"], "--stall", str(st), "--max-cycles", "2000000"]
                if raster: cmd.append("--raster")
                if not exp["pixels"]: cmd.append("--no-pixels")
                r = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
                n += 1
                ok = r.returncode == 0 and "PASS" in r.stderr
                if not ok:
                    fails += 1
                    last = [l for l in r.stderr.splitlines() if "FAIL" in l or "cycles=" in l]
                    print(f"FAIL {cfg:7s} stall={st:2d} {name}: {' | '.join(last)}")
    print(f"{n - fails}/{n} passed")
    sys.exit(1 if fails else 0)

if __name__ == "__main__":
    main()
