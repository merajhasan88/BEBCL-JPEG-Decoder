#!/usr/bin/env python3
"""Multi-image regression: several files streamed back to back through one decoder without a
reset, for every build configuration, with and without 30 % random stalls.  Every supported
frame must match its golden with err = 0; an unsupported file must end with a non-zero err and
no pixels, and must not affect the image after it.
usage: run_stream_tests.py [--configs=a,b]      (needs obj_<cfg>/Vmulti: `make multi`)"""
import sys, os, re, subprocess
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "model"))
import jpeg_golden as G
from run_tests import CONFIGS

CORPUS = os.path.join(HERE, "corpus")
SCENARIOS = [
    ("restart interval does not leak into the next image", ["adp_45x37_q30_420_rst2", "adp_32x32_q25_420"]),
    ("an unsupported SOF1 file does not block the next image", ["adp_40x40_q20_sof1_UNSUPPORTED", "adp_32x32_q25_420"]),
    ("an unsupported progressive file does not block the next image", ["adp_45x37_q30_progressive_UNSUPPORTED", "scr_17x33_q40_420"]),
    ("grey, 4:4:4, 4:2:0 with restarts, 4:2:2 with EXIF, back to back",
     ["scr_13x11_q40_gray", "adp_32x32_q25_444", "adp_40x50_q30_420_rst3", "adp_45x37_q30_422_exifthumb"]),
    ("the same image twice", ["adp_64x64_q25_420", "adp_64x64_q25_420"]),
]

def golden(name, prof, fmt):
    g = os.path.join(HERE, "golden", f"{name}.{prof}.{fmt}.pnm")
    src = os.path.join(CORPUS, name + ".jpg")
    if not os.path.exists(g) or os.path.getmtime(g) < os.path.getmtime(src):
        os.makedirs(os.path.dirname(g), exist_ok=True)
        data = open(src, "rb").read()
        open(g, "wb").write(G.Decoder(data, upsample=prof, cc="turbo" if prof == "fancy" else "libjpeg9", out=fmt).run())
    return g

def main():
    sel = [a.split("=", 1)[1].split(",") for a in sys.argv[1:] if a.startswith("--configs=")]
    configs = {k: v for k, v in CONFIGS.items() if not sel or k in sel[0]}
    total = fails = 0
    for cfg, cv in configs.items():
        raster, fancy, rb, has_rgb = cv[:4]
        fmt = "rgb" if has_rgb else "ycbcr"          # RGB_OUT=0 builds deliver YCbCr
        prof = "fancy" if fancy else "box"
        binp = os.path.join(HERE, f"obj_{cfg}", "Vmulti")
        for title, names in SCENARIOS:
            for stall in (0, 30):
                args = [binp, "--fmt", fmt, "--stall", str(stall)]
                for n in names:
                    args += [os.path.join(CORPUS, n + ".jpg"), "-" if "UNSUPPORTED" in n else golden(n, prof, fmt)]
                r = subprocess.run(args, capture_output=True, text=True, timeout=600)
                frames = re.findall(r"frame (\d+): (\d+)x(\d+), (\d+) pixels, err=0x([0-9a-f]+), (.*)", r.stdout)
                ok = len(frames) == len(names)
                for (k, w, h, npx, err, verdict), n in zip(frames, names):
                    if "UNSUPPORTED" in n: ok &= int(err, 16) != 0 and int(npx) == 0
                    else: ok &= int(err, 16) == 0 and verdict.strip() == "MATCH"
                total += 1
                if not ok:
                    fails += 1
                    print(f"FAIL {cfg:7s} stall={stall:2d} {title}\n   " + r.stdout.strip().replace("\n", "\n   "))
        print(f"done {cfg}", flush=True)
    print(f"STREAM TESTS {total - fails}/{total} passed" + ("" if not fails else f"  ({fails} FAILED)"))
    return 1 if fails else 0

if __name__ == "__main__":
    sys.exit(main())
