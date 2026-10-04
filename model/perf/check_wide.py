#!/usr/bin/env python3
"""check_wide.py - the wide core (FAST=2) on the photos: cycle-exact simulation vs the model.

For every photo in test_images/ and its 4:2:0 copy (perf_model.photos()): decodes it with
libjpeg 9e (`djpeg -dct int -nosmooth`, bench/tools.py) as the reference, runs the Verilator
build tb/obj_wmcu (FAST=2, MCU order, RGB) with that reference, and prints the clock count next
to the model's prediction and the fast core's count measured on the Artix-7 board.

    python3 model/perf/check_wide.py [--out results.json] [files.jpg ...]
"""
import json, os, subprocess, sys, time
from dataclasses import replace
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE); sys.path.insert(0, os.path.join(REPO, "bench"))
import perf_model as P
from tools import djpeg9

# the wide core as built (WIDE_STATUS.md step 3)
W4 = replace(P.Cfg(name="FAST=2 (wide)"), px_clk=4, halves=3, sym_clk=1, look=8, long_fix=5, hd_fin=0, hd_gap=0,
             slots=4, in_rate=1, **P.IDCT_WIDE)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    out = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv else None
    if out in args: args.remove(out)
    files = args or P.photos()
    exe = os.path.join(REPO, "tb", "obj_wmcu", "Vjpeg_decoder")
    gdir = os.path.join(P.BUILD, "golden9"); os.makedirs(gdir, exist_ok=True)
    meas = P.measured()
    res = {}
    print(f"{'file':28s} {'sim clocks':>11s} {'clk/px':>7s} {'model':>8s} {'fast core':>8s}  result")
    for f in files:
        im = P.Image(f)
        g = os.path.join(gdir, im.name[:-4] + ".ppm")
        if not os.path.exists(g):
            with open(g, "wb") as fo:
                subprocess.run([djpeg9(), "-dct", "int", "-nosmooth", "-pnm", f], stdout=fo, check=True)
        t0 = time.time()
        r = subprocess.run(["nice", "-n", "10", exe, f, "/dev/null", "--golden", g, "--quiet", "--max-cycles", "200000000"],
                           capture_output=True, text=True)
        line = next((l for l in r.stderr.splitlines() if l.startswith("cycles=")), "")
        clk = int(line.split()[0].split("=")[1]) if line else 0
        ok = r.returncode == 0 and "PASS" in r.stderr
        model = P.simulate(im, W4)
        fast = meas.get(im.name)
        res[im.name] = dict(clocks=clk, pixels=im.pixels, model=model, fast=fast, ok=ok, sim_s=round(time.time() - t0, 1))
        print(f"{im.name:28s} {clk:11d} {clk/im.pixels:7.3f} {100*(model-clk)/max(clk,1):+7.2f}% "
              f"{(fast/im.pixels if fast else 0):8.3f}  {'identical to libjpeg 9e' if ok else 'FAIL: ' + line}", flush=True)
        if out: json.dump(res, open(out, "w"), indent=1)
    bad = [n for n, v in res.items() if not v["ok"]]
    print(f"{len(res) - len(bad)}/{len(res)} identical to libjpeg 9e" + (f"; failed: {bad}" if bad else ""))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
