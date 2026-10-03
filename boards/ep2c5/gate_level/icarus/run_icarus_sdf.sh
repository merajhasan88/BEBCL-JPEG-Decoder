#!/bin/bash
# SDF-annotated (slow-corner timing) gate-level simulation with Icarus Verilog of a short window:
# reset, ROM start-up and the first UART bytes of the production netlist at the real baud rate.
#   ./run_icarus_sdf.sh <revision dir> <revision> <clk_div> <stop_after_bytes> <max_cycles>
# e.g. ./run_icarus_sdf.sh ../../fpga jpeg_fpga 434 12 300000
# Needs CYCLONEII_ATOMS = <quartus>/eda/sim_lib/cycloneii_atoms.v (from your Quartus installation).
# (~200 clocks/s with timing annotation, so keep the window small)
set -e
REVDIR=$1; REV=$2; CLKDIV=$3; STOP=$4; MAXC=$5
HERE=$(cd "$(dirname "$0")" && pwd); cd "$HERE"
cp "$REVDIR/simulation/modelsim/$REV.vo" "$REV.vo"; cp "$REVDIR/simulation/modelsim/${REV}_v.sdo" "${REV}_v.sdo"
mkdir -p db && cp "$REVDIR"/db/*.mif db/
iverilog -g2012 -o "sim_$REV" -s tb_gls -Ttyp -Ptb_gls.CLK_DIV=$CLKDIV -Ptb_gls.STOP_AFTER_BYTES=$STOP -Ptb_gls.MAX_CYCLES=$MAXC \
  -Ptb_gls.OUT_FILE=\"uart_$REV.bin\" "$REV.vo" "${CYCLONEII_ATOMS:?set CYCLONEII_ATOMS to cycloneii_atoms.v of Quartus 13.0sp1}" ../tb_gls.sv > "iverilog_$REV.log" 2>&1
stdbuf -oL vvp -n "sim_$REV" 2>&1 | grep --line-buffered -E "tb_gls:|rror" | tee "vvp_$REV.log"
python3 ../../scripts/uart_bytes_to_pnm.py "uart_$REV.bin" "sdf_$REV.ppm" "$(realpath ../../../../tb/golden/adp_64x64_q25_420.box.rgb.pnm)" || true
