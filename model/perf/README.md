# Performance model

Predicts the decoder's clock count for any baseline JPEG in about a second, without simulating
the RTL, and explores faster variants of the core before they are built.

- `blockstats.c` decodes the Huffman-coded data of a file (T.81 F.2.2, no IDCT) and writes one
  record per block: Huffman symbols, codes longer than 8 bits by length, non-zero coefficients,
  bits, and the file offset where the block ends.
- `perf_model.py` replays those records through a clock-level model of the fast core's pipeline
  (Huffman decoder, coefficient slots and their zeroer, IDCT pass 1 and pass 2 on the IDCT's
  4-clock period, workspace, MCU buffers, output), following the handshakes of
  `rtl/jpeg_dec_fast.sv`. Every stage parameter (symbols per clock, lookahead width, slot clearing,
  IDCT clocks per block, MCU buffers, pixels per clock, input bytes per clock) can be changed.

```sh
python3 model/perf/perf_model.py one photo.jpg                  # today's fast core (FAST=1, MCU order)
python3 model/perf/perf_model.py one photo.jpg sym_clk=1 px_clk=4 period=1 zero_rate=0 halves=4
python3 model/perf/perf_model.py calibrate                      # model vs the counts measured on the boards
python3 model/perf/perf_model.py sweep                          # variants on test_images/ + 4:2:0 copies
```

`photos()` uses the JPEGs in `test_images/` and makes their 4:2:0 copies in `build/p420/` with
libjpeg-turbo (`djpeg -pnm | cjpeg -baseline -quality 90 -sample 2x2`, the files measured on the
Artix-7 board, byte for byte). `blockstats` is compiled into `build/` on first use (needs `cc`).

## Accuracy

With its default parameters the model reproduces today's fast core:

| check | result |
|---|---|
| the 24 photos measured on the Artix-7 board (`boards/acorn_cle215/results_2026-10-03.json`) | within 1.14 %, mean 0.28 % (the model is slightly low on detailed photos) |
| flat 512x512 images, 4:4:4 / 4:2:2 / 4:4:0 / 4:2:0, cycle-exact Verilator | within 0.004 % |
| 1024x1024 lossless crops of three photos, Verilator | within 0.61 % |
| a 256x128 crop, traced event by event (VCD) | 0.02 % |

The trace also showed what limits today's core on 4:2:2 photos: the slot zeroer, which clears 2
coefficients per clock and pauses for every coefficient the Huffman decoder writes, needs
32 + (coefficients written) clocks per block, more than the 32 the IDCT needs; a 4:2:2 MCU (4 blocks,
128 pixels) then takes ~143 clocks instead of 128.

## Variants (2026-10-04, the owner's 12 photos and their 4:2:0 copies, MCU order, 150 MHz)

| configuration | clocks/pixel, 4:2:2 photos | 4:2:0 copies | ms per 12 MP photo | x libjpeg-turbo's time (one core, ~3.8 GHz) |
|---|---:|---:|---:|---:|
| today's fast core | 1.18-1.76 | 1.00-1.36 | 87-152 | 1.88-2.72 |
| today + slot valid-bit masks (no zeroer) | 1.08-1.70 | 1.00-1.35 | 87-147 | 1.84-2.72 |
| today + masks + 3 MCU buffers | 1.05-1.70 | 1.00-1.34 | 87-147 | 1.83-2.72 |
| 1 symbol/clock, IDCT 32 clocks/block, 1 pixel/clock | 1.03 | 1.00 | 87-89 | 1.36-2.72 |
| W2: 1 symbol/clock, IDCT 16, 2 pixels/clock | 0.54-0.61 | 0.50-0.52 | 44-52 | 0.77-1.36 |
| **W4: 1 symbol/clock, IDCT 8, 4 pixels/clock** | **0.31-0.52** | **0.25-0.40** | **22-45** | **0.55-0.71** |
| W4 with a 1-byte/clock input | 0.33-0.54 | 0.25-0.40 | 22-46 | 0.56-0.73 |
| W4 with 2 symbols/clock (upper bound) | 0.30-0.34 | 0.25-0.27 | 22-29 | 0.40-0.69 |

W4 matches libjpeg-turbo on every photo from 106 MHz up; W2 would need 205 MHz. Its symbols average
about 5 bits, so a 1-symbol/clock decoder needs only ~5 bits per clock: an 8-bit input port is enough.
