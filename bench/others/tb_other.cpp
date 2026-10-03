// tb_other.cpp - cycle-exact harness for other FPGA JPEG decoders (not part of this project;
// fetched by fetch.sh into ../../../third_party), same conditions as this project's benchmarks:
// the JPEG offered as fast as the core accepts it (32-bit words, first byte in bits 7:0), every
// pixel accepted at once.  Build with -DCORE_JPEG (ultraembedded core_jpeg, top jpeg_core) or
// -DAQ_DJPEG (H. Ishihara's / AQUAXIS decoder as in ultraembedded/legacy_jpeg_decoder, top aq_djpeg).
//   Vother in.jpg out.ppm [reference.ppm]
// Prints: "cycles=<n> pixels=<n> WxH=<w>x<h> clocks/pixel=<x>" and, with a reference, the
// accuracy: identical values, maximum absolute difference, PSNR.
#include <verilated.h>
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <vector>
#include <string>
#include <fstream>
#if defined(CORE_JPEG)
#include "Vjpeg_core.h"
typedef Vjpeg_core DUT;
#elif defined(AQ_DJPEG)
#include "Vaq_djpeg.h"
typedef Vaq_djpeg DUT;
#endif
static vluint64_t sim_time = 0;
double sc_time_stamp() { return sim_time; }

static bool read_ppm(const std::string& p, int& w, int& h, std::vector<unsigned char>& rgb) {
    std::ifstream f(p, std::ios::binary);
    if (!f) return false;
    std::string m; int mx; f >> m >> w >> h >> mx; f.get();
    std::vector<unsigned char> raw((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    rgb.assign((size_t)w * h * 3, 0);
    for (size_t i = 0; i < (size_t)w * h; i++)
        for (int c = 0; c < 3; c++) rgb[i*3+c] = (m == "P6") ? raw[i*3+c] : raw[i];
    return true;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 3) { fprintf(stderr, "usage: %s in.jpg out.ppm [reference.ppm]\n", argv[0]); return 2; }
    std::ifstream f(argv[1], std::ios::binary);
    std::vector<unsigned char> data((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    size_t nwords = (data.size() + 3) / 4;
    DUT* dut = new DUT;
    auto tick = [&]() {
#if defined(CORE_JPEG)
        dut->clk_i = 0; dut->eval(); sim_time++; dut->clk_i = 1; dut->eval(); sim_time++;
#else
        dut->clk = 0; dut->eval(); sim_time++; dut->clk = 1; dut->eval(); sim_time++;
#endif
    };
#if defined(CORE_JPEG)
    dut->rst_i = 1; dut->inport_valid_i = 0; dut->outport_accept_i = 1;
    for (int i = 0; i < 8; i++) tick();
    dut->rst_i = 0;
#else
    dut->rst = 0; dut->DataInEnable = 0; dut->OutReady = 1;   // active-low reset
    for (int i = 0; i < 8; i++) tick();
    dut->rst = 1;
#endif
    size_t wp = 0; long long cycles = 0, last_px = 0, npx = 0;
    int W = 0, H = 0;
    std::vector<unsigned char> img;
    while (cycles < 400000000LL) {
        uint32_t word = 0; unsigned strb = 0;
        for (int b = 0; b < 4; b++) if (wp * 4 + b < data.size()) { word |= (uint32_t)data[wp * 4 + b] << (8 * b); strb |= 1u << b; }
#if defined(CORE_JPEG)
        // core_jpeg reads a word one byte per clock and ends the word at `last` whatever byte it is
        // on, so `last` stays low and the final word is zero-padded (bytes after EOI are ignored)
        dut->inport_valid_i = wp < nwords; dut->inport_data_i = word; dut->inport_strb_i = 0xF;
        dut->inport_last_i = 0; (void)strb;
        dut->eval();
        bool in_fire = dut->inport_valid_i && dut->inport_accept_o;
        bool px = dut->outport_valid_o;
        int x = dut->outport_pixel_x_o, y = dut->outport_pixel_y_o, r = dut->outport_pixel_r_o,
            g = dut->outport_pixel_g_o, b = dut->outport_pixel_b_o, w = dut->outport_width_o, h = dut->outport_height_o;
#else
        dut->DataInEnable = wp < nwords; dut->DataIn = word;
        dut->eval();
        bool in_fire = dut->DataInEnable && dut->DataInRead;
        bool px = dut->OutEnable;
        int x = dut->OutPixelX, y = dut->OutPixelY, r = dut->OutR, g = dut->OutG, b = dut->OutB,
            w = dut->OutWidth, h = dut->OutHeight;
#endif
        tick(); cycles++;
        if (in_fire) wp++;
        if (px) {
            if (W == 0) { W = w; H = h; img.assign((size_t)W * H * 3, 0); }
            if (x < W && y < H) { size_t k = ((size_t)y * W + x) * 3; img[k] = r; img[k+1] = g; img[k+2] = b; }
            npx++; last_px = cycles;
            if (npx == (long long)W * H) break;
        }
        if (cycles - last_px > 20000000LL && last_px) break;
    }
    printf("cycles=%lld pixels=%lld WxH=%dx%d clocks/pixel=%.3f words_consumed=%zu/%zu\n",
           last_px, npx, W, H, W ? (double)last_px / ((double)W * H) : 0.0, wp, nwords);
    std::ofstream o(argv[2], std::ios::binary);
    o << "P6\n" << W << " " << H << "\n255\n"; o.write((const char*)img.data(), img.size());
    if (argc > 3) {
        int rw, rh; std::vector<unsigned char> ref;
        if (!read_ppm(argv[3], rw, rh, ref) || rw != W || rh != H) { printf("reference: size mismatch or missing\n"); return 1; }
        long long same = 0; int maxd = 0; double se = 0;
        for (size_t i = 0; i < ref.size(); i++) {
            int d = abs((int)img[i] - (int)ref[i]); same += d == 0; maxd = std::max(maxd, d); se += (double)d * d;
        }
        double mse = se / ref.size();
        printf("vs reference: %.2f%% of values identical, max abs diff %d, PSNR %s dB\n",
               100.0 * same / ref.size(), maxd, mse == 0 ? "inf" : std::to_string(10 * log10(255.0 * 255.0 / mse)).c_str());
    }
    delete dut;
    return npx == (long long)W * H && W ? 0 : 1;
}
