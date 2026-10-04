#!/usr/bin/env python3
"""proposals.py - estimates for Proposals A and B of ROADMAP.md on the owner's photos (estimates, not
measurements: the inputs are measured, the designs are not built).

Inputs, per photo and 4:2:0 copy (perf_model.photos()):
  syncstats (syncstats.c)  self-synchronisation distances, symbols, k-symbols-per-clock rates
  the wide core's clocks   wide_photos_sim_2026-10-04.json (= the counts measured on the Artix-7 board)
  CPU times                perf_model.cpu_ms(best=True): the fastest CPU decoder on each photo, one
                           laptop core (i7-8550U) at a steady 3.9 GHz
  the fastest desktop core DESKTOP x the laptop core (libjpeg-turbo tjbench, OpenBenchmarking:
                           Core Ultra 9 285K 359 Mpixel/s vs i7-8550U 176)
Scenarios (clocks at MHZ):
  wide   today's wide core (measured)
  A<P>   Proposal A, two passes over P segments: a Huffman-only pass (sync points, DC sums, block
         counts) then the full decode, each over 1/P of the scan; pass 1 overlaps into the next
         segment by the sync distance (99th percentile). A<P>s: pass 1 with a 2-symbol skimmer.
  B2     Proposal B, 2 symbols per clock (32-bit window), 4-pixel output (perf_model, scaled by the
         model's error on today's core)
  B2w    2 symbols per clock + 8-pixel output + IDCT twice as wide
  python3 model/perf/proposals.py [--out proposals.json]
"""
import json, os, subprocess, sys
from dataclasses import replace
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import perf_model as P

DESKTOP = 359 / 176
MHZ = 150.0
W4 = replace(P.Cfg(name="FAST=2 (wide)"), px_clk=4, halves=3, sym_clk=1, look=8, long_fix=6, hd_fin=0, hd_gap=0,
             slots=4, in_rate=1, **P.IDCT_WIDE)


def syncstats(path):
    exe = os.path.join(P.BUILD, "syncstats")
    src = os.path.join(HERE, "syncstats.c")
    if not os.path.exists(exe) or os.path.getmtime(exe) < os.path.getmtime(src):
        subprocess.check_call(["cc", "-O2", "-o", exe, src])
    j = os.path.join(P.BUILD, "stats", os.path.basename(path) + ".sync.json")
    if not os.path.exists(j) or os.path.getmtime(j) < os.path.getmtime(path):
        out = subprocess.run(["nice", "-n", "10", exe, path, "2000"], check=True, capture_output=True, text=True).stdout
        open(j, "w").write(out)
    return json.load(open(j))


def main():
    out = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv else None
    wide = json.load(open(os.path.join(HERE, "wide_photos_sim_2026-10-04.json")))
    cpu = P.cpu_ms(best=True)
    rows = {}
    for f in P.photos():
        im = P.Image(f); st = syncstats(f); n = im.name
        clk = wide[n]["clocks"]; px = im.pixels; nsym = st["symbols"]; nlong = st["long_codes"]
        cps = st["clocks_per_symbol"]
        huff1 = cps["W64"][0] * nsym                    # Huffman-only pass, 1 symbol per clock
        huff2 = cps["W32"][1] * nsym                    # ... with a 2-symbol skimmer
        sync_clk = st["sync_mcu0_bits"]["p99"] * nsym / st["scan_bits"]
        r = {"pixels": px, "symbols_per_pixel": st["symbols_per_pixel"], "sync": st["sync_mcu0_bits"],
             "sync_best": st["sync_best_bits"], "sync_symbols": st["sync_mcu0_symbols"],
             "huff_clk_per_px": huff1 / px, "clk": {"wide": clk}}
        for p in (2, 4, 8):
            r["clk"][f"A{p}"] = huff1 / p + sync_clk + clk / p
            r["clk"][f"A{p}s"] = huff2 / p + sync_clk + clk / p
        # Proposal B with the model, scaled by its error on today's core
        m0 = P.simulate(im, W4)
        s2 = (cps["W32"][1] * nsym - 6 * nlong) / max(1, nsym - nlong)
        r["model_err"] = (m0 - clk) / clk
        r["sym_clk_2"] = s2
        r["clk"]["B2"] = P.simulate(im, replace(W4, sym_clk=s2)) * clk / m0
        r["clk"]["B2w"] = P.simulate(im, replace(W4, sym_clk=s2, px_clk=8, period=0.5)) * clk / m0
        c = cpu.get(n)
        r["cpu_ms"] = c
        r["ms"] = {k: v / (MHZ * 1e3) for k, v in r["clk"].items()}
        if c: r["vs_laptop"] = {k: v / c for k, v in r["ms"].items()}; r["vs_desktop"] = {k: v * DESKTOP / c for k, v in r["ms"].items()}
        rows[n] = r
    keys = list(next(iter(rows.values()))["clk"].keys())
    print(f"{'photo':30s} {'sym/px':>6s} {'sync p50/p99/max bits':>22s}  " + " ".join(f"{k:>6s}" for k in keys) + "   (clocks per pixel)")
    for n, r in rows.items():
        s = r["sync"]
        print(f"{n:30s} {r['symbols_per_pixel']:6.3f} {s['median']:>7d}/{s['p99']:>6d}/{s['max']:>7d}  "
              + " ".join(f"{r['clk'][k] / r['pixels']:6.3f}" for k in keys))
    def rng(field, k):
        v = [r[field][k] for r in rows.values() if field in r]
        return f"{min(v):.2f}-{max(v):.2f}"
    print(f"\nat {MHZ:.0f} MHz: time / the fastest CPU decoder's time (laptop core at 3.9 GHz | fastest desktop core, est. {DESKTOP:.2f}x the laptop core)")
    for k in keys:
        print(f"  {k:5s} ms {rng('ms', k):>11s}   vs laptop {rng('vs_laptop', k):>10s}   vs desktop {rng('vs_desktop', k):>10s}")
    me = [r["model_err"] for r in rows.values()]
    print(f"model error on today's wide core: {100*min(me):+.2f}% .. {100*max(me):+.2f}%")
    if out: json.dump(rows, open(out, "w"), indent=1)


if __name__ == "__main__":
    main()
