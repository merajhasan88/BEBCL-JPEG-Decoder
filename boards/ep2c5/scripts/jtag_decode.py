#!/usr/bin/env python3
"""Decode JPEG files on the EP2C5 through the USB-Blaster (boards/ep2c5/fpga_jtag, boards/ep2c5/rtl/fpga_jtag_top.sv)
and report the decoder's own time separately from the streaming time.

usage: jtag_decode.py [--mhz 95] [--chunk 256] [--djpeg PATH] file.jpg [...]
  --mhz    core clock of the build (fpga_jtag: 50 * 19 / 10 = 95 MHz)
  --djpeg  libjpeg 9e djpeg for the reference checksum (default: built by bench/tools.py, or
           $LIBJPEG9_DJPEG); the fast core's MCU-order output is bit-identical to
           `djpeg -dct int -nosmooth`.
Files of tb/malformed (make_malformed.py) are checked against tb/malformed/cases.json instead:
the frame must end (frames = 1) with the expected err bits, without pixels (checksum 0) where the
case says so; where libjpeg still produces an image (truncated files) the checksum is compared too.
Needs Quartus (quartus_stp on PATH) and the fpga_jtag bitstream loaded:
  quartus_pgm -m jtag -o "p;boards/ep2c5/fpga_jtag/output_files/jpeg_fpga_jtag.sof"
Decoder clocks are counted on the board: the decoder's clock only runs while its next input byte
is waiting, so the count equals the decode time with an ideal input (see boards/ep2c5/rtl/jtag_stream_core.sv).
"""
import os, sys, re, subprocess, tempfile
import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(REPO, "bench"))
from tools import ref_checksum, djpeg9      # libjpeg 9e reference (built on demand)

def sof_type(path):
    """n of the first SOFn marker (0 = baseline, the only type the decoder supports)"""
    d = open(path, "rb").read(); i = 2
    while i + 4 <= len(d) and d[i] == 0xFF:
        m = d[i + 1]
        if 0xC0 <= m <= 0xCF and m not in (0xC4, 0xC8, 0xCC): return m - 0xC0
        i += 2 + int.from_bytes(d[i + 2:i + 4], "big")
    return None

def main():
    args = sys.argv[1:]
    def opt(name, default):
        if name in args:
            i = args.index(name); v = args[i + 1]; del args[i:i + 2]; return v
        return default
    mhz = float(opt("--mhz", "95")); chunk = opt("--chunk", "256")
    djpeg = opt("--djpeg", None) or djpeg9()
    tcl = os.path.join(HERE, "jtag_stream.tcl")
    import json
    cases_f = os.path.join(REPO, "tb", "malformed", "cases.json")
    cases = json.load(open(cases_f)) if os.path.exists(cases_f) else {}
    for jpg in args:
        chk, w, h = ref_checksum(jpg, djpeg)
        exp = cases.get(os.path.basename(jpg)[:-4]) if os.path.dirname(os.path.abspath(jpg)).endswith(os.path.join("tb", "malformed")) else None
        r = subprocess.run(["quartus_stp", "-t", tcl, jpg, chunk], capture_output=True, text=True)
        m = re.search(r"RESULT frames=(\d+) clocks=(\d+) checksum=0x([0-9A-Fa-f]+) err=0x([0-9A-Fa-f]+) "
                      r"overflow=(\d) bytes=(\d+) wall_ms=(\d+)", r.stdout)
        if not m:
            print(f"{os.path.basename(jpg)}: no result\n{r.stdout[-800:]}{r.stderr[-400:]}"); continue
        frames, cyc, bchk, err, ovf, nbytes, wall = m.groups()
        cyc, nbytes, wall = int(cyc), int(nbytes), int(wall)
        if exp is not None:                                   # malformed / truncated file
            e = int(err, 16)
            ok = frames == "1" and ovf == "0" and (e & exp["err"]) == exp["err"] and (exp["pixels"] or int(bchk, 16) == 0)
            same = "" if chk is None else (", = libjpeg" if int(bchk, 16) == chk else ", != libjpeg")
            print(f"{os.path.basename(jpg)}: {nbytes} bytes | frames {frames}, decoder {cyc} clocks, err 0x{err} "
                  f"(expected bits 0x{exp['err']:04X}{'' if exp['pixels'] else ', no pixels'}), checksum 0x{bchk}{same}"
                  f" -> {'PASS' if ok else 'FAIL'}", flush=True)
            continue
        if sof_type(jpg) != 0:                                # not baseline (progressive, SOF1, ...)
            ok = frames == "1" and ovf == "0" and int(err, 16) & 1 and int(bchk, 16) == 0
            print(f"{os.path.basename(jpg)}: {nbytes} bytes, SOF{sof_type(jpg)} (not supported) | frames {frames}, "
                  f"decoder {cyc} clocks, err 0x{err} (expected ERR_SOF_TYPE, no pixels), checksum 0x{bchk} "
                  f"-> {'PASS' if ok else 'FAIL'}", flush=True)
            continue
        if chk is None:
            print(f"{os.path.basename(jpg)}: libjpeg cannot decode it; board: frames {frames}, err 0x{err}"); continue
        ok = int(bchk, 16) == chk and int(err, 16) == 0 and ovf == "0" and frames == "1"
        print(f"{os.path.basename(jpg)}: {w}x{h}, {nbytes} bytes | decoder {cyc} clocks = "
              f"{cyc / (w * h):.3f} clocks/pixel = {cyc / mhz / 1e3:.3f} ms at {mhz:g} MHz | "
              f"streaming {wall / 1e3:.1f} s ({nbytes / max(wall, 1):.1f} KB/s) | checksum 0x{bchk} "
              f"{'= reference' if int(bchk, 16) == chk else f'!= reference 0x{chk:08X}'}, err 0x{err}, "
              f"overflow {ovf} -> {'PASS' if ok else 'FAIL'}", flush=True)

if __name__ == "__main__":
    main()
