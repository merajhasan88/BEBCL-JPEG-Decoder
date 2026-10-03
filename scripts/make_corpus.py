#!/usr/bin/env python3
"""Generate the RTL test corpus (tb/corpus/*.jpg) from the project owner's own photos.

usage: make_corpus.py [SOURCE_DIR] [OUT_DIR]
  SOURCE_DIR  folder with the source photos (default: <project>/test_images)
  OUT_DIR     output folder (default: claude_jpeg/tb/corpus)
Needs ImageMagick (`convert`) and libjpeg-turbo's `cjpeg`.  The output is deterministic for the
same sources and tools.  Every file is listed with its source and settings in OUT_DIR/SOURCES.md.

Coverage: every chroma layout the decoder supports (grey, 4:4:4, 4:2:2, 4:4:0, 4:2:0, luma
subsampled relative to chroma, mixed 1x2/2x1 chroma), sizes from 1x1 to 1160 px wide including
sizes that are not multiples of the MCU, restart intervals (per MCU and per MCU row), optimised
and standard Huffman tables, an EXIF-style APP1 that embeds a complete JPEG plus a COM segment
containing FF D9, strips at the row-buffer limits of the raster builds, dense high-quality
images (Huffman codes longer than 8 bits), and two unsupported files (progressive, SOF1)."""
import os, sys, subprocess, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
SRC_DIR = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.join(ROOT, "test_images")
OUT_DIR = os.path.abspath(sys.argv[2]) if len(sys.argv) > 2 else os.path.join(HERE, "..", "tb", "corpus")

# source photos (the owner's own; screen photos and the USB-serial adapter)
SCREEN = ["IMG_20260912_000207.jpg", "IMG_20260912_003139.jpg", "IMG_20260912_004330.jpg",
          "IMG_20260912_004759.jpg", "IMG_20260912_005827.jpg", "IMG_20260912_012049.jpg",
          "IMG_20260912_012545.jpg"]
ADAPTER = "adapter.jpg"
ROM_MAX = 1024          # on-chip ROM of the board demo builds (ROM_ADDR_BITS = 10)

# (file name, source, geometry W x H, "fill" (scale to cover, centre crop) or "strip"
#  (scale to width W, centre band of height H), grey?, cjpeg options)
SPECS = [
    # tiny and small images (fill-crop keeps the aspect ratio of the source)
    ("scr_8x8_q10_gray",        SCREEN[0], 8, 8,   "fill", True,  "-quality 10"),
    ("adp_1x1_q50_420",         ADAPTER,   1, 1,   "fill", False, "-quality 50 -sample 2x2"),
    ("adp_3x5_q50_420",         ADAPTER,   3, 5,   "fill", False, "-quality 50 -sample 2x2"),
    ("adp_5x3_q50_420",         ADAPTER,   5, 3,   "fill", False, "-quality 50 -sample 2x2"),
    ("adp_4x6_q50_422",         ADAPTER,   4, 6,   "fill", False, "-quality 50 -sample 2x1"),
    ("scr_13x11_q40_gray",      SCREEN[1], 13, 11, "fill", True,  "-quality 40"),
    ("adp_16x16_q25_420",       ADAPTER,   16, 16, "fill", False, "-quality 25 -sample 2x2 -optimize"),
    ("adp_16x16_q25_gray",      ADAPTER,   16, 16, "fill", True,  "-quality 25 -optimize"),
    ("scr_17x33_q40_420",       SCREEN[2], 17, 33, "fill", False, "-quality 40 -sample 2x2"),
    ("adp_32x32_q25_420",       ADAPTER,   32, 32, "fill", False, "-quality 25 -sample 2x2 -optimize"),
    ("adp_32x32_q25_444",       ADAPTER,   32, 32, "fill", False, "-quality 25 -sample 1x1 -optimize"),
    ("adp_33x18_q40_440",       ADAPTER,   33, 18, "fill", False, "-quality 40 -sample 1x2"),
    ("adp_40x40_q40_lumasub",   ADAPTER,   40, 40, "fill", False, "-quality 40 -sample 1x1,2x2,2x2"),
    ("scr_48x40_q40_mixed",     SCREEN[3], 48, 40, "fill", False, "-quality 40 -sample 2x2,1x2,2x1"),
    ("adp_40x50_q30_420_rst3",  ADAPTER,   40, 50, "fill", False, "-quality 30 -sample 2x2 -restart 3B"),
    ("adp_45x37_q30_420_rst2",  ADAPTER,   45, 37, "fill", False, "-quality 30 -sample 2x2 -restart 2B"),
    ("adp_45x37_q30_422",       ADAPTER,   45, 37, "fill", False, "-quality 30 -sample 2x1"),
    ("adp_45x37_q30_440_rst1row", ADAPTER, 45, 37, "fill", False, "-quality 30 -sample 1x2 -restart 1"),
    ("adp_45x37_q30_gray_rst3", ADAPTER,   45, 37, "fill", True,  "-quality 30 -restart 3B"),
    ("adp_64x64_q25_420",       ADAPTER,   64, 64, "fill", False, "-quality 25 -sample 2x2 -optimize"),
    # strips at the row-buffer limits of the raster builds (9,216-byte EP2C5 buffer, 16 KB default)
    ("board_352x32_q6_420",     ADAPTER,   352, 32, "strip", False, "-quality 6 -sample 2x2"),
    ("wide_352x20_q20_420",     SCREEN[5], 352, 20, "strip", False, "-quality 20 -sample 2x2"),
    ("wide_368x20_q20_420",     SCREEN[5], 368, 20, "strip", False, "-quality 20 -sample 2x2"),
    ("wide_384x12_q20_444",     SCREEN[6], 384, 12, "strip", False, "-quality 20 -sample 1x1"),
    ("wide_576x10_q20_422",     SCREEN[0], 576, 10, "strip", False, "-quality 20 -sample 2x1"),
    ("wide_592x10_q20_422",     SCREEN[0], 592, 10, "strip", False, "-quality 20 -sample 2x1"),
    ("wide_1152x6_q20_gray",    SCREEN[1], 1152, 6, "strip", True,  "-quality 20"),
    ("wide_1160x6_q20_gray",    SCREEN[1], 1160, 6, "strip", True,  "-quality 20"),
    # dense, high-quality images: long Huffman codes (> 8 bits) and many coefficients per block
    ("scr_160x120_q95_444",     SCREEN[2], 160, 120, "fill", False, "-quality 95 -sample 1x1"),
    ("scr_320x240_q90_420",     SCREEN[3], 320, 240, "fill", False, "-quality 90 -sample 2x2"),
    ("adp_240x320_q95_422_rst4",ADAPTER,   240, 320, "fill", False, "-quality 95 -sample 2x1 -restart 4B"),
    ("scr_256x64_q98_gray",     SCREEN[6], 256, 64, "fill", True,  "-quality 98"),
]
# unsupported files: the decoder must end them with a non-zero error
UNSUPPORTED = [
    ("adp_45x37_q30_progressive_UNSUPPORTED", ADAPTER, 45, 37, "fill", False, "-quality 30 -progressive"),
    ("adp_40x40_q20_sof1_UNSUPPORTED",        ADAPTER, 40, 40, "fill", False, "-quality 20 -sample 2x2"),  # no -baseline: 16-bit DQT -> SOF1
]

def run(cmd):
    subprocess.run(cmd, check=True)

def raw_image(src, w, h, mode, grey, out):
    """Scaled source as PPM/PGM (no metadata)."""
    geo = ["-resize", f"{w}x{h}^", "-gravity", "center", "-extent", f"{w}x{h}"] if mode == "fill" else \
          ["-resize", f"{w}x", "-gravity", "center", "-crop", f"{w}x{h}+0+0", "+repage"]
    cs = ["-colorspace", "Gray"] if grey else []
    run(["convert", os.path.join(SRC_DIR, src), "-auto-orient", "-strip"] + geo + cs + [out])

def sof_type(path):
    d = open(path, "rb").read(); i = 2
    while i + 4 <= len(d) and d[i] == 0xFF:
        m = d[i + 1]
        if 0xC0 <= m <= 0xCF and m not in (0xC4, 0xC8, 0xCC): return m - 0xC0
        i += 2 + int.from_bytes(d[i + 2:i + 4], "big")
    return None

def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    rows = []
    with tempfile.TemporaryDirectory() as tmp:
        for name, src, w, h, mode, grey, opts in SPECS + UNSUPPORTED:
            raw = os.path.join(tmp, name + (".pgm" if grey else ".ppm"))
            raw_image(src, w, h, mode, grey, raw)
            out = os.path.join(OUT_DIR, name + ".jpg")
            base = [] if "sof1" in name else ["-baseline"]
            run(["cjpeg"] + base + (["-grayscale"] if grey else []) + opts.split() + ["-outfile", out, raw])
            want = 2 if "progressive" in name else 1 if "sof1" in name else 0
            got = sof_type(out)
            if got != want: sys.exit(f"{name}: SOF{got}, expected SOF{want}")
            rows.append((name, src, w, h, mode, grey, opts))
        # EXIF-style APP1 embedding a complete JPEG (the 8x8 image) plus a COM segment that
        # contains FF D9: a decoder that searches for markers instead of skipping segments by
        # their length stops early
        big = open(os.path.join(OUT_DIR, "adp_45x37_q30_422.jpg"), "rb").read()
        thumb = open(os.path.join(OUT_DIR, "scr_8x8_q10_gray.jpg"), "rb").read()
        payload = b"Exif\x00\x00" + b"II*\x00" + b"\x08\x00\x00\x00" + b"\x00\x00" + thumb
        app1 = b"\xff\xe1" + (len(payload) + 2).to_bytes(2, "big") + payload
        text = b"comment with ffd9 inside: \xff\xd9 !"
        com = b"\xff\xfe" + (len(text) + 2).to_bytes(2, "big") + text
        open(os.path.join(OUT_DIR, "adp_45x37_q30_422_exifthumb.jpg"), "wb").write(big[:2] + app1 + com + big[2:])
        rows.append(("adp_45x37_q30_422_exifthumb", ADAPTER, 45, 37, "fill", False,
                     "adp_45x37_q30_422 with an APP1 embedding scr_8x8_q10_gray and a COM containing FF D9"))
    for rom in ("adp_64x64_q25_420", "board_352x32_q6_420"):
        n = os.path.getsize(os.path.join(OUT_DIR, rom + ".jpg"))
        if n > ROM_MAX: sys.exit(f"{rom}: {n} bytes, does not fit the {ROM_MAX}-byte board ROM")
    with open(os.path.join(OUT_DIR, "SOURCES.md"), "w") as f:
        f.write("# Test corpus: origin of every file\n\nGenerated by `scripts/make_corpus.py` from the "
                "project owner's own photos (screen photos `IMG_20260912_*.jpg` and `adapter.jpg`) "
                "with ImageMagick and libjpeg-turbo `cjpeg`. Metadata is stripped.\n\n"
                "| file | source photo | size | scaling | settings |\n|---|---|---|---|---|\n")
        for name, src, w, h, mode, grey, opts in rows:
            desc = ("grey, " if grey else "") + ("" if "exifthumb" in name else ("-baseline " if "sof1" not in name else "")) + opts
            f.write(f"| {name}.jpg | {src} | {w}x{h} | {'centre crop' if mode == 'fill' else 'centre band'} | {desc} |\n")
    print(f"{len(rows)} files in {OUT_DIR}")

if __name__ == "__main__":
    main()
