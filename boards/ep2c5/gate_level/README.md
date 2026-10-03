# Gate-level simulation of the post-fit netlist

Goal: run the *exact* netlist that Quartus placed and routed (what `jpeg_fpga.sof` is made of),
not the RTL, to catch synthesis/mapping problems (RAM and DSP inference, register packing,
`$readmemh` ROM initialisation) before touching the board.

## Netlist generation (Quartus 13.0sp1)
`../fpga/jpeg_fpga.qsf` and `../gls/jpeg_gls.qsf` enable the EDA netlist writer, so
`quartus_sh --flow compile <rev>` followed by
`quartus_eda <rev> --simulation --tool=modelsim --format=verilog`
writes `simulation/modelsim/<rev>.vo` (structural Verilog of Cyclone II atoms) and
`<rev>_v.sdo` (SDF delays, slow corner). RAM/ROM contents are embedded as `mem_init0/1`
parameters; the `.mif` files they also reference must be copied next to the netlist
(`run_gls.sh` does this).

* `../fpga` = production build (115200 baud). A whole 64x64 frame takes ~125 M clocks
  because the UART paces the pixel stream, so only a header/first-pixels run is practical.
* `../gls`  = identical except `BAUD=12500000` (4 clocks per bit) and a short
  inter-frame delay, so a complete frame is ~1.3 M clocks.
* `../gls_raster` = the same twin of `../fpga_raster` (raster order, libjpeg-turbo
  smoothing, RGB; 352x32 board image, ~3.4 M clocks per frame).

## ModelSim-Altera Starter Edition (installed with Quartus II 13.0sp1; set `MSIM` to its bin directory)
`run_gls.sh` compiles the netlist + `tb_gls.sv`, applies the SDF, samples `uart_tx`, writes the
received bytes to `uart_bytes.bin` and `scripts/uart_bytes_to_pnm.py` compares them with the
golden image. Setup notes: the installer is `~/Quartus/components/ModelSimSetup-13.0.1.232.run`
(`--mode unattended`), the `vco` script needs the kernel-version patch (done) and the 32-bit
libraries `libxft2:i386 libxext6:i386 libncurses5:i386 libsm6:i386 libx11-6:i386 libxi6:i386
lib32z1 libfreetype6:i386 libfontconfig1:i386 libxrender1:i386` (installed);
`export MTI_VCO_MODE=32`.

**Limitation found:** the Starter Edition throttles designs above ~10 k lines of code, and the
netlist is 36 k lines: measured ~30 clocks/second with timing checks off, i.e. ~12 h for one
frame. It is fine for a few thousand clocks (reset, first UART bytes) but not for full frames.

## Icarus Verilog (`gls/icarus/`)
`iverilog -g2012 -o sim_gls -s tb_gls -Ttyp <rev>.vo cycloneii_atoms.v ../tb_gls.sv` compiles the
netlist, the *unmodified* atom library and the SDF (`$sdf_annotate` inside the .vo) without
complaint, but with timing annotation it runs at ~50 clocks per second - use it for short
timing-annotated windows, not for frames. `run_icarus_sdf.sh` does exactly that: the
production netlist (`../fpga`, real 115200 baud) with slow-corner SDF delays through
power-on reset, ROM start-up, header parsing and the first pixel. Result (113 392 clocks,
~35 min): `ff a5 5a 4a 50 47 00 40 00 40 00 00` on the UART - a start-bit artefact while the
pads leave reset, then the exact frame header (64x64) and the start of pixel (0,0).

## Verilator zero-delay gate-level run (`gls/verilator/`) - the practical flow
Verilator cannot digest the vendor's atom library as is (unnamed instances, switch-level I/O
buffers, gate primitives with constants, the `$sdf_annotate` PLI call, and its RAM-block model
is so event-heavy that it runs at ~300 clocks/s).  `cycloneii_cells.v` holds independent,
zero-delay behavioural models of the eight cell types the netlists use - `cycloneii_lcell_comb`
(LUT4 mask + carry), `cycloneii_lcell_ff` (DFF with ena/sclr/sload/aclr), `cycloneii_ram_block`
(M4K dual-port/ROM, contents from the `mem_init0/1` parameters, old data on a simultaneous
read/write), `cycloneii_mac_mult` / `cycloneii_mac_out` (18x18 multiplier with optional
registers), `cycloneii_clkctrl` (clock select + enable) and plain pads - written for this project
from the Cyclone II Device Handbook, not derived from the vendor's library (which may not be
redistributed).  They reproduce the earlier results exactly (MCU build: checksum 0xD49C70EF;
raster build: 0x7809898C in 3,388,467 clocks).  `prepare_netlist.py`
rewrites the .vo mechanically (I/O cells split into `cycloneii_io_in/out` by
`operation_mode`, `[n]` in escaped instance names replaced, bit-select output connections
routed through named wires, `$sdf_annotate` commented out) and `run_verilator_gls.sh` runs
the ordinary `../sim/tb_fpga.cpp` testbench against it at ~45 000 clocks/s:

```sh
cd boards/ep2c5/gate_level/verilator
./run_verilator_gls.sh ../../gls jpeg_gls ../../../../tb/golden/adp_64x64_q25_420.box.rgb.pnm
./run_verilator_gls.sh ../../gls_fast jpeg_gls ../../../../tb/golden/adp_64x64_q25_420.box.rgb.pnm
./run_verilator_gls.sh ../../gls_raster jpeg_gls_raster ../../../../tb/golden/board_352x32_q6_420.fancy.rgb.pnm 8000000
```
Copy `../<rev>/db/*.mif` to `../<rev>/simulation/modelsim/db/` first (the .vo refers to
them relatively; `run_gls.sh` does this for ModelSim).  `gls` and `gls_fast` share the revision name
`jpeg_gls`, so they reuse `obj_jpeg_gls` (run them one after the other).  Results (2026-10-01, RTL
with header validation, CHECKS=1, and the corpus ROM images): all three netlists decode their frame
bit-exactly - `gls` and `gls_fast` the 64x64 image (checksum 0x10137ECE, LED on), `gls_raster` the
352x32 strip with Pillow-exact smoothing (checksum 0x3C7A89E2 = Pillow's decode, 3,386,104 clocks
including power-on reset and the UART).  `gls_fast` is the first gate-level run of the fast core. Re-run 2026-10-04 after the move to `boards/ep2c5/`: the same
results (`verilator/gls_2026-10-04.txt`).
Timing is *not* simulated here (that is what the Quartus TimeQuest report is for: single clock,
+3 ns setup slack, all inputs synchronised); the functionality of the placed-and-routed netlist
is. First result: the frame decoded bit-exactly with the same clock count as the RTL, and the
run exposed a real bitstream bug - `EXPECTED_CHK` had been passed to Quartus as a Verilog
literal in the .qsf, which Quartus 13 takes as a *string* (see the main README).
