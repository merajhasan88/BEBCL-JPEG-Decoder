
## What the numbers say

### Against CPU decoders

1. **At full clock, one laptop core beats the EP2C5 on every image.** In the performance profile
   (3.4-3.9 GHz) libjpeg-turbo decodes donald.jpg in 6.9 ms against the EP2C5's 30.0 ms (4.4x
   faster). It decodes the 12-megapixel phone photos in 54-73 ms against 203-284 ms (3.7-4.0x) and
   the 4:4:4 portrait in 16.8-17.8 ms against 88.3 ms (5.0-5.3x). Even the slowest CPU decoder on
   each large photo is 1.4-1.8x faster than the EP2C5 (libjpeg 9e with its default upsampling, or
   stb_image, depending on the image). Apart from the pure-Python reference model, the only CPU
   result the FPGA beats is Pillow on the 64x64 image, where Python's per-call overhead dominates.
2. **Per clock, the FPGA does about 10x more work.** It needs 1.0-2.25 clocks per pixel. libjpeg-turbo
   with SIMD (AVX2) needs 8-22 CPU clocks per pixel, and libjpeg 9e and stb_image need 20-52 on the
   large photos. But
   the laptop's clock is 40x higher (3.9 GHz against 95 MHz). At the laptop's power-saver clock
   (~1 GHz) libjpeg-turbo and the EP2C5 are close. The CPU is 7-47 % faster on six images and level
   (3 %) on the 320x240 image. It takes 21 % longer on the 64x64 image (see the last table of the
   results).
3. **Energy per image is the FPGA's clear advantage.** donald.jpg costs ~4.4 mJ on the EP2C5
   (PowerPlay estimate 147 mW x 30 ms). libjpeg-turbo uses 124 mJ of CPU package energy at full
   clock and 65 mJ in the power-saver profile, so the FPGA uses 15-28x less. Both figures are
   rough: the FPGA's is a vectorless estimate that includes I/O, and the CPU's is RAPL package
   energy that includes background power.
4. **Correction.** Earlier versions of this file, README.md and the project notes said the EP2C5
   at 95 MHz decodes donald.jpg faster than libjpeg-turbo, FFmpeg and Pillow on one laptop core
   (30.0 ms against 32.8-42.6 ms). Those CPU numbers were measured with the laptop in its
   power-saver profile (~0.8-1 GHz), and so was the first run on 2026-09-30. FFmpeg was also
   measured without its RGB conversion. **That claim is withdrawn.** At full clock the laptop is
   3-6x faster. What still holds is the per-clock and energy comparison above.
5. **The decode time is the decoder alone.** On this board the file arrives over JTAG at ~35 KB/s
   (170 s for a 5.9 MB photo), and the pixels are checked on the chip. To keep up with the
   decoder, a system needs an input path of ~8 MB/s (donald.jpg) to ~21 MB/s (the dense phone
   photo). It also needs a consumer that takes 42-93 Mpixel/s in 8x8 / 16x16 tiles.
6. **The compact core** (`FAST=0`, 3.4k LEs, 50 MHz) needs 12.8-21 clocks/pixel (0.75 s for
   donald.jpg). Use it when area matters more than speed. It is also the core that fits the EP2C5
   with raster output and Pillow-exact smoothing (up to 352 pixels wide for 4:2:0).
7. **Among the CPU decoders** at full clock (on the 320x240 image and the large photos),
   libjpeg-turbo is the fastest. Pillow (which uses it inside) takes 1.15-1.5x as long. OpenCV
   takes 1.4-2.3x and FFmpeg (its own decoder, plus the RGB conversion) 1.1-2.9x. libjpeg 9e takes
   1.8-2.3x (`-nosmooth`) and stb_image 2.0-2.9x; neither has SIMD.

### Against other FPGA decoders

- **Neither core_jpeg nor aq_djpeg fits the EP2C5.** On the EP2C35 they need 7.0k-9.5k logic
  elements and 34-64 9-bit multiplier elements; the EP2C5 has 4,608 and 26. This decoder is the
  only one of the three that runs on the owner's board.
- **On the larger Cyclone II this decoder leads on every measure but one.** It has the highest Fmax
  (103.8 MHz against 60.2 and 40.1-40.4 MHz) and the fewest clocks per pixel on every image. It
  uses the fewest logic elements (4.4k against 7.0k-9.5k) and multipliers (26 against 34-64). It
  uses the most block-RAM bits (55.6 kbit against 27.5-51.2 kbit). It is the only one whose pixels
  are identical to libjpeg's; the others differ by up to 14 (core_jpeg) and 32 (aq_djpeg) levels,
  PSNR 42-51 dB. donald.jpg takes 30.0 ms on the EP2C5 board at 95 MHz, against 66.4 ms for
  aq_djpeg (60 MHz) and 148 ms for core_jpeg (40 MHz).
- **core_jpeg fails on the owner's phone photos.** It decodes the 512x384 EXIF thumbnail inside the
  APP1 segment instead of the photo. It also mis-decodes the 4:4:4 portrait and the q6 strip, and
  it does not support 4:2:2 or restart markers.
- **aq_djpeg decodes every file**, at 1.4-5.0 clocks/pixel. That makes it 3.0-3.3x slower than this
  decoder on the phone photos.
- Commercial cores were not available for testing. CAST's JPEG-DX-F data sheet quotes 2-32
  samples per clock (e.g. 300 Msamples/s) with 6,700 ALMs on Cyclone V or 18,250 LUT4 on ECP5 at
  70 MHz. These are vendor figures for larger devices, not measured on the same files.

## Where more speed would come from

- **On the EP2C5 this design is close to the ceiling.** The fast core uses 4,473 of 4,608 LEs and
  all 26 multiplier elements, and each of its three limits would need more logic or multipliers
  than the device has:
  - the output, at 1 pixel per clock (4:2:0 photos such as donald.jpg);
  - the IDCT, with 13 multipliers and 32 clocks per block, which is 1.5 clocks per pixel for 4:4:4;
  - the Huffman decoder, at 3 clocks per coded coefficient (the dense phone photos).
- **Matching one laptop core at full clock** (~400 Mpixel/s on donald.jpg) needs ~4 pixels per clock
  at 100 MHz. There are two ways to get there on a larger FPGA:
  - a wider decoder: 2 coefficients per clock in the Huffman decoder, more IDCT lanes, and 2-4
    pixels per clock out;
  - several decoders working on different images (an MJPEG stream, a batch).

  A single image without restart markers cannot simply be split between decoders, because its
  Huffman-coded data has to be decoded in order. None of the owner's photos has restart markers.
- **Newer FPGA families** would run the same RTL at a higher clock (not measured here).

## Reproduce

```sh
cd claude_jpeg/tb && make obj_mcu/Vjpeg_decoder obj_fmcu/Vjpeg_decoder
cd ../bench
BENCH_POWER_PROFILE=performance python3 run_bench.py bench.json   # CPU decoders, full clock
python3 bench_fpga.py bench.json         # this decoder's clock counts (cycle-exact simulation)
python3 ../scripts/jtag_decode.py <files> > board_jtag_95mhz.txt   # on the board, fpga_jtag loaded
cd others && ./fetch.sh && ./build.sh && python3 run_others.py others.json
./quartus/make_projects.sh && ./quartus/compile_all.sh
./quartus/make_projects.sh EP2C35F672C8 35 && SUF=35 ./quartus/compile_all.sh
cd .. && python3 make_benchmarks_md.py   # -> ../BENCHMARKS.md
```

`bench_powersaver.json` holds the CPU runs in the laptop's power-saver profile. Its libjpeg-turbo
`-nosmooth` rows were re-run with the clock recorded (`BENCH_ONLY="libjpeg-turbo (nosmooth)"
python3 run_bench.py bench_powersaver.json`). Caveats: CPU decoders ran single-threaded on one
pinned core, and RAPL energy includes background package power.
