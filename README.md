# claude_jpeg — a portable, synthesizable baseline JPEG decoder

A streaming JPEG decoder in the SystemVerilog-2005 subset that Quartus II 13.0sp1 accepts:
JPEG bytes in, pixels out, with no processor and no frame buffer. It is written for reuse
across FPGAs: no vendor primitives (RAMs and multipliers are inferred), and it synthesizes
unchanged for Intel/Altera (Quartus), Xilinx 7-series and Lattice ECP5 (Yosys).
Every build option is verified **bit for bit** against a reference decoder:

| profile (build options) | pixels identical to |
|---|---|
| default | libjpeg 9e `djpeg -dct int -nosmooth` |
| `RASTER_OUT=1 FANCY_UPSAMPLE=1 CC_TURBO=1` | **Pillow, OpenCV** and libjpeg-turbo `djpeg -dct int` (libjpeg-turbo 2.1 defaults) |

The first target is the owner's Cyclone II **EP2C5T144C8** (4,608 LEs, 26 M4K blocks, 13
multipliers, 2004 silicon), where even the largest configuration fits (see "EP2C5 builds").

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

## Interface (`rtl/jpeg_decoder.sv`)

| port | dir | meaning |
|---|---|---|
| `in_valid`, `in_data[7:0]`, `in_ready` | in | the JPEG file, one byte per accepted clock (files may follow back to back) |
| `in_last` | in | 1 on the last byte of a file (0 if unknown): a file cut short before its EOI still ends with `frame_done` and `ERR_TRUNC` |
| `out_fmt[1:0]` | in | `FMT_RGB` (0), `FMT_YCBCR` (1), `FMT_Y` (2); sampled when a frame starts |
| `px_valid`, `px_ready` | out/in | pixel handshake (AXI4-Stream style: a pixel moves when both are high) |
| `px_x`, `px_y` | out | pixel coordinates |
| `px_c0`, `px_c1`, `px_c2` | out | R,G,B / Y,Cb,Cr / Y,128,128 (grey images in RGB: Y,Y,Y) |
| `px_sof`, `px_eol` | out | first pixel of the frame (0,0) / last pixel of an image row (x = W-1) |
| `img_w`, `img_h`, `frame_start`, `frame_done` | out | frame size (valid from `frame_start`), end of frame |
| `err[12:0]` | out | errors of the current image (`jpeg_pkg.sv`): unsupported frame type, invalid/missing/incomplete tables or headers, corrupt data, truncated file, row buffer too small ... |

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
height - DNL is not supported), SOS (length, the frame's components in frame order as T.81 B.2.3 requires, defined tables),
and RSTn in sequence. With `in_last` on the last byte, a truncated file raises `ERR_TRUNC` and the
decoder completes the frame from zero bits - its pixels are not meant to be used (libjpeg fills
the rest of such a scan with uniform grey instead, so they differ); a file cut inside its headers
gives a frame without pixels. With `in_last` tied to 0 a truncated
file leaves the decoder waiting for more bytes: reset it to abort. A file without any scan (tables
only, or no SOI) produces no frame.

## Build options (parameters)

| parameter | default | effect |
|---|---|---|
| `FAST` | 0 | 0: compact core (~13.6 clocks/pixel, smallest). 1: pipelined core, **~1 clock/pixel** (Huffman lookahead tables, 2-lane pipelined IDCT, 1 pixel/clock output); same pixels, same interface, see FAST_STATUS.md |
| `RASTER_OUT` | 0 | 0: pixels in MCU order, 1 KB buffer, any width. 1: raster order via an MCU-row buffer |
| `ROWBUF_BYTES` | 16384 | row-buffer size for `RASTER_OUT=1`; images whose MCU row does not fit set `err[ERR_WIDTH]` and produce no pixels (the file is still consumed) |
| `FANCY_UPSAMPLE` | 0 | libjpeg-turbo's triangle-filter chroma upsampling (Pillow/OpenCV default) instead of replication; needs `RASTER_OUT=1` |
| `CC_TURBO` | 0 | YCbCr->RGB constants of libjpeg-turbo (`FIX(0.34414)`=22554) instead of libjpeg 9 (22553); differs for 59 of 65,536 (Cb,Cr) pairs |
| `RGB_OUT` | 1 | 0 removes the colour converter (~280 LEs) for YCbCr/luma consumers; `FMT_RGB` then delivers YCbCr |
| `ROWBUF_Y_BYTES`, `ROWBUF_C_BYTES` | 0 | `FAST=1` with `RASTER_OUT=1`: separate luma / chroma row buffers (0 = derived from `ROWBUF_BYTES`) |

Row-buffer bytes needed per 16 pixels of image width (`FMT_Y` stores luma only):

| sampling | replication | with `FANCY_UPSAMPLE` | `FMT_Y` |
|---|---:|---:|---:|
| grey | 128 | 128 | 128 |
| 4:2:2 | 256 | 256 | 128 |
| 4:2:0 | 384 | 416 | 256 |
| 4:4:4 | 384 | 384 | 128 |
| 4:4:0 | 512 | 560 | 256 |

## EP2C5 builds (Quartus II 13.0sp1, EP2C5T144C8, area optimisation)

Every build below includes the full header/table validation (`CHECKS=1`) and the 13-bit `err`
(numbers of 2026-10-01). The validation costs ~100 logic elements; they were recovered elsewhere
(the parser's counters and tables, the scan-component mapping, the board tops), so the tightest
builds (`fpga_raster`, `fpga_jtag`, `fpga_fast_bench`) are smaller than before it; `fpga_raster_ycc`
came out 91 LEs larger (still 154 LEs below the limit).

| build (`quartus/...`) | options | LEs | M4K | Fmax | row buffer / max width |
|---|---|---:|---:|---:|---|
| `fpga` | MCU order, replication, RGB (= djpeg 9e) | 3,374 (73 %) | 9 | 61.3 MHz | none needed / any |
| `fpga_raster_box` | raster, replication, RGB | 4,089 (89 %) | 25 | 64.6 MHz | 9,216 B / 4:2:0 384 px |
| `fpga_raster_ycc` | raster, Pillow smoothing, YCbCr only | 4,454 (97 %) | 25 | 59.6 MHz | 9,216 B / 4:2:0 352 px |
| `fpga_raster` | raster, Pillow smoothing, RGB (= Pillow) | 4,547 (99 %) | 25 | 59.6 MHz | 9,216 B / 4:2:0 352 px |

Fast core (`FAST=1`), MCU order, replication, RGB:

| build (`quartus/...`) | clock | LEs | memory | timing |
|---|---|---:|---:|---|
| `fpga_jtag` | **95 MHz from the PLL**; the JPEG is streamed in over the USB-Blaster (virtual JTAG), the decoder clock only runs while its next byte is waiting, so the on-chip clock count is the decode time without streaming time (`scripts/jtag_decode.py`) | 4,455 (97 %) | 59,712 bits | met at 95 MHz, +0.32 ns setup, +0.50 ns hold (Fmax 97.9 MHz); PowerPlay ~147 mW |
| `fpga_fast_bench` | **95 MHz from the PLL** (`PLL_MUL=19`, `PLL_DIV=10`), `BENCH=1` (decodes at full speed, reports the clock count over UART) | 4,368 (95 %) | 63,808 bits | met at 95 MHz, +0.13 ns (slow model, Fmax 96.2 MHz); PowerPlay ~151 mW |
| `fpga_fast` | 50 MHz, pixels over UART like `fpga` (the board demo) | 4,296 (93 %) | 63,808 bits | met at 50 MHz, +6.18 ns (Fmax 72.4 MHz) |

The fast raster core (`FAST=1 RASTER_OUT=1`) needs ~6,900 LEs: Cyclone IV E class
(`quartus/fpga_fast_raster`, EP4CE10), not the EP2C5.

All use 13/13 multipliers (26 9-bit elements); the compact builds meet timing at 50 MHz. Memory was never the
problem on the EP2C5; logic was. What made the largest build fit: the Huffman symbol table
folded into one M4K (valid tables need <= 12 DC + 162 AC entries), the coefficient buffer zeroed
during the IDCT's second pass instead of tracking a 64-bit "written" mask, the smoothing filter
reduced to one formula `(3*cs[i] + cs[neighbour] + bias) >> 4` shared by all sampling modes,
geometry derived by shifts, and Quartus's area optimisation. Each `quartus/fpga_raster*/` build
carries the golden checksum of its own profile for the board's self-check LED.

## Verification

- **Test corpus** (`tb/corpus/`, 35 files): generated by `scripts/make_corpus.py` from the project
  owner's own photos (provenance of every file in `tb/corpus/SOURCES.md`); it covers every chroma
  layout, sizes from 1x1 to 1160 px wide, restart intervals, an EXIF APP1 embedding a whole JPEG,
  strips at the row-buffer limits, dense q90-q98 images and two unsupported files.
- **References agree with each other first** (`scripts/compare_refs.py`): on all 33 supported corpus files
  the model in each profile is identical to Pillow, OpenCV, libjpeg-turbo `djpeg` (default,
  `-nosmooth`, `-grayscale`) and Pillow's YCbCr/luma draft modes; the model's filter is also
  cross-checked against a literal transcription of libjpeg-turbo's C loops.
- **RTL regression** (`tb/run_tests.py`, `make test`): 8 build configurations (5 compact, 3 `FAST=1`)
  x 3 output formats x 33 files x {no stalls, 30 % random input stalls + output back-pressure},
  plus the 2 unsupported files = **1,616 runs, all bit-exact, with no unexpected error bit**, with strict raster order and `sof`/`eol` checked, too-wide images raising
  `ERR_WIDTH` exactly where predicted, and unsupported files (progressive, SOF1 16-bit tables)
  terminating with errors. Edge cases covered: 1x1, 3x5, 5x3, 4x6 (the width <= 2 fallback of
  libjpeg-turbo), odd sizes, restart intervals, EXIF thumbnails, luma subsampled relative to
  chroma, mixed 1x2/2x1 chroma, widths at the row-buffer limit.
- **Several images through one decoder without reset** (`tb/run_stream_tests.py`, `tb/tb_multi.cpp`):
  restart interval then none, an unsupported SOF1 or progressive file then a valid one, four
  different layouts back to back, the same image twice - 8 configurations x 2 stall settings =
  **80 runs, all pass** (the restart interval and `err` are per image, an unusable image is
  consumed up to its EOI and ends with one `frame_done`).
- **Malformed and truncated files** (`tb/make_malformed.py`, `tb/run_malformed_tests.py`): 26
  files, each one edit away from a corpus file - missing, invalid-id, incomplete and zero-entry
  DQT; over-subscribed, all-ones, DC-symbol-12, incomplete and invalid-id DHT; zero width, zero
  height, wrong length, repeated Ci, invalid and undefined Tq in SOF; repeated or reordered Csj, wrong length,
  undefined table in SOS; RSTn out of order and without DRI; files cut in the headers, in the
  scan and before the EOI. Each must end with `frame_done`, the expected error bit and (header
  errors) no pixels: 26 x 8 configurations x 2 stall settings = **416 runs, all pass**; the same 26
  files also pass on the EP2C5 board over JTAG.
- **Full-size photos**: the owner's seven 12-megapixel phone photos (4000x3000 4:2:0), a
  3120x4160 4:2:2 and a 1944x2592 4:4:4 photo decode bit-identically to libjpeg 9e
  `djpeg -dct int -nosmooth` in simulation and on the EP2C5 (below).
- **Colour converter**: exhaustive over all 2^24 (Y,Cb,Cr) inputs for both constant sets.
- **Whole board design** (`tb/tb_fpga.cpp`): ROM -> decoder -> UART decoded back in the testbench,
  checksum LED on, for the MCU build and the raster + smoothing + RGB build.
- **Gate level**: the placed-and-routed netlists of `quartus/gls` (compact core, MCU order),
  `quartus/gls_raster` (raster + smoothing + RGB) and `quartus/gls_fast` (fast core) decode their
  test images bit-exactly (Verilator flow in `gls/`, with this project's own models of the
  Cyclone II cells, `gls/verilator/cycloneii_cells.v`); see `gls/README.md`.
- **On the EP2C5 board** (`quartus/fpga_jtag`, JPEG streamed over the USB-Blaster, decoder clock
  gated so that the on-chip clock count excludes streaming time; `scripts/jtag_decode.py`): every
  image decodes with the checksum of libjpeg's decode and exactly the simulated clock count, e.g.
  donald.jpg 2,847,577 clocks = 29.97 ms at 95 MHz.
- **Portability**: `sv2v` + Yosys synthesize the compact raster + smoothing configuration and the
  `FAST=1` raster + smoothing configuration for Xilinx 7-series and Lattice ECP5 without errors,
  and the `FAST=1` MCU-order core for Xilinx 7-series.

## Performance

Fast core (`FAST=1`, MCU order) on the EP2C5 at 95 MHz, clocks counted on the board
(`quartus/fpga_jtag`; each count equals the cycle-exact simulation, each checksum equals libjpeg's):

| image | clocks / pixel | decode time at 95 MHz |
|---|---:|---:|
| donald.jpg, 2048x1365 4:2:0, 247 KB | **1.02** | **29.97 ms** (93 Mpixel/s) |
| 1944x2592 4:4:4 photo, 520 KB | 1.67 | 88 ms |
| 3120x4160 4:2:2 photo, 3.4 MB | 1.48 | 202 ms |
| 4000x3000 4:2:0 phone photos, 3.7-5.9 MB (7 files) | 1.61-2.25 | 203-284 ms |

The output side delivers one pixel per clock; images with dense entropy-coded data (high quality,
fine detail) are limited by the Huffman decoder (3 clocks per coded coefficient), hence the
1.6-2.3 clocks/pixel of the 12-megapixel phone photos. The compact core (`FAST=0`) needs 13.5
clocks/pixel on donald.jpg (752 ms at 50 MHz) and up to 21 on 4:4:4 images.

**Against CPU decoders, one laptop core at full clock is faster.** The comparison uses one core of
the owner's i7-8550U, in the performance power profile at ~3.9 GHz. On donald.jpg libjpeg-turbo
takes 6.9 ms, Pillow 7.9 ms, libjpeg 9e and stb_image ~14 ms, OpenCV 16 ms and FFmpeg (with RGB
output) 20 ms, all faster than the EP2C5's 30 ms. libjpeg-turbo is 3-6x faster than the EP2C5 on
every benchmark image.

The FPGA does ~10x more work per clock: 1.0-2.25 clocks/pixel against 8-22 CPU clocks/pixel for
libjpeg-turbo with AVX2. By estimate it also uses 15-28x less energy per image. But the laptop's
clock is 40x higher. At the laptop's power-saver clock (~1 GHz) the two are close: libjpeg-turbo
is 3-47 % faster on the larger images and takes 21 % longer on the 64x64 image.

Earlier versions of this README said the EP2C5 beats libjpeg-turbo. That was wrong: those CPU
numbers had been measured, unnoticed, with the laptop in its power-saver profile.

The FPGA time is the decoder alone. Getting the file in and the pixels out is a separate budget;
over JTAG the board receives ~35 KB/s.

**Against other FPGA JPEG decoders** (ultraembedded core_jpeg, Ishihara's aq_djpeg), this is the
only one of the three that fits the EP2C5; the others need 7.0k-9.5k LEs. On the larger EP2C35 it
has the highest Fmax and the fewest clocks per pixel on every image, and it is the only one that is
bit-exact. donald.jpg takes 30 ms here against 66 ms and 148 ms. All numbers:
**[BENCHMARKS.md](BENCHMARKS.md)**.

## What is supported

Baseline sequential DCT (SOF0), 8-bit samples, Huffman coding, 1 or 3 components, sampling
factors 1 or 2 in each direction (4:4:4, 4:2:2, 4:4:0, 4:2:0, and luma-subsampled layouts), one
interleaved scan (components in frame order, T.81 B.2.3), restart intervals (DRI/RSTn), any number of APPn/COM segments (EXIF thumbnails
are skipped correctly), several tables per DQT/DHT segment, image sizes up to 65535x65535 (MCU
order; raster order up to the row-buffer width). Not supported, flagged in `err`, and the scan is
skipped to its EOI: progressive, lossless, arithmetic coding, 12-bit, 16-bit quantisation tables,
non-interleaved multi-scan files, sampling factors 3/4. Adobe-RGB (no colour transform) files are
decoded as YCbCr. Dequantised coefficients and the IDCT workspace are 16-bit (saturating); real
images from 8-bit sources stay far inside that, so all test files match exactly.

## Directory layout

| path | what |
|------|------|
| `rtl/jpeg_decoder.sv` | top: build options, MCU/block sequencing (A.2.3), row-buffer layout, error handling |
| `rtl/jpeg_parser.sv` | markers (Annex B): DQT, DHT (Annex C tables built on the fly), SOF0, DRI, SOS; skips APPn/COM; FF00 un-stuffing |
| `rtl/jpeg_bitreader.sv` | token FIFO -> MSB-first bit stream, RSTn handling (F.2.2.5), end-of-scan detection |
| `rtl/jpeg_coefdec.sv` | one 8x8 block: DECODE (F.2.2.3), DC/AC (F.2.2.1/2), dequantisation, zig-zag |
| `rtl/jpeg_blockram.sv`, `rtl/jpeg_sdp_ram.sv` | inferred RAMs; the coefficient buffer zeroes itself during IDCT pass 2 |
| `rtl/jpeg_idct.sv` | 2-pass 8x8 IDCT, exact port of `jpeg_idct_islow`, 12 multipliers, 2-stage pipeline |
| `rtl/jpeg_pixgen.sv` | MCU-order output stage |
| `rtl/jpeg_raster.sv` | raster-order output stage, row/line-buffer protocol, libjpeg-turbo filter |
| `rtl/jpeg_ycc2rgb.sv` | libjpeg `ycc_rgb_convert` arithmetic, both constant sets |
| `rtl/fpga_top.sv`, `rtl/jpeg_rom.sv`, `rtl/uart_tx.sv` | board demo: ROM -> decoder -> UART, checksum LED, watchdog; `BENCH=1` clock-count report, `PLL_MUL`/`PLL_DIV` core clock |
| `rtl/jpeg_dec_small.sv` | the compact core (`FAST=0`); `rtl/jpeg_decoder.sv` is the wrapper selecting the core |
| `rtl/jpeg_dec_fast.sv`, `rtl/jpeg_bitwin.sv`, `rtl/jpeg_huffdec.sv`, `rtl/jpeg_idct_fast.sv`, `rtl/jpeg_mcuout.sv`, `rtl/jpeg_raster_fast.sv` | the fast core (`FAST=1`): sequencing, bit accumulator, lookahead Huffman + coefficient pipeline, 2-lane pipelined IDCT, 1 pixel/clock output stages (details in FAST_STATUS.md) |
| `rtl/jtag_stream_core.sv`, `rtl/fpga_jtag_top.sv` | board harness: JPEG in over a virtual-JTAG instance, input FIFO, decoder clock gated so its clock count excludes streaming time, checksum; the top holds the Intel/Altera parts (PLL, clock buffer, virtual JTAG) |
| `model/jpeg_golden.py` | bit-exact reference: `--profile djpeg9|pillow`, `--out rgb|ycbcr|y`, block dumps |
| `scripts/compare_refs.py` | model vs Pillow / OpenCV / libjpeg-turbo in every mode |
| `scripts/make_corpus.py` | generates the test corpus from the owner's photos |
| `scripts/jtag_decode.py`, `scripts/jtag_stream.tcl` | host side of `fpga_jtag`: stream a JPEG, read decoder clocks, checksum, errors |
| `tb/` | Verilator testbenches, `Makefile` (8 configurations), `run_tests.py` regression, `run_stream_tests.py` + `tb_multi.cpp` (images back to back), `tb_jtag.cpp` + `jtag_sim_top.sv` (JTAG harness), `run_board_sim.sh`, `corpus/` |
| `quartus/` | `fpga` (MCU), `fpga_raster*` (3 raster variants), `gls`/`gls_raster` (fast-UART twins), `core`; fast core: `fpga_jtag` (95 MHz, JPEG over JTAG), `fpga_fast_bench` (95 MHz, ROM), `fpga_fast`, `fpga_fast_raster` (Cyclone IV), `gls_fast`; `sta_paths.tcl` |
| `FAST_STATUS.md` | the fast core: design, timing closure history, verification, open items |
| `gls/` | gate-level simulation flows (Verilator with this project's Cyclone II cell models, Icarus + SDF, ModelSim-ASE) |
| `bench/` | benchmark harness; results in `BENCHMARKS.md`; `bench/others/` compares other FPGA JPEG decoders (their sources are fetched, not included) |
| `LICENSE`, `NOTICE.md` | Apache License 2.0; copyright, credits (Independent JPEG Group / libjpeg-turbo arithmetic), tools, test-image provenance |

## Build, test, program

```sh
cd claude_jpeg/tb && make && make test          # 8 configurations: 1,616 runs + 80 multi-image runs
python3 ../scripts/make_corpus.py               # regenerate tb/corpus from the owner's photos
python3 ../scripts/compare_refs.py corpus/*.jpg  # model vs Pillow/OpenCV/djpeg
python3 ../model/jpeg_golden.py in.jpg out.pnm --profile pillow --out ycbcr

export PATH=/root/altera/13.0sp1/quartus/bin:$PATH
cd ../quartus/fpga_jtag && quartus_sh --flow compile jpeg_fpga_jtag           # fast core, 95 MHz
quartus_pgm -m jtag -o "p;output_files/jpeg_fpga_jtag.sof"                    # USB-Blaster
cd ../.. && python3 scripts/jtag_decode.py photo.jpg   # stream it, read decoder clocks + checksum
cd quartus/fpga_raster && quartus_sh --flow compile jpeg_fpga_raster          # compact raster demo
```
A different ROM image: `scripts/jpeg_to_hex.py img.jpg jpeg_rom.hex 1024`, then set `ROM_LENGTH`
and `EXPECTED_CHK` (from `scripts/pnm_checksum.py golden.pnm`, **in decimal**: Quartus 13 turns a
Verilog literal in `set_parameter` into a string without warning) in the `.qsf`.

**Pins** (from the owner's 2022 projects): `clk` PIN_17 (50 MHz), `key_n` PIN_144 (reset button),
`led_n[0..2]` PIN_3/7/9 (toggles with every frame / checksum OK / error), `uart_tx` PIN_41 (3.3 V -> RXD of a
USB-serial adapter). Serial: `A5 5A 'J' 'P' 'G' W H`, then `X Y C0 C1 C2` per pixel, then `'E'
'N' 'D'`, repeated every 1.5 s; `scripts/uart_capture.py /dev/ttyUSB0 out.ppm` saves a frame.
The checksum LED alone proves the decode on the board; the UART only shows the picture.

## License

Copyright 2026 Meraj Hasan. Licensed under the Apache License, Version 2.0 (`LICENSE`); see
`NOTICE.md` for the credits that must travel with the code, including the Independent JPEG Group
credit for the IDCT, colour-conversion and upsampling arithmetic.
