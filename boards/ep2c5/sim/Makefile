# Verilator simulations of the EP2C5 board harnesses (the decoder RTL is in ../../../rtl).
#   make jtag      -> obj_jtag/Vjtag: ../rtl/jtag_stream_core.sv with the gated clock buffer modelled
#                     (jtag_sim_top.sv), driven by tb_jtag.cpp
#   ./run_board_sim.sh FAST BENCH [WORKDIR]  -> whole board design (ROM -> decoder -> UART), tb_fpga.cpp
DEC   := ../../../rtl
TOPS  := ../rtl
RTL   := $(addprefix $(DEC)/,jpeg_pkg.sv jpeg_sdp_ram.sv jpeg_blockram.sv jpeg_parser.sv jpeg_bitreader.sv \
           jpeg_coefdec.sv jpeg_idct.sv jpeg_ycc2rgb.sv jpeg_pixgen.sv jpeg_raster.sv jpeg_dec_small.sv \
           jpeg_bitwin.sv jpeg_huffdec.sv jpeg_idct_fast.sv jpeg_mcuout.sv jpeg_raster_fast.sv jpeg_dec_fast.sv \
           jpeg_decoder.sv)

jtag: obj_jtag/Vjtag

obj_jtag/Vjtag: $(RTL) $(TOPS)/jtag_stream_core.sv jtag_sim_top.sv tb_jtag.cpp
	verilator -Wno-fatal -Wno-lint -Wno-style --top-module jtag_sim_top -O2 --x-assign fast --x-initial fast \
	  -Mdir obj_jtag -cc $(RTL) $(TOPS)/jtag_stream_core.sv jtag_sim_top.sv --exe tb_jtag.cpp -o Vjtag > obj_jtag.log 2>&1 || (cat obj_jtag.log; false)
	$(MAKE) -s -j2 -C obj_jtag -f Vjtag_sim_top.mk Vjtag

clean:
	rm -rf obj_jtag obj_jtag.log

.PHONY: jtag clean
