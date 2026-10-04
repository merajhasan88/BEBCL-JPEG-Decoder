#!/usr/bin/env python3
"""Markdown tables of a board run (results_<date>.json, written by collect.py): the builds (area,
Fmax, board clock) and, per file, each decoder's clock count, time and correctness.
usage: report.py results_<date>.json"""
import sys, json

def main():
    R = json.load(open(sys.argv[1]))
    B, F = R["builds"], R["files"]
    D = sorted(B, key=int)                       # 0: FAST=1, 1: core_jpeg, 2: aq_djpeg, 3: FAST=2 (if run)
    OURS = ("0", "3")                            # this library: checked against libjpeg 9e
    out = [f"Board: {R['board']}. Date: {R['date']}. Timing: Vivado {R['vivado']}, part {R['timing_part']}.", ""]
    out += ["| decoder | board clock | Fmax (Vivado) | LUTs | flip-flops | block RAM (36 kb tiles) | DSP48E1 |",
            "|---|---:|---:|---:|---:|---:|---:|"]
    for d in D:
        b = B[d]
        out.append(f"| {b['name']} | {b['board_mhz']:.1f} MHz | {b['fmax']} | {b['luts']:,} | {b['ffs']:,} | "
                   f"{b['bram']:g} | {b['dsps']} |")
    out += ["", "Areas include the same UART harness (`uart_bench_core.sv`) around each decoder.", ""]
    out += ["| file | size | " + " | ".join(B[d]["short"] for d in D) + " |",
            "|---|---|" + "---|" * len(D)]
    for name, f in F.items():
        cells = []
        for d in D:
            r = R["board_runs"].get(f"{d}/{name}")
            if r is None: cells.append("not run"); continue
            px = f["w"] * f["h"]
            flags = int(r["flags"], 16)
            if flags & 2 or int(r["pixels"]) != px:
                cells.append(f"fails: {int(r['pixels']):,} of {px:,} pixels, reported size {r['WxH']}"
                             + (" (stalled, watchdog)" if flags & 2 else ""))
                continue
            c = int(r["clocks"]); ms = c / (B[d]["board_mhz"] * 1e3)
            if d in OURS:
                ok = int(r["checksum"], 16) == int(f["libjpeg9e"], 16) and int(r["err"], 16) == 0
                tail = "identical to libjpeg 9e" if ok else "DIFFERS from libjpeg 9e"
            else:
                s = R["sim"].get(f"{d}/{name}", {})
                same = s and s.get("clocks") == c and int(s.get("checksum", "0x0"), 16) == int(r["checksum"], 16)
                tail = ("= its simulation" if same else "NOT = its simulation") + (
                    f"; vs libjpeg max diff {s['max_diff']}, PSNR {float(s['psnr_db']):.1f} dB" if "max_diff" in s else "")
            cells.append(f"{c / px:.3f} clk/px, {ms:.1f} ms; {tail}")
        out.append(f"| {name} | {f['w']}x{f['h']} {f['sampling']} | " + " | ".join(cells) + " |")
    print("\n".join(out))

if __name__ == "__main__":
    main()
