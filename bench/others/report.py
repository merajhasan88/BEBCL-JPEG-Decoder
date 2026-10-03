#!/usr/bin/env python3
"""Markdown tables for the FPGA decoder comparison: resources and Fmax from the Quartus projects in
quartus/cmp_* (EP2C5) and quartus/cmp35_* (EP2C35, same family and speed grade; saved in
quartus_fits.json for clones that have not compiled them), clock counts and
accuracy from others.json (run_others.py plus this project's fast core).
usage: report.py [others.json] > comparison.md"""
import os, re, sys, json
HERE = os.path.dirname(os.path.abspath(__file__))
Q = os.path.join(HERE, "quartus")
SHOW = {"donald": "donald.jpg 2048x1365 4:2:0", "unnamed": "portrait 1944x2592 4:4:4",
        "adapter": "adapter photo 3120x4160 4:2:2"}
for i, n in enumerate(["IMG_20260912_000207", "IMG_20260912_003139", "IMG_20260912_004330", "IMG_20260912_004759",
                       "IMG_20260912_005827", "IMG_20260912_012049", "IMG_20260912_012545"]):
    SHOW[n] = f"phone photo {i + 1}, 4000x3000 4:2:0"
NAMES = {"ours": "this project, fast core", "core_jpeg": "ultraembedded core_jpeg",
         "core_jpeg_fixed": "core_jpeg, fixed tables only", "aq_djpeg": "Ishihara aq_djpeg"}

FITS = os.path.join(HERE, "quartus_fits.json")   # the numbers below, kept for clones without the builds

def fit_from_reports(proj):
    s = open(os.path.join(Q, proj, "output_files", "cmp.fit.summary")).read() if os.path.exists(os.path.join(Q, proj, "output_files", "cmp.fit.summary")) else ""
    if not s: return None
    le = re.search(r"Total logic elements : ([\d,]+) / ([\d,]+)", s)
    mem = re.search(r"Total memory bits : ([\d,]+)", s)
    mul = re.search(r"Embedded Multiplier 9-bit elements : (\d+)", s)
    ok = "Successful" in s
    sta = os.path.join(Q, proj, "output_files", "cmp.sta.rpt")
    fmax = None
    if ok and os.path.exists(sta):
        m = re.search(r"Slow Model Fmax Summary.*?\n; ([\d.]+) MHz", open(sta).read(), re.S)
        fmax = float(m[1]) if m else None
    return dict(le=le[1] if le else "?", dev_le=le[2] if le else "?", mem=mem[1] if mem else "?",
                mul=mul[1] if mul else "?", ok=ok, fmax=fmax)

def fit_table():
    """resources and Fmax of every comparison project: from the Quartus reports when the projects
    have been compiled here (quartus/compile_all.sh; the numbers are then saved to quartus_fits.json),
    otherwise from quartus_fits.json"""
    saved = json.load(open(FITS)) if os.path.exists(FITS) else {}
    out, fresh = {}, False
    for k in NAMES:
        for proj in (f"cmp_{k}", f"cmp35_{k}"):
            r = fit_from_reports(proj)
            if r: out[proj] = r; fresh = True
            else: out[proj] = saved.get(proj, dict(le="?", dev_le="?", mem="?", mul="?", ok=False, fmax=None))
    if fresh: json.dump(out, open(FITS, "w"), indent=1)
    return out

def main():
    data = json.load(open(sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "others.json")))
    print("| decoder | EP2C5 (4,608 LEs): logic elements | fits | Fmax | EP2C35: logic elements | Fmax | memory bits | 9-bit multipliers |")
    print("|---|---:|---|---:|---:|---:|---:|---:|")
    F5, F35 = {}, {}
    FIT = fit_table()
    for k in NAMES:
        a, b = FIT[f"cmp_{k}"], FIT[f"cmp35_{k}"]
        F5[k], F35[k] = a, b
        fa = "%.1f MHz" % a["fmax"] if a["fmax"] else "-"
        fb = "%.1f MHz" % b["fmax"] if b["fmax"] else "-"
        fits = "yes" if a["ok"] else "no"
        print(f"| {NAMES[k]} | {a['le']} | {fits} | {fa} | {b['le']} | {fb} | {b['mem']} | {b['mul']} |")
    print()
    print("| image | pixels | this project (bit-exact vs libjpeg) | core_jpeg | aq_djpeg |")
    print("|---|---:|---|---|---|")
    for img, d in data.items():
        o = d.get("ours", {}); px = o.get("pixels") or next(v.get("w", 0) * v.get("h", 0) for v in d.values() if "w" in v)
        def cell(k, fk):
            v = d.get(k)
            if not v: return "-"
            if "unsupported" in v: return f"not supported ({v['unsupported']})"
            if not v.get("complete"):
                return f"fails ({v['pixels']} of {px} pixels" + (f", decoded a {v['w']}x{v['h']} image" if v.get('w') and v['w'] * v['h'] != px else "") + ")"
            cpp = v["cycles"] / px
            fm = 95.0 if k == "ours" else F35[fk]["fmax"]      # ours: as run on the EP2C5 board
            where = " (EP2C5)" if k == "ours" else ""
            t = f", {v['cycles'] / fm / 1e3:.2f} ms at {fm:.0f} MHz{where}" if fm else ""
            if k == "ours":
                acc = "bit-exact" if v.get("bit_exact") else "NOT bit-exact"
            else:
                acc = f"PSNR {float(v['psnr']):.1f} dB, max diff {v['max_diff']}" if v.get("psnr") not in (None, "inf") else "bit-exact"
                if float(v.get("psnr", 99) if v.get("psnr") != "inf" else 99) < 30: acc = f"wrong output (PSNR {float(v['psnr']):.1f} dB)"
            return f"{cpp:.2f} clocks/px{t}; {acc}"
        print(f"| {SHOW.get(img, img)} | {px:,} | {cell('ours', 'ours')} | {cell('core_jpeg', 'core_jpeg')} | {cell('aq_djpeg', 'aq_djpeg')} |")

if __name__ == "__main__":
    main()
