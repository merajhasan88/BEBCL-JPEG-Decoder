// jpeg_huffdec_wide.sv - entropy decoder of the WIDE build (FAST = 2): one Huffman symbol per clock.
//
// Bit window and block decoder in one module, because the symbol loop runs through both:
//   window D (MSB first: the next bit of the scan is D[63]) -> its top 8 bits address four
//   256-entry lookahead tables (one per {Tc, Th}, read in parallel, selected late by {AC, Th})
//   -> n = L + SSSS (code + magnitude bits, stored in the entry) -> D << n.
// The loop has no shifter in front of the tables and no adder behind them; bytes are merged below
// the valid bits using only registered values (timing probe: model/perf/probes/hufloop_probe2.sv).
//
// Same contracts as jpeg_bitwin + jpeg_huffdec (T.81 F.2.2, F.1.2.3), so the pixels and errors of
// the wide build are those of the others for any input:
//  - tokens (data bytes, FF00 removed, and markers) enter through a 2-entry buffer whose ready is a
//    register; a byte is merged when at most 56 bits are valid; a marker token ends the data: it is
//    latched and zero bytes follow (libjpeg's fill_bit_buffer); consuming such padding bits raises
//    err_pad; restart_req (held until restart_done) drops the window and data up to the next marker,
//    consumes an RSTn, and reports any other marker with err_pad (at_end) - as jpeg_bitwin;
//  - a symbol is decoded when at least 31 bits are valid (any code and magnitude, as jpeg_huffdec);
//    codes longer than 8 bits: MAXCODE (F.2.2.3, Figure F.16) of all lengths 9..16 compared at
//    once, then HUFFVAL read (6 clocks); no code within 16 bits raises err_huff and ends the block
//    without consuming bits;
//  - DC: DIFF = EXTEND(RECEIVE(SSSS)), predictor per component (pred_clear resets them); AC: run
//    lengths, ZRL, EOB; a run past k = 63 or a ZRL past k = 47 raises err_huff, consumes the symbol
//    and ends the block; the coefficient pipeline E1 (magnitude) E2 (EXTEND) E3 (prediction)
//    M (x Qk) S (16-bit saturation) is that of jpeg_huffdec, one coefficient per clock;
//  - only the DC and the non-zero AC coefficients are written (natural order, into slot cw_slot of
//    jpeg_idct_wide, whose valid masks make the rest zero); a block of a skipped component
//    (d_wr = 0, out_fmt = Y) is decoded - predictors included - but not written or committed.
// Blocks follow each other without a gap: the sequencer queues block descriptors (d_*), and the
// symbol after a block's last one is already the next block's DC.  A written block takes the next
// slot in order once it is clean; its commit (with the descriptor d_desc given at its start)
// leaves stage S with or after its last coefficient write.
module jpeg_huffdec_wide #(
  parameter int DW = 12               // IDCT descriptor width
) (
  input  logic        clk,
  input  logic        rst,
  input  logic        clear,          // drop everything (new frame)
  // tokens from the parser
  input  logic        tok_valid,
  input  logic [8:0]  tok_data,       // {marker, byte}
  output logic        tok_ready,
  // tables, written by the parser (jpeg_parser LUT_EN)
  input  logic        lut_we,         // lookahead: {Tc, Th, 8 bits} -> {hit, L-1, HUFFVAL}
  input  logic [9:0]  lut_waddr,
  input  logic [11:0] lut_wdata,
  input  logic        hc_we,          // {Tc, Th, L-1} -> {valid, MAXCODE+1, VALPTR-MINCODE}
  input  logic [5:0]  hc_waddr,
  input  logic [24:0] hc_wdata,
  output logic [8:0]  hv_raddr,       // HUFFVAL RAM (2-clock read)
  input  logic [7:0]  hv_rdata,
  output logic [7:0]  dqt_raddr,      // {Tq, k} (2-clock read)
  input  logic [7:0]  dqt_rdata,
  // block descriptors
  input  logic        d_valid,
  output logic        d_ready,
  input  logic [1:0]  d_comp,         // frame component index (DC predictor)
  input  logic        d_dc,           // Td
  input  logic        d_ac,           // Ta
  input  logic [1:0]  d_tq,           // Tq
  input  logic        d_wr,           // 0: decode only (component not transformed)
  input  logic [DW-1:0] d_desc,       // passed to the IDCT with the commit
  input  logic        pred_clear,     // pulse (while idle): reset the DC predictors
  output logic        idle,           // no block, no symbol or coefficient in flight
  output logic        err_huff,       // pulse
  // restart handling (as jpeg_bitwin)
  input  logic        restart_req,
  output logic        restart_done,   // one-cycle pulse
  output logic        err_pad,        // one-cycle pulse
  output logic        at_end,         // a non-RST marker has been reached: segment over
  // coefficient slots (jpeg_idct_wide)
  input  logic [3:0]  clean,
  output logic        cw_we,
  output logic [1:0]  cw_slot,
  output logic [5:0]  cw_addr,        // natural index
  output logic signed [15:0] cw_data,
  output logic        cw_commit,
  output logic [1:0]  cw_cslot,
  output logic [DW-1:0] cw_desc
);
  import jpeg_pkg::*;

  // ================================================================ token buffer (as jpeg_bitwin)
  logic       b0v, b1v, hv, pop;
  logic [8:0] b0, b1, hd;
  assign tok_ready = ~b1v;
  assign hv = b0v;
  assign hd = b0;
  logic       mk_valid, mk_rst;
  logic [7:0] mk_code;
  assign mk_rst = mk_valid & (mk_code[7:3] == 5'b11010);
  assign at_end = mk_valid & ~mk_rst;

  // ================================================================ window
  logic [63:0] D;                     // next bit = D[63]
  logic [6:0]  v;                     // valid bits
  logic [6:0]  real_;                 // of which real data (the rest: zero padding)
  logic        room, take_data, take_zero;
  logic [63:0] Dm;                    // D with this clock's byte merged below the valid bits
  logic [6:0]  vm, rm;
  assign room      = (v <= 7'd56);
  assign take_data = hv & ~hd[8] & ~mk_valid & room & ~restart_req;
  assign take_zero = mk_valid & room & ~restart_req;
  assign pop       = hv & ~mk_valid & (restart_req ? ~restart_done : (hd[8] | room));
  assign Dm = take_data ? (D | ({hd[7:0], 56'd0} >> v)) : D;
  assign vm = (take_data | take_zero) ? v + 7'd8 : v;
  assign rm = take_data ? real_ + 7'd8 : real_;
  logic have;
  assign have = (v >= 7'd31);

  // ================================================================ tables
  // lookahead entry: {hit, EOB (AC, SSSS = 0, not ZRL), n = L + SSSS (5), L (5), HUFFVAL (8)}
  logic [19:0] lent;
  logic [4:0]  wl, ws_;
  assign wl   = {2'b00, lut_wdata[10:8]} + 5'd1;
  assign ws_  = {1'b0, lut_wdata[3:0]};
  assign lent = {lut_wdata[11], lut_waddr[9] && lut_wdata[3:0] == 4'd0 && lut_wdata[7:4] != 4'hF, wl + ws_, wl, lut_wdata[7:0]};
  logic [19:0] e_t [0:3];             // the entries at D[63:56] of the four tables
  genvar gt;
  generate
    for (gt = 0; gt < 4; gt = gt + 1) begin : g_lut
      logic [19:0] mem [0:255];
      always_ff @(posedge clk) if (lut_we && lut_waddr[9:8] == gt) mem[lut_waddr[7:0]] <= lent;
      assign e_t[gt] = mem[D[63:56]];
    end
  endgenerate
  // MAXCODE+1 and VALPTR-MINCODE of lengths 9..16, per table: {valid, MAXCODE+1 (16), offset (8)}
  logic [24:0] mc [0:3][0:7];
  always_ff @(posedge clk) if (hc_we && hc_waddr[3]) mc[hc_waddr[5:4]][hc_waddr[2:0]] <= hc_wdata;

  // ================================================================ block state
  logic        active, phase_ac;
  logic [6:0]  k;                     // zig-zag index of the next coefficient
  logic [6:0]  kr;                    // 63 - k (AC phase: 0..62), so the end tests need no adder
  logic [1:0]  b_comp, b_tq, b_slot;
  logic        b_dc, b_ac, b_wr;
  logic        th;
  assign th = phase_ac ? b_ac : b_dc;
  logic [19:0] ent;
  always_comb case ({phase_ac, th})
    2'd0: ent = e_t[0]; 2'd1: ent = e_t[1]; 2'd2: ent = e_t[2]; default: ent = e_t[3];
  endcase

  // ---- slow path: 1 capture the next 16 bits and the table's MAXCODE entries, 2 compare all
  // lengths and pick the first that matches, 3 HUFFVAL address (prefix + offset), 4-5 RAM,
  // 5 symbol (consumed); every step starts from registers
  logic        sl1, sl2, sl3, sl4, sl5;
  logic [15:0] sview;
  logic [24:0] mcr [0:7];             // {valid, MAXCODE+1, offset} of lengths 9..16, current table
  logic [4:0]  slen, slen_r;
  logic        sfound, sfound_r;
  logic [7:0]  spre, soff, spre_r, soff_r;
  always_comb begin : g_slow
    integer l;
    logic [15:0] pre;
    slen = 5'd16; sfound = 1'b0; spre = 8'd0; soff = 8'd0;
    for (l = 9; l <= 16; l = l + 1) begin
      pre = sview >> (16 - l);
      if (!sfound && mcr[l - 9][24] && (pre < mcr[l - 9][23:8])) begin
        slen = l[4:0]; sfound = 1'b1; spre = pre[7:0]; soff = mcr[l - 9][7:0];
      end
    end
  end
  logic [7:0] sidx;
  assign sidx = spre_r + soff_r;
  logic slow_busy;
  assign slow_busy = sl1 | sl2 | sl3 | sl4 | sl5;

  // ---- the symbol of this clock
  logic        go_fast, go_slow, go, miss;
  logic [7:0]  sym;
  logic [4:0]  L, n;
  logic [3:0]  s, r;
  logic        eob;
  always_comb begin
    miss    = active && have && !ent[19] && !slow_busy;
    go_fast = active && have && ent[19] && !slow_busy;
    go_slow = sl5;
    go      = go_fast | go_slow;
    if (go_slow) begin
      sym = hv_rdata; L = slen_r; n = slen_r + {1'b0, hv_rdata[3:0]};
      eob = phase_ac && hv_rdata[3:0] == 4'd0 && hv_rdata[7:4] != 4'hF;
    end else begin
      sym = ent[7:0]; L = ent[12:8]; n = ent[17:13]; eob = ent[18];
    end
    s = sym[3:0];
    r = phase_ac ? sym[7:4] : 4'd0;
  end
  logic [6:0] k_run;                  // position of an AC coefficient (data path only)
  assign k_run = k + {3'd0, r};
  logic zrl, zrl_err, run_err, coef, last, kr_small;
  assign kr_small = (kr[6:4] == 3'd0);                               // k > 47
  assign zrl     = phase_ac && s == 4'd0 && r == 4'hF;
  assign zrl_err = zrl && kr_small;                                  // ZRL past k = 47
  assign run_err = phase_ac && s != 4'd0 && kr_small && (r > kr[3:0]);   // k + r > 63
  assign coef    = !phase_ac || (s != 4'd0 && !run_err);             // a coefficient is written
  assign last    = phase_ac && (eob || zrl_err || (s != 4'd0 && kr_small && r >= kr[3:0]));   // ... or k + r = 63
  logic noc;                          // slow path: no code within 16 bits -> the block ends
  assign noc = sl3 && !sfound_r;
  logic blk_fin;                      // the current block ends this clock
  assign blk_fin = (go && last) || noc;

  // ---- next block: when idle, or right after the current block's last symbol
  logic [1:0] ap;                     // next slot to allocate (in step with jpeg_idct_wide's rp)
  logic [3:0] inflight;               // allocated, commit not yet out of stage S
  logic       can_load;
  assign can_load = d_valid && (!d_wr || (clean[ap] && !inflight[ap]));
  assign d_ready  = can_load && (!active || blk_fin);
  logic [DW-1:0] desc_s [0:3];

  // ================================================================ coefficient pipeline
  //   go -> E1 (magnitude bits) -> E2 (EXTEND) -> E3 (DC prediction) -> M (x Qk) -> S (saturate) -> write
  // A block's end travels as `end` with its last entry (or alone: EOB, errors).
  logic        e_v, e_c, e_dc, e_end, e_wr;   logic [1:0] e_comp, e_tq, e_slot; logic [5:0] e_k; logic [3:0] e_s;
  logic [31:0] e_win, e_sh;  logic [4:0] e_n;
  assign e_sh = e_win >> (6'd32 - {1'b0, e_n});
  logic        f_v, f_c, f_dc, f_end, f_wr;   logic [1:0] f_comp, f_tq, f_slot; logic [5:0] f_k; logic [3:0] f_s;
  logic [15:0] f_raw, f_m;
  logic        g_v, g_c, g_dc, g_end, g_wr;   logic [1:0] g_comp, g_slot;       logic [5:0] g_k;
  logic signed [15:0] g_val, g_pred;
  logic        m_v, m_c, m_end, m_wr;         logic [1:0] m_slot;
  logic signed [15:0] m_coef;
  logic        p_v, p_c, p_end, p_wr;         logic [1:0] p_slot;
  logic signed [24:0] p_prod;
  logic [5:0]  p_addr;
  logic [15:0] pred [0:3];
  // E2: EXTEND (F.2.2.1): a value whose top bit is 0 is negative, v - (2^s - 1)  (s = 0: v = 0)
  logic [15:0] f_mag;
  logic        f_msb;
  logic signed [15:0] v_ext;
  assign f_mag = f_raw & f_m;
  assign f_msb = (f_s == 4'd0) | f_raw[f_s - 4'd1];
  assign v_ext = f_msb ? f_mag : f_mag - f_m;
  logic signed [15:0] coef_e;
  assign coef_e    = g_dc ? (g_pred + g_val) : g_val;
  assign dqt_raddr = {f_tq, f_k};
  logic [5:0] zz_nat;                 // natural position, arrives in M
  always_ff @(posedge clk) zz_nat <= zigzag_to_natural(g_k);
  (* multstyle = "dsp" *) logic signed [24:0] prod;
  assign prod = m_coef * $signed({1'b0, dqt_rdata});
  logic signed [15:0] prod_sat;
  always_comb begin
    if (p_prod > 25'sd32767)       prod_sat = 16'sd32767;
    else if (p_prod < -25'sd32768) prod_sat = 16'sh8000;
    else                           prod_sat = p_prod[15:0];
  end
  assign idle = !active && !slow_busy && !e_v && !f_v && !g_v && !m_v && !p_v;
  assign hv_raddr = {th, phase_ac ? sidx : {4'hF, sidx[3:0]}};

  // ================================================================ registers
  logic over;
  assign over = go && ({2'b00, n} > real_);

  always_ff @(posedge clk) begin : g_main
    integer i;
    restart_done <= 1'b0; err_pad <= 1'b0; err_huff <= 1'b0;
    cw_we <= 1'b0; cw_commit <= 1'b0;
    if (rst || clear) begin
      b0v <= 1'b0; b1v <= 1'b0; b0 <= '0; b1 <= '0;
      D <= '0; v <= '0; real_ <= '0; mk_valid <= 1'b0; mk_code <= '0;
      active <= 1'b0; phase_ac <= 1'b0; k <= '0; kr <= 7'd63; b_comp <= '0; b_tq <= '0; b_slot <= '0; b_dc <= 1'b0; b_ac <= 1'b0; b_wr <= 1'b0;
      sl1 <= 1'b0; sl2 <= 1'b0; sl3 <= 1'b0; sl4 <= 1'b0; sl5 <= 1'b0; sview <= '0; slen_r <= '0; sfound_r <= 1'b0;
      spre_r <= '0; soff_r <= '0;
      // (ap / inflight survive `clear`: the IDCT takes the slots in order across frames too)
      if (rst) begin ap <= '0; inflight <= '0; end
      e_v <= 1'b0; f_v <= 1'b0; g_v <= 1'b0; m_v <= 1'b0; p_v <= 1'b0;
      e_c <= 1'b0; e_dc <= 1'b0; e_end <= 1'b0; e_wr <= 1'b0; e_comp <= '0; e_tq <= '0; e_slot <= '0; e_k <= '0; e_s <= '0; e_win <= '0; e_n <= '0;
      f_c <= 1'b0; f_dc <= 1'b0; f_end <= 1'b0; f_wr <= 1'b0; f_comp <= '0; f_tq <= '0; f_slot <= '0; f_k <= '0; f_s <= '0; f_raw <= '0; f_m <= '0;
      g_c <= 1'b0; g_dc <= 1'b0; g_end <= 1'b0; g_wr <= 1'b0; g_comp <= '0; g_slot <= '0; g_k <= '0; g_val <= '0; g_pred <= '0;
      m_c <= 1'b0; m_end <= 1'b0; m_wr <= 1'b0; m_slot <= '0; m_coef <= '0;
      p_c <= 1'b0; p_end <= 1'b0; p_wr <= 1'b0; p_slot <= '0; p_prod <= '0; p_addr <= '0;
      cw_slot <= '0; cw_addr <= '0; cw_data <= '0; cw_cslot <= '0; cw_desc <= '0;
      if (rst) for (i = 0; i < 4; i = i + 1) pred[i] <= '0;
    end else begin
      if (pred_clear) for (i = 0; i < 4; i = i + 1) pred[i] <= '0;

      // ---- token buffer
      case ({tok_valid & ~b1v, pop})
        2'b10: if (!b0v) begin b0v <= 1'b1; b0 <= tok_data; end
               else      begin b1v <= 1'b1; b1 <= tok_data; end
        2'b01: begin b0v <= b1v; b0 <= b1; b1v <= 1'b0; end
        2'b11: if (b1v) begin b0 <= b1; b1 <= tok_data; end
               else     begin b0 <= tok_data; end
        default: ;
      endcase

      // ---- window: restart, or refill and consumption
      if (restart_req) begin
        D <= '0; v <= '0; real_ <= '0;
        if (restart_done) ;                              // request already served (see tok_ready)
        else if (mk_valid) begin                         // marker reached
          restart_done <= 1'b1;
          if (mk_rst) mk_valid <= 1'b0;                  // RSTn consumed
          else err_pad <= 1'b1;                          // EOI where RSTn was expected
        end else if (hv && hd[8]) begin
          mk_valid <= 1'b1; mk_code <= hd[7:0];
        end
      end else begin
        if (over) err_pad <= 1'b1;
        D     <= go ? (Dm << n) : Dm;
        v     <= go ? vm - {2'b00, n} : vm;
        real_ <= !go ? rm : over ? 7'd0 : rm - {2'b00, n};
        if (hv && hd[8] && !mk_valid) begin mk_valid <= 1'b1; mk_code <= hd[7:0]; end
      end

      // ---- slow path
      sl1 <= miss;
      if (miss) begin
        sview <= D[63:48];
        for (i = 0; i < 8; i = i + 1) mcr[i] <= mc[{phase_ac, th}][i];
      end
      sl2 <= sl1;
      sl3 <= sl2;
      if (sl2) begin slen_r <= slen; sfound_r <= sfound; spre_r <= spre; soff_r <= soff; end
      sl4 <= sl3 && sfound_r;                            // HUFFVAL address issued with sl3
      sl5 <= sl4;

      // ---- the symbol: block state, pipeline entry
      e_v <= 1'b0;
      if (go) begin
        e_v <= 1'b1; e_c <= coef; e_dc <= !phase_ac; e_end <= last; e_wr <= b_wr;
        e_comp <= b_comp; e_tq <= b_tq; e_slot <= b_slot; e_s <= s; e_win <= D[63:32]; e_n <= n;
        e_k <= phase_ac ? k_run[5:0] : 6'd0;
        if (!phase_ac) begin phase_ac <= 1'b1; k <= 7'd1; kr <= 7'd62; end
        else if (zrl) begin k <= k + 7'd16; kr <= kr - 7'd16; end
        else begin k <= k_run + 7'd1; kr <= kr - {3'd0, r} - 7'd1; end
        if (zrl_err || run_err) err_huff <= 1'b1;
      end else if (noc) begin                            // no code: end the block, no bits consumed
        e_v <= 1'b1; e_c <= 1'b0; e_end <= 1'b1; e_wr <= b_wr; e_slot <= b_slot;
        err_huff <= 1'b1;
      end
      if (!active || blk_fin) begin
        if (can_load) begin
          active <= 1'b1; phase_ac <= 1'b0; k <= '0; kr <= 7'd63;
          b_comp <= d_comp; b_dc <= d_dc; b_ac <= d_ac; b_tq <= d_tq; b_wr <= d_wr;
          if (d_wr) begin b_slot <= ap; desc_s[ap] <= d_desc; ap <= ap + 2'd1; inflight[ap] <= 1'b1; end
        end else begin
          active <= 1'b0; phase_ac <= 1'b0;
        end
      end

      // ---- E1: magnitude bits right-aligned (the n bits of code + magnitude end at bit 0)
      f_v <= e_v; f_c <= e_c; f_dc <= e_dc; f_end <= e_end; f_wr <= e_wr; f_comp <= e_comp; f_tq <= e_tq;
      f_slot <= e_slot; f_k <= e_k; f_s <= e_s;
      f_raw <= e_sh[15:0];
      f_m   <= ~(16'hFFFF << e_s);                       // 2^s - 1 (the magnitude mask)
      // ---- E2: EXTEND; the predictor of the component; Qk addressed
      g_v <= f_v; g_c <= f_c; g_dc <= f_dc; g_end <= f_end; g_wr <= f_wr; g_comp <= f_comp; g_slot <= f_slot; g_k <= f_k;
      g_val <= v_ext; g_pred <= pred[f_comp];
      // ---- E3: DC prediction (multiplier operand loaded every clock: DSP input register)
      m_coef <= coef_e;
      m_v <= g_v; m_c <= g_c; m_end <= g_end; m_wr <= g_wr; m_slot <= g_slot;
      if (g_v && g_c && g_dc) pred[g_comp] <= coef_e;
      // ---- M: dequantise
      p_prod <= prod;
      p_v <= m_v; p_c <= m_c; p_end <= m_end; p_wr <= m_wr; p_slot <= m_slot; p_addr <= zz_nat;
      if (cw_commit) inflight[cw_cslot] <= 1'b0;         // the IDCT marks the slot full now
      // ---- S: saturate, write, commit
      if (p_v) begin
        cw_we <= p_c && p_wr; cw_slot <= p_slot; cw_addr <= p_addr; cw_data <= prod_sat;
        if (p_end && p_wr) begin
          cw_commit <= 1'b1; cw_cslot <= p_slot; cw_desc <= desc_s[p_slot];
        end
      end
    end
  end
endmodule
