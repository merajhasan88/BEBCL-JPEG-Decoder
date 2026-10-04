// syncstats.c - measurements for the two research tracks of ROADMAP.md on one baseline JPEG.
//
// Proposal A (split one scan without restart markers): Huffman codes tend to fall back into step
// after a decoder starts at a wrong bit (Klein & Wiseman 2003; Weissenberger & Schmidt 2021). The
// true decode of the scan records, at every symbol start, the bit position and the decoder state
// (block of the MCU b, zig-zag index z: z = 0 means a DC code is next). A speculative decoder then
// starts at random bit positions with a guessed state and decodes until it reaches a symbol start of
// the true decode in the same state; from there on it decodes exactly like the true decoder. The
// distance (bits, symbols) is what a decoder that starts in the middle of the stream must overlap.
//   guess "mcu0": b = 0, z = 0 (the first block of an MCU, a DC code next; the GPU paper's guess)
//   guess "best": the best of the MCU's nb phases b = 0..nb-1 with z = 0 (nb decoders, or retries)
// An invalid code advances the speculative decoder by one bit; an AC run past the block ends it.
//
// Proposal B (more than one symbol per clock): per symbol, the code length L and the magnitude bits
// S (n = L + S bits); a greedy multi-symbol decoder that takes up to k symbols per clock while their
// codes are table hits (L <= 8) and the n of the clock's symbols fit in a W-bit window; a longer code
// costs LONG clocks (the wide core: 6) on its own. Prints the clocks per symbol for k = 1..4.
//
//   cc -O2 -o syncstats syncstats.c
//   syncstats in.jpg [samples]          (one JSON line; the default is 2000 start positions)
//
// Supported: SOF0/SOF1 with 8-bit tables, 1-4 components, one interleaved scan, no restart interval
// (with restart markers a scan is split at the markers instead).
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint8_t *d; static size_t dn;
static void die(const char *m) { fprintf(stderr, "syncstats: %s\n", m); exit(1); }
static unsigned u16(size_t p) { if (p + 1 >= dn) die("truncated"); return (unsigned)d[p] << 8 | d[p + 1]; }

typedef struct { int valid; int32_t maxcode[18], valptr[17], mincode[17]; uint8_t val[256]; } htab_t;
static htab_t dc[4], ac[4];
static void build(htab_t *t, const uint8_t *bits, const uint8_t *val, int nval) {
  memset(t, 0, sizeof *t); t->valid = 1; memcpy(t->val, val, nval);
  int code = 0, k = 0;
  for (int l = 1; l <= 16; l++) {
    if (bits[l - 1]) { t->valptr[l] = k; t->mincode[l] = code; code += bits[l - 1]; k += bits[l - 1]; t->maxcode[l] = code - 1; }
    else t->maxcode[l] = -1;
    code <<= 1;
  }
  t->maxcode[17] = 0x7fffffff;
}

// ---------------------------------------------------------------- the scan's bits, stuffing removed
static uint8_t *sb; static uint64_t nbits_scan;
static inline int bitat(uint64_t p) { return p < nbits_scan ? (sb[p >> 3] >> (7 - (p & 7))) & 1 : 0; }
// one Huffman decode at bit p: the symbol, or -1 for no code of up to 16 bits; *len = code length
static int hdec(const htab_t *t, uint64_t p, int *len) {
  int code = bitat(p), l = 1;
  while (code > t->maxcode[l]) { if (++l > 16) { *len = 0; return -1; } code = code << 1 | bitat(p + l - 1); }
  *len = l;
  return t->val[t->valptr[l] + code - t->mincode[l]];
}

// the MCU's blocks: table indices per block
static int nb, blk_td[40], blk_ta[40];

// ---------------------------------------------------------------- the true decode
static uint32_t *tpos; static uint16_t *tst; static uint8_t *tL, *tS; static size_t nsym, cap;
static void rec(uint64_t p, int b, int z, int L, int S) {
  if (nsym == cap) {
    cap = cap ? 2 * cap : 1 << 20;
    tpos = realloc(tpos, cap * 4); tst = realloc(tst, cap * 2); tL = realloc(tL, cap); tS = realloc(tS, cap);
    if (!tpos || !tst || !tL || !tS) die("out of memory");
  }
  tpos[nsym] = (uint32_t)p; tst[nsym] = (uint16_t)(b << 6 | z); tL[nsym] = (uint8_t)L; tS[nsym] = (uint8_t)S; nsym++;
}
static long find(uint64_t p) {                   // index of the true symbol starting at bit p, or -1
  size_t lo = 0, hi = nsym;
  while (lo < hi) { size_t m = (lo + hi) / 2; if (tpos[m] < p) lo = m + 1; else hi = m; }
  return (lo < nsym && tpos[lo] == p) ? (long)lo : -1;
}

// ---------------------------------------------------------------- a speculative decoder
// decodes from bit p in state (b, z) until it meets the true decode; returns the bits to that point
// (and the symbols in *ns), or -1 when it has not met it within lim bits
static long spec(uint64_t p0, int b, int z, long lim, long *ns) {
  uint64_t p = p0; long n = 0;
  while ((long)(p - p0) <= lim && p < nbits_scan) {
    long i = find(p);
    if (i >= 0 && tst[i] == (uint16_t)(b << 6 | z)) { *ns = n; return (long)(p - p0); }
    int L, s = hdec(z == 0 ? &dc[blk_td[b]] : &ac[blk_ta[b]], p, &L);
    n++;
    if (s < 0) { p++; continue; }                 // no code here: one bit on
    p += L;
    if (z == 0) {                                 // DC: S magnitude bits, then the block's AC codes
      p += (s > 11 ? 0 : s); z = 1;
    } else {
      int r = s >> 4, S = s & 15;
      if (S == 0) {
        if (r == 15) { z += 16; if (z > 63) { z = 0; b = (b + 1) % nb; } }
        else { z = 0; b = (b + 1) % nb; }         // EOB
      } else {
        z += r; p += S;
        if (z > 63) { z = 0; b = (b + 1) % nb; }  // run past the block (garbage): next block
        else if (++z > 63) { z = 0; b = (b + 1) % nb; }
      }
    }
  }
  *ns = n; return -1;
}

static int cmpl(const void *a, const void *b) { long x = *(const long *)a, y = *(const long *)b; return (x > y) - (x < y); }
static uint64_t rng = 0x9E3779B97F4A7C15ull;
static uint64_t rnd(void) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return rng; }

int main(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "usage: syncstats in.jpg [samples]\n"); return 2; }
  int K = argc > 2 ? atoi(argv[2]) : 2000;
  FILE *f = fopen(argv[1], "rb"); if (!f) die("cannot open input");
  fseek(f, 0, SEEK_END); dn = (size_t)ftell(f); fseek(f, 0, SEEK_SET);
  d = malloc(dn); if (fread(d, 1, dn, f) != dn) die("read"); fclose(f);
  if (dn < 4 || d[0] != 0xFF || d[1] != 0xD8) die("no SOI");
  int W = 0, H = 0, nf = 0, cid[4] = {0}, ch[4] = {0}, cv[4] = {0}, ri = 0, sof = -1;
  size_t p = 2;
  for (;;) {                                                        // B.2.4 segments up to SOS
    while (p < dn && d[p] != 0xFF) p++;
    while (p < dn && d[p] == 0xFF) p++;
    if (p >= dn) die("no SOS");
    int m = d[p++];
    if (m == 0xD8 || (m >= 0xD0 && m <= 0xD7)) continue;
    if (m == 0xD9) die("EOI before SOS");
    unsigned len = u16(p); size_t seg = p + 2, end = p + len;
    if (end > dn) die("segment past end of file");
    if (m == 0xC4) {
      size_t q = seg;
      while (q < end) {
        int tc = d[q] >> 4, th = d[q] & 15, n = 0; const uint8_t *bits = d + q + 1;
        for (int i = 0; i < 16; i++) n += bits[i];
        if (th > 3 || tc > 1 || n > 256 || q + 17 + n > end) die("bad DHT");
        build(tc ? &ac[th] : &dc[th], bits, d + q + 17, n); q += 17 + n;
      }
    } else if (m == 0xC0 || m == 0xC1) {
      sof = m; H = (int)u16(seg + 1); W = (int)u16(seg + 3); nf = d[seg + 5];
      if (d[seg] != 8 || nf < 1 || nf > 4) die("unsupported frame");
      for (int i = 0; i < nf; i++) { cid[i] = d[seg + 6 + 3*i]; ch[i] = d[seg + 7 + 3*i] >> 4; cv[i] = d[seg + 7 + 3*i] & 15; }
    } else if (m >= 0xC2 && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC) {
      die("not a sequential Huffman frame");
    } else if (m == 0xDD) {
      ri = (int)u16(seg);
    } else if (m == 0xDA) {
      if (sof < 0) die("SOS before SOF");
      if (ri) die("restart interval: split at the markers instead");
      int ns = d[seg];
      if (ns < 2 && nf > 1) die("non-interleaved scan");
      nb = 0;
      for (int j = 0; j < ns; j++) {
        int c = -1; for (int i = 0; i < nf; i++) if (cid[i] == d[seg + 1 + 2*j]) c = i;
        if (c < 0) die("scan component not in frame");
        int td = d[seg + 2 + 2*j] >> 4, ta = d[seg + 2 + 2*j] & 15;
        if (!dc[td].valid || !ac[ta].valid) die("missing table");
        int reps = (ns == 1) ? 1 : ch[c] * cv[c];
        for (int r = 0; r < reps; r++) { blk_td[nb] = td; blk_ta[nb] = ta; nb++; }
      }
      int hmax = 1, vmax = 1;
      for (int i = 0; i < nf; i++) { if (ch[i] > hmax) hmax = ch[i]; if (cv[i] > vmax) vmax = cv[i]; }
      long mcux = ns == 1 ? (W + 7) / 8 : (W + 8L*hmax - 1) / (8L*hmax);
      long mcuy = ns == 1 ? (H + 7) / 8 : (H + 8L*vmax - 1) / (8L*vmax);
      // un-stuff the entropy-coded segment (F.1.2.3) up to the first marker
      sb = malloc(dn); size_t n8 = 0, q = end;
      while (q < dn) {
        if (d[q] == 0xFF) { if (q + 1 < dn && d[q + 1] == 0x00) { sb[n8++] = 0xFF; q += 2; continue; } break; }
        sb[n8++] = d[q++];
      }
      nbits_scan = (uint64_t)n8 * 8;
      // the true decode
      uint64_t bp = 0;
      for (long mcu = 0; mcu < mcux * mcuy; mcu++)
        for (int b = 0; b < nb; b++) {
          int L, s = hdec(&dc[blk_td[b]], bp, &L);
          if (s < 0 || s > 11) die("bad DC code");
          rec(bp, b, 0, L, s); bp += L + s;
          for (int k = 1; k < 64; ) {
            s = hdec(&ac[blk_ta[b]], bp, &L);
            if (s < 0) die("bad AC code");
            int r = s >> 4, S = s & 15;
            rec(bp, b, k, L, S); bp += L + S;
            if (S == 0) { if (r == 15) { k += 16; continue; } break; }
            k += r; if (k > 63) die("AC run past the end of a block");
            k++;
          }
        }
      // Proposal A: speculative decoders from random bit positions
      long lim = 1L << 20;
      long *dA = malloc(K * sizeof(long)), *dB = malloc(K * sizeof(long)), *sA = malloc(K * sizeof(long));
      long failA = 0, failB = 0;
      for (int i = 0; i < K; i++) {
        uint64_t s0 = rnd() % (bp > 4096 ? bp - 4096 : 1);
        long ns, a = spec(s0, 0, 0, lim, &ns);
        if (a < 0) { failA++; a = lim; }
        dA[i] = a; sA[i] = ns;
        long best = -1;
        for (int b0 = 0; b0 < nb; b0++) { long t = spec(s0, b0, 0, best < 0 ? lim : best, &ns); if (t >= 0 && (best < 0 || t < best)) best = t; }
        if (best < 0) { failB++; best = lim; }
        dB[i] = best;
      }
      qsort(dA, K, sizeof(long), cmpl); qsort(dB, K, sizeof(long), cmpl); qsort(sA, K, sizeof(long), cmpl);
      double mA = 0, mB = 0; for (int i = 0; i < K; i++) { mA += dA[i]; mB += dB[i]; } mA /= K; mB /= K;
      // Proposal B: code lengths and the greedy k-symbols-per-clock decoder
      long hist_n[32] = {0}, nlong = 0;
      for (size_t i = 0; i < nsym; i++) { int n = tL[i] + tS[i]; hist_n[n < 31 ? n : 31]++; if (tL[i] > 8) nlong++; }
      const int LONG = 6, Ws[3] = {32, 48, 64};
      double cps[3][5];
      for (int wi = 0; wi < 3; wi++)
        for (int k = 1; k <= 4; k++) {
          long clocks = 0; size_t i = 0;
          while (i < nsym) {
            if (tL[i] > 8) { clocks += LONG; i++; continue; }
            clocks++; int used = tL[i] + tS[i], c = 1; i++;
            while (c < k && i < nsym && tL[i] <= 8 && used + tL[i] + tS[i] <= Ws[wi]) { used += tL[i] + tS[i]; c++; i++; }
          }
          cps[wi][k] = (double)clocks / nsym;
        }
      printf("{\"file\": \"%s\", \"W\": %d, \"H\": %d, \"blocks_per_mcu\": %d, \"scan_bits\": %llu, \"symbols\": %zu, "
             "\"symbols_per_pixel\": %.4f, \"long_codes\": %ld, \"samples\": %d, ",
             argv[1], W, H, nb, (unsigned long long)bp, nsym, (double)nsym / ((double)W * H), nlong, K);
      printf("\"sync_mcu0_bits\": {\"median\": %ld, \"mean\": %.1f, \"p90\": %ld, \"p99\": %ld, \"max\": %ld, \"none\": %ld}, ",
             dA[K / 2], mA, dA[K * 9 / 10], dA[K * 99 / 100], dA[K - 1], failA);
      printf("\"sync_mcu0_symbols\": {\"median\": %ld, \"p99\": %ld, \"max\": %ld}, ", sA[K / 2], sA[K * 99 / 100], sA[K - 1]);
      printf("\"sync_best_bits\": {\"median\": %ld, \"mean\": %.1f, \"p90\": %ld, \"p99\": %ld, \"max\": %ld, \"none\": %ld}, ",
             dB[K / 2], mB, dB[K * 9 / 10], dB[K * 99 / 100], dB[K - 1], failB);
      printf("\"n_hist\": [");
      for (int i = 0; i < 32; i++) printf("%s%ld", i ? ", " : "", hist_n[i]);
      printf("], \"clocks_per_symbol\": {");
      for (int wi = 0; wi < 3; wi++) {
        printf("%s\"W%d\": [", wi ? ", " : "", Ws[wi]);
        for (int k = 1; k <= 4; k++) printf("%s%.4f", k > 1 ? ", " : "", cps[wi][k]);
        printf("]");
      }
      printf("}}\n");
      return 0;
    }
    p = end;
  }
}
