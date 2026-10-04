#!/usr/bin/env python3
"""Pixel checksum used by fpga_top's self-check LED:
   CHK = sum over all pixels of ((x ^ y) & 0xFF) << 24 | r << 16 | g << 8 | b   (mod 2^32)
usage: pnm_checksum.py golden.pnm   -> prints the value to use as EXPECTED_CHK"""
import sys, re
data = open(sys.argv[1], 'rb').read()
m = re.match(rb'(P[56])\s+(\d+)\s+(\d+)\s+(\d+)\s', data)
kind, w, h = m.group(1), int(m.group(2)), int(m.group(3))
px = data[m.end():]
chk = 0
for y in range(h):
    for x in range(w):
        if kind == b'P6': r, g, b = px[3*(y*w+x):3*(y*w+x)+3]
        else: r = g = b = px[y*w+x]
        chk = (chk + ((((x ^ y) & 0xFF) << 24) | (r << 16) | (g << 8) | b)) & 0xFFFFFFFF
print("EXPECTED_CHK = 32'h%08X = %d decimal (use the DECIMAL value in the .qsf)   (%dx%d %s)" % (chk, chk, w, h, kind.decode()))
