// tb_batch.cpp - simulates uart_batch_core (through batch_sim_top): sends JPEG files over the UART model
// as pi_batch.py does on the board - in rounds of NLANES files, one per lane, interleaved in data
// packets - and prints each lane's 32-byte result as it arrives.
//   Vbatch [--packet BYTES] file.jpg [file.jpg ...]     (8 clocks per bit, as batch_sim_top sets CLK_HZ/BAUD)
// Build with -DNLANES=<N> matching batch_sim_top's N.
#include <verilated.h>
#include "Vbatch_sim_top.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <fstream>
#ifndef NLANES
#define NLANES 3
#endif
static vluint64_t sim_time = 0;
double sc_time_stamp() { return sim_time; }
static Vbatch_sim_top* dut;
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

struct Job { std::string name; std::vector<uint8_t> d; size_t sent = 0; bool done = false; };
static size_t used = 0;                           // bytes of rxq already parsed
static int results(std::vector<Job>& round) {     // parses complete result records; returns how many
    int n = 0;
    while (rxq.size() - used >= 32) {
        const uint8_t* r = rxq.data() + used; used += 32;
        int lane = r[5];
        const char* name = (lane < (int)round.size()) ? round[lane].name.c_str() : "?";
        printf("%s lane=%d dut=%d flags=0x%02x clocks=%u checksum=0x%08X err=0x%04X %ux%u pixels=%u bytes=%u\n",
               name, lane, r[3], r[4], be(r + 8, 4), be(r + 12, 4), be(r + 16, 2), be(r + 18, 2), be(r + 20, 2),
               be(r + 22, 4), be(r + 26, 4));
        fflush(stdout);
        if (lane < (int)round.size()) round[lane].done = true;
        n++;
    }
    return n;
}
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    size_t packet = 64;
    bool bcast = false;
    std::vector<std::string> files;
    for (int a = 1; a < argc; a++) {
        if (!strcmp(argv[a], "--packet") && a + 1 < argc) packet = (size_t)atoi(argv[++a]);
        else if (!strcmp(argv[a], "--broadcast")) bcast = true;
        else if (argv[a][0] != '+') files.push_back(argv[a]);
    }
    dut = new Vbatch_sim_top;
    dut->uart_rx = 1; dut->rst = 1;
    for (int i = 0; i < 20; i++) tick();
    dut->rst = 0;
    for (int i = 0; i < 20; i++) tick();
    int rc = 0;
    for (size_t f0 = 0; f0 < files.size(); f0 += bcast ? 1 : NLANES) {
        std::vector<Job> round;
        for (size_t f = f0; f < files.size() && f < f0 + NLANES; f++) {
            if (bcast && f != f0) break;
            std::ifstream in(files[f], std::ios::binary);
            Job j; j.name = files[f];
            j.d.assign((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
            round.push_back(j);
        }
        if (bcast) {                                           // the same file in every lane, 'M' packets
            Job j = round[0];
            round.assign(NLANES, j);
            uint32_t n = j.d.size(), m = (NLANES >= 32) ? 0xFFFFFFFFu : ((1u << NLANES) - 1);
            for (int l = 0; l < NLANES; l++) {
                uint8_t h[9] = {0x55, 0xAA, 'J', 'B', (uint8_t)l, (uint8_t)(n >> 24), (uint8_t)(n >> 16), (uint8_t)(n >> 8), (uint8_t)n};
                for (uint8_t b : h) send_byte(b);
            }
            for (size_t o = 0; o < n; o += packet) {
                size_t k = std::min(packet, (size_t)n - o);
                uint8_t h[10] = {0x55, 0xAA, 'J', 'M', (uint8_t)(m >> 24), (uint8_t)(m >> 16), (uint8_t)(m >> 8), (uint8_t)m,
                                 (uint8_t)(k >> 8), (uint8_t)k};
                for (uint8_t b : h) send_byte(b);
                for (size_t i = 0; i < k; i++) send_byte(j.d[o + i]);
                results(round);
            }
            for (auto& r : round) r.sent = r.d.size();
        }
        for (size_t l = 0; l < round.size() && !bcast; l++) {  // file headers
            uint32_t n = round[l].d.size();
            uint8_t h[9] = {0x55, 0xAA, 'J', 'B', (uint8_t)l, (uint8_t)(n >> 24), (uint8_t)(n >> 16), (uint8_t)(n >> 8), (uint8_t)n};
            for (uint8_t b : h) send_byte(b);
        }
        for (bool more = true; more;) {                        // data packets, lane after lane
            more = false;
            for (size_t l = 0; l < round.size(); l++) {
                Job& j = round[l];
                if (j.sent >= j.d.size()) continue;
                size_t n = std::min(packet, j.d.size() - j.sent);
                uint8_t h[7] = {0x55, 0xAA, 'J', 'D', (uint8_t)l, (uint8_t)(n >> 8), (uint8_t)n};
                for (uint8_t b : h) send_byte(b);
                for (size_t i = 0; i < n; i++) send_byte(j.d[j.sent + i]);
                j.sent += n;
                if (j.sent < j.d.size()) more = true;
                results(round);
            }
        }
        uint64_t t = 0;
        auto all_done = [&]() { for (auto& j : round) if (!j.done) return false; return true; };
        while (!all_done() && t < 4000000000ULL) { tick(); t++; if ((t & 1023) == 0) results(round); }
        results(round);
        for (auto& j : round) if (!j.done) { printf("%s: no result\n", j.name.c_str()); rc = 1; }
        for (int i = 0; i < 200; i++) tick();
    }
    delete dut;
    return rc;
}
