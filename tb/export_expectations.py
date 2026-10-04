#!/usr/bin/env python3
"""Write the regression's expectations as plain data for tb/run_tests.sh (the regression with the
SystemVerilog testbench, which needs no Python):
  tb/expected.txt          one line per (image, configuration, format): pass <golden> | width | error
  tb/malformed/cases.txt   <name> <err bits hex> <pixels allowed 0/1>   (from cases.json)
  tb/stream_scenarios.txt  <files...>|<title>                           (run_stream_tests.py)
The golden images (tb/golden/) are made by run_tests.py / model/jpeg_golden.py; run it first.
usage: export_expectations.py"""
import os, json, glob
HERE = os.path.dirname(os.path.abspath(__file__))
import run_tests as T
import run_stream_tests as S

def main():
    lines = []
    for img in sorted(glob.glob(os.path.join(HERE, "corpus", "*.jpg"))):
        b = os.path.basename(img)[:-4]
        data = open(img, "rb").read()
        unsupported = "UNSUPPORTED" in b
        for cfg, cv in T.CONFIGS.items():
            raster, fancy, rb, has_rgb = cv[:4]
            fast = len(cv) > 4 and cv[4]
            for fmt in (["rgb"] if unsupported else T.FMTS):
                if unsupported:
                    lines.append(f"{b} {cfg} {fmt} error -"); continue
                if rb is not None and (not T.rowbuf_fits_fast(data, fancy, fmt, rb) if fast else T.rowbuf_need(data, fancy, fmt) > rb):
                    lines.append(f"{b} {cfg} {fmt} width -"); continue
                gfmt = fmt if (has_rgb or fmt != "rgb") else "ycbcr"     # RGB_OUT=0: FMT_RGB gives YCbCr
                g = f"golden/{b}.{'fancy' if fancy else 'box'}.{gfmt}.pnm"
                if not os.path.exists(os.path.join(HERE, g)): raise SystemExit(f"missing {g}: run run_tests.py first")
                lines.append(f"{b} {cfg} {fmt} pass {g}")
    with open(os.path.join(HERE, "expected.txt"), "w") as f:
        f.write("# image configuration format expectation [golden]   (written by export_expectations.py)\n")
        f.write("\n".join(lines) + "\n")
    cases = json.load(open(os.path.join(HERE, "malformed", "cases.json")))
    with open(os.path.join(HERE, "malformed", "cases.txt"), "w") as f:
        f.write("# file err-bits(hex, at least) pixels-allowed   (written by export_expectations.py)\n")
        for name, e in sorted(cases.items()):
            f.write(f"{name} {e['err']:x} {1 if e['pixels'] else 0}\n")
    with open(os.path.join(HERE, "stream_scenarios.txt"), "w") as f:
        f.write("# files streamed back to back without a reset|what it checks   (written by export_expectations.py)\n")
        for title, names in S.SCENARIOS:
            f.write(" ".join(names) + "|" + title + "\n")
    print(f"{len(lines)} expectations, {len(cases)} malformed cases, {len(S.SCENARIOS)} stream scenarios")

if __name__ == "__main__":
    main()
