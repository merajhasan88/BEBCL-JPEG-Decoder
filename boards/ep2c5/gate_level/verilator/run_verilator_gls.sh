#!/bin/bash
# Zero-delay gate-level simulation of a Quartus post-fit netlist with Verilator.
#   ./run_verilator_gls.sh <revision dir> <revision> <golden.pnm> [max_cycles]
# e.g. ./run_verilator_gls.sh ../../gls jpeg_gls ../../../../tb/golden/adp_64x64_q25_420.box.rgb.pnm
# The netlist's UART divider must match tb_fpga.cpp's CLK_DIV (4 -> the ../../gls build).
set -e
REVDIR=$1; REV=$2; GOLDEN=$3; MAXC=${4:-60000000}
HERE=$(cd "$(dirname "$0")" && pwd); cd "$HERE"
python3 prepare_netlist.py "$REVDIR/simulation/modelsim/$REV.vo" "${REV}_verilator.vo"
verilator -cc --top-module fpga_top --no-timing -Wno-fatal -Wno-lint -Wno-style -Wno-STMTDLY -Wno-IGNOREDRETURN \
  --x-assign fast --x-initial fast -O1 -Mdir "obj_$REV" "${REV}_verilator.vo" cycloneii_cells.v \
  --exe ../../sim/tb_fpga.cpp -o Vfpga_top > "verilate_$REV.log" 2>&1
make -s -j3 -C "obj_$REV" -f Vfpga_top.mk Vfpga_top > /dev/null
"./obj_$REV/Vfpga_top" "$GOLDEN" "gls_${REV}.ppm" "$MAXC"
