#!/usr/bin/env python3
"""Runs on the Raspberry Pi wired to the FPGA: streams JPEG files to uart_bench_core over the UART
and prints the decoder's result for each file (one line per file).
usage: pi_bench.py <serial port> <baud> file.jpg [file.jpg ...]
Line format: "<name> bytes=<n> dut=<d> flags=0x<f> clocks=<c> checksum=0x<chk> err=0x<e> WxH=<w>x<h>
              pixels=<p> rx=<bytes the FPGA received> send_s=<seconds>"   (flags: 1 overflow, 2 watchdog, 4 done)
Needs pyserial (python3-serial)."""
import sys, os, time, struct
import serial

def main():
    port, baud, files = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
    s = serial.Serial(port, baud, timeout=1)
    for path in files:
        data = open(path, "rb").read()
        s.reset_input_buffer()
        t0 = time.time()
        s.write(b"\x55\xaaJP" + struct.pack(">I", len(data)))
        for i in range(0, len(data), 4096):
            s.write(data[i:i + 4096])
        s.flush()
        t1 = time.time()
        res, deadline = b"", time.time() + 60
        while len(res) < 32 and time.time() < deadline:
            res += s.read(32 - len(res))
        name = os.path.basename(path)
        if len(res) < 32 or res[:3] != b"RES":
            print(f"{name} bytes={len(data)} NO_RESULT got={res.hex()}", flush=True)
            continue
        dut, flags = res[3], res[4]
        clocks, chk = struct.unpack(">II", res[8:16])
        err, w, h = struct.unpack(">HHH", res[16:22])
        pixels, nrx = struct.unpack(">II", res[22:30])
        print(f"{name} bytes={len(data)} dut={dut} flags=0x{flags:02x} clocks={clocks} checksum=0x{chk:08X} "
              f"err=0x{err:04X} WxH={w}x{h} pixels={pixels} rx={nrx} send_s={t1 - t0:.1f}", flush=True)
    s.close()

if __name__ == "__main__":
    main()
