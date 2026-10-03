#!/usr/bin/env python3
"""Parse a captured fpga_top UART byte stream (file) into a PPM and optionally compare it.
usage: uart_bytes_to_pnm.py uart_bytes.bin out.ppm [golden.pnm]
Exit status 0 = complete frame (and identical to golden if given)."""
import sys
data = open(sys.argv[1], 'rb').read()
i = data.find(b'\xa5\x5aJPG')
if i < 0: print("no frame header found (%d bytes)" % len(data)); sys.exit(1)
w = int.from_bytes(data[i+5:i+7], 'big'); h = int.from_bytes(data[i+7:i+9], 'big'); i += 9
img = bytearray(w*h*3); seen = bytearray(w*h); n = 0
while i + 3 <= len(data) and data[i:i+3] != b'END':
    if i + 7 > len(data): break
    x = int.from_bytes(data[i:i+2], 'big'); y = int.from_bytes(data[i+2:i+4], 'big')
    if x < w and y < h:
        img[3*(y*w+x):3*(y*w+x)+3] = data[i+4:i+7]; seen[y*w+x] = 1; n += 1
    i += 7
complete = data[i:i+3] == b'END'
out = b'P6\n%d %d\n255\n' % (w, h) + bytes(img)
open(sys.argv[2], 'wb').write(out)
print("frame %dx%d: %d pixel records, %d distinct pixels, trailer %s" % (w, h, n, sum(seen), "seen" if complete else "MISSING"))
rc = 0 if complete and sum(seen) == w*h else 1
if len(sys.argv) > 3:
    g = open(sys.argv[3], 'rb').read()
    gray = g[:2] == b'P5'
    gp = g[len(g) - (w*h if gray else 3*w*h):]
    def golden_px(k): return (gp[k], gp[k], gp[k]) if gray else tuple(gp[3*k:3*k+3])
    bad = sum(1 for k in range(w*h) if seen[k] and tuple(img[3*k:3*k+3]) != golden_px(k))
    if complete and sum(seen) == w*h:
        print("compare with golden: %s" % ("IDENTICAL" if bad == 0 else "DIFFERENT (%d pixels)" % bad))
        rc = rc or (0 if bad == 0 else 1)
    else:
        print("partial frame: %d of %d received pixels match the golden image" % (sum(seen) - bad, sum(seen)))
        rc = 0 if bad == 0 and sum(seen) > 0 else 1
sys.exit(rc)
