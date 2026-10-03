#!/usr/bin/env python3
"""Decode JPEG files on the EP2C5 through the USB-Blaster (quartus/fpga_jtag, rtl/fpga_jtag_top.sv)
and report the decoder's own time separately from the streaming time.

usage: jtag_decode.py [--mhz 95] [--chunk 256] [--djpeg PATH] file.jpg [...]
  --mhz    core clock of the build (fpga_jtag: 50 * 19 / 10 = 95 MHz)
  --djpeg  libjpeg 9e djpeg for the reference checksum (default: $BENCH_SCRATCH/jpeg9e/inst/bin/djpeg,
           as built by bench/run_bench.py); the fast core's MCU-order output is bit-identical to
           `djpeg -dct int -nosmooth`.
Files of tb/malformed (make_malformed.py) are checked against tb/malformed/cases.json instead:
the frame must end (frames = 1) with the expected err bits, without pixels (checksum 0) where the
case says so; where libjpeg still produces an image (truncated files) the checksum is compared too.
Needs Quartus (quartus_stp on PATH) and the fpga_jtag bitstream loaded:
  quartus_pgm -m jtag -o "p;quartus/fpga_jtag/output_files/jpeg_fpga_jtag.sof"
Decoder clocks are counted on the board: the decoder's clock only runs while its next input byte
is waiting, so the count equals the decode time with an ideal input (see rtl/jtag_stream_core.sv).
"""
import os, sys, re, subprocess, tempfile
import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))

def ref_checksum(jpg, djpeg):
    """Board checksum of the reference decode: sum of {x^y, R, G, B} over all pixels, mod 2^32.
    (None, 0, 0) when libjpeg rejects the file; a file with only warnings (truncated) still counts."""
    with tempfile.TemporaryDirectory() as t:
        out = os.path.join(t, "ref.pnm")
        subprocess.run([djpeg, "-dct", "int", "-nosmooth", "-pnm", "-outfile", out, jpg], capture_output=True)
        try:
            im = Image.open(out)
            a = np.asarray(im.convert("RGB")).astype(np.uint64)
        except Exception:
            return None, 0, 0
    h, w, _ = a.shape
    y, x = np.mgrid[0:h, 0:w]
    xy = ((x ^ y) & 0xFF).astype(np.uint64)
    words = (xy << 24) | (a[:, :, 0] << 16) | (a[:, :, 1] << 8) | a[:, :, 2]
    return int(words.sum()) & 0xFFFFFFFF, w, h

def main():
    args = sys.argv[1:]
    def opt(name, default):
        if name in args:
            i = args.index(name); v = args[i + 1]; del args[i:i + 2]; return v
        return default
    mhz = float(opt("--mhz", "95")); chunk = opt("--chunk", "256")
    djpeg = opt("--djpeg", os.path.join(os.environ.get("BENCH_SCRATCH", "/tmp/claude_bench"), "jpeg9e/inst/bin/djpeg"))
    tcl = os.path.join(HERE, "jtag_stream.tcl")
    import json
    cases_f = os.path.join(HERE, "..", "tb", "malformed", "cases.json")
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
