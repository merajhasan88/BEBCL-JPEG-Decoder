// tb_fpga.cpp - simulates fpga_top: samples the UART line, decodes 8N1 bytes, parses the
// frame protocol and compares the reconstructed image with a golden PNM.
//   Vfpga_top <golden.pnm> <out.ppm>      (build with -GBAUD=12500000 -GRESTART_DELAY=1000)
#include <verilated.h>
#include "Vfpga_top.h"
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <fstream>
#include <string>
#include <cctype>
static vluint64_t sim_time = 0;
double sc_time_stamp() { return sim_time; }
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const int CLK_DIV = 4;                       // must match CLK_HZ/BAUD used at build time
    Vfpga_top* dut = new Vfpga_top;
    dut->clk = 0; dut->key_n = 1; dut->eval();
    auto tick = [&]() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); sim_time++; };
    std::vector<unsigned char> bytes;
    int state = 0, cnt = 0, bitno = 0; unsigned char cur = 0; int prev_tx = 1;
    long long cycles = 0; long long MAX = 60000000LL;
    if (argc > 3) MAX = atoll(argv[3]);                  // optional cycle cap
    int frames = 0;
    while (cycles < MAX && frames < 2) {
        tick(); cycles++;
        int tx = dut->uart_tx;
        // UART receiver: detect start bit, sample mid-bit
        if (state == 0) { if (prev_tx == 1 && tx == 0) { state = 1; cnt = CLK_DIV / 2; bitno = 0; cur = 0; } }
        else if (state == 1) { if (--cnt == 0) { state = 2; cnt = CLK_DIV; } }   // middle of start bit
        else if (state == 2) { if (--cnt == 0) { cur |= (tx << bitno); bitno++; cnt = CLK_DIV; if (bitno == 8) state = 3; } }
        else if (state == 3) { if (--cnt == 0) { bytes.push_back(cur); state = 0; } }  // stop bit
        prev_tx = tx;
        if (bytes.size() >= 3 && bytes[bytes.size()-3] == 'E' && bytes[bytes.size()-2] == 'N' && bytes[bytes.size()-1] == 'D') { frames++; if (frames == 1) break; }
    }
    for (int i = 0; i < 200; i++) tick();               // let the trailer state update chk_ok / LEDs
    int leds = dut->led_n;
    fprintf(stderr, "led_n = %d%d%d (active low: [1]=0 means checksum LED ON)\n", (leds>>2)&1, (leds>>1)&1, leds&1);
    fprintf(stderr, "cycles=%lld uart bytes=%zu por+decode done\n", cycles, bytes.size());
    if (bytes.size() && bytes.size() < 64) { fprintf(stderr, "first bytes:"); for (size_t i = 0; i < bytes.size(); i++) fprintf(stderr, " %02x", bytes[i]); fprintf(stderr, "\n"); }
    // BENCH build: A5 5A 'B' 'N' 'C' W H CLOCKS CHK ERR 'E' 'N' 'D' - compare the checksum with the golden image
    for (size_t j = 0; j + 21 <= bytes.size(); j++) {
        if (!(bytes[j] == 0xA5 && bytes[j+1] == 0x5A && bytes[j+2] == 'B' && bytes[j+3] == 'N' && bytes[j+4] == 'C')) continue;
        const unsigned char* r = &bytes[j + 5];
        int W = (r[0] << 8) | r[1], H = (r[2] << 8) | r[3];
        unsigned clocks = (r[4] << 24) | (r[5] << 16) | (r[6] << 8) | r[7], rchk = (r[8] << 24) | (r[9] << 16) | (r[10] << 8) | r[11];
        int rerr = (r[12] << 8) | r[13];
        std::ifstream gf(argv[1], std::ios::binary); std::vector<unsigned char> g((std::istreambuf_iterator<char>(gf)), std::istreambuf_iterator<char>());
        // golden checksum: P6 (or P5 = grey, replicated to RGB)
        size_t p = 0; int f = 0, gw = 0, gh = 0; std::string tok; bool p5 = g.size() > 1 && g[1] == '5';
        while (f < 4 && p < g.size()) { if (isspace(g[p])) { if (!tok.empty()) { if (f == 1) gw = atoi(tok.c_str()); if (f == 2) gh = atoi(tok.c_str()); f++; tok.clear(); } } else tok += g[p]; p++; }
        unsigned gchk = 0;
        for (int y = 0; y < gh; y++) for (int x = 0; x < gw; x++) {
            size_t k = (size_t)y * gw + x; unsigned c0, c1, c2;
            if (p5) c0 = c1 = c2 = g[p + k]; else { c0 = g[p + 3*k]; c1 = g[p + 3*k + 1]; c2 = g[p + 3*k + 2]; }
            gchk += (((x ^ y) & 0xFF) << 24) | (c0 << 16) | (c1 << 8) | c2;
        }
        fprintf(stderr, "BENCH report: %dx%d, %u clocks (%.3f clocks/pixel), checksum 0x%08X (golden 0x%08X), err 0x%03x\n",
                W, H, clocks, (double)clocks / (W * H), rchk, gchk, rerr);
        bool led_ok = ((leds >> 1) & 1) == 0;
        if (rchk == gchk && W == gw && H == gh && rerr == 0 && led_ok) { fprintf(stderr, "PASS: benchmark report checksum matches golden, checksum LED on\n"); return 0; }
        fprintf(stderr, "FAIL: benchmark report\n"); return 1;
    }
    // parse
    size_t i = 0; while (i + 9 <= bytes.size() && !(bytes[i] == 0xA5 && bytes[i+1] == 0x5A && bytes[i+2] == 'J' && bytes[i+3] == 'P' && bytes[i+4] == 'G')) i++;
    if (i + 9 > bytes.size()) { fprintf(stderr, "FAIL: no frame header\n"); return 1; }
    int W = (bytes[i+5] << 8) | bytes[i+6], H = (bytes[i+7] << 8) | bytes[i+8]; i += 9;
    std::vector<unsigned char> img((size_t)W * H * 3, 0), seen((size_t)W * H, 0); long long npx = 0;
    while (i + 3 <= bytes.size() && !(bytes[i] == 'E' && bytes[i+1] == 'N' && bytes[i+2] == 'D')) {
        if (i + 7 > bytes.size()) break;
        int x = (bytes[i] << 8) | bytes[i+1], y = (bytes[i+2] << 8) | bytes[i+3];
        if (x < W && y < H) { size_t k = (size_t)y * W + x; img[3*k] = bytes[i+4]; img[3*k+1] = bytes[i+5]; img[3*k+2] = bytes[i+6]; seen[k] = 1; npx++; }
        i += 7;
    }
    fprintf(stderr, "frame %dx%d, %lld pixels\n", W, H, npx);
    std::string hdr = "P6\n" + std::to_string(W) + " " + std::to_string(H) + "\n255\n";
    std::vector<unsigned char> out(hdr.begin(), hdr.end()); out.insert(out.end(), img.begin(), img.end());
    std::ofstream(argv[2], std::ios::binary).write((const char*)out.data(), out.size());
    std::ifstream gf(argv[1], std::ios::binary); std::vector<unsigned char> golden((std::istreambuf_iterator<char>(gf)), std::istreambuf_iterator<char>());
    long long missing = 0; for (auto s : seen) if (!s) missing++;
    unsigned chk = 0;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) { size_t k = (size_t)y * W + x; chk += (((x ^ y) & 0xFF) << 24) | (img[3*k] << 16) | (img[3*k+1] << 8) | img[3*k+2]; }
    fprintf(stderr, "pixel checksum of received frame = 0x%08X\n", chk);
    bool led_ok = ((leds >> 1) & 1) == 0;
    if (golden == out && !missing && led_ok) { fprintf(stderr, "PASS: UART frame matches golden and the checksum LED is on\n"); return 0; }
    if (golden == out && !missing) { fprintf(stderr, "FAIL: frame matches but the checksum LED is off (EXPECTED_CHK wrong?)\n"); return 1; }
    fprintf(stderr, "FAIL: mismatch (missing=%lld, sizes %zu vs %zu)\n", missing, out.size(), golden.size()); return 1;
}
