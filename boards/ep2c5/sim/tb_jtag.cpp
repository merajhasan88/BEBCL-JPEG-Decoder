// tb_jtag.cpp - simulates jtag_stream_core (through jtag_sim_top): streams a JPEG over the
// virtual-JTAG interface the way the host script does (restart, data in chunks, end of stream,
// poll status, read the result) and prints the decoder's clock count and checksum.
//   Vjtag in.jpg [--tck-div N] [--gap N] [--chunk N] [--seed N]
//     --tck-div  clk half-periods per TCK half-period (default 8: TCK = clk/8)
//     --gap      maximum random idle TCK cycles between JTAG operations (default 50)
//     --chunk    bytes per DATA scan (default 256)
//     --hub-bits header bits the virtual-JTAG hub shifts in before every payload (default 7, as
//                measured on the EP2C5 with Quartus 13.0sp1)
// Output: "result: frames=<n> clocks=<cyc> checksum=0x<chk> err=0x<err> overflow=<0|1>"
#include <verilated.h>
#include "Vjtag_sim_top.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <vector>
#include <string>
#include <fstream>
static vluint64_t sim_time = 0;
double sc_time_stamp() { return sim_time; }

static Vjtag_sim_top* dut;
static int tck_div = 8;
static uint64_t clk_edges = 0, gated_edges = 0;
static int phase = 0;              // clk half-period counter within a TCK half-period
static unsigned rng = 1;
static int hub_bits = 7;

// advance one clk half-period; TCK toggles every tck_div half-periods
static bool tck_now = false;
static void half_step() {
    dut->clk = !dut->clk;
    if (++phase >= tck_div) { phase = 0; tck_now = !tck_now; dut->tck = tck_now; }
    dut->eval(); sim_time++;
    if (dut->clk) { clk_edges++; if (dut->dclk_en) gated_edges++; }
}
// wait until TCK has made one full cycle (the JTAG signals are set up while TCK is low)
static void tck_cycle() {
    while (!tck_now) half_step();          // rising edge happens here
    while (tck_now) half_step();           // falling edge: next bit may be presented
}
static void idle(int n) { for (int i = 0; i < n; i++) tck_cycle(); }

// one DR scan of `bits` bits with instruction `ir`: Capture-DR, Shift-DR, Update-DR
static std::vector<uint8_t> dr_scan(int ir, const std::vector<uint8_t>& in_bits) {
    std::vector<uint8_t> out;
    dut->ir = ir;
    dut->v_cdr = 1; tck_cycle(); dut->v_cdr = 0;
    dut->v_sdr = 1;
    // the hub shifts its header bits in first; the instance's DR comes out from the first clock on,
    // and the host tools return the first bits that come out (so reads stay aligned)
    for (int i = 0; i < hub_bits; i++) { dut->tdi = 0; dut->eval(); out.push_back(dut->tdo); tck_cycle(); }
    for (size_t i = 0; i < in_bits.size(); i++) {
        dut->tdi = in_bits[i]; dut->eval();
        out.push_back(dut->tdo);           // TDO of the current bit, before the shifting edge
        tck_cycle();
    }
    out.resize(in_bits.size());
    dut->v_sdr = 0;
    dut->v_udr = 1; tck_cycle(); dut->v_udr = 0;
    idle(1 + (int)(rng = rng * 1103515245u + 12345u) % 3);
    return out;
}
static uint64_t scan64(int ir, uint64_t value) {
    std::vector<uint8_t> b(64);
    for (int i = 0; i < 64; i++) b[i] = (value >> i) & 1;
    auto o = dr_scan(ir, b);
    uint64_t r = 0;
    for (int i = 0; i < 64; i++) r |= (uint64_t)o[i] << i;
    return r;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 2) { fprintf(stderr, "usage: %s in.jpg [--tck-div N] [--gap N] [--chunk N] [--seed N]\n", argv[0]); return 2; }
    int gap = 50, chunk = 256;
    for (int i = 2; i + 1 < argc; i++) {
        if (!strcmp(argv[i], "--tck-div")) tck_div = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--gap")) gap = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--chunk")) chunk = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--seed")) rng = (unsigned)atoi(argv[++i]);
        else if (!strcmp(argv[i], "--hub-bits")) hub_bits = atoi(argv[++i]);
    }
    std::ifstream f(argv[1], std::ios::binary);
    if (!f) { fprintf(stderr, "cannot open %s\n", argv[1]); return 2; }
    std::vector<uint8_t> data((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());

    dut = new Vjtag_sim_top;
    dut->clk = 0; dut->tck = 0; dut->rst = 1; dut->ir = 0; dut->v_cdr = dut->v_sdr = dut->v_udr = 0; dut->tdi = 0;
    for (int i = 0; i < 64; i++) half_step();
    dut->rst = 0;
    idle(4);

    uint64_t st = scan64(3, 0);                         // status before
    int frames0 = (st >> 48) & 0xFF;
    if ((st >> 56) != 0xA5) { fprintf(stderr, "bad status magic: %016llx\n", (unsigned long long)st); return 1; }
    scan64(3, 1); scan64(3, 0);                         // restart (rising edge of bit 0)
    idle(40);
    for (size_t p = 0; p < data.size(); p += chunk) {
        size_t n = std::min((size_t)chunk, data.size() - p);
        std::vector<uint8_t> bits;
        for (int b = 0; b < 16; b++) bits.push_back((0xA5C3 >> b) & 1);          // sync word
        for (size_t k = 0; k < n; k++) for (int b = 0; b < 8; b++) bits.push_back((data[p + k] >> b) & 1);
        dr_scan(1, bits);
        idle((int)((rng = rng * 1103515245u + 12345u) >> 8) % (gap + 1));
    }
    scan64(3, 2);                                       // end of stream
    uint64_t status = 0; int frames = frames0;
    for (int t = 0; t < 200000 && frames == frames0; t++) {
        idle(20);
        status = scan64(3, 2);
        frames = (status >> 48) & 0xFF;
    }
    uint64_t res = scan64(2, 0);
    unsigned cyc = (unsigned)(res & 0xFFFFFFFFu), chk = (unsigned)(res >> 32);
    unsigned err = (unsigned)((status >> 32) & 0x1FFF);
    printf("result: frames=%d clocks=%u checksum=0x%08X err=0x%04X overflow=%d  (clk edges %llu, decoder edges %llu)\n",
           frames - frames0, cyc, chk, err, (int)(status & 1),
           (unsigned long long)clk_edges, (unsigned long long)gated_edges);
    delete dut;
    return frames != frames0 ? 0 : 1;
}
