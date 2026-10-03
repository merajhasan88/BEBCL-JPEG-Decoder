#!/bin/bash
# Gate-level simulation of a post-fit Quartus netlist with ModelSim-Altera Starter Edition.
#   ./run_gls.sh <revision dir> <revision> <clk_div> <golden.pnm> [max_cycles] [stop_after_bytes]
# e.g. ./run_gls.sh ../quartus/gls  jpeg_gls  4   ../tb/golden/dog_64x64_q25_420.pnm 4000000
#      ./run_gls.sh ../quartus/fpga jpeg_fpga 434 ../tb/golden/dog_64x64_q25_420.pnm 2000000 30
set -e
REVDIR=$1; REV=$2; CLKDIV=$3; GOLDEN=$4; MAXC=${5:-4000000}; STOP=${6:-0}
MSIM=/root/altera/13.0sp1/modelsim_ase/bin
HERE=$(cd "$(dirname "$0")" && pwd)
SIM=$REVDIR/simulation/modelsim
cd "$SIM"
mkdir -p db && cp -u "$REVDIR"/db/*.mif db/ 2>/dev/null || true      # RAM/ROM init files referenced relatively by the .vo
rm -rf work && $MSIM/vlib work > /dev/null
$MSIM/vlog -quiet -work work "$REV.vo" > vlog_netlist.log 2>&1 || { tail -20 vlog_netlist.log; exit 1; }
$MSIM/vlog -quiet -sv -work work "$HERE/tb_gls.sv" > vlog_tb.log 2>&1 || { tail -20 vlog_tb.log; exit 1; }
# the .vo annotates itself with $REV_v.sdo (slow corner) via $sdf_annotate
$MSIM/vsim -c -t 1ps -L cycloneii_ver -L altera_ver -L altera_mf_ver -L lpm_ver -L sgate_ver \
  -GCLK_DIV=$CLKDIV -GMAX_CYCLES=$MAXC -GSTOP_AFTER_BYTES=$STOP -GOUT_FILE="uart_bytes.bin" \
  +no_notifier +sdf_verbose ${EXTRA_VSIM_ARGS} work.tb_gls -do "run -all; quit -f" > vsim.log 2>&1 || true
grep -E "tb_gls:|Error|Fatal|SDF" vsim.log | grep -vE "^# \*\* Warning" | head -20
python3 "$HERE/../scripts/uart_bytes_to_pnm.py" uart_bytes.bin gls_out.ppm "$(cd "$HERE" && realpath "$GOLDEN")"
