#!/usr/bin/env python3
"""Clock counts of the RTL decoder for the benchmark images (Verilator, cycle exact).
Runs tb/obj_<cfg>/Vjpeg_decoder with no stalls (the JPEG offered one byte per clock, every pixel
accepted the clock it is offered), reads the clock count from frame start to frame_done.
usage: bench_fpga.py in_bench.json [--only SUBSTRING]   (adds/updates the "rtl" section)"""
import os, sys, re, json, subprocess
HERE = os.path.dirname(os.path.abspath(__file__)); TB = os.path.join(HERE, "..", "tb")
sys.path.insert(0, HERE)
from run_bench import IMAGES
CONFIGS = [   # (label, obj dir, fmt, raster) - the configurations that run on the EP2C5
    ("MCU order, replication, RGB",       "obj_mcu",  "rgb", False),   # compact core, quartus/fpga, 50 MHz
    ("FAST, MCU order, replication, RGB", "obj_fmcu", "rgb", False),   # fast core, quartus/fpga_jtag, 95 MHz
]
def main():
    res = json.load(open(sys.argv[1]))
    only = sys.argv[sys.argv.index("--only") + 1] if "--only" in sys.argv else None
    rtl = res.get("rtl", {})
    for name, path in IMAGES:
        rtl.setdefault(name, {})
        for label, obj, fmt, raster in CONFIGS:
            if only and only not in label: continue
            cmd = ["nice", "-n", "10", os.path.join(TB, obj, "Vjpeg_decoder"), path, "/dev/null", "--fmt", fmt, "--quiet"]
            if raster: cmd.append("--raster")
            out = subprocess.run(cmd, capture_output=True, text=True, timeout=3600).stderr
            m = re.search(r"cycles=(\d+) .*pixels=(\d+).*err=0x([0-9a-f]+)", out)
            fs = re.search(r"frame_start: .* at cycle (\d+)", out)
            rtl[name][label] = dict(cycles=int(m[1]), pixels=int(m[2]), err=m[3])
            print(name, label, rtl[name][label], flush=True)
    res["rtl"] = rtl
    json.dump(res, open(sys.argv[1], "w"), indent=1)
if __name__ == "__main__":
    main()
