// blockstats.c - per-block entropy statistics of a baseline JPEG, the input of perf_model.py.
//
// Decodes the Huffman-coded data of the first scan (T.81 F.2.2: DECODE, RECEIVE, run lengths,
// ZRL, EOB) without dequantisation or IDCT, and writes one 20-byte record per block in decoding
// order.  The bit reader fetches bytes only when it needs a bit, so `endpos` is the number of
// file bytes (stuffed zeros and RSTn markers included) that a decoder must have read to finish
// the block.
//
//   cc -O2 -o blockstats blockstats.c
//   blockstats in.jpg out.bin          (prints one JSON line with the frame and scan facts)
//
// APPn/COM segments are skipped by their length (an EXIF thumbnail's own SOI/SOF stays inside
// APP1).  Supported: SOF0/SOF1 with 8-bit tables, 1-4 components, one scan, DRI/RSTn.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct __attribute__((packed)) {
  uint8_t  comp;      // frame component index (0..3)
  uint8_t  flags;     // bit 0: last block of its MCU; bit 1: first block after a restart marker
  uint8_t  nsym;      // Huffman symbols: DC + AC, ZRL and EOB included
  uint8_t  nnz;       // nonzero AC coefficients
  uint8_t  maxk;      // zig-zag index of the last coded AC coefficient (0: DC only)
  uint8_t  nzrl;      // ZRL symbols
  uint16_t bits;      // bits consumed: Huffman codes + magnitude bits
  uint8_t  nlen[8];   // codes of length 9..16
  uint32_t endpos;    // file bytes read when the block is finished
} rec_t;
_Static_assert(sizeof(rec_t) == 20, "record size");

static uint8_t *d; static size_t dn;
static void die(const char *m) { fprintf(stderr, "blockstats: %s\n", m); exit(1); }
static unsigned u16(size_t p) { if (p + 1 >= dn) die("truncated"); return (unsigned)d[p] << 8 | d[p + 1]; }

// ---------------------------------------------------------------- Huffman tables (Annex C, F.2.2.3)
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

// ---------------------------------------------------------------- bit reader (F.2.2.5, F.1.2.3 stuffing)
static size_t pos; static int bitbuf, bitcnt, at_marker; static uint32_t nbits, stuffed;
static int bit(void) {
  if (bitcnt == 0) {
    int b = 0;
    if (!at_marker && pos < dn) {
      if (d[pos] == 0xFF) {
        if (pos + 1 < dn && d[pos + 1] == 0x00) { b = 0xFF; pos += 2; stuffed++; }
        else at_marker = 1;                                         // a marker: zeros from here
      } else b = d[pos++];
    }
    bitbuf = b; bitcnt = 8;
  }
  bitcnt--; nbits++;
  return (bitbuf >> bitcnt) & 1;
}
static int receive(int s) { int v = 0; while (s--) v = v << 1 | bit(); return v; }
static int decode(const htab_t *t, int *len) {
  int code = bit(), l = 1;
  while (code > t->maxcode[l]) { if (++l > 16) die("bad Huffman code"); code = code << 1 | bit(); }
  *len = l;
  return t->val[t->valptr[l] + code - t->mincode[l]];
}

int main(int argc, char **argv) {
  if (argc != 3) { fprintf(stderr, "usage: blockstats in.jpg out.bin\n"); return 2; }
  FILE *f = fopen(argv[1], "rb"); if (!f) die("cannot open input");
  fseek(f, 0, SEEK_END); dn = (size_t)ftell(f); fseek(f, 0, SEEK_SET);
  d = malloc(dn); if (fread(d, 1, dn, f) != dn) die("read"); fclose(f);
  if (dn < 4 || d[0] != 0xFF || d[1] != 0xD8) die("no SOI");

  int W = 0, H = 0, nf = 0, cid[4] = {0}, ch[4] = {0}, cv[4] = {0}, ri = 0, sof = -1, ndht = 0;
  size_t p = 2, appbytes = 0;
  for (;;) {                                                        // B.2.4 segments up to SOS
    while (p < dn && d[p] != 0xFF) p++;
    while (p < dn && d[p] == 0xFF) p++;                             // fill bytes
    if (p >= dn) die("no SOS");
    int m = d[p++];
    if (m == 0xD8 || (m >= 0xD0 && m <= 0xD7)) continue;
    if (m == 0xD9) die("EOI before SOS");
    unsigned len = u16(p); size_t seg = p + 2, end = p + len;
    if (end > dn) die("segment past end of file");
    if ((m >= 0xE0 && m <= 0xEF) || m == 0xFE) appbytes += len + 2;
    if (m == 0xC4) {                                                // B.2.4.2 DHT, several tables
      size_t q = seg;
      while (q < end) {
        int tc = d[q] >> 4, th = d[q] & 15, n = 0; const uint8_t *bits = d + q + 1;
        for (int i = 0; i < 16; i++) n += bits[i];
        if (th > 3 || tc > 1 || n > 256 || q + 17 + n > end) die("bad DHT");
        build(tc ? &ac[th] : &dc[th], bits, d + q + 17, n); q += 17 + n; ndht++;
      }
    } else if (m == 0xC0 || m == 0xC1) {                            // B.2.2 frame header
      sof = m; H = (int)u16(seg + 1); W = (int)u16(seg + 3); nf = d[seg + 5];
      if (d[seg] != 8 || nf < 1 || nf > 4) die("unsupported frame");
      for (int i = 0; i < nf; i++) { cid[i] = d[seg + 6 + 3*i]; ch[i] = d[seg + 7 + 3*i] >> 4; cv[i] = d[seg + 7 + 3*i] & 15; }
    } else if (m >= 0xC2 && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC) {
      die("not a sequential Huffman frame");
    } else if (m == 0xDD) {                                         // B.2.4.4 DRI
      ri = (int)u16(seg);
    } else if (m == 0xDA) {                                         // B.2.3 scan header
      if (sof < 0) die("SOS before SOF");
      int ns = d[seg], sc[4], td[4], ta[4];
      for (int j = 0; j < ns; j++) {
        int c = -1; for (int i = 0; i < nf; i++) if (cid[i] == d[seg + 1 + 2*j]) c = i;
        if (c < 0) die("scan component not in frame");
        sc[j] = c; td[j] = d[seg + 2 + 2*j] >> 4; ta[j] = d[seg + 2 + 2*j] & 15;
        if (!dc[td[j]].valid || !ac[ta[j]].valid) die("missing table");
      }
      int hmax = 1, vmax = 1;
      for (int i = 0; i < nf; i++) { if (ch[i] > hmax) hmax = ch[i]; if (cv[i] > vmax) vmax = cv[i]; }
      long mcux, mcuy;
      if (ns == 1) {                                                // A.2.2 non-interleaved
        mcux = (((long)W * ch[sc[0]] + 8*hmax - 1) / (8*hmax));
        mcuy = (((long)H * cv[sc[0]] + 8*vmax - 1) / (8*vmax));
      } else {
        mcux = (W + 8L*hmax - 1) / (8L*hmax); mcuy = (H + 8L*vmax - 1) / (8L*vmax);
      }
      FILE *o = fopen(argv[2], "wb"); if (!o) die("cannot write output");
      size_t scan0 = end; pos = scan0;
      long nmcu = mcux * mcuy, nblk = 0, nsym_all = 0, nlong = 0, nrst = 0;
      int next_rst = 0;
      for (long mcu = 0; mcu < nmcu; mcu++) {
        int after_rst = 0;
        if (ri && mcu && mcu % ri == 0) {                           // F.2.1.3.1 restart
          bitcnt = 0;                                               // byte-align: drop the fill bits
          if (pos + 1 < dn && d[pos] == 0xFF && d[pos + 1] == (0xD0 + next_rst)) pos += 2;
          else die("restart marker missing");
          next_rst = (next_rst + 1) & 7; at_marker = 0; nrst++; after_rst = 1;
        }
        int nb = 0; for (int j = 0; j < ns; j++) nb += (ns == 1) ? 1 : ch[sc[j]] * cv[sc[j]];
        int b = 0;
        for (int j = 0; j < ns; j++) {
          int reps = (ns == 1) ? 1 : ch[sc[j]] * cv[sc[j]];
          for (int r = 0; r < reps; r++, b++) {
            rec_t rc; memset(&rc, 0, sizeof rc);
            rc.comp = (uint8_t)sc[j];
            rc.flags = (uint8_t)((b == nb - 1) | ((after_rst && b == 0) << 1));
            uint32_t b0 = nbits; int l;
            int s = decode(&dc[td[j]], &l); rc.nsym++; if (l > 8) { rc.nlen[l - 9]++; nlong++; }
            if (s > 11) die("DC magnitude category > 11");
            receive(s);
            for (int k = 1; k < 64; ) {
              int rs = decode(&ac[ta[j]], &l); rc.nsym++; if (l > 8) { rc.nlen[l - 9]++; nlong++; }
              int rr = rs >> 4, ss = rs & 15;
              if (ss == 0) { if (rr == 15) { rc.nzrl++; k += 16; continue; } break; }
              k += rr; if (k > 63) die("AC run past the end of a block");
              receive(ss); rc.nnz++; rc.maxk = (uint8_t)k; k++;
            }
            rc.bits = (uint16_t)(nbits - b0); rc.endpos = (uint32_t)pos;
            nsym_all += rc.nsym; nblk++;
            fwrite(&rc, sizeof rc, 1, o);
          }
        }
      }
      fclose(o);
      size_t q = pos; while (q + 1 < dn && !(d[q] == 0xFF && d[q + 1] != 0x00 && !(d[q + 1] >= 0xD0 && d[q + 1] <= 0xD7))) q++;
      printf("{\"file\": \"%s\", \"bytes\": %zu, \"sof\": %d, \"W\": %d, \"H\": %d, \"comps\": [", argv[1], dn, sof & 15, W, H);
      for (int i = 0; i < nf; i++) printf("%s[%d, %d]", i ? ", " : "", ch[i], cv[i]);
      printf("], \"ns\": %d, \"mcux\": %ld, \"mcuy\": %ld, \"blocks\": %ld, \"ri\": %d, \"rst\": %ld, "
             "\"scan_start\": %zu, \"scan_end\": %zu, \"stuffed\": %u, \"app_bytes\": %zu, \"dht_tables\": %d, "
             "\"bits\": %u, \"symbols\": %ld, \"long_codes\": %ld}\n",
             ns, mcux, mcuy, nblk, ri, nrst, scan0, q, stuffed, appbytes, ndht, nbits, nsym_all, nlong);
      return 0;
    }
    p = end;
  }
}
