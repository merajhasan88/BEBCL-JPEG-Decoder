#!/bin/sh
# Fetch the other FPGA JPEG decoders used for comparison into ../../../third_party (outside this
# library: their code is not part of it and is not redistributed with it).
#   ultraembedded/core_jpeg   Apache-2.0                          commit bb03cce (2020-10-26)
#   H. Ishihara's (AQUAXIS)   MIT (repository LICENSE, (c) 2019 Hidemi Ishihara; file headers:
#   decoder, aq_djpeg         OSL-3.0 / AQUAXIS License), ultraembedded/legacy_jpeg_decoder
#                             commit de6832b (2020-10-25)
set -e
TP=$(cd "$(dirname "$0")/../../.." && pwd)/third_party
mkdir -p "$TP" && cd "$TP"
[ -d core_jpeg ] || git clone -q https://github.com/ultraembedded/core_jpeg.git
git -C core_jpeg checkout -q bb03cce
[ -d legacy_jpeg_decoder ] || git clone -q https://github.com/ultraembedded/legacy_jpeg_decoder.git
git -C legacy_jpeg_decoder checkout -q de6832b
echo "fetched into $TP"
