// cmp_wrap.sv - identical evaluation wrapper for the decoder comparison on the EP2C5: the decoder
// under test gets its input word from a 32-bit shift register fed from a pin (so no input is
// constant), every output pixel is accepted at once (as in this project's board builds) and folded
// into a 32-bit checksum that drives a pin (so no output logic is optimised away).  Four pins in
// total; area and Fmax are then those of the decoder in a board configuration.
//   DUT = 0: this project's fast core (jpeg_decoder FAST=1, MCU order, RGB)
//         1: ultraembedded core_jpeg (SUPPORT_WRITABLE_DHT = DHT)
//         2: H. Ishihara's aq_djpeg
module cmp_wrap #(
  parameter int DUT = 0,
  parameter int DHT = 1
) (
  input  logic clk,
  input  logic rst_n,
  input  logic sin,          // serial input data
  output logic sout          // checksum bit
);
  logic [31:0] word;
  logic [2:0]  rs;
  always_ff @(posedge clk) begin word <= {word[30:0], sin}; rs <= {rs[1:0], rst_n}; end
  wire rst = ~rs[2];
  logic        valid, taken, px;
  logic [15:0] x, y;
  logic [7:0]  r, g, b;
  assign valid = word[31];
  generate
    if (DUT == 0) begin : g_ours
      logic [15:0] w_, h_; logic fs, fd, sof, eol; logic [12:0] err;
      jpeg_decoder #(.FAST(1)) u (
        .clk(clk), .rst(rst), .in_valid(valid), .in_data(word[7:0]), .in_last(1'b0), .in_ready(taken),
        .out_fmt(2'd0), .px_valid(px), .px_ready(1'b1), .px_x(x), .px_y(y),
        .px_c0(r), .px_c1(g), .px_c2(b), .px_sof(sof), .px_eol(eol),
        .img_w(w_), .img_h(h_), .frame_start(fs), .frame_done(fd), .err(err));
    end else if (DUT == 1) begin : g_core_jpeg
      logic [15:0] w_, h_; logic idle;
      jpeg_core #(.SUPPORT_WRITABLE_DHT(DHT)) u (
        .clk_i(clk), .rst_i(rst), .inport_valid_i(valid), .inport_data_i(word), .inport_strb_i(4'hF),
        .inport_last_i(1'b0), .outport_accept_i(1'b1), .inport_accept_o(taken),
        .outport_valid_o(px), .outport_width_o(w_), .outport_height_o(h_),
        .outport_pixel_x_o(x), .outport_pixel_y_o(y), .outport_pixel_r_o(r), .outport_pixel_g_o(g),
        .outport_pixel_b_o(b), .idle_o(idle));
    end else begin : g_aq_djpeg
      logic [15:0] w_, h_; logic idle, prog, req;
      aq_djpeg u (
        .rst(~rst), .clk(clk), .DataIn(word), .DataInEnable(valid), .DataInRead(taken), .DataInReq(req),
        .JpegDecodeIdle(idle), .JpegProgressive(prog), .OutReady(1'b1), .OutEnable(px),
        .OutWidth(w_), .OutHeight(h_), .OutPixelX(x), .OutPixelY(y), .OutR(r), .OutG(g), .OutB(b));
    end
  endgenerate
  logic [31:0] chk;
  always_ff @(posedge clk) begin
    if (rst) chk <= '0;
    else if (px) chk <= chk + {x[7:0] ^ y[7:0], r, g, b} + {31'd0, taken};
    sout <= ^chk;
  end
endmodule
