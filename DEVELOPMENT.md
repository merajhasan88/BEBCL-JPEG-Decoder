# Pasha-development

This branch is the full working tree behind the Pasha library. The `main` branch (the library) is
exported from it by `scripts/export_pasha.py` and is a strict subset, so every file of `main` is
developed and verified here first.

## What is only here

| path | contents |
|---|---|
| `FAST_STATUS.md` | design of the fast core (`FAST=1`), timing-closure history on the EP2C5, verification log, open items |
| `test_images/` | all of the owner's test photos (12 phone photos; `main` has `adapter.jpg` only) for runs on other boards |
| `boards/ep2c5/gate_level/` | gate-level simulation of the post-fit netlists (Verilator with this project's own Cyclone II cell models, Icarus + SDF, ModelSim-ASE) |
| `boards/ep2c5/gls*/` | fast-UART twins of the EP2C5 builds, for the gate-level runs |
| `boards/ep2c5/fpga_jtag_dbg/` | `fpga_jtag` at 50 MHz (PLL 1/1), used while bringing up the JTAG harness |
| `quartus/core`, `quartus/fpga_fast_raster` | the decoder alone (does not fit the EP2C5 Web Edition flow) and the fast raster core on a Cyclone IV EP4CE10 |
| `tb/regression_*.txt`, `tb/*.txt` | regression logs cited by `FAST_STATUS.md` |
| `boards/ep2c5/*/build_status.txt` | notes of earlier builds |

## Updating `main`

```sh
cd tb && make && make test                      # 1,616 + 80 + 416 runs must pass (check for PASS lines)
git add -A && git commit                        # on Pasha-development
python3 scripts/export_pasha.py ../Pasha        # ../Pasha is the worktree of main
cd ../Pasha && git add -A && git commit
```
After RTL changes also re-fit the EP2C5 builds (`boards/ep2c5/compile_all.sh`): `fpga_raster` uses
99 % of the device, so any growth on the raster path can break it.

## RTL conventions

* The SystemVerilog-2005 subset that Quartus II 13.0sp1 accepts: no size casts (`32'(x)`), no
  `string` parameters, no part-selects of parameters, `import pkg::*;` inside the module body,
  `integer` loop variables, `always_ff` with synchronous reset, RAMs in the `jpeg_sdp_ram` style so
  they infer into block RAM, `(* multstyle = "dsp" *)` on the multiplies that must use DSP blocks.
* Declare every signal before its first use (Vivado and stricter tools warn about implicit nets).
* Every arithmetic detail follows the reference libraries - libjpeg 9e (`jidctint.c`,
  `jdcolor.c`, `jdsample.c`) for the default profile, libjpeg-turbo 2.1 (`jdsample.c` fancy
  upsampling, `FIX(0.34414)`) for `FANCY_UPSAMPLE`/`CC_TURBO` - so the golden comparisons stay
  exact; if you change arithmetic, change `model/jpeg_golden.py` too and re-run
  `scripts/compare_refs.py` and `make test`.
* Comment with T.81 section numbers (B.2.x headers, C Huffman tables, F.2.2 decode procedures).
* `set_parameter` values in a `.qsf` must be plain decimal integers (Quartus 13 turns a Verilog
  literal into a string without warning).
* Keep the RTL vendor-neutral: inferred RAMs/ROMs/multipliers only; Quartus attributes are fine as
  hints. Vendor primitives (PLLs, clock buffers, JTAG) belong in `boards/<board>/`.
* Test images: generate with libjpeg-turbo `cjpeg -baseline ...` (without `-baseline`, quality
  below ~25 silently produces SOF1 files with 16-bit tables, which are unsupported). Files in the
  repository come only from the owner's photos.
