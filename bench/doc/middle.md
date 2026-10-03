
## Other FPGA JPEG decoders on the same device family

Open-source FPGA JPEG decoders that are complete, portable and licensed for use: **core_jpeg** by
ultraembedded (Apache-2.0, Verilog, baseline, 4:4:4 / 4:2:0 / grey, no restart markers, no 4:2:2)
and **H. Ishihara's aq_djpeg** (MIT, via ultraembedded/legacy_jpeg_decoder; baseline, all
subsamplings, restart markers). Others were excluded: forks of these two, a VHDL decoder built on
Xilinx-licensed CoreGen modules (not usable on an Intel/Altera device), incomplete student
designs, and HLS libraries for data-centre FPGAs. Their sources are fetched by
`bench/others/fetch.sh` into `../third_party` and are not part of this library.

Method: every decoder is wrapped in the same 4-pin harness (`bench/others/quartus/cmp_wrap.sv`:
input word from a serial pin, every output pixel accepted at once and folded into a checksum on a
pin), compiled with the same Quartus settings for the EP2C5 and, because the others do not fit it,
for the larger Cyclone II EP2C35 (same family and speed grade). Clock counts come from cycle-exact
Verilator simulation on the same files with the input offered as fast as accepted
(`bench/others/tb_other.cpp`, `run_others.py`); accuracy is measured against libjpeg 9e
`djpeg -dct int -nosmooth`, which this decoder reproduces exactly. The other decoders' times use
their own Fmax on the EP2C35; this decoder's times are at the 95 MHz it runs at on the EP2C5 board
(its Fmax on the EP2C35 is 103.8 MHz).
