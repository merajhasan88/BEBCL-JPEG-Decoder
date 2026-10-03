#!/usr/bin/env python3
"""Convert a JPEG file into a $readmemh hex file for jpeg_rom.sv.
usage: jpeg_to_hex.py in.jpg out.hex [rom_size_bytes]"""
import sys
data = open(sys.argv[1], 'rb').read()
size = int(sys.argv[3]) if len(sys.argv) > 3 else 1 << (len(data) - 1).bit_length()
assert len(data) <= size, "file (%d bytes) does not fit the ROM (%d bytes)" % (len(data), size)
with open(sys.argv[2], 'w') as f:
    for i in range(size):
        f.write("%02x\n" % (data[i] if i < len(data) else 0))
print("wrote %s: %d bytes of data in a %d-byte ROM (use ROM_LENGTH=%d, ROM_ADDR_BITS=%d)" % (sys.argv[2], len(data), size, len(data), size.bit_length() - 1))
