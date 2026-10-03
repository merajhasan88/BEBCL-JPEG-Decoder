// tb_multi.cpp - stream several JPEG files back to back through ONE decoder (no reset between
// them) and check every frame: the decoder must not carry state (restart interval, errors) from
// one image into the next.
//   Vmulti [--fmt rgb|ycbcr|y] [--stall N] file1.jpg golden1.pnm|- file2.jpg golden2.pnm|- ...
// "-" = no golden (an unsupported file).  Prints one line per frame:
//   frame <k>: <W>x<H>, <pixels> pixels, err=0x<err>, MATCH | DIFFERS (<n> bytes) | no golden
// and "frames: <n>" at the end.  Exit status 0 when every golden matched.
#include <verilated.h>
#include "Vjpeg_decoder.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <string>
#include <fstream>
#include <algorithm>
static vluint64_t sim_time = 0;
double sc_time_stamp() { return sim_time; }
static bool slurp(const std::string& p, std::vector<unsigned char>& out) {
    std::ifstream f(p, std::ios::binary);
    if (!f) return false;
    out.assign((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    return true;
}
int main(int argc, char** argv) {
    int fmt_code = 0, stall = 0, argi = 1;
    while (argi < argc && !strncmp(argv[argi], "--", 2)) {
        if (!strcmp(argv[argi], "--fmt") && argi + 1 < argc) {
            std::string f = argv[argi + 1]; fmt_code = f == "ycbcr" ? 1 : f == "y" ? 2 : 0; argi += 2;
        } else if (!strcmp(argv[argi], "--stall") && argi + 1 < argc) { stall = atoi(argv[argi + 1]); argi += 2; }
        else { fprintf(stderr, "unknown option %s\n", argv[argi]); return 2; }
    }
    std::vector<unsigned char> data;
    std::vector<std::string> goldens;
    std::vector<size_t> ends;                  // index of each file's last byte (in_last)
    for (; argi + 1 < argc; argi += 2) {
        std::vector<unsigned char> d;
        if (!slurp(argv[argi], d)) { fprintf(stderr, "cannot open %s\n", argv[argi]); return 2; }
        data.insert(data.end(), d.begin(), d.end());
        ends.push_back(data.size() - 1);
        goldens.push_back(argv[argi + 1]);
    }
    Vjpeg_decoder* dut = new Vjpeg_decoder;
    auto tick = [&]() { dut->clk = 0; dut->eval(); sim_time++; dut->clk = 1; dut->eval(); sim_time++; };
    dut->clk = 0; dut->rst = 1; dut->in_valid = 0; dut->in_last = 0; dut->px_ready = 0; dut->out_fmt = fmt_code;
    for (int i = 0; i < 4; i++) tick();
    dut->rst = 0;
    size_t pos = 0; int frame = 0, W = 0, H = 0, fails = 0; long long npx = 0;
    std::vector<unsigned char> img;
    unsigned rng = 777;
    vluint64_t cycles = 0, last = 0;
    while (frame < (int)goldens.size()) {
        bool in_st  = stall && ((rng = rng * 1103515245u + 12345u) >> 16) % 100 < (unsigned)stall;
        bool out_st = stall && ((rng = rng * 1103515245u + 12345u) >> 16) % 100 < (unsigned)stall;
        dut->in_valid = pos < data.size() && !in_st; dut->in_data = pos < data.size() ? data[pos] : 0;
        dut->in_last = std::find(ends.begin(), ends.end(), pos) != ends.end();
        dut->px_ready = !out_st; dut->eval();
        bool in_fire = dut->in_valid && dut->in_ready, px_fire = dut->px_valid && dut->px_ready;
        int x = dut->px_x, y = dut->px_y, c0 = dut->px_c0, c1 = dut->px_c1, c2 = dut->px_c2;
        bool fs = dut->frame_start, fd = dut->frame_done;
        tick(); cycles++;
        if (in_fire) { pos++; last = cycles; }
        if (fs) { W = dut->img_w; H = dut->img_h; img.assign((size_t)W * H * 3, 0); npx = 0; }
        if (px_fire && x < W && y < H) { size_t k = ((size_t)y * W + x) * 3; img[k] = c0; img[k+1] = c1; img[k+2] = c2; npx++; last = cycles; }
        if (fd) {
            std::string g = goldens[frame], verdict = "no golden";
            if (g != "-") {
                std::vector<unsigned char> gd;
                if (!slurp(g, gd)) { verdict = "cannot open golden"; fails++; }
                else {
                    bool one = gd.size() > 1 && gd[1] == '5';
                    std::string hdr = std::string(one ? "P5" : "P6") + "\n" + std::to_string(W) + " " + std::to_string(H) + "\n255\n";
                    std::vector<unsigned char> out(hdr.begin(), hdr.end());
                    for (size_t i = 0; i < (size_t)W * H; i++) {
                        out.push_back(img[i*3]);
                        if (!one) { out.push_back(img[i*3+1]); out.push_back(img[i*3+2]); }
                    }
                    long long diff = 0;
                    for (size_t i = 0; i < std::min(out.size(), gd.size()); i++) diff += out[i] != gd[i];
                    if (out == gd) verdict = "MATCH";
                    else { verdict = "DIFFERS (" + std::to_string(diff) + " bytes)"; fails++; }
                }
            }
            printf("frame %d: %dx%d, %lld pixels, err=0x%04x, %s\n", frame + 1, W, H, npx, (unsigned)dut->err, verdict.c_str());
            frame++;
        }
        if (cycles - last > 2000000ULL) { printf("stalled: no progress for 2M clocks in frame %d\n", frame + 1); fails++; break; }
    }
    printf("frames: %d\n", frame);
    delete dut;
    return fails ? 1 : 0;
}
