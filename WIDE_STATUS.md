# WIDE core (FAST=2): plan, decisions and resume notes

Owner's decision (2026-10-04): "Model first then wide RTL. Afterwards, some other time we take up
multi-decoder." The question behind it: today's fast core needs 1.0-1.8 clocks per pixel, so one
laptop core with libjpeg-turbo (~3.8 GHz) decodes a 12 MP photo 1.9-2.7x faster than the core at
150 MHz on the Artix-7; can a wider core doing several pixels per clock beat it?

This file is the hand-over note for that work, in the style of FAST_STATUS.md.

## 1. The model (done, `model/perf/`)

`model/perf/blockstats.c` + `perf_model.py`: a clock-level model of today's fast core, driven by the
per-block Huffman statistics of real files; it reproduces the 24 photos measured on the Artix-7
within 1.14 % (mean 0.28 %) and cycle-exact simulations within 0.61 % (details and tables:
`model/perf/README.md`). Variants on the owner's 12 photos and their 4:2:0 copies, MCU order:

| configuration | clocks/pixel, 4:2:2 photos | 4:2:0 copies | ms at 150 MHz | x libjpeg-turbo's time |
|---|---:|---:|---:|---:|
| today's fast core | 1.18-1.76 | 1.00-1.36 | 87-152 | 1.88-2.72 |
| W2: 1 symbol/clock, IDCT 16 clocks/block, 2 pixels/clock | 0.54-0.61 | 0.50-0.52 | 44-52 | 0.77-1.36 |
| **W4: 1 symbol/clock, IDCT 8 clocks/block, 4 pixels/clock** | **0.31-0.52** | **0.25-0.40** | **22-45** | **0.55-0.71** |

W4 matches libjpeg-turbo on every photo from 106 MHz up; W2 would need 205 MHz. W4 is the target.

Sizing of W4 (model, 1-byte/clock input, all 24 files; worst case = busiest photo):

| choice | effect |
|---|---|
| lookahead table 8 / 9 / 10 bits | 0.55 / 0.54 / 0.53 clocks/pixel worst case: **8 bits** (the parser already builds these tables) |
| codes longer than the table: today's search (L-1 clocks) / L-6 / 3 / 2 clocks | worst 0.63 / 0.56 / 0.55 / 0.54: **<= 3 clocks** (parallel MAXCODE compare) |
| clocks between blocks in the Huffman decoder: 0 / 1 / 3 | worst 0.51 / 0.54 / 0.60: **<= 1** (needs the next block's descriptor queued: sequencer change) |
| coefficient slots 4 / 8 / 16 | no difference: **4**, cleared at once by valid-bit masks (no zeroer) |
| MCU buffers 2 / 3 / 4 | within 4 %: **3** |
| IDCT 16 clocks/block | worst 0.62: the IDCT must do **8 clocks per block** (two 1-D cores, 1 column + 1 row per clock) |
| 2 pixels/clock output | 0.53-0.60: the output must do **4 pixels per clock** |
| input 1 byte/clock vs 4 | ~4 %: symbols average ~5 bits, so **the 8-bit input stays** |

Side finding for today's core: on 4:2:2 photos its slot zeroer (2 coefficients per clock, paused by
every coefficient write) is the bottleneck, not the Huffman decoder; valid-bit masks would make the
smooth 4:2:2 photos ~9 % faster, but cost ~300 LEs the EP2C5 does not have.

## 2. Decisions

- A new core behind the same wrapper: `jpeg_decoder #(.FAST(2))`, MCU order only (RASTER_OUT=1 with
  FAST=2 is not supported yet), `NPIX = 4` pixels per output beat. FAST=0 and FAST=1 and every
  EP2C5 build stay as they are.
- Interface: `jpeg_decoder` gets parameter `NPIX` (1 for FAST=0/1); `px_c0/px_c1/px_c2` become
  `[8*NPIX-1:0]` (pixel i in bits 8i+7..8i), `px_x` is the x of pixel 0, new output `px_n` = number of
  valid pixels in the beat (1..NPIX; fewer only at the right edge of the image). With NPIX = 1 the
  ports are unchanged apart from `px_n` (always 1). The input stays one byte per clock.
- Arithmetic copied from the bit-exact modules (jpeg_idct_fast for the IDCT, jpeg_mcuout for colour
  conversion and formats, jpeg_huffdec for EXTEND / prediction / dequantisation / saturation): the
  goldens stay the same.
- Contracts copied deliberately (they are what the malformed and stream suites check): zero fill of the
  bit window after the end of data and after `in_last` (as jpeg_bitwin), ERR_HUFF exactly as F.2.2 in
  jpeg_huffdec (no code within 16 bits, run past k = 63, ZRL past k = 47), `frame_done` exactly once
  per frame, `out_fmt = Y` still decodes chroma but does not transform it, restart handling, CHECKS.
- Target platform: Artix-7 class (the Acorn CLE-215+ at fpgas.online Welland); the core is still
  vendor-neutral SystemVerilog in the project's Quartus-13 subset.

## 3. Work order (each step bit-exact under the regression, and checked against the model)

0. Timing probe: the 1-symbol/clock loop alone (64-bit window, next 8 bits, async 1024 x 12 table,
   L + S, bit count, refill) in Vivado out of context at 150 MHz. Decides whether the parser must
   precompute L + S and whether 150 MHz is realistic.
1. Interface + wide output: `NPIX`, `px_n`, `jpeg_mcuout_wide` (4 pixels/clock, 3 MCU buffers) on top of
   today's entropy decoder and IDCT; every instantiation updated (list below); C++ and SV testbenches
   and `tb_multi.cpp` take NPIX-pixel beats; regression config `wmcu`. Model oracle: px_clk=4, halves=3.
2. `jpeg_idct_wide`: 8 clocks per block, 4 slots with valid masks, two 1-D cores, register transpose.
   Model oracle: + period=1, zero_rate=0.
3. `jpeg_huffdec_wide` + sequencer: 1 symbol/clock, next block's descriptor queued (<= 1 clock between
   blocks), long codes <= 3 clocks. Model oracle: full W4.
4. Clock counts of the photos in simulation vs the model; Vivado build of the Acorn harness with the
   wide DUT (checksum folds `px_n` pixels per beat; `pi_bench.py` pixel count); board-level sim; run at
   Welland; BENCHMARKS / README.
5. Because the wrapper changes: all EP2C5 builds re-fitted (`boards/ep2c5/compile_all.sh`, LE counts
   expected unchanged), the three gate-level runs, full regression (1616 / 80 / 416 + the new config),
   xsim subset.

Instantiations of `jpeg_decoder` (2026-10-04): `boards/ep2c5/rtl/fpga_top.sv`, `boards/ep2c5/rtl/jtag_stream_core.sv`,
`boards/acorn_cle215/uart_bench_core.sv`, `bench/others/quartus/cmp_wrap.sv`, `tb/tb_jpeg.sv`; Verilator harnesses with
`jpeg_decoder` as top: `tb/tb_jpeg.cpp`, `tb/tb_multi.cpp` (and `boards/ep2c5/sim/tb_fpga.cpp` through fpga_top). With
NPIX = 1 the pixel ports keep their widths and the new output `px_n` may stay unconnected (named connections: no
implicit net), so the RTL tops need no change; the harnesses get NPIX-pixel beats (C++: `-DNPIX=4` from the Makefile
config; SV testbench: parameter derived from FAST); the Acorn harness folds `px_n` pixels per beat for FAST=2.

## 4. Progress log

- 2026-10-04: model built and validated, W4 chosen, sizing done (sections 1-2).
- Timing probe 1 (scratchpad `probe/hufloop_probe.sv`, Vivado 2026.1 out of context, xc7a200t-2, 150 MHz):
  the loop as in jpeg_huffdec but in one clock - LSB-aligned 64-bit window, 80-bit shifter to the next 8
  bits, one 1024 x 12 asynchronous table, L + S adder, bit count, `have` compare - **fails by 3.05 ns**:
  9.67 ns, 12 logic levels, 77 % routing (wcnt fan-out 61, table address fan-out 98) = ~103 MHz.
  Probe 2: MSB-aligned window (table address = top 8 bits, no shifter before the table), n = L + S stored
  in the table, four 256-entry tables selected late by {AC, Th}, refill merge and `have` from registers only:
  **meets 150 MHz** (+0.095 ns: 6.53 ns, 7 logic levels, 80 % routing; 993 LUTs of which 416 as memory,
  160 flip-flops). Both probes and the Tcl script: `model/perf/probes/` (`vivado -mode batch -source probe.tcl`).
  Decision: the wide Huffman decoder uses probe 2's structure. The parser stays unchanged: the decoder
  keeps its own copy of the lookahead tables and derives {n = L + S, EOB} when an entry is written.
- **Step 1 done**: `rtl/jpeg_dec_wide.sv` (input side of jpeg_dec_fast in MCU order, three MCU buffers),
  `rtl/jpeg_mcuout_wide.sv` (4 pixels per beat), wrapper `FAST` now `int` with `NPIX`/`px_n`, testbenches
  (`tb_jpeg.cpp`, `tb_multi.cpp` with `-DNPIX=4`; `tb_jpeg.sv`), regression config `wmcu` (in every default
  list: C++ regression **1818/1818, 90/90, 468/468** = 9 configurations, log `tb/regression_2026-10-04c.txt`;
  SV testbench on `wmcu` 202/202, 10/10, 52/52). Clock counts vs the model (px_clk=4, halves=3): traced crop
  +0.02 %, flat images +0.00-0.01 %, crops -0.12 to -0.61 % (the same residual as today's core). Flat 4:2:0
  1.011 -> 0.780 clocks/pixel (now the IDCT's 0.75 limits it); photos unchanged, as the model said.
- Written, not yet built: `rtl/jpeg_idct1d.sv` (one 8-point 1-D IDCT per clock, the arithmetic of
  jpeg_idct_fast), `rtl/jpeg_idct_wide.sv` (step 2: 8 row banks + valid masks, 3 workspace buffers - 2 would
  limit it to ~11 clocks/block because of the 15-clock pass-1 latency - and 64-bit sample words),
  `rtl/jpeg_huffdec_wide.sv` (step 3: probe 2's loop + the contracts of jpeg_bitwin / jpeg_huffdec).
