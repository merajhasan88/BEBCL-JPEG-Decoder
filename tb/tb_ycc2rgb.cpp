// tb_ycc2rgb.cpp - exhaustive check of jpeg_ycc2rgb against libjpeg's jdcolor.c arithmetic
// for all 2^24 (Y, Cb, Cr) inputs.  Build with -GCC_TURBO=0 or 1; pass the same value as argv[1].
#include <verilated.h>
#include "Vjpeg_ycc2rgb.h"
#include <cstdio>
#include <cstdlib>
static int clamp8(int v) { return v < 0 ? 0 : v > 255 ? 255 : v; }
int main(int argc, char** argv) {
    int turbo = argc > 1 ? atoi(argv[1]) : 0;
    const long FIX_R = 91881, FIX_B = 116130, FIX_GCR = 46802, FIX_GCB = turbo ? 22554 : 22553, HALF = 1L << 15;
    Vjpeg_ycc2rgb* d = new Vjpeg_ycc2rgb;
    long bad = 0;
    for (int cb = 0; cb < 256; cb++) for (int cr = 0; cr < 256; cr++) {
        long xcb = cb - 128, xcr = cr - 128;
        int dr = (int)((FIX_R * xcr + HALF) >> 16);          // Cr_r_tab
        int db = (int)((FIX_B * xcb + HALF) >> 16);          // Cb_b_tab
        int dg = (int)((-FIX_GCB * xcb + HALF + -FIX_GCR * xcr) >> 16);   // Cb_g_tab + Cr_g_tab
        for (int y = 0; y < 256; y++) {
            d->y = y; d->cb = cb; d->cr = cr; d->eval();
            if (d->r != clamp8(y + dr) || d->g != clamp8(y + dg) || d->b != clamp8(y + db)) {
                if (bad < 5) printf("mismatch y=%d cb=%d cr=%d: got %d %d %d want %d %d %d\n", y, cb, cr, d->r, d->g, d->b, clamp8(y+dr), clamp8(y+dg), clamp8(y+db));
                bad++;
            }
        }
    }
    printf("CC_TURBO=%d: %s (%ld mismatches over 16777216 inputs)\n", turbo, bad ? "FAIL" : "PASS", bad);
    delete d; return bad ? 1 : 0;
}
