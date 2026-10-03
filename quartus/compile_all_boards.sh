#!/bin/bash
# Recompile the EP2C5 (and Cyclone IV) board projects one after another, niced, and summarise
# fit and timing: quartus/compile_all_boards.log.  Gate-level twins also get their .vo netlist.
#   ./compile_all_boards.sh [project ...]      (default: all, tightest builds first)
export PATH=/root/altera/13.0sp1/quartus/bin:$PATH
cd "$(dirname "$0")"
PROJ=${*:-"fpga_raster fpga_jtag fpga_fast_bench fpga_fast gls_fast gls_raster fpga_raster_ycc fpga_raster_box fpga fpga_fast_raster gls core"}
LOG=$PWD/compile_all_boards.log
echo "== $(date '+%F %T') $PROJ" >> "$LOG"
for p in $PROJ; do
  rev=$(basename "$(ls "$p"/*.qpf | head -1)" .qpf)
  t0=$(date +%s)
  ( cd "$p" && ulimit -v 6000000 && nice -n 10 timeout 3600 quartus_sh --flow compile "$rev" > compile.log 2>&1 )
  rc=$?
  if [ $rc -eq 0 ] && grep -q "EDA_SIMULATION_TOOL" "$p/$rev.qsf"; then
    ( cd "$p" && nice -n 10 timeout 1200 quartus_eda "$rev" --simulation --tool=modelsim --format=verilog > eda.log 2>&1 )
  fi
  le=$(grep -h "Total logic elements" "$p"/output_files/"$rev".fit.summary 2>/dev/null)
  slack=$(grep -m1 -A3 "Slow Model Setup Summary" "$p"/output_files/"$rev".sta.rpt 2>/dev/null | tail -1)
  fmax=$(grep -m1 -A4 "Slow Model Fmax Summary" "$p"/output_files/"$rev".sta.rpt 2>/dev/null | tail -1)
  echo "$p rc=$rc $(( $(date +%s) - t0 ))s | $le | setup: $slack | fmax: $fmax" >> "$LOG"
done
echo "== done $(date '+%F %T')" >> "$LOG"
