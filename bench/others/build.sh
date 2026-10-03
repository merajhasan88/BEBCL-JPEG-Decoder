#!/bin/sh
# Verilator builds of tb_other.cpp against each third-party decoder (run fetch.sh first).
set -e
HERE=$(cd "$(dirname "$0")" && pwd); TP=$HERE/../../../third_party; cd "$HERE"
V="verilator -Wno-fatal -Wno-lint -Wno-style -O2 --x-assign fast --x-initial fast"
$V --top-module jpeg_core -GSUPPORT_WRITABLE_DHT=1 -cc $TP/core_jpeg/src_v/*.v --exe tb_other.cpp \
   -CFLAGS -DCORE_JPEG -Mdir obj_core_jpeg -o Vcore_jpeg > obj_core_jpeg.log 2>&1
make -s -j2 -C obj_core_jpeg -f Vjpeg_core.mk Vcore_jpeg > /dev/null
$V --top-module aq_djpeg -cc $TP/legacy_jpeg_decoder/core/*.v --exe tb_other.cpp \
   -CFLAGS -DAQ_DJPEG -Mdir obj_aq_djpeg -o Vaq_djpeg > obj_aq_djpeg.log 2>&1
make -s -j2 -C obj_aq_djpeg -f Vaq_djpeg.mk Vaq_djpeg > /dev/null
echo "built obj_core_jpeg/Vcore_jpeg obj_aq_djpeg/Vaq_djpeg"
