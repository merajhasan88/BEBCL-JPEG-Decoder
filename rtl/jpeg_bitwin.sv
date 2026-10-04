// jpeg_bitwin.sv - bit accumulator on the entropy-coded data for the fast decoder (T.81 F.2.2.5).
//
// Like libjpeg's get_buffer/bits_left: un-stuffed data bytes enter at the bottom of `acc` (a
// fixed 8-bit shift) and the next bit of the scan is acc[wcnt-1].  Removing bits only lowers
// wcnt, so the consumer (jpeg_huffdec) extracts the bits it needs itself.  A byte is taken
// whenever at least 8 of the 40 bit positions are free, so the window refills to >= 33 valid
// bits: enough for the longest code plus its magnitude (16 + 11).  `acc` keeps 48 bits so
// that bits consumed in one clock can still be read in the next one after a refill.
// A marker token ends the data: it is latched (the parser moves on) and zero bytes are appended
// from then on, like libjpeg's fill_bit_buffer ("premature end of data"); consuming such padding
// bits is flagged on err_pad.  restart_req (held until restart_done) drops the window
// and stray data bytes up to the next marker; an RSTn marker is consumed, any other marker (EOI)
// is reported with err_pad and kept (at_end) - the same behaviour as jpeg_bitreader.
module jpeg_bitwin (
  input  logic        clk,
  input  logic        rst,
  input  logic        clear,          // drop everything (new frame)
  // tokens from the parser
  input  logic        tok_valid,
  input  logic [8:0]  tok_data,
  output logic        tok_ready,
  // window
  output logic [47:0] acc,            // next bit = acc[wcnt-1]
  (* maxfan = 16 *)                   // (drives the bit selectors: duplicated for speed)
  output logic [5:0]  wcnt,           // valid bits (0..40)
  output logic        eod,            // end of data reached (marker latched), zeros follow
  input  logic        consume,
  input  logic [4:0]  n,              // bits removed when consume (0..31)
  // restart handling
  input  logic        restart_req,
  output logic        restart_done,   // one-cycle pulse
  output logic        err_pad,        // one-cycle pulse
  output logic        at_end          // a non-RST marker has been reached: segment over
);
  logic       mk_valid;               // marker token latched
  logic [7:0] mk_code;
  logic       mk_rst;
  assign mk_rst = mk_valid & (mk_code[7:3] == 5'b11010);
  assign eod    = mk_valid;
  assign at_end = mk_valid & ~mk_rst;

  logic [5:0] cnt_c;                  // valid bits after this cycle's consumption
  logic [5:0] real_, real_c;          // bits of the window that are real data (the rest: zero padding)
  logic       over;                   // padding bits consumed
  assign over   = consume && ({1'b0, n} > real_);
  assign cnt_c  = !consume ? wcnt : wcnt - {1'b0, n};     // (the decoder never takes more than wcnt)
  assign real_c = !consume ? real_ : over ? 6'd0 : real_ - {1'b0, n};

  // Tokens pass a 2-entry buffer (hd/hv = its head) whose ready towards the parser is a register,
  // so neither the window count nor the decoder's consume logic reaches the parser.  The parser
  // also uses tok_ready to consume the FF of FF00 / FFxx, so it must not depend on tok_valid.
  // A byte enters the window when 8 positions are free before this cycle's consumption (<= 40
  // bits, refilled to >= 33).  restart_done is registered: the cycle it is high, restart_req is
  // still up but already served.
  logic       b0v, b1v, hv, pop;
  logic [8:0] b0, b1, hd;
  assign tok_ready = ~b1v;
  assign hv = b0v;
  assign hd = b0;
  logic room, take_data, take_zero;
  assign room      = (wcnt <= 6'd32);
  assign take_data = hv & ~hd[8] & ~mk_valid & room & ~restart_req;
  assign take_zero = mk_valid & room & ~restart_req;
  assign pop       = hv & ~mk_valid & (restart_req ? ~restart_done : (hd[8] | room));
  always_ff @(posedge clk) begin
    if (rst || clear) begin
      b0v <= 1'b0; b1v <= 1'b0; b0 <= '0; b1 <= '0;
    end else begin
      case ({tok_valid & ~b1v, pop})
        2'b10: if (!b0v) begin b0v <= 1'b1; b0 <= tok_data; end
               else      begin b1v <= 1'b1; b1 <= tok_data; end
        2'b01: begin b0v <= b1v; b0 <= b1; b1v <= 1'b0; end
        2'b11: if (b1v) begin b0 <= b1; b1 <= tok_data; end
               else     begin b0 <= tok_data; end
        default: ;
      endcase
    end
  end

  always_ff @(posedge clk) begin
    restart_done <= 1'b0; err_pad <= 1'b0;
    if (rst || clear) begin
      acc <= '0; wcnt <= '0; real_ <= '0; mk_valid <= 1'b0; mk_code <= '0;
    end else if (restart_req) begin
      wcnt <= '0; real_ <= '0;
      if (restart_done) ;                                // request already served (see tok_ready)
      else if (mk_valid) begin                           // marker reached
        restart_done <= 1'b1;
        if (mk_rst) mk_valid <= 1'b0;                    // RSTn consumed
        else err_pad <= 1'b1;                            // EOI where RSTn was expected
      end else if (hv && hd[8]) begin
        mk_valid <= 1'b1; mk_code <= hd[7:0];
      end
    end else begin
      if (over) err_pad <= 1'b1;
      if (take_data || take_zero) begin
        acc   <= {acc[39:0], take_data ? hd[7:0] : 8'h00};
        wcnt  <= cnt_c + 6'd8;
        real_ <= take_data ? real_c + 6'd8 : real_c;
      end else begin
        wcnt  <= cnt_c;
        real_ <= real_c;
      end
      if (hv && hd[8] && !mk_valid) begin mk_valid <= 1'b1; mk_code <= hd[7:0]; end
    end
  end
endmodule
