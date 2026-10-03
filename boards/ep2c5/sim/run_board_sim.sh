#!/bin/sh
# Board-level simulation of boards/ep2c5/rtl/fpga_top.sv: on-chip ROM -> decoder -> UART, decoded back
# by tb_fpga.cpp and compared with the golden image (and, with BENCH=1, the clock-count report).
#   ./run_board_sim.sh FAST BENCH [WORKDIR]        e.g.  ./run_board_sim.sh 1 1
# The golden image is made by the regression (cd ../../../tb && make && make test) or by
# model/jpeg_golden.py.
# FAST=1 fast core, 0 compact core; BENCH=1 decodes at full speed and reports clocks + checksum.
# Uses the 64x64 ROM image of ../fpga (tb/corpus/adp_64x64_q25_420.jpg, 761 bytes, checksum 0x10137ECE).
# One Verilator build (~2 min, niced) + a few seconds of simulation.
set -e
FAST=${1:-1}; BENCH=${2:-0}; D=${3:-${TMPDIR:-/tmp}/board_sim_$FAST$BENCH}
HERE=$(cd "$(dirname "$0")" && pwd); R=$HERE/../../../rtl; T=$HERE/../rtl
mkdir -p "$D"; cp "$HERE/../fpga/jpeg_rom.hex" "$D/jpeg_rom.hex"; rm -rf "$D/obj"
RTL="$R/jpeg_pkg.sv $R/jpeg_sdp_ram.sv $R/jpeg_blockram.sv $R/jpeg_parser.sv $R/jpeg_bitreader.sv
     $R/jpeg_coefdec.sv $R/jpeg_idct.sv $R/jpeg_ycc2rgb.sv $R/jpeg_pixgen.sv $R/jpeg_raster.sv
     $R/jpeg_dec_small.sv $R/jpeg_bitwin.sv $R/jpeg_huffdec.sv $R/jpeg_idct_fast.sv $R/jpeg_mcuout.sv
     $R/jpeg_raster_fast.sv $R/jpeg_dec_fast.sv $R/jpeg_decoder.sv $T/uart_tx.sv $T/jpeg_rom.sv $T/fpga_top.sv"
nice verilator -Wno-fatal -Wno-lint -Wno-style --top-module fpga_top -O2 --x-assign fast --x-initial fast \
  -GFAST=$FAST -GBENCH=$BENCH -GBAUD=12500000 -GRESTART_DELAY=1000 -GROM_LENGTH=761 -GROM_ADDR_BITS=10 \
  '-GROM_HEX="jpeg_rom.hex"' -GEXPECTED_CHK=269713102 -Mdir "$D/obj" -cc $RTL \
  --exe "$HERE/tb_fpga.cpp" -o Vfpga_top > "$D/build.log" 2>&1
nice make -s -j2 -C "$D/obj" -f Vfpga_top.mk Vfpga_top > "$D/make.log" 2>&1
cd "$D" && timeout 300 ./obj/Vfpga_top "$HERE/../../../tb/golden/adp_64x64_q25_420.box.rgb.pnm" out.ppm 8000000
