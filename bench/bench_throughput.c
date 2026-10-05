/* bench_throughput.c - one worker of the multi-core throughput run (bench_multicore.py): decodes the
 * given JPEGs, already in memory, one after another and round-robin with the libjpeg API (libjpeg-turbo
 * when linked with -ljpeg): ISLOW IDCT, no fancy upsampling (libjpeg-turbo -nosmooth: the pixels of the
 * FPGA decoder's MCU-order output), RGB out. It runs for at least SECONDS and stops at the end of a
 * whole pass over the files, starting at file OFFSET so that the workers do not decode the same file at
 * the same moment. Prints: decodes, Mpixel, seconds.
 *   bench_tp SECONDS OFFSET file.jpg [file.jpg ...]                                     */
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <jpeglib.h>

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec * 1e-9; }

int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: bench_tp SECONDS OFFSET file.jpg ...\n"); return 2; }
    double secs = atof(argv[1]); int off = atoi(argv[2]), n = argc - 3;
    unsigned char **buf = calloc(n, sizeof *buf); long *len = calloc(n, sizeof *len);
    for (int i = 0; i < n; i++) {
        FILE *f = fopen(argv[3 + i], "rb"); if (!f) { perror(argv[3 + i]); return 1; }
        fseek(f, 0, SEEK_END); len[i] = ftell(f); fseek(f, 0, SEEK_SET);
        buf[i] = malloc(len[i]); if (fread(buf[i], 1, len[i], f) != (size_t)len[i]) return 1; fclose(f);
    }
    unsigned char *out = NULL; size_t cap = 0;
    long decodes = 0; double mpix = 0, t0 = now();
    for (long k = off; ; k++) {
        int i = (int)(k % n);
        struct jpeg_decompress_struct c; struct jpeg_error_mgr e;
        c.err = jpeg_std_error(&e); jpeg_create_decompress(&c);
        jpeg_mem_src(&c, buf[i], len[i]); jpeg_read_header(&c, TRUE);
        c.out_color_space = (c.num_components == 1) ? JCS_GRAYSCALE : JCS_RGB;
        c.dct_method = JDCT_ISLOW; c.do_fancy_upsampling = FALSE;
        jpeg_start_decompress(&c);
        size_t stride = (size_t)c.output_width * c.output_components, need = stride * (c.output_height + 16);
        if (need > cap) { out = realloc(out, need); cap = need; }
        while (c.output_scanline < c.output_height) {
            JSAMPROW rows[16];
            for (int r = 0; r < 16; r++) rows[r] = out + (size_t)(c.output_scanline + r) * stride;
            jpeg_read_scanlines(&c, rows, 16);
        }
        mpix += (double)c.output_width * c.output_height / 1e6;
        jpeg_finish_decompress(&c); jpeg_destroy_decompress(&c);
        decodes++;
        if ((k - off + 1) % n == 0 && now() - t0 >= secs) break;      /* whole passes only */
    }
    printf("decodes=%ld mpix=%.1f seconds=%.3f\n", decodes, mpix, now() - t0);
    return 0;
}
