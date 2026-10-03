
#### adp 64x64 q25 420: 64x64 (0.00 Mpixel)

| decoder | where | clock | ms / image | Mpixel/s | clocks / pixel | energy / image |
|---|---|---:|---:|---:|---:|---:|
| libjpeg-turbo 2.1.2, default (smoothing) | i7-8550U, 1 thread | 3.64 GHz | 0.018 | 232.5 | 15.6 | 0.3 mJ |
| libjpeg-turbo 2.1.2, -nosmooth | i7-8550U, 1 thread | 3.62 GHz | 0.020 | 202.3 | 17.9 | 0.4 mJ |
| FFmpeg 4.4.2 mjpeg decoder, RGB24 out | i7-8550U, 1 thread | 3.71 GHz | 0.032 | 127.7 | 29.1 | - |
| Pillow 9.0.1 (libjpeg-turbo) | i7-8550U, 1 thread | 3.65 GHz | 0.081 | 50.4 | 72.5 | 1.6 mJ |
| OpenCV 4.7 imdecode (libjpeg-turbo) | i7-8550U, 1 thread | 3.66 GHz | 0.035 | 116.9 | 31.3 | 0.6 mJ |
| stb_image v2.27 | i7-8550U, 1 thread | 3.73 GHz | 0.026 | 155.4 | 24.0 | 0.5 mJ |
| libjpeg 9e, -nosmooth | i7-8550U, 1 thread | 3.70 GHz | 0.023 | 177.2 | 20.9 | 0.4 mJ |
| libjpeg 9e, default | i7-8550U, 1 thread | 3.71 GHz | 0.036 | 114.4 | 32.5 | 0.7 mJ |
| model/jpeg_golden.py (pure Python) | i7-8550U, 1 thread | 3.76 GHz | 19.465 | 0.2 | 17867.9 | 397.3 mJ |
| **this decoder**: MCU order, replication, RGB | EP2C5, compact core (`quartus/fpga`) | 50 MHz | 1.128 | 3.63 | 13.77 | 0.1 mJ (est.) |
| **this decoder**: FAST, MCU order, replication, RGB \* | EP2C5, fast core (`quartus/fpga_jtag`) | 95 MHz | 0.061 | 67.32 | 1.41 | 0.0 mJ (est.) |

#### board 352x32 q6 420: 352x32 (0.01 Mpixel)

| decoder | where | clock | ms / image | Mpixel/s | clocks / pixel | energy / image |
|---|---|---:|---:|---:|---:|---:|
| libjpeg-turbo 2.1.2, default (smoothing) | i7-8550U, 1 thread | 3.82 GHz | 0.023 | 483.7 | 7.9 | 0.5 mJ |
| libjpeg-turbo 2.1.2, -nosmooth | i7-8550U, 1 thread | 3.86 GHz | 0.024 | 477.6 | 8.1 | 0.5 mJ |
| FFmpeg 4.4.2 mjpeg decoder, RGB24 out | i7-8550U, 1 thread | 3.50 GHz | 0.047 | 239.4 | 14.6 | - |
| Pillow 9.0.1 (libjpeg-turbo) | i7-8550U, 1 thread | 3.69 GHz | 0.084 | 133.5 | 27.6 | 1.8 mJ |
| OpenCV 4.7 imdecode (libjpeg-turbo) | i7-8550U, 1 thread | 3.65 GHz | 0.044 | 253.2 | 14.4 | 1.0 mJ |
| stb_image v2.27 | i7-8550U, 1 thread | 3.81 GHz | 0.054 | 207.1 | 18.4 | 1.0 mJ |
| libjpeg 9e, -nosmooth | i7-8550U, 1 thread | 3.77 GHz | 0.042 | 269.1 | 14.0 | 0.9 mJ |
| libjpeg 9e, default | i7-8550U, 1 thread | 3.81 GHz | 0.072 | 156.8 | 24.3 | 1.4 mJ |
| model/jpeg_golden.py (pure Python) | i7-8550U, 1 thread | 3.59 GHz | 49.951 | 0.2 | 15928.9 | 1431.5 mJ |
| **this decoder**: MCU order, replication, RGB | EP2C5, compact core (`quartus/fpga`) | 50 MHz | 2.886 | 3.90 | 12.81 | 0.2 mJ (est.) |
| **this decoder**: FAST, MCU order, replication, RGB | EP2C5, fast core (`quartus/fpga_jtag`) | 95 MHz | 0.139 | 81.07 | 1.17 | 0.0 mJ (est.) |

#### scr 320x240 q90 420: 320x240 (0.08 Mpixel)

| decoder | where | clock | ms / image | Mpixel/s | clocks / pixel | energy / image |
|---|---|---:|---:|---:|---:|---:|
| libjpeg-turbo 2.1.2, default (smoothing) | i7-8550U, 1 thread | 3.73 GHz | 0.278 | 276.4 | 13.5 | 5.5 mJ |
| libjpeg-turbo 2.1.2, -nosmooth | i7-8550U, 1 thread | 3.76 GHz | 0.270 | 284.9 | 13.2 | 5.6 mJ |
| FFmpeg 4.4.2 mjpeg decoder, RGB24 out | i7-8550U, 1 thread | 3.89 GHz | 0.315 | 243.7 | 15.9 | - |
| Pillow 9.0.1 (libjpeg-turbo) | i7-8550U, 1 thread | 3.84 GHz | 0.396 | 193.8 | 19.8 | 7.2 mJ |
| OpenCV 4.7 imdecode (libjpeg-turbo) | i7-8550U, 1 thread | 3.89 GHz | 0.387 | 198.6 | 19.6 | 7.1 mJ |
| stb_image v2.27 | i7-8550U, 1 thread | 3.73 GHz | 0.623 | 123.3 | 30.2 | 12.2 mJ |
| libjpeg 9e, -nosmooth | i7-8550U, 1 thread | 3.91 GHz | 0.501 | 153.3 | 25.5 | 9.0 mJ |
| libjpeg 9e, default | i7-8550U, 1 thread | 3.72 GHz | 0.739 | 103.9 | 35.8 | 15.3 mJ |
| **this decoder**: MCU order, replication, RGB | EP2C5, compact core (`quartus/fpga`) | 50 MHz | 22.200 | 3.46 | 14.45 | 1.6 mJ (est.) |
| **this decoder**: FAST, MCU order, replication, RGB \* | EP2C5, fast core (`quartus/fpga_jtag`) | 95 MHz | 1.015 | 75.65 | 1.26 | 0.1 mJ (est.) |

#### donald 2048x1365: 2048x1365 (2.80 Mpixel)

| decoder | where | clock | ms / image | Mpixel/s | clocks / pixel | energy / image |
|---|---|---:|---:|---:|---:|---:|
| libjpeg-turbo 2.1.2, default (smoothing) | i7-8550U, 1 thread | 3.89 GHz | 6.920 | 404.0 | 9.6 | 127.8 mJ |
| libjpeg-turbo 2.1.2, -nosmooth | i7-8550U, 1 thread | 3.88 GHz | 6.871 | 406.9 | 9.5 | 123.6 mJ |
| FFmpeg 4.4.2 mjpeg decoder, RGB24 out | i7-8550U, 1 thread | 3.92 GHz | 19.992 | 139.8 | 28.0 | - |
| Pillow 9.0.1 (libjpeg-turbo) | i7-8550U, 1 thread | 3.90 GHz | 7.870 | 355.2 | 11.0 | 146.2 mJ |
| OpenCV 4.7 imdecode (libjpeg-turbo) | i7-8550U, 1 thread | 3.84 GHz | 16.069 | 174.0 | 22.1 | 288.1 mJ |
| stb_image v2.27 | i7-8550U, 1 thread | 3.89 GHz | 14.348 | 194.8 | 20.0 | 235.5 mJ |
| libjpeg 9e, -nosmooth | i7-8550U, 1 thread | 3.89 GHz | 14.149 | 197.6 | 19.7 | 259.9 mJ |
| libjpeg 9e, default | i7-8550U, 1 thread | 3.89 GHz | 21.704 | 128.8 | 30.2 | 404.5 mJ |
| **this decoder**: MCU order, replication, RGB | EP2C5, compact core (`quartus/fpga`) | 50 MHz | 752.525 | 3.71 | 13.46 | 53.0 mJ (est.) |
| **this decoder**: FAST, MCU order, replication, RGB \* | EP2C5, fast core (`quartus/fpga_jtag`) | 95 MHz | 29.974 | 93.26 | 1.02 | 4.4 mJ (est.) |

#### portrait 1944x2592 444: 1944x2592 (5.04 Mpixel)

| decoder | where | clock | ms / image | Mpixel/s | clocks / pixel | energy / image |
|---|---|---:|---:|---:|---:|---:|
| libjpeg-turbo 2.1.2, default (smoothing) | i7-8550U, 1 thread | 3.77 GHz | 17.773 | 283.5 | 13.3 | 381.1 mJ |
| libjpeg-turbo 2.1.2, -nosmooth | i7-8550U, 1 thread | 3.87 GHz | 16.789 | 300.1 | 12.9 | 323.5 mJ |
| FFmpeg 4.4.2 mjpeg decoder, RGB24 out | i7-8550U, 1 thread | 3.66 GHz | 38.187 | 132.0 | 27.7 | - |
| Pillow 9.0.1 (libjpeg-turbo) | i7-8550U, 1 thread | 3.60 GHz | 21.639 | 232.9 | 15.5 | 416.5 mJ |
| OpenCV 4.7 imdecode (libjpeg-turbo) | i7-8550U, 1 thread | 3.41 GHz | 37.066 | 135.9 | 25.1 | 624.9 mJ |
| stb_image v2.27 | i7-8550U, 1 thread | 3.67 GHz | 48.633 | 103.6 | 35.5 | 1015.3 mJ |
| libjpeg 9e, -nosmooth | i7-8550U, 1 thread | 3.83 GHz | 35.991 | 140.0 | 27.4 | 693.0 mJ |
| libjpeg 9e, default | i7-8550U, 1 thread | 3.90 GHz | 35.740 | 141.0 | 27.7 | 664.6 mJ |
| **this decoder**: MCU order, replication, RGB | EP2C5, compact core (`quartus/fpga`) | 50 MHz | 2118.629 | 2.38 | 21.02 | 149.2 mJ (est.) |
| **this decoder**: FAST, MCU order, replication, RGB \* | EP2C5, fast core (`quartus/fpga_jtag`) | 95 MHz | 88.337 | 57.04 | 1.67 | 13.0 mJ (est.) |

#### adapter 3120x4160 422: 3120x4160 (12.98 Mpixel)

| decoder | where | clock | ms / image | Mpixel/s | clocks / pixel | energy / image |
|---|---|---:|---:|---:|---:|---:|
| libjpeg-turbo 2.1.2, default (smoothing) | i7-8550U, 1 thread | 3.48 GHz | 65.106 | 199.4 | 17.4 | 1089.5 mJ |
| libjpeg-turbo 2.1.2, -nosmooth | i7-8550U, 1 thread | 3.52 GHz | 66.289 | 195.8 | 18.0 | 1098.9 mJ |
| FFmpeg 4.4.2 mjpeg decoder, RGB24 out | i7-8550U, 1 thread | 3.87 GHz | 70.426 | 184.3 | 21.0 | - |
| Pillow 9.0.1 (libjpeg-turbo) | i7-8550U, 1 thread | 3.83 GHz | 85.891 | 151.1 | 25.3 | 1465.0 mJ |
| OpenCV 4.7 imdecode (libjpeg-turbo) | i7-8550U, 1 thread | 3.81 GHz | 98.443 | 131.8 | 28.9 | 1665.7 mJ |
| stb_image v2.27 | i7-8550U, 1 thread | 3.76 GHz | 137.057 | 94.7 | 39.7 | 2314.0 mJ |
| libjpeg 9e, -nosmooth | i7-8550U, 1 thread | 3.77 GHz | 119.094 | 109.0 | 34.6 | 2056.5 mJ |
| libjpeg 9e, default | i7-8550U, 1 thread | 3.76 GHz | 135.280 | 95.9 | 39.1 | 2284.1 mJ |
| **this decoder**: MCU order, replication, RGB | EP2C5, compact core (`quartus/fpga`) | 50 MHz | 4638.696 | 2.80 | 17.87 | 326.6 mJ (est.) |
| **this decoder**: FAST, MCU order, replication, RGB \* | EP2C5, fast core (`quartus/fpga_jtag`) | 95 MHz | 202.465 | 64.11 | 1.48 | 29.7 mJ (est.) |

#### phone 4000x3000 light: 4000x3000 (12.00 Mpixel)

| decoder | where | clock | ms / image | Mpixel/s | clocks / pixel | energy / image |
|---|---|---:|---:|---:|---:|---:|
| libjpeg-turbo 2.1.2, default (smoothing) | i7-8550U, 1 thread | 3.83 GHz | 54.507 | 220.2 | 17.4 | 918.2 mJ |
| libjpeg-turbo 2.1.2, -nosmooth | i7-8550U, 1 thread | 3.84 GHz | 53.913 | 222.6 | 17.3 | 917.1 mJ |
| FFmpeg 4.4.2 mjpeg decoder, RGB24 out | i7-8550U, 1 thread | 3.92 GHz | 67.424 | 178.0 | 22.0 | - |
| Pillow 9.0.1 (libjpeg-turbo) | i7-8550U, 1 thread | 3.82 GHz | 79.010 | 151.9 | 25.2 | 1276.6 mJ |
| OpenCV 4.7 imdecode (libjpeg-turbo) | i7-8550U, 1 thread | 3.71 GHz | 91.644 | 130.9 | 28.4 | 1442.8 mJ |
| stb_image v2.27 | i7-8550U, 1 thread | 3.90 GHz | 109.302 | 109.8 | 35.5 | 1863.0 mJ |
| libjpeg 9e, -nosmooth | i7-8550U, 1 thread | 3.71 GHz | 121.229 | 99.0 | 37.5 | 2069.4 mJ |
| libjpeg 9e, default | i7-8550U, 1 thread | 3.80 GHz | 139.048 | 86.3 | 44.0 | 2364.6 mJ |
| **this decoder**: MCU order, replication, RGB | EP2C5, compact core (`quartus/fpga`) | 50 MHz | 3862.994 | 3.11 | 16.10 | 272.0 mJ (est.) |
| **this decoder**: FAST, MCU order, replication, RGB \* | EP2C5, fast core (`quartus/fpga_jtag`) | 95 MHz | 203.171 | 59.06 | 1.61 | 29.8 mJ (est.) |

#### phone 4000x3000 dense: 4000x3000 (12.00 Mpixel)

| decoder | where | clock | ms / image | Mpixel/s | clocks / pixel | energy / image |
|---|---|---:|---:|---:|---:|---:|
| libjpeg-turbo 2.1.2, default (smoothing) | i7-8550U, 1 thread | 3.77 GHz | 70.082 | 171.2 | 22.0 | 1072.6 mJ |
| libjpeg-turbo 2.1.2, -nosmooth | i7-8550U, 1 thread | 3.64 GHz | 73.385 | 163.5 | 22.2 | 1061.3 mJ |
| FFmpeg 4.4.2 mjpeg decoder, RGB24 out | i7-8550U, 1 thread | 3.68 GHz | 93.242 | 128.7 | 28.6 | - |
| Pillow 9.0.1 (libjpeg-turbo) | i7-8550U, 1 thread | 3.81 GHz | 96.497 | 124.4 | 30.6 | 1438.4 mJ |
| OpenCV 4.7 imdecode (libjpeg-turbo) | i7-8550U, 1 thread | 3.69 GHz | 108.317 | 110.8 | 33.3 | 1733.4 mJ |
| stb_image v2.27 | i7-8550U, 1 thread | 3.74 GHz | 147.450 | 81.4 | 45.9 | 2214.0 mJ |
| libjpeg 9e, -nosmooth | i7-8550U, 1 thread | 3.76 GHz | 135.119 | 88.8 | 42.3 | 2027.4 mJ |
| libjpeg 9e, default | i7-8550U, 1 thread | 3.77 GHz | 163.859 | 73.2 | 51.5 | 2437.9 mJ |
| **this decoder**: MCU order, replication, RGB | EP2C5, compact core (`quartus/fpga`) | 50 MHz | 4348.150 | 2.76 | 18.12 | 306.1 mJ (est.) |
| **this decoder**: FAST, MCU order, replication, RGB \* | EP2C5, fast core (`quartus/fpga_jtag`) | 95 MHz | 283.671 | 42.30 | 2.25 | 41.6 mJ (est.) |

CPU: power profile `performance`, clock = average measured by `perf stat` during each run (cycles / task time); CPU clocks per pixel = time x that clock / pixels.  \* this clock count was also measured on the EP2C5 board (identical to the simulation), see `bench/board_jtag_95mhz.txt`.  FPGA energy: PowerPlay vectorless estimate x decode time (low confidence).

#### The same laptop in its `power-saver` power profile

| image | libjpeg-turbo -nosmooth, `power-saver` | libjpeg-turbo -nosmooth, `performance` | this decoder, EP2C5 fast core @ 95 MHz |
|---|---:|---:|---:|
| adp 64x64 q25 420 | 0.074 ms (0.93 GHz) | 0.020 ms (3.62 GHz) | 0.061 ms |
| board 352x32 q6 420 | 0.099 ms (0.93 GHz) | 0.024 ms (3.86 GHz) | 0.139 ms |
| scr 320x240 q90 420 | 0.987 ms (1.04 GHz) | 0.270 ms (3.76 GHz) | 1.02 ms |
| donald 2048x1365 | 26.46 ms (1.00 GHz) | 6.87 ms (3.88 GHz) | 29.97 ms |
| portrait 1944x2592 444 | 60.08 ms (1.08 GHz) | 16.79 ms (3.87 GHz) | 88.34 ms |
| adapter 3120x4160 422 | 188.79 ms (1.08 GHz) | 66.29 ms (3.52 GHz) | 202.47 ms |
| phone 4000x3000 light | 184.38 ms (1.10 GHz) | 53.91 ms (3.84 GHz) | 203.17 ms |
| phone 4000x3000 dense | 265.06 ms (0.98 GHz) | 73.39 ms (3.64 GHz) | 283.67 ms |
