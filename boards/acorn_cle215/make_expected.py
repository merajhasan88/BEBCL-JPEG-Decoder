#!/usr/bin/env python3
"""Expected board results for pi_bench.py runs, from simulations and the reference decoder.
  DUT 0, 3 (this library, FAST=1 / FAST=2): checksum of libjpeg 9e `djpeg -dct int -nosmooth` (the MCU-order
        output is bit-identical to it) and the clock count of the RTL simulation (tb/obj_fmcu / tb/obj_wmcu);
  DUT 1, 2 (core_jpeg, aq_djpeg): clock count and checksum of their own Verilator simulation
        (bench/others/obj_*: build.sh; files below 64 KB: the board harness simulation sim/obj_dut<d>),
        i.e. the board must reproduce the simulation exactly.
usage: make_expected.py [--djpeg PATH] --out expected.json [--duts 0,1,2,3] file.jpg [...]
Needs tb/obj_fmcu / tb/obj_wmcu (cd tb && make) and, for DUT 1/2, bench/others/build.sh."""
import os, sys, re, json, subprocess, tempfile
import numpy as np
from PIL import Image
HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.normpath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(LIB, "bench"))
from tools import ref_checksum, djpeg9      # libjpeg 9e reference (built on demand)

def ppm_checksum(path):
    a = np.asarray(Image.open(path).convert("RGB")).astype(np.uint64)
    h, w, _ = a.shape
    y, x = np.mgrid[0:h, 0:w]
    words = ((((x ^ y) & 0xFF).astype(np.uint64)) << 24) | (a[:, :, 0] << 16) | (a[:, :, 1] << 8) | a[:, :, 2]
    return int(words.sum()) & 0xFFFFFFFF

def main():
    args = sys.argv[1:]
    def opt(name, default=None):
        if name in args:
            i = args.index(name); v = args[i + 1]; del args[i:i + 2]; return v
        return default
    djpeg = opt("--djpeg") or djpeg9(); out = opt("--out", "expected.json"); duts = [int(d) for d in opt("--duts", "0,1,2").split(",")]
    exp = json.load(open(out)) if os.path.exists(out) else {}
    for f in args:
        name = os.path.basename(f)
        for d, obj in ((0, "obj_fmcu"), (3, "obj_wmcu")):
            if d not in duts: continue
            chk, w, h = ref_checksum(f, djpeg)
            r = subprocess.run(["nice", "-n", "19", os.path.join(LIB, "tb", obj, "Vjpeg_decoder"), f, "/dev/null",
                                "--fmt", "rgb", "--quiet"], capture_output=True, text=True, timeout=7200).stderr
            m = re.search(r"cycles=(\d+) .*pixels=(\d+).*err=0x([0-9a-f]+)", r)
            e = {"clocks": int(m[1]), "err": f"0x{int(m[3], 16):04X}", "w": w, "h": h}
            if chk is not None: e["checksum"] = f"0x{chk:08X}"
            exp[f"{d}/{name}"] = e; print(d, name, e, flush=True)
        for d, tag in ((1, "core_jpeg"), (2, "aq_djpeg")):
            if d not in duts: continue
            if os.path.getsize(f) < 65536:
                # small files: the simulation of the whole board harness (sim/), exact even where the
                # decoder emits pixels outside the image (MCU padding)
                r = subprocess.run([os.path.join(HERE, "sim", f"obj_dut{d}", "Vuart"), f], capture_output=True,
                                   text=True, timeout=7200).stdout
                m = re.search(r"clocks=(\d+) checksum=(0x[0-9A-F]+) err=\S+ (\d+)x(\d+) pixels=(\d+)", r)
                e = {"clocks": int(m[1]), "checksum": m[2], "w": int(m[3]), "h": int(m[4]), "pixels": int(m[5])}
                exp[f"{d}/{name}"] = e; print(d, name, e, flush=True)
                continue
            with tempfile.TemporaryDirectory() as t:
                ppm, ref = os.path.join(t, "o.ppm"), os.path.join(t, "ref.ppm")
                # accuracy against libjpeg 9e `djpeg -dct int -nosmooth` (which DUT 0 reproduces exactly)
                subprocess.run([djpeg, "-dct", "int", "-nosmooth", "-pnm", "-outfile", ref, f], capture_output=True)
                r = subprocess.run(["nice", "-n", "19", os.path.join(LIB, "bench", "others", f"obj_{tag}", f"V{tag}"), f, ppm]
                                   + ([ref] if os.path.exists(ref) else []), capture_output=True, text=True, timeout=7200).stdout
                m = re.search(r"cycles=(\d+) pixels=(\d+) WxH=(\d+)x(\d+)", r)
                e = {"clocks": int(m[1]), "pixels": int(m[2]), "w": int(m[3]), "h": int(m[4])}
                if int(m[2]) == int(m[3]) * int(m[4]) and int(m[2]) > 0: e["checksum"] = f"0x{ppm_checksum(ppm):08X}"
                a = re.search(r"([\d.]+)% of values identical, max abs diff (\d+), PSNR (\S+) dB", r)
                if a: e.update(identical_pct=float(a[1]), max_diff=int(a[2]), psnr_db=a[3])
                elif "size mismatch" in r: e["accuracy"] = "size differs from libjpeg's image"
            exp[f"{d}/{name}"] = e; print(d, name, e, flush=True)
        json.dump(exp, open(out, "w"), indent=1)

if __name__ == "__main__":
    main()
