// tb_uart.cpp - simulates uart_bench_core (through uart_sim_top): sends JPEG files over the UART
// model exactly as pi_bench.py does on the board and prints the 32-byte results.
//   Vuart file.jpg [file.jpg ...]       (8 clocks per bit, as uart_sim_top sets CLK_HZ/BAUD)
#include <verilated.h>
#include "Vuart_sim_top.h"
#include <cstdio>
#include <cstdint>
#include <vector>
#include <fstream>
static vluint64_t sim_time = 0;
double sc_time_stamp() { return sim_time; }
static Vuart_sim_top* dut;
static const int DIV = 8;
static std::vector<uint8_t> rxq;                  // bytes received from the FPGA
static int tstate = 0, tcnt = 0, tbit = 0, tcur = 0, prev_tx = 1;
static void tick() {
    dut->clk = 0; dut->eval(); sim_time++;
    dut->clk = 1; dut->eval(); sim_time++;
    int tx = dut->uart_tx;                        // receive the FPGA's bytes (8N1)
    if (tstate == 0) { if (prev_tx == 1 && tx == 0) { tstate = 1; tcnt = DIV / 2; } }
    else if (tstate == 1) { if (--tcnt == 0) { tstate = 2; tcnt = DIV; tbit = 0; tcur = 0; } }
    else if (tstate == 2) { if (--tcnt == 0) { tcur |= tx << tbit; tcnt = DIV; if (++tbit == 8) tstate = 3; } }
    else if (tstate == 3) { if (--tcnt == 0) { rxq.push_back((uint8_t)tcur); tstate = 0; } }
    prev_tx = tx;
}
static void send_byte(uint8_t b) {
    int bits[10] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 1};
    for (int i = 0; i < 8; i++) bits[1 + i] = (b >> i) & 1;
    for (int i = 0; i < 10; i++) { dut->uart_rx = bits[i]; for (int k = 0; k < DIV; k++) tick(); }
}
static uint32_t be(const uint8_t* p, int n) { uint32_t v = 0; for (int i = 0; i < n; i++) v = (v << 8) | p[i]; return v; }
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vuart_sim_top;
    dut->uart_rx = 1; dut->rst = 1;
    for (int i = 0; i < 20; i++) tick();
    dut->rst = 0;
    for (int i = 0; i < 20; i++) tick();
    int rc = 0;
    for (int a = 1; a < argc; a++) {
        std::ifstream f(argv[a], std::ios::binary);
        std::vector<uint8_t> d((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
        rxq.clear();
        uint8_t hdr[8] = {0x55, 0xAA, 'J', 'P', (uint8_t)(d.size() >> 24), (uint8_t)(d.size() >> 16), (uint8_t)(d.size() >> 8), (uint8_t)d.size()};
        for (int i = 0; i < 8; i++) send_byte(hdr[i]);
        for (uint8_t b : d) send_byte(b);
        uint64_t t = 0;
        while (rxq.size() < 32 && t < 4000000000ULL) { tick(); t++; }
        if (rxq.size() < 32) { printf("%s: no result\n", argv[a]); rc = 1; continue; }
        const uint8_t* r = rxq.data();
        printf("%s: dut=%d flags=0x%02x clocks=%u checksum=0x%08X err=0x%04X %ux%u pixels=%u bytes=%u\n",
               argv[a], r[3], r[4], be(r + 8, 4), be(r + 12, 4), be(r + 16, 2), be(r + 18, 2), be(r + 20, 2),
               be(r + 22, 4), be(r + 26, 4));
        for (int i = 0; i < 200; i++) tick();
    }
    delete dut;
    return rc;
}
