#!/usr/bin/env python3
"""Receive one frame from fpga_top over a serial port and save it as a PPM.
usage: uart_capture.py /dev/ttyUSB0 out.ppm [baud]     (needs: pip install pyserial)"""
import sys, serial
port, out = sys.argv[1], sys.argv[2]
baud = int(sys.argv[3]) if len(sys.argv) > 3 else 115200
s = serial.Serial(port, baud, timeout=10)
buf = b''
while True:                                  # find the frame header
    buf += s.read(1)
    if buf.endswith(b'\xa5\x5aJPG'): break
    buf = buf[-5:]
w, h = int.from_bytes(s.read(2), 'big'), int.from_bytes(s.read(2), 'big')
print("frame %dx%d" % (w, h))
img = bytearray(w * h * 3); got = 0
while True:
    rec = s.read(7)
    if rec[:3] == b'END': break
    x, y = int.from_bytes(rec[0:2], 'big'), int.from_bytes(rec[2:4], 'big')
    if x < w and y < h:
        img[3*(y*w+x):3*(y*w+x)+3] = rec[4:7]; got += 1
open(out, 'wb').write(b'P6\n%d %d\n255\n' % (w, h) + bytes(img))
print("saved %s (%d of %d pixels)" % (out, got, w*h))
