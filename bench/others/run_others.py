#!/usr/bin/env python3
"""Clock counts and accuracy of other FPGA JPEG decoders on the benchmark images, under the same
conditions as this project's RTL numbers (input offered as fast as accepted, every pixel accepted
at once).  Accuracy is measured against libjpeg 9e `djpeg -dct int -nosmooth` (which this
project's MCU-order output reproduces exactly).
usage: run_others.py out.json [image.jpg ...]     (run fetch.sh and build.sh first)
Environment: BENCH_SCRATCH (default /tmp/claude_bench) holds jpeg9e/inst/bin/djpeg (built by
../run_bench.py) and the temporary reference images."""
import os, sys, re, json, subprocess
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
SCR = os.environ.get("BENCH_SCRATCH", "/tmp/claude_bench")
DJPEG = os.path.join(SCR, "jpeg9e", "inst", "bin", "djpeg")
DECODERS = {"core_jpeg": os.path.join(HERE, "obj_core_jpeg", "Vcore_jpeg"),
            "aq_djpeg":  os.path.join(HERE, "obj_aq_djpeg", "Vaq_djpeg")}
DEFAULT = ([os.path.join(HERE, "..", "..", "tb", "corpus", n + ".jpg") for n in
            ("adp_64x64_q25_420", "board_352x32_q6_420", "scr_320x240_q90_420", "scr_160x120_q95_444",
             "adp_240x320_q95_422_rst4", "scr_256x64_q98_gray")] +
           [os.path.join(ROOT, "donald.jpg"), os.path.join(ROOT, "test_images", "unnamed.jpg"),
            os.path.join(ROOT, "test_images", "adapter.jpg")] +
           sorted(os.path.join(ROOT, "test_images", f) for f in os.listdir(os.path.join(ROOT, "test_images"))
                  if f.startswith("IMG_2026")))

def sof_info(path):
    d = open(path, "rb").read(); i = 2; info = {"dri": 0}
    while i + 4 <= len(d) and d[i] == 0xFF:
        m = d[i + 1]; L = int.from_bytes(d[i + 2:i + 4], "big")
        if m == 0xDD: info["dri"] = int.from_bytes(d[i + 4:i + 6], "big")
        if m == 0xC0:
            nf = d[i + 9]; info["samp"] = [(d[i + 11 + 3 * k] >> 4, d[i + 11 + 3 * k] & 15) for k in range(nf)]
        if m == 0xDA: break
        i += 2 + L
    return info

def main():
    out = sys.argv[1]; images = sys.argv[2:] or DEFAULT
    res = json.load(open(out)) if os.path.exists(out) else {}
    os.makedirs(os.path.join(SCR, "others"), exist_ok=True)
    for img in images:
        name = os.path.basename(img)[:-4]; info = sof_info(img)
        ref = os.path.join(SCR, "others", name + ".ref.ppm")
        subprocess.run([DJPEG, "-dct", "int", "-nosmooth", "-ppm", "-outfile", ref, img], check=True)
        for dec, binp in DECODERS.items():
            samp = info.get("samp", [])
            if dec == "core_jpeg" and (info["dri"] or (len(samp) == 3 and samp[0] not in ((1, 1), (2, 2)))):
                res.setdefault(name, {})[dec] = {"unsupported": "restart markers" if info["dri"] else "4:2:2"}
                print(name, dec, "unsupported", flush=True); continue
            o = os.path.join(SCR, "others", f"{name}.{dec}.ppm")
            r = subprocess.run(["nice", "-n", "10", binp, img, o, ref], capture_output=True, text=True, timeout=7200)
            m = re.search(r"cycles=(\d+) pixels=(\d+) WxH=(\d+)x(\d+)", r.stdout)
            a = re.search(r"vs reference: ([\d.]+)% of values identical, max abs diff (\d+), PSNR (\S+) dB", r.stdout)
            entry = {"cycles": int(m[1]), "pixels": int(m[2]), "w": int(m[3]), "h": int(m[4]),
                     "complete": r.returncode == 0}
            if a: entry.update(identical_pct=float(a[1]), max_diff=int(a[2]), psnr=a[3])
            res.setdefault(name, {})[dec] = entry
            print(name, dec, entry, flush=True)
            os.remove(o)
        os.remove(ref)
        json.dump(res, open(out, "w"), indent=1)

if __name__ == "__main__":
    main()
