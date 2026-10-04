#!/usr/bin/env python3
"""Decode JPEG files with the decoder's RTL (cycle-exact Verilator simulation) and report the
decode time in clocks.  Put your files in test_images/ (or name them) and run:

  python3 scripts/decode.py                       # every .jpg/.jpeg in test_images/
  python3 scripts/decode.py photo.jpg --profile pillow --check

options:
  --profile libjpeg   pixels identical to libjpeg 9e `djpeg -dct int -nosmooth` (default; MCU-order
                      output, so any image size)
  --profile pillow    pixels identical to Pillow / OpenCV / libjpeg-turbo defaults (raster output with
                      fancy upsampling; the row buffer is sized for the widest image)
  --core fast|small|wide  FAST=1 pipelined core, ~1 clock/pixel (default), the compact core (~13 clocks/pixel),
                      or the wide core (FAST=2, 4 pixels per clock; MCU order, so --profile libjpeg only)
  --fmt rgb|ycbcr|y   output format (default rgb)
  --out DIR           output folder (default out/): <name>.ppm (or .pgm), plus <name>.png when Pillow is installed
  --mhz F             also report the decode time at this clock (default 100)
  --check             compare with the reference decoder: Pillow for --profile pillow; for --profile
                      libjpeg, libjpeg 9e's djpeg given with --djpeg PATH (bench/run_bench.py builds it)
Needs Verilator and make (the simulation is built on first use into sim build folders under tb/).
"""
import os, sys, re, glob, subprocess, struct

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, ".."))
TB = os.path.join(REPO, "tb")
ERR_NAMES = ["SOF_TYPE", "PRECISION", "DQT", "DHT", "NCOMP", "SAMPLING", "SCAN", "HUFF", "MARKER",
             "SYNC", "WIDTH", "FRAME", "TRUNC"]
ROWBUF_PER_16PX = 560        # worst case (4:4:0 with fancy upsampling), README "Row-buffer bytes"

def opt(args, name, default=None, flag=False):
    if name in args:
        i = args.index(name)
        if flag: del args[i]; return True
        v = args[i + 1]; del args[i:i + 2]; return v
    return default

def sof_info(path):
    """(width, height, sampling text) from the first SOFn, skipping APPn payloads (EXIF thumbnails)"""
    d = open(path, "rb").read(); i = 2
    while i + 4 <= len(d) and d[i] == 0xFF:
        m = d[i + 1]
        if m in (0xD8, 0x01) or 0xD0 <= m <= 0xD7: i += 2; continue
        L = struct.unpack(">H", d[i + 2:i + 4])[0]
        if 0xC0 <= m <= 0xCF and m not in (0xC4, 0xC8, 0xCC):
            h, w, nf = struct.unpack(">HHB", d[i + 5:i + 10])
            s = [(d[i + 11 + 3 * k] >> 4, d[i + 11 + 3 * k] & 15) for k in range(nf)]
            name = "grey" if nf == 1 else {(1, 1): "4:4:4", (2, 1): "4:2:2", (2, 2): "4:2:0", (1, 2): "4:4:0"}.get(s[0], "x".join(map(str, s[0])))
            return w, h, ("SOF%d " % (m - 0xC0) if m != 0xC0 else "") + name
        if m == 0xDA: break
        i += 2 + L
    return 0, 0, "?"

def build(target):
    r = subprocess.run(["make", "-C", TB, target], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"building {target} failed:\n{r.stdout[-2000:]}{r.stderr[-2000:]}")
    return os.path.join(TB, target)

def main():
    args = sys.argv[1:]
    if "-h" in args or "--help" in args: print(__doc__); return
    profile = opt(args, "--profile", "libjpeg"); core = opt(args, "--core", "fast"); fmt = opt(args, "--fmt", "rgb")
    out = os.path.abspath(opt(args, "--out", os.path.join(REPO, "out"))); mhz = float(opt(args, "--mhz", "100"))
    check = opt(args, "--check", flag=True); djpeg = opt(args, "--djpeg")
    files = args or sorted(glob.glob(os.path.join(REPO, "test_images", "*.jpg")) + glob.glob(os.path.join(REPO, "test_images", "*.jpeg"))
                           + glob.glob(os.path.join(REPO, "test_images", "*.JPG")))
    if not files: sys.exit("no JPEG files given and none in test_images/")
    if profile not in ("libjpeg", "pillow") or core not in ("fast", "small", "wide") or fmt not in ("rgb", "ycbcr", "y"):
        sys.exit("bad option; see --help")
    if core == "wide" and profile != "libjpeg":
        sys.exit("the wide core (FAST=2) has MCU-order output only: use --profile libjpeg")
    info = {f: sof_info(f) for f in files}
    f_ = "f" if core == "fast" else ""
    if profile == "libjpeg":
        target = {"fast": "obj_fmcu", "small": "obj_mcu", "wide": "obj_wmcu"}[core] + "/Vjpeg_decoder"
        raster = False
    else:
        need = max(((w + 15) // 16) * ROWBUF_PER_16PX for w, _, _ in info.values())
        rb = 16384
        while rb < need: rb *= 2
        target = f"obj_{f_}rfancy_rb{rb}/Vjpeg_decoder"; raster = True
    print(f"building {target} (first use only) ...", flush=True)
    exe = build(target)
    os.makedirs(out, exist_ok=True)
    try:
        from PIL import Image
    except ImportError:
        Image = None
    print(f"{'file':32s} {'size':>11s} {'type':>7s} {'clocks':>12s} {'clk/px':>7s} {'ms@%gMHz' % mhz:>10s}  result")
    bad = 0
    for f in files:
        w, h, kind = info[f]
        base = os.path.splitext(os.path.basename(f))[0]
        pnm = os.path.join(out, base + (".pgm" if fmt == "y" else ".ppm"))
        cmd = [exe, f, pnm, "--fmt", fmt, "--quiet"] + (["--raster"] if raster else [])
        r = subprocess.run(cmd, capture_output=True, text=True)
        m = re.search(r"cycles=(\d+) .*pixels=(\d+).*err=0x([0-9a-fA-F]+)", r.stderr + r.stdout)
        if not m:
            print(f"{os.path.basename(f):32s} simulation failed: {(r.stderr + r.stdout)[-300:]}"); bad += 1; continue
        cyc, px, err = int(m[1]), int(m[2]), int(m[3], 16)
        res = "ok" if err == 0 else "err " + ",".join(n for k, n in enumerate(ERR_NAMES) if err >> k & 1)
        if err: bad += 1
        if check and px:
            res += "; " + compare(f, pnm, profile, fmt, djpeg, Image)
            bad += "DIFFERS" in res
        if Image is not None and px and os.path.exists(pnm):
            Image.open(pnm).save(os.path.join(out, base + ".png"))
        cpp = cyc / (w * h) if w * h else 0
        print(f"{os.path.basename(f):32s} {f'{w}x{h}':>11s} {kind:>7s} {cyc:12,d} {cpp:7.3f} {cyc / (mhz * 1e3):10.2f}  {res}", flush=True)
    print(f"outputs in {out}")
    sys.exit(1 if bad else 0)

def compare(jpg, pnm, profile, fmt, djpeg, Image):
    if Image is None: return "no check (Pillow not installed)"
    import tempfile
    mine = Image.open(pnm)
    if profile == "pillow":
        ref = Image.open(jpg)                    # libjpeg-turbo inside Pillow
        if fmt == "ycbcr": ref.draft("YCbCr", ref.size)      # decoder output before colour conversion
        if fmt == "y": ref.draft("L", ref.size)              # luma only
        ref.load()
        name = "Pillow"
    else:
        if not djpeg: return "no check (give --djpeg PATH to libjpeg 9e djpeg)"
        if fmt == "ycbcr": return "no check (djpeg gives RGB)"
        with tempfile.TemporaryDirectory() as t:
            o = os.path.join(t, "ref.pnm")
            a = [djpeg, "-dct", "int", "-nosmooth"] + (["-grayscale"] if fmt == "y" else []) + ["-pnm", "-outfile", o, jpg]
            subprocess.run(a, capture_output=True)
            if not os.path.exists(o): return "no check (djpeg failed)"
            ref = Image.open(o); ref.load()
        name = "libjpeg 9e"
    if ref.size != mine.size: return f"DIFFERS from {name} (size {ref.size} vs {mine.size})"
    a, b = ref.tobytes(), mine.tobytes()        # raw bytes: RGB, YCbCr or luma
    if a == b: return f"identical to {name}"
    diff = max(abs(x - y) for x, y in zip(a, b))
    return f"DIFFERS from {name} (max diff {diff})"

if __name__ == "__main__":
    main()
