#!/usr/bin/env python3
"""Runs on the Raspberry Pi wired to the FPGA: sends JPEG files to uart_batch_core (the batched harness,
N decoder lanes) over the UART, in rounds of N files - one per lane, interleaved in data packets so
that all lanes decode at the same time - and prints each lane's result as it arrives (one line per
file).
usage: pi_batch.py <serial port> <baud> <lanes> [--packet BYTES] [--broadcast] file.jpg [file.jpg ...]
  --broadcast   one file per round, sent once and decoded by every lane at the same time
Line format: as pi_bench.py, with the lane: "<name> lane=<l> bytes=<n> dut=<d> flags=0x<f>
              clocks=<c> checksum=0x<chk> err=0x<e> WxH=<w>x<h> pixels=<p> rx=<bytes> send_s=<seconds>"
Needs pyserial (python3-serial)."""
import sys, os, time, struct
import serial

def main():
    args = sys.argv[1:]
    packet = 1024
    if "--packet" in args:
        i = args.index("--packet"); packet = int(args[i + 1]); del args[i:i + 2]
    bcast = "--broadcast" in args
    if bcast: args.remove("--broadcast")
    port, baud, lanes, files = args[0], int(args[1]), int(args[2]), args[3:]
    s = serial.Serial(port, baud, timeout=0)          # reads never block: results arrive while sending
    buf = bytearray()

    def poll(rnd, t_send):
        nonlocal buf
        buf += s.read(4096)
        while True:
            k = buf.find(b"RES")
            if k < 0:
                del buf[:max(0, len(buf) - 2)]; return
            del buf[:k]
            if len(buf) < 32: return
            res = bytes(buf[:32]); del buf[:32]
            lane, dut, flags = res[5], res[3], res[4]
            clocks, chk = struct.unpack(">II", res[8:16])
            err, w, h = struct.unpack(">HHH", res[16:22])
            pixels, nrx = struct.unpack(">II", res[22:30])
            if lane >= len(rnd):
                print(f"? lane={lane} {res.hex()}", flush=True); continue
            j = rnd[lane]; j["done"] = True
            print(f"{os.path.basename(j['path'])} lane={lane} bytes={len(j['data'])} dut={dut} flags=0x{flags:02x} "
                  f"clocks={clocks} checksum=0x{chk:08X} err=0x{err:04X} WxH={w}x{h} pixels={pixels} rx={nrx} "
                  f"send_s={t_send():.1f}", flush=True)

    for f0 in range(0, len(files), 1 if bcast else lanes):
        group = [files[f0]] * lanes if bcast else files[f0:f0 + lanes]
        rnd = [dict(path=p, data=open(p, "rb").read(), sent=0, done=False) for p in group]
        s.reset_input_buffer(); buf.clear()
        t0 = time.time(); t1 = [None]
        t_send = lambda: (t1[0] or time.time()) - t0
        for lane, j in enumerate(rnd):                 # file headers
            s.write(b"\x55\xaaJB" + bytes([lane]) + struct.pack(">I", len(j["data"])))
        more = not bcast
        if bcast:                                      # 'M' packets: every lane gets each byte
            data, mask = rnd[0]["data"], (1 << lanes) - 1
            for o in range(0, len(data), packet):
                chunk = data[o:o + packet]
                s.write(b"\x55\xaaJM" + struct.pack(">IH", mask, len(chunk)) + chunk)
                poll(rnd, t_send)
        while more:                                    # data packets, lane after lane
            more = False
            for lane, j in enumerate(rnd):
                if j["sent"] >= len(j["data"]): continue
                chunk = j["data"][j["sent"]:j["sent"] + packet]
                s.write(b"\x55\xaaJD" + bytes([lane]) + struct.pack(">H", len(chunk)) + chunk)
                j["sent"] += len(chunk)
                more |= j["sent"] < len(j["data"])
                poll(rnd, t_send)
        s.flush(); t1[0] = time.time()
        deadline = time.time() + 120
        while not all(j["done"] for j in rnd) and time.time() < deadline:
            poll(rnd, t_send); time.sleep(0.05)
        for lane, j in enumerate(rnd):
            if not j["done"]:
                print(f"{os.path.basename(j['path'])} lane={lane} bytes={len(j['data'])} NO_RESULT", flush=True)
    s.close()

if __name__ == "__main__":
    main()
