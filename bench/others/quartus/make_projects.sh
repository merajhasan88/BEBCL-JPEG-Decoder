#!/bin/sh
# EP2C5T144C8 projects for the decoder comparison: each decoder inside the same 4-pin wrapper
# (cmp_wrap.sv), the same settings as this project's EP2C5 builds, clock constrained at 95 MHz.
# Only the decoder under test's sources are included (core_jpeg and this project both have a
# module named jpeg_idct).  Run: ./make_projects.sh && ./compile_all.sh
#   ./make_projects.sh EP2C35F672C8 35  -> the same projects for the larger Cyclone II EP2C35 (same
#   family and speed grade: gives the Fmax of designs that do not fit the EP2C5), named cmp35_*
set -e
DEV=${1:-EP2C5T144C8}; SUF=${2:-}
HERE=$(cd "$(dirname "$0")" && pwd); TP=$HERE/../third_party; RTL=$HERE/../../../rtl
mk() {  # name DUT DHT file...
  n=$1; dut=$2; dht=$3; shift 3; d=$HERE/cmp${SUF}_$n; mkdir -p $d
  { echo 'set_global_assignment -name FAMILY "Cyclone II"'
    echo "set_global_assignment -name DEVICE $DEV"
    echo 'set_global_assignment -name TOP_LEVEL_ENTITY cmp_wrap'
    echo 'set_global_assignment -name VERILOG_INPUT_VERSION SYSTEMVERILOG_2005'
    echo 'set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files'
    echo 'set_global_assignment -name NUM_PARALLEL_PROCESSORS 2'
    echo 'set_global_assignment -name CYCLONEII_OPTIMIZATION_TECHNIQUE AREA'
    echo 'set_global_assignment -name AUTO_PACKED_REGISTERS_STRATIXII "MINIMIZE AREA WITH CHAINS"'
    echo 'set_global_assignment -name PHYSICAL_SYNTHESIS_COMBO_LOGIC ON'
    echo 'set_global_assignment -name PHYSICAL_SYNTHESIS_REGISTER_DUPLICATION ON'
    echo 'set_global_assignment -name ROUTER_TIMING_OPTIMIZATION_LEVEL MAXIMUM'
    echo 'set_global_assignment -name SDC_FILE cmp.sdc'
    echo "set_global_assignment -name SYSTEMVERILOG_FILE $HERE/cmp_wrap.sv"
    for f in "$@"; do case $f in *.sv) echo "set_global_assignment -name SYSTEMVERILOG_FILE $f";; *) echo "set_global_assignment -name VERILOG_FILE $f";; esac; done
    echo "set_parameter -name DUT $dut"
    echo "set_parameter -name DHT $dht"
    if [ "$DEV" = EP2C5T144C8 ]; then echo 'set_location_assignment PIN_17 -to clk'; echo 'set_location_assignment PIN_144 -to rst_n'; fi
  } > $d/cmp.qsf
  echo 'PROJECT_REVISION = "cmp"' > $d/cmp.qpf
  printf 'create_clock -name clk -period 10.526 [get_ports clk]\nderive_clock_uncertainty\nset_false_path -from [get_ports {rst_n sin}]\nset_false_path -to [get_ports sout]\n' > $d/cmp.sdc
}
R="$RTL/jpeg_pkg.sv $RTL/jpeg_sdp_ram.sv $RTL/jpeg_blockram.sv $RTL/jpeg_parser.sv $RTL/jpeg_bitreader.sv $RTL/jpeg_coefdec.sv $RTL/jpeg_idct.sv $RTL/jpeg_ycc2rgb.sv $RTL/jpeg_pixgen.sv $RTL/jpeg_raster.sv $RTL/jpeg_dec_small.sv $RTL/jpeg_bitwin.sv $RTL/jpeg_huffdec.sv $RTL/jpeg_idct_fast.sv $RTL/jpeg_mcuout.sv $RTL/jpeg_raster_fast.sv $RTL/jpeg_dec_fast.sv $RTL/jpeg_decoder.sv"
mk ours 0 1 $R
mk core_jpeg 1 1 $TP/core_jpeg/src_v/*.v
mk core_jpeg_fixed 1 0 $TP/core_jpeg/src_v/*.v
mk aq_djpeg 2 1 $TP/legacy_jpeg_decoder/core/*.v
echo "projects in $HERE"
