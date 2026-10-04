#!/usr/bin/env python3
"""Markdown tables: the CPU decoders at full clock (bench_photos_<date>.json, run_bench.py on the
owner's 12 photos and 4:2:0 re-encodes of them) against the three FPGA decoders measured on the
Artix-7 board (boards/acorn_cle215/results_<date>.json) and this library on the EP2C5 (95 MHz; the
EP2C5 runs the same RTL, so its clock counts are the Artix-7's - measured for the originals on
2026-10-04, bench/board_jtag_95mhz_2026-10-04.txt).
CPU times are given at a steady REF_GHZ (the highest clock measured on the laptop): the laptop throttles
under sustained load, so each run's time is rescaled from its measured clock (perf stat), i.e. its cycle
count / REF_GHZ - the CPU's best case.  This library's MCU-order output has the pixels of
`djpeg -dct int -nosmooth`, so libjpeg-turbo -nosmooth is the like-for-like reference.
usage: photos_report.py bench_photos.json results.json"""
import sys, json

REF_GHZ = 3.9
CPU = [("libjpeg-turbo (nosmooth)", "libjpeg-turbo -nosmooth"), ("libjpeg-turbo (fancy)", "libjpeg-turbo"),
       ("FFmpeg mjpeg", "FFmpeg"), ("zune-jpeg", "zune-jpeg"),
       ("Pillow", "Pillow"), ("OpenCV", "OpenCV"), ("libjpeg 9e (nosmooth)", "libjpeg 9e -nosmooth"),
       ("stb_image", "stb_image"), ("Go image/jpeg", "Go image/jpeg")]

def main():
    B = json.load(open(sys.argv[1])); R = json.load(open(sys.argv[2]))
    res, board = B["results"], R["board_runs"]
    mhz = {d: R["builds"][d]["board_mhz"] for d in ("0", "1", "2")}
    ghz = [v["ghz"] for r in res.values() for v in r.values() if v and v.get("ghz")]
    def at_ref(v):                       # the run's cycles at a steady REF_GHZ
        return v["ms"] * v["ghz"] / REF_GHZ
    print(f"CPU: one core of the laptop's i7-8550U in the performance profile, single thread, file already "
          f"in memory; times in ms per photo **at a steady {REF_GHZ} GHz**: the laptop throttled to "
          f"{min(ghz):.2f}-{max(ghz):.2f} GHz during the runs (`perf stat`), so each time is its cycle count "
          f"/ {REF_GHZ} GHz, the CPU's best case.  FPGA: decoder clocks counted on the board (ideal input), "
          f"times at the board clock.\n")
    for title, sel in (("The owner's 12 photos (4:2:2, EXIF thumbnail)", lambda n: not n.endswith("_420")),
                       ("4:2:0 re-encodes of the same photos (core_jpeg supports only 4:4:4 / 4:2:0)", lambda n: n.endswith("_420"))):
        names = [n for n in res if sel(n)]
        print(f"#### {title}\n")
        print("| photo | " + " | ".join(c for _, c in CPU) + " | **BEBCL-JPEG** Artix-7 150 MHz | BEBCL-JPEG EP2C5 95 MHz | aq_djpeg Artix-7 150 MHz | core_jpeg Artix-7 92.3 MHz |")
        print("|---|" + "---:|" * (len(CPU) + 4))
        best_ratio = []; turbo_ratio = []; cpp_turbo = []; cpp_ours = []
        for n in names:
            r = res[n]; f = n + ".jpg"
            cells = [f"{at_ref(r[k]):.1f}" if r.get(k) else "-" for k, _ in CPU]
            def fpga(d, clk):
                b = board.get(f"{d}/{f}")
                if not b: return "-", None
                if int(b["flags"], 16) & 2 or int(b["pixels"]) == 0: return "fails", None
                ms = int(b["clocks"]) / (clk * 1e3)
                return f"{ms:.1f}", ms
            p0, ms0 = fpga("0", mhz["0"]); e0, _ = fpga("0", 95.0)
            a2, _ = fpga("2", mhz["2"]); c1, _ = fpga("1", mhz["1"])
            print(f"| {n} | " + " | ".join(cells) + f" | **{p0}** | {e0} | {a2} | {c1} |")
            if ms0:
                best = min(at_ref(v) for v in r.values() if v)
                best_ratio.append(ms0 / best); turbo_ratio.append(ms0 / at_ref(r["libjpeg-turbo (nosmooth)"]))
                t = r["libjpeg-turbo (nosmooth)"]; px = int(board[f"0/{f}"]["pixels"])
                cpp_turbo.append(t["ms"] * 1e-3 * t["ghz"] * 1e9 / px); cpp_ours.append(int(board[f"0/{f}"]["clocks"]) / px)
        print(f"\nBEBCL-JPEG (`FAST=1`) on the Artix-7 takes {min(turbo_ratio):.2f}-{max(turbo_ratio):.2f}x the time of "
              f"libjpeg-turbo -nosmooth at {REF_GHZ} GHz per photo ({min(best_ratio):.2f}-{max(best_ratio):.2f}x that of the "
              f"fastest CPU decoder on each photo); per clock it does "
              f"{min(a / b for a, b in zip(cpp_turbo, cpp_ours)):.1f}-{max(a / b for a, b in zip(cpp_turbo, cpp_ours)):.1f}x "
              f"more work ({min(cpp_ours):.2f}-{max(cpp_ours):.2f} clocks/pixel against libjpeg-turbo's "
              f"{min(cpp_turbo):.1f}-{max(cpp_turbo):.1f} CPU clocks/pixel).\n")

if __name__ == "__main__":
    main()
