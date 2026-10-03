#!/bin/sh
# Compile the comparison projects one after another (heavy: never in parallel).
HERE=$(cd "$(dirname "$0")" && pwd); export PATH=/root/altera/13.0sp1/quartus/bin:$PATH
for n in ${*:-ours core_jpeg core_jpeg_fixed aq_djpeg}; do
  cd $HERE/cmp${SUF:-}_$n && nice -n 15 timeout 3000 quartus_sh --flow compile cmp > compile_log.txt 2>&1; echo "$n exit=$?"
done
