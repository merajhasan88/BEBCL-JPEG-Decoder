# Pasha — a synthesizable baseline JPEG decoder in SystemVerilog

Pasha is a streaming JPEG decoder for FPGAs: JPEG bytes in, pixels out, with no processor and no
frame buffer. It decodes baseline JPEG (ITU-T T.81 sequential DCT, Huffman coding, 8-bit samples),
which is what cameras, phones and almost all software write. It is plain SystemVerilog with no
vendor primitives (RAMs and multipliers are inferred), and it has run on an Intel/Altera
Cyclone II and a Xilinx Artix-7 board; Yosys also synthesizes it for Lattice ECP5.

Every build option is verified **bit for bit** against a reference decoder:

| profile (build options) | pixels identical to |
|---|---|
| default | libjpeg 9e `djpeg -dct int -nosmooth` |
| `RASTER_OUT=1 FANCY_UPSAMPLE=1 CC_TURBO=1` | **Pillow, OpenCV** and libjpeg-turbo `djpeg -dct int` (libjpeg-turbo 2.1 defaults) |

Two cores share one interface: a compact core (`FAST=0`, ~13.6 clocks per pixel, the smallest)
and a pipelined core (`FAST=1`, **1.0-2.4 clocks per pixel**).

| measured on a board | core | clock | resources | 12-megapixel photo |
|---|---|---:|---|---:|
| Intel/Altera Cyclone II EP2C5T144C8 (2004, 4,608 LEs) | `FAST=1` | 95 MHz | 4,449 LEs (97 %), 26/26 multipliers | 202-284 ms |
| Xilinx Artix-7 XC7A200T (Acorn CLE-215+, remote board at fpgas.online) | `FAST=1` | 150 MHz | 2,488 LUTs, 17 DSP48E1, 7.5 BRAM | 87-154 ms |

Against the two other open-source FPGA JPEG decoders that could be measured (ultraembedded
core_jpeg, H. Ishihara's aq_djpeg), Pasha is the only one that is bit-exact, the only one that fits
the EP2C5, and on the same Artix-7 board it needs 1.4-1.95x fewer clocks per photo than aq_djpeg
and decodes 4:2:2 photos that core_jpeg cannot. All numbers: **[BENCHMARKS.md](BENCHMARKS.md)**,
`boards/acorn_cle215/README.md`.

## Quick start: decode your own images

Needs Verilator (5.x), make, a C++ compiler and Python 3; Pillow is optional (PNG output, `--check`).

```sh
git clone <this repository> pasha && cd pasha
cp ~/photos/*.jpg test_images/          # any baseline JPEGs (adapter.jpg is already there)
python3 scripts/decode.py               # decodes every file in test_images/ -> out/*.ppm (+ .png)
python3 scripts/decode.py --profile pillow --check test_images/adapter.jpg   # compare with Pillow
```

`decode.py` builds the cycle-exact simulation of the decoder on first use (in `tb/`), decodes each
file, writes the image and prints the decode time in clocks:

```
file                                    size    type       clocks  clk/px  ms@100MHz  result
adapter.jpg                        3120x4160   4:2:2   19,234,181   1.482     192.34  ok
```

Options: `--profile libjpeg|pillow` (which reference the pixels match), `--core fast|small`,
`--fmt rgb|ycbcr|y`, `--mhz F` (report times at your clock), `--out DIR`. A file the decoder
does not support (progressive, 12-bit, arithmetic coding ...) is reported with its error bits.

## Using Pasha in your FPGA design

Add the files of `rtl/` to your project (Quartus, Vivado, Yosys, ...), instantiate
`jpeg_decoder` and set the parameters below. `boards/` has complete examples:
`boards/ep2c5/` (Quartus II 13.0sp1, Cyclone II: ROM demo with UART output, a 95 MHz build that
streams JPEGs over the USB-Blaster) and `boards/acorn_cle215/` (Vivado, Artix-7: files over a
UART, with the decoder's clock counted on the chip).

```
bytes in ─► jpeg_parser ─► table RAMs (DQT, Huffman MAXCODE/VALPTR, HUFFVAL)
               │
               └─ un-stuffed entropy bytes + marker tokens
                        ▼
                  jpeg_bitreader ─► jpeg_coefdec ─► jpeg_blockram (64x16 coefficients)
                  (1 bit / clock)   (Huffman, RECEIVE/EXTEND,          │
                                     DC prediction, xQk, zig-zag)      ▼
                                                              jpeg_idct (libjpeg islow, bit-exact)
                                                                       │
              RASTER_OUT = 0 ──────────────────────────────────────────┼─────────────── RASTER_OUT = 1
              MCU buffer (1 KB) ◄──────────────────────────────────────┴──► MCU-row buffer (ROWBUF_BYTES)
              jpeg_pixgen: replication, YCbCr->RGB                           jpeg_raster: replication or libjpeg-turbo
              pixels in MCU order (8x8 / 16x16 tiles)                        triangle filter, YCbCr->RGB; pixels row by row
                                                                       ▼
                     pixels out: (x, y, c0, c1, c2, sof, eol) with a valid/ready handshake
```
(the compact core; the `FAST=1` core has the same structure with a 32-bit bit window, lookahead
Huffman tables, a 2-lane pipelined IDCT and 1-pixel-per-clock output stages.)

### Interface (`rtl/jpeg_decoder.sv`)

| port | dir | meaning |
|---|---|---|
| `clk`, `rst` | in | one clock; synchronous active-high reset |
| `in_valid`, `in_data[7:0]`, `in_ready` | in | the JPEG file, one byte per accepted clock (files may follow back to back) |
| `in_last` | in | 1 on the last byte of a file (0 if unknown): a file cut short before its EOI still ends with `frame_done` and `ERR_TRUNC` |
| `out_fmt[1:0]` | in | `FMT_RGB` (0), `FMT_YCBCR` (1), `FMT_Y` (2); sampled when a frame starts |
| `px_valid`, `px_ready` | out/in | pixel handshake (AXI4-Stream style: a pixel moves when both are high) |
| `px_x`, `px_y` | out | pixel coordinates |
| `px_c0`, `px_c1`, `px_c2` | out | R,G,B / Y,Cb,Cr / Y,128,128 (grey images in RGB: Y,Y,Y) |
| `px_sof`, `px_eol` | out | first pixel of the frame (0,0) / last pixel of an image row (x = W-1) |
| `img_w`, `img_h`, `frame_start`, `frame_done` | out | frame size (valid from `frame_start`), end of frame |
| `err[12:0]` | out | errors of the current image (`rtl/jpeg_pkg.sv`): unsupported frame type, invalid/missing/incomplete tables or headers, corrupt data, truncated file, row buffer too small ... |

`FMT_YCBCR` hands out the upsampled Y, Cb, Cr without colour conversion; `FMT_Y` hands out luma
only, and chroma blocks are then only entropy-decoded (to keep the bitstream in step) but never
transformed, which makes decoding ~30 % faster. With `RASTER_OUT=1` pixels arrive in strict
raster order, so `px_sof`/`px_eol` map directly onto AXI4-Stream video `tuser`/`tlast`.

**Completion contract.** Every image that reaches its scan (SOS) produces exactly one
`frame_start` and one `frame_done`, also when it is unusable. Read `err` at `frame_done`: it
holds that image's errors (it is cleared when the next image's SOI is accepted; the input is held
at that SOI until the previous frame is done). If `err` is not zero, discard the frame's pixels.
An image with a header or table error produces no pixels at all. The parser only uses a table
that was read completely and legally, and only one that the image or an earlier one defined:
DQT (Pq = 0, Tq <= 3, no zero Qk), DHT (Tc/Th <= 1, a code tree that is not over-subscribed and
has no all-ones code, DC symbols <= 11), SOF0 (length, distinct Ci, Tq <= 3, non-zero width and
height - DNL is not supported), SOS (length, the frame's components in frame order as T.81 B.2.3
requires, defined tables), and RSTn in sequence. With `in_last` on the last byte, a truncated file
raises `ERR_TRUNC` and the decoder completes the frame from zero bits - its pixels are not meant to
be used (libjpeg fills the rest of such a scan with uniform grey instead, so they differ); a file
cut inside its headers gives a frame without pixels. With `in_last` tied to 0 a truncated file
leaves the decoder waiting for more bytes: reset it to abort. A file without any scan (tables
only, or no SOI) produces no frame.

### Parameters

| parameter | default | effect |
|---|---|---|
| `FAST` | 0 | 0: compact core (~13.6 clocks/pixel, smallest). 1: pipelined core, **~1-2.4 clocks/pixel** (Huffman lookahead tables, 2-lane pipelined IDCT, 1 pixel/clock output); same pixels, same interface |
| `RASTER_OUT` | 0 | 0: pixels in MCU order, 1 KB buffer, any width. 1: raster order via an MCU-row buffer |
| `ROWBUF_BYTES` | 16384 | row-buffer size for `RASTER_OUT=1`; images whose MCU row does not fit set `err[ERR_WIDTH]` and produce no pixels (the file is still consumed) |
| `FANCY_UPSAMPLE` | 0 | libjpeg-turbo's triangle-filter chroma upsampling (Pillow/OpenCV default) instead of replication; needs `RASTER_OUT=1` |
| `CC_TURBO` | 0 | YCbCr->RGB constants of libjpeg-turbo (`FIX(0.34414)`=22554) instead of libjpeg 9 (22553); differs for 59 of 65,536 (Cb,Cr) pairs |
| `RGB_OUT` | 1 | 0 removes the colour converter (~280 LEs) for YCbCr/luma consumers; `FMT_RGB` then delivers YCbCr |
| `CHECKS` | 1 | header and table validation (above); 0 saves ~100 LEs on a device where every LE counts |
| `ROWBUF_Y_BYTES`, `ROWBUF_C_BYTES` | 0 | `FAST=1` with `RASTER_OUT=1`: separate luma / chroma row buffers (0 = derived from `ROWBUF_BYTES`) |

Row-buffer bytes needed per 16 pixels of image width (`FMT_Y` stores luma only):

| sampling | replication | with `FANCY_UPSAMPLE` | `FMT_Y` |
|---|---:|---:|---:|
| grey | 128 | 128 | 128 |
| 4:2:2 | 256 | 256 | 128 |
| 4:2:0 | 384 | 416 | 256 |
| 4:4:4 | 384 | 384 | 128 |
| 4:4:0 | 512 | 560 | 256 |

Tool notes: the RTL is the SystemVerilog-2005 subset that Quartus II 13.0sp1 accepts (the oldest
tool it targets), so newer tools take it unchanged. RAMs are written to infer block RAM
(`rtl/jpeg_sdp_ram.sv`); `(* ramstyle = "M4K" *)` and `(* multstyle = "dsp" *)` are Quartus hints
that other tools ignore.

### Resources

| device, tool | build | logic | memory | multipliers | Fmax |
|---|---|---:|---:|---:|---:|
| Cyclone II EP2C5, Quartus 13.0sp1 | compact, MCU order (`boards/ep2c5/fpga`) | 3,374 LEs | 9 M4K | 26 9-bit | 61 MHz |
| Cyclone II EP2C5, Quartus 13.0sp1 | compact, raster + Pillow smoothing + RGB (`fpga_raster`) | 4,547 LEs | 25 M4K | 26 9-bit | 60 MHz |
| Cyclone II EP2C5, Quartus 13.0sp1 | fast, MCU order (`fpga_jtag`, board harness included) | 4,449 LEs | 59,712 bits | 26 9-bit | 99.0 MHz |
| Artix-7 XC7A200T-2, Vivado 2026.1 | fast, MCU order, decoder alone (from the build below) | 2,204 LUTs, 2,124 FFs | 13 BRAM18 | 17 DSP48E1 | - |
| Artix-7 XC7A200T-2, Vivado 2026.1 | fast, MCU order (`boards/acorn_cle215`, UART harness included) | 2,488 LUTs, 2,671 FFs | 7.5 BRAM36 | 17 DSP48E1 | 157-160 MHz |

The fast raster core (`FAST=1 RASTER_OUT=1`) needs ~6,900 LEs on a Cyclone IV E (EP4CE10).
More EP2C5 builds and their timing: `boards/ep2c5/README.md`.

## What is supported

Baseline sequential DCT (SOF0), 8-bit samples, Huffman coding, 1 or 3 components, sampling
factors 1 or 2 in each direction (4:4:4, 4:2:2, 4:4:0, 4:2:0, and luma-subsampled layouts), one
interleaved scan (components in frame order, T.81 B.2.3), restart intervals (DRI/RSTn), any
number of APPn/COM segments (EXIF thumbnails are skipped correctly), several tables per DQT/DHT
segment, image sizes up to 65535x65535 (MCU order; raster order up to the row-buffer width).
Not supported, flagged in `err`, and the scan is skipped to its EOI: progressive, lossless,
arithmetic coding, 12-bit samples, 16-bit quantisation tables, non-interleaved multi-scan files,
sampling factors 3/4, 4-component (CMYK) files. Adobe-RGB (no colour transform) files are decoded
as YCbCr. Dequantised coefficients and the IDCT workspace are 16-bit (saturating); real images
from 8-bit sources stay far inside that, so all test files match exactly.

## Verification

```sh
cd tb && make && make test            # 8 configurations: 1,616 runs + 80 multi-image + 416 malformed runs
python3 ../scripts/compare_refs.py corpus/*.jpg   # the model against Pillow / OpenCV / libjpeg-turbo
```

- **Test files** (`tb/corpus/`, 35 files): generated by `scripts/make_corpus.py` from one photo,
  `test_images/adapter.jpg` (settings of every file in `tb/corpus/SOURCES.md`): every chroma
  layout, sizes from 1x1 to 1160 px wide, restart intervals, an EXIF APP1 embedding a whole JPEG,
  strips at the row-buffer limits, dense q90-q98 images with Huffman codes up to 16 bits, and two
  unsupported files.
- **Reference model** (`model/jpeg_golden.py`): a bit-exact Python decoder in both profiles; on
  every corpus file it is identical to Pillow, OpenCV and libjpeg-turbo `djpeg` (default,
  `-nosmooth`, `-grayscale`) and to Pillow's YCbCr/luma draft modes (`scripts/compare_refs.py`).
- **RTL regression** (`tb/run_tests.py`): 8 build configurations (5 compact, 3 `FAST=1`) x 3
  output formats x 33 files x {no stalls, 30 % random input stalls + output back-pressure}, plus
  the 2 unsupported files = **1,616 runs, all bit-exact, with no unexpected error bit**, with
  strict raster order and `sof`/`eol` checked and `ERR_WIDTH` raised exactly where predicted.
- **Images back to back without reset** (`tb/run_stream_tests.py`): 80 runs.
- **Malformed and truncated files** (`tb/make_malformed.py`, `tb/run_malformed_tests.py`): 26
  files, each one edit away from a corpus file (bad, missing or incomplete DQT/DHT/SOF/SOS, RSTn
  errors, files cut in the headers, in the scan and before the EOI) x 8 configurations x 2 stall
  settings = **416 runs**: each must end with `frame_done`, the expected error bit and, for header
  errors, no pixels.
- **Colour converter**: exhaustive over all 2^24 (Y,Cb,Cr) inputs for both constant sets.
- **On hardware**: on the EP2C5 every test photo decodes with libjpeg's checksum and exactly the
  simulated clock count (`boards/ep2c5/fpga_jtag`); on the Artix-7 (fpgas.online) the owner's 12
  phone photos and 4:2:0 re-encodes of them decode identically to libjpeg 9e
  (`boards/acorn_cle215`).
- **Portability**: `sv2v` + Yosys synthesize the compact and the fast raster + smoothing
  configurations for Xilinx 7-series and Lattice ECP5 and the fast MCU-order core for Xilinx
  7-series without errors; Verilator lint is clean with implicit-net warnings enabled.

## Repository layout

| path | what |
|------|------|
| `rtl/` | the decoder (vendor-neutral): `jpeg_decoder.sv` (top, selects the core), `jpeg_dec_small.sv` (compact core), `jpeg_dec_fast.sv` + `jpeg_bitwin.sv`, `jpeg_huffdec.sv`, `jpeg_idct_fast.sv`, `jpeg_mcuout.sv`, `jpeg_raster_fast.sv` (fast core), `jpeg_parser.sv` (Annex B markers, Annex C tables), `jpeg_bitreader.sv`, `jpeg_coefdec.sv` (F.2.2 decoding), `jpeg_idct.sv` (libjpeg islow), `jpeg_pixgen.sv`, `jpeg_raster.sv` (output stages), `jpeg_ycc2rgb.sv`, `jpeg_blockram.sv`, `jpeg_sdp_ram.sv`, `jpeg_pkg.sv` |
| `test_images/` | your JPEGs; `adapter.jpg` is the photo the test files are made from |
| `scripts/` | `decode.py` (decode your images), `make_corpus.py`, `compare_refs.py`, `jpeg_to_hex.py`, `pnm_checksum.py` |
| `model/jpeg_golden.py` | bit-exact reference decoder: `--profile djpeg9|pillow`, `--out rgb|ycbcr|y`, block dumps |
| `tb/` | Verilator testbench (`tb_jpeg.cpp`, `tb_multi.cpp`), `Makefile`, regression scripts, `corpus/`, `malformed/` |
| `boards/ep2c5/` | Intel/Altera Cyclone II EP2C5 board: tops (`rtl/`), Quartus projects, programming and host scripts, board-level simulations |
| `boards/acorn_cle215/` | Xilinx Artix-7 (Acorn CLE-215+): Vivado build, UART measurement harness, host script, results |
| `bench/` | benchmarks against CPU decoders and other FPGA decoders; results in `BENCHMARKS.md` |
| `LICENSE`, `NOTICE.md` | Apache License 2.0; copyright and the credits that travel with the code |

## License

Copyright 2026 Meraj Hasan. Licensed under the Apache License, Version 2.0 (`LICENSE`); see
`NOTICE.md` for the credits that must travel with the code, including the Independent JPEG Group
credit for the IDCT, colour-conversion and upsampling arithmetic.
