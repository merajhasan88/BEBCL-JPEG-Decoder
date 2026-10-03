#!/bin/bash
# Recompile the EP2C5 board projects one after another, niced, and summarise fit and timing in
# compile_all.log.  Gate-level twins (gls*, development branch only) also get their .vo netlist.
# Needs Quartus II 13.0sp1 (the last version with Cyclone II support) on PATH.
#   ./compile_all_boards.sh [project ...]      (default: all, tightest builds first)
command -v quartus_sh >/dev/null || { echo "put the bin directory of Quartus II 13.0sp1 on PATH"; exit 1; }
cd "$(dirname "$0")"
PROJ=${*:-"fpga_raster fpga_jtag fpga_fast_bench fpga_fast gls_fast gls_raster fpga_raster_ycc fpga_raster_box fpga gls"}
LOG=$PWD/compile_all.log
echo "== $(date '+%F %T') $PROJ" >> "$LOG"
for p in $PROJ; do
  [ -d "$p" ] || continue
  rev=$(basename "$(ls "$p"/*.qpf | head -1)" .qpf)
  t0=$(date +%s)
  ( cd "$p" && ulimit -v 6000000 && nice -n 10 timeout 3600 quartus_sh --flow compile "$rev" > compile.log 2>&1 )
  rc=$?
  if [ $rc -eq 0 ] && grep -q "EDA_SIMULATION_TOOL" "$p/$rev.qsf"; then
    ( cd "$p" && nice -n 10 timeout 1200 quartus_eda "$rev" --simulation --tool=modelsim --format=verilog > eda.log 2>&1 )
  fi
  le=$(grep -h "Total logic elements" "$p"/output_files/"$rev".fit.summary 2>/dev/null)
  sum="$p/output_files/$rev.sta.summary"
  setup=$(awk '/^Type/{t=$0} /^Slack/{if (t ~ /Slow Model Setup/ && s == "") s=$3} END{print s}' "$sum" 2>/dev/null)
  hold=$(awk '/^Type/{t=$0} /^Slack/{if (t ~ /Slow Model Hold/ && h == "") h=$3} END{print h}' "$sum" 2>/dev/null)
  fmax=$(grep -A4 "^; Slow Model Fmax Summary" "$p"/output_files/"$rev".sta.rpt 2>/dev/null | grep -oE "[0-9.]+ MHz" | head -1)
  echo "$p rc=$rc $(( $(date +%s) - t0 ))s | $le | setup slack $setup ns, hold slack $hold ns | Fmax $fmax" >> "$LOG"
done
echo "== done $(date '+%F %T')" >> "$LOG"
