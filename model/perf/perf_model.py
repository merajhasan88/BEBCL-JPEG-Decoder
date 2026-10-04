#!/usr/bin/env python3
"""perf_model.py - clock-count model of the fast core (FAST=1, MCU order) and of wider variants.

The per-block statistics of real files (blockstats.c: Huffman symbols, long codes, bits, file
offsets) drive a model of the pipeline

    parser -> bit window -> Huffman decoder -> coefficient slots -> IDCT pass 1 -> workspace
           -> IDCT pass 2 -> MCU buffer (halves) -> output (pixels per clock)

in which every stage starts a block as soon as its input is complete and its resources are free,
as the handshakes of rtl/jpeg_dec_fast.sv do.  The constants of the current core are calibrated
against clock counts measured on the boards (= cycle-exact simulation); a variant changes the
stage parameters (symbols per clock, IDCT lanes, pixels per clock, input bytes per clock ...).

    python3 perf_model.py calibrate              # model vs the measured counts of the 24 photos
    python3 perf_model.py sweep                  # predicted clocks/pixel of the variants
    python3 perf_model.py one FILE.jpg [k=v ...] # one file, one configuration
"""
import json, os, subprocess, sys
from dataclasses import dataclass, replace, asdict
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
BUILD = os.path.join(HERE, "build")
REC = np.dtype([('comp', 'u1'), ('flags', 'u1'), ('nsym', 'u1'), ('nnz', 'u1'), ('maxk', 'u1'),
                ('nzrl', 'u1'), ('bits', '<u2'), ('nlen', 'u1', 8), ('endpos', '<u4')])


# ---------------------------------------------------------------- inputs
def tool():
    exe = os.path.join(BUILD, "blockstats")
    src = os.path.join(HERE, "blockstats.c")
    if not os.path.exists(exe) or os.path.getmtime(exe) < os.path.getmtime(src):
        os.makedirs(BUILD, exist_ok=True)
        subprocess.check_call(["cc", "-O2", "-o", exe, src])
    return exe


def photos():
    """The owner's photos in test_images/ and their 4:2:0 re-encodes (libjpeg-turbo djpeg | cjpeg
    -baseline -quality 90 -sample 2x2: the files measured on the Artix-7, byte for byte)."""
    ti = os.path.join(REPO, "test_images")
    orig = sorted(os.path.join(ti, f) for f in os.listdir(ti) if f.lower().endswith(".jpg"))
    out = []
    os.makedirs(os.path.join(BUILD, "p420"), exist_ok=True)
    for f in orig:
        c = os.path.join(BUILD, "p420", os.path.basename(f)[:-4] + "_420.jpg")
        if not os.path.exists(c):
            ppm = subprocess.run(["djpeg", "-pnm", f], check=True, capture_output=True).stdout
            jpg = subprocess.run(["cjpeg", "-baseline", "-quality", "90", "-sample", "2x2"], input=ppm,
                                 check=True, capture_output=True).stdout
            open(c, "wb").write(jpg)
        out.append(c)
    return orig + out


class Image:
    def __init__(self, path):
        self.path, self.name = path, os.path.basename(path)
        b = os.path.join(BUILD, "stats", self.name + ".bin")
        j = b[:-4] + ".json"
        if not os.path.exists(j) or os.path.getmtime(j) < os.path.getmtime(path):
            os.makedirs(os.path.dirname(b), exist_ok=True)
            out = subprocess.run([tool(), path, b], check=True, capture_output=True, text=True).stdout
            open(j, "w").write(out)
        self.info = json.load(open(j))
        self.r = np.fromfile(b, dtype=REC)
        self.W, self.H = self.info["W"], self.info["H"]
        self.pixels = self.W * self.H
        comps = self.info["comps"]
        hmax = max(h for h, v in comps); vmax = max(v for h, v in comps)
        self.mcu_px = (8 * hmax) * (8 * vmax) if self.info["ns"] > 1 else 64
        if self.info["ns"] == 1:   # grey: MCU = one block of the (only) component
            hmax = vmax = 1
        self.mcu_w, self.mcu_h = 8 * hmax, 8 * vmax


# ---------------------------------------------------------------- the model
@dataclass(frozen=True)
class Cfg:
    """One core configuration.  The defaults are today's fast core (validated against the boards);
    a variant changes some of them."""
    name: str = "today"
    # parser / input
    app_rate: float = 1.0     # APPn/COM bytes skipped per clock (EXIF data of phone photos: ~300 KB)
    lut_clk: int = 256        # clocks per DHT table (building its lookahead table)
    in_rate: float = 0.0      # entropy-coded bytes per clock into the bit window (0: never limits)
    in_buf: int = 8           # bytes the input may run ahead of the Huffman decoder
    # Huffman decoder (jpeg_huffdec)
    sym_clk: float = 3        # clocks per symbol found in the lookahead table
    look: int = 8             # lookahead table width (bits)
    long_base: int = -1       # a code of length L > look costs long_base + L clocks (today: L - 1) ...
    long_fix: int = 0         # ... or this many clocks if > 0 (second-level table)
    hd_fin: int = 4           # clocks from the last symbol of a block to `done` (pipeline drain)
    hd_gap: int = 2           # clocks from `done` to the next block's first symbol
    # coefficient slots between the decoder and the IDCT
    slots: int = 4
    zero_rate: int = 2        # coefficients cleared per clock after pass 1 (0: valid-bit masks, clean at once)
    # IDCT (jpeg_idct_fast): pass 1 reads a column, pass 2 a row, every `period` clocks
    period: int = 4           # 2 lanes: 4 (32 clocks per block); 8 lanes: 1 (8 clocks per block)
    ws: int = 2               # workspace slots between pass 1 and pass 2
    g1g2: int = 0             # pass 1 start -> pass 2 may start (0: today's 8*period + period + 2)
    wsfree: int = 0           # pass 2 start -> its workspace slot is free (0: today's 6*period + 2)
    g2bd: int = 0             # pass 2 start -> last sample written (0: today's 8*period + 7)
    # MCU buffer and output (jpeg_mcuout)
    halves: int = 2           # MCU buffers
    px_clk: int = 1           # pixels per clock
    tail: int = 2             # last MCU done -> frame done


def simulate(img, c=Cfg()):
    """Clock count of one image, MCU order, for configuration c.  With the defaults this is a
    clock-level model of today's fast core, following the handshakes of the RTL:

    jpeg_huffdec   block i starts hd_gap clocks after block i-1 is done or 1 clock after its slot
                   is clean; it takes sym_clk per symbol + hd_fin (a code longer than the
                   lookahead table: long_base + L).
    jpeg_idct_fast pass 1 (G1) and pass 2 (G2) start on period boundaries (G1 at phase 0, G2 at
                   phase 2) and take 8 periods each; G1 needs the block committed and a free
                   workspace slot (freed when G2 of the block ws earlier reaches row 5); G2 needs
                   pass 1 settled (one period) and the block's MCU buffer free.  A slot is cleared
                   after G1 has read it: one zeroer, slots in order, zero_rate coefficients per
                   clock, paused by every coefficient the decoder writes (DC + non-zero AC).
    jpeg_mcuout    MCU m starts 1 clock after its last block is written, at least P/px_clk + 1
                   clocks after MCU m-1 (P = pixels per MCU) and frees its buffer P/px_clk + 2
                   clocks after starting.
    With all 24 photos measured on the Artix-7 board: within 1.2 % (mean 0.3 %).
    """
    r = img.r
    nsym = r['nsym'].astype(np.int64)
    nlen = r['nlen'].astype(np.int64)
    L = np.arange(9, 17)
    miss = L > c.look
    cost_long = np.where(miss, c.long_fix if c.long_fix > 0 else c.long_base + L, 0)
    n_long = (nlen * miss).sum(axis=1)
    hd = np.ceil(c.sym_clk * (nsym - n_long)) + (nlen * cost_long).sum(axis=1) + c.hd_fin
    hd = hd.astype(np.int64).tolist()
    wr = (r['nnz'].astype(np.int64) + 1).tolist()            # coefficient writes per block
    last = (r['flags'] & 1).astype(bool).tolist()
    endpos = r['endpos'].astype(np.int64)
    nbytes = np.diff(np.concatenate(([img.info["scan_start"]], endpos))).tolist()
    n = len(hd)
    info = img.info
    t0 = int(info["app_bytes"] / c.app_rate + (info["scan_start"] - info["app_bytes"]) + c.lut_clk * info["dht_tables"])
    q = c.period
    p1len, p2len = 8 * q, 8 * q
    pout = -(-img.mcu_px // c.px_clk)                         # clocks per MCU at the output
    zclk = 64 // c.zero_rate if c.zero_rate else 0
    S, WS, H = c.slots, c.ws, c.halves
    g1g2 = c.g1g2 or (p1len + q + 2)
    wsf = c.wsfree or (6 * q + 2)
    g2bd = c.g2bd or (p2len + 7)

    def at_phase(t, p):                                       # first cycle >= t with t = p (mod q)
        return t + ((p - t) % q) if q > 1 else t

    hd_done = [0] * n; g1 = [0] * n; g2 = [0] * n; clean = [0] * n
    hd_prev = t0 - c.hd_gap
    arr = float(t0)
    mo_start_prev = -10**9
    mo_done = []
    m = 0
    mcu_last_bd = 0
    zero_free = 0
    for i in range(n):
        s = hd_prev + c.hd_gap
        if i >= S and clean[i - S] + 1 > s: s = clean[i - S] + 1
        e = s + hd[i]
        if c.in_rate:                                         # bytes of this block arrive in time?
            a0 = s - c.in_buf / c.in_rate
            arr = (arr if arr > a0 else a0) + nbytes[i] / c.in_rate
            if arr + c.hd_fin > e: e = int(arr) + 1 + c.hd_fin
        hd_done[i] = e; hd_prev = e
        # G1: committed, in order, free workspace slot
        t = e + 2
        if i >= 1 and g1[i - 1] + p1len > t: t = g1[i - 1] + p1len
        if i >= WS and g2[i - WS] + wsf > t: t = g2[i - WS] + wsf
        g1[i] = at_phase(t, 0)
        # clearing the slot after G1 has read it
        if zclk:
            z0 = g1[i] + p1len
            if zero_free > z0: z0 = zero_free
            zero_free = z0 + zclk + (wr[i + S - 1] if i + S - 1 < n else 0)
            clean[i] = zero_free
        else:
            clean[i] = g1[i] + p1len
        # G2: pass 1 settled, in order, MCU buffer free
        t = g1[i] + g1g2
        if i >= 1 and g2[i - 1] + p2len > t: t = g2[i - 1] + p2len
        if m >= H and mo_done[m - H] + 2 > t: t = mo_done[m - H] + 2
        g2[i] = at_phase(t, 2 % q if q > 1 else 0)
        bd = g2[i] + g2bd
        if bd > mcu_last_bd: mcu_last_bd = bd
        if last[i]:
            ms = mcu_last_bd + 1
            if mo_start_prev + pout + 1 > ms: ms = mo_start_prev + pout + 1
            mo_start_prev = ms
            mo_done.append(ms + pout + 2)
            m += 1
            mcu_last_bd = 0
    return mo_done[-1] + c.tail


# ---------------------------------------------------------------- measured counts
def measured():
    """Clock counts of the fast core (MCU order, RGB) on the Artix-7 board = simulation."""
    j = json.load(open(os.path.join(REPO, "boards", "acorn_cle215", "results_2026-10-03.json")))
    out = {}
    for k, v in j["board_runs"].items():
        b, f = k.split("/", 1)
        if b == "0" and isinstance(v, dict) and v.get("clocks"):
            out[f] = int(v["clocks"])
    return out


def calibrate(c=Cfg(), files=None, quiet=False):
    meas = measured()
    imgs = [Image(p) for p in (files or photos()) if os.path.basename(p) in meas]
    errs = []
    if not quiet:
        print(f"{'file':28s} {'measured':>10s} {'model':>10s} {'error':>7s}  clk/px")
    for im in imgs:
        m = meas[im.name]; t = simulate(im, c)
        errs.append((t - m) / m)
        if not quiet:
            print(f"{im.name:28s} {m:10d} {t:10.0f} {100*(t-m)/m:+6.2f}%  {m/im.pixels:.3f}")
    e = np.array(errs)
    if not quiet:
        print(f"mean error {100*e.mean():+.2f}%, mean |error| {100*np.abs(e).mean():.2f}%, worst {100*np.abs(e).max():.2f}%")
    return e


# ---------------------------------------------------------------- variants
# jpeg_idct_wide: pass 1 and pass 2 one column / row per clock, 3 workspace buffers, valid masks
IDCT_WIDE = dict(period=1, ws=3, g1g2=15, wsfree=9, g2bd=14, zero_rate=0)
WIDE = dict(sym_clk=1, look=9, long_fix=3, hd_fin=0, hd_gap=1, slots=8, zero_rate=0, halves=3)
VARIANTS = [
    Cfg(),
    replace(Cfg(), name="today + slot valid masks", zero_rate=0),
    replace(Cfg(), name="today + masks + 3 MCU buffers", zero_rate=0, halves=3),
    Cfg(name="1 sym/clk, IDCT 32 clk/blk, 1 px/clk", in_rate=1, **WIDE),
    Cfg(name="W2: 1 sym/clk, IDCT 16, 2 px/clk", period=2, px_clk=2, in_rate=2, app_rate=2, **WIDE),
    replace(Cfg(name="W4: 1 sym/clk, IDCT 8, 4 px/clk", period=1, px_clk=4, in_rate=4, app_rate=4, **WIDE), halves=4),
    replace(Cfg(name="W4 with 1 byte/clk input", period=1, px_clk=4, in_rate=1, app_rate=1, **WIDE), halves=4),
    replace(Cfg(name="W4 with 2 sym/clk (upper bound)", period=1, px_clk=4, in_rate=4, app_rate=4, **WIDE), halves=4, sym_clk=0.5),
]


def cpu_ms():
    """libjpeg-turbo's time per photo at full clock (bench/bench_photos_2026-10-04.json)."""
    j = json.load(open(os.path.join(REPO, "bench", "bench_photos_2026-10-04.json")))
    return {k + ".jpg": v["libjpeg-turbo (fancy)"]["ms"] for k, v in j["results"].items() if v.get("libjpeg-turbo (fancy)")}


def _run(args):
    path, c = args
    im = Image(path)
    return im.name, im.pixels, simulate(im, c)


def sweep(variants=VARIANTS, mhz=150.0, out=None):
    from multiprocessing import Pool
    files = photos()
    jobs = [(f, c) for c in variants for f in files]
    with Pool(int(os.environ.get("PERF_JOBS", "3"))) as pool:
        res = pool.map(_run, jobs)
    turbo = cpu_ms()
    table = {}
    for (f, c), (name, px, clk) in zip(jobs, res):
        table.setdefault(c.name, {})[name] = (clk, px)
    lines = []
    lines.append(f"| configuration | clocks/pixel, 4:2:2 originals | 4:2:0 copies | ms per photo at {mhz:.0f} MHz | x libjpeg-turbo's time |")
    lines.append("|---|---:|---:|---:|---:|")
    for c in variants:
        t = table[c.name]
        o = [clk / px for n, (clk, px) in t.items() if not n.endswith("_420.jpg")]
        q = [clk / px for n, (clk, px) in t.items() if n.endswith("_420.jpg")]
        ms = [clk / (mhz * 1e3) for n, (clk, px) in t.items()]
        ratio = [clk / (mhz * 1e3) / turbo[n] for n, (clk, px) in t.items() if n in turbo]
        lines.append(f"| {c.name} | {min(o):.2f}-{max(o):.2f} | {min(q):.2f}-{max(q):.2f} | {min(ms):.0f}-{max(ms):.0f} | {min(ratio):.2f}-{max(ratio):.2f} |")
    txt = "\n".join(lines)
    print(txt)
    if out:
        json.dump({c: {n: v for n, v in t.items()} for c, t in table.items()}, open(out, "w"), indent=1)
    return table


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "calibrate"
    kv = dict(a.split("=", 1) for a in sys.argv[2:] if "=" in a)
    c = Cfg()
    for k, v in kv.items():
        c = replace(c, **{k: type(getattr(c, k))(v)})
    if cmd == "calibrate":
        calibrate(c)
    elif cmd == "sweep":
        sweep(out=os.path.join(BUILD, "sweep.json"))
    elif cmd == "one":
        im = Image(sys.argv[2]); t = simulate(im, c)
        print(f"{im.name}: {t:.0f} clocks, {t/im.pixels:.3f} clocks/pixel")
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
