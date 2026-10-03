#!/usr/bin/env python3
"""Read the benchmark report of an fpga_top BENCH=1 build from the serial port.
The board decodes its ROM image at full speed and sends, after every frame:
  A5 5A 'B' 'N' 'C'  W H  CLOCKS[31:0]  CHK[31:0]  ERR[15:0]  'E' 'N' 'D'   (big-endian)
usage: uart_bench.py /dev/ttyUSB0 CLOCK_MHZ [golden.pnm] [baud]     (needs: pip install pyserial)
Prints the decode time and Mpixel/s at the given core clock; with a golden PNM the checksum is
compared too (same checksum as scripts/pnm_checksum.py)."""
import sys, serial

def pnm_checksum(path):
    data = open(path, "rb").read()
    fields, p = [], 0
    while len(fields) < 4:
        while data[p:p+1].isspace(): p += 1
        q = p
        while not data[q:q+1].isspace(): q += 1
        fields.append(data[p:q]); p = q
    p += 1
    grey = fields[0] == b"P5"; w, h = int(fields[1]), int(fields[2])
    chk = 0
    for y in range(h):
        for x in range(w):
            k = y * w + x
            c0, c1, c2 = (data[p+k],) * 3 if grey else data[p+3*k:p+3*k+3]
            chk = (chk + ((((x ^ y) & 0xFF) << 24) | (c0 << 16) | (c1 << 8) | c2)) & 0xFFFFFFFF
    return chk

def main():
    port, mhz = sys.argv[1], float(sys.argv[2])
    golden = sys.argv[3] if len(sys.argv) > 3 else None
    baud = int(sys.argv[4]) if len(sys.argv) > 4 else 115200
    gchk = pnm_checksum(golden) if golden else None
    s = serial.Serial(port, baud, timeout=10)
    buf = b""
    while True:                                        # find the report header
        buf = (buf + s.read(1))[-5:]
        if buf == b"\xa5\x5aBNC": break
    r = s.read(19)
    w, h = int.from_bytes(r[0:2], "big"), int.from_bytes(r[2:4], "big")
    clocks, chk, err = int.from_bytes(r[4:8], "big"), int.from_bytes(r[8:12], "big"), int.from_bytes(r[12:14], "big")
    t = clocks / (mhz * 1e6)
    print(f"{w}x{h}: {clocks} clocks = {clocks / (w * h):.3f} clocks/pixel; at {mhz:g} MHz "
          f"{t * 1e6:.1f} us = {w * h / t / 1e6:.1f} Mpixel/s; checksum 0x{chk:08X}, err 0x{err:04X}")
    if gchk is not None:
        print("checksum matches the golden image" if chk == gchk else f"CHECKSUM MISMATCH (golden 0x{gchk:08X})")
    if r[14:17] != b"END": print("warning: trailer missing")

if __name__ == "__main__":
    main()
