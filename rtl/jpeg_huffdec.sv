// jpeg_huffdec.sv - fast block decoder (T.81 F.2.2) for the FAST build of jpeg_decoder.
//
// Same job as jpeg_coefdec - Huffman DECODE, RECEIVE/EXTEND, DC prediction, run lengths, ZRL/EOB,
// dequantisation, zig-zag to natural order - but it reads the bit stream through the bit
// accumulator of jpeg_bitwin (next bit = acc[wcnt-1]) instead of one bit per clock:
//   LOOK  the next 8 bits address the lookahead table built by jpeg_parser (LUT_EN), a block RAM
//         with output register (LW: its data arrives two clocks later);
//   SYM   the entry gives code length L <= 8 and the symbol; L + SSSS bits (code + magnitude) are
//         removed from the window in one go.                        -> 3 clocks per coefficient
//         The SSSS magnitude bits are then read in stage E1, where they sit just above wcnt.
//   SLOW  codes longer than 8 bits: MAXCODE(L) (T.81 F.2.2.3 Figure F.16) is compared for
//         L = 9..16, one length per clock (read through the RAM output register, so the compare
//         trails the request by two clocks), then HUFFVAL is read (SLOWW, SLOWV).
// Extraction of the magnitude bits (E1), EXTEND (E2), DC prediction (E3), the multiplication by
// Qk (M) and saturation (S) follow in a pipeline that runs while the next symbols are decoded;
// every stage is a single level of logic behind a register, for a high clock rate.
// Error behaviour (err_huff: no code within 16 bits, run past k = 63, ZRL past k = 47) and the
// 16-bit saturation of dequantised values are identical to jpeg_coefdec, so both builds produce
// the same pixels for any input.
module jpeg_huffdec (
  input  logic        clk,
  input  logic        rst,
  // control
  input  logic        start,        // pulse (only while idle): decode one block
  input  logic [1:0]  comp,         // frame component index (DC predictor)
  input  logic        dc_tbl,       // Td
  input  logic        ac_tbl,       // Ta
  input  logic [1:0]  tq,           // Tq
  input  logic        wr_en,        // 0: decode only (block not transformed), no coefficient writes
  input  logic        pred_clear,   // pulse (while idle): reset the DC predictors
  output logic        idle,
  output logic        done,         // pulse: block decoded and its last coefficient write issued
  output logic        err_huff,     // pulse
  // bit window
  input  logic [47:0] acc,
  input  logic [5:0]  wcnt,
  output logic        consume,
  output logic [4:0]  n,
  // table RAM read ports
  output logic [9:0]  lut_raddr,    // {Tc, Th, next 8 bits} -> {hit, L-1, HUFFVAL}   (2 clocks)
  input  logic [11:0] lut_rdata,
  output logic [5:0]  hc_raddr,     // {Tc, Th, L-1} -> {valid, MAXCODE+1, VALPTR-MINCODE} (2 clocks)
  input  logic [24:0] hc_rdata,
  output logic [8:0]  hv_raddr,     //                                                  (2 clocks)
  input  logic [7:0]  hv_rdata,
  output logic [7:0]  dqt_raddr,    // {Tq, k}                                          (2 clocks)
  input  logic [7:0]  dqt_rdata,
  // coefficient writes, natural order (the block buffer reads as zero where nothing is written)
  output logic        cw_we,
  output logic [5:0]  cw_addr,
  output logic signed [15:0] cw_data
);
  import jpeg_pkg::*;

  typedef enum logic [2:0] { IDLE, LOOK, LW, SYM, SLOW, SLOWW, SLOWV, FIN } state_t;
  state_t state;

  logic        phase_ac;
  logic [5:0]  k;                  // zig-zag index of the next coefficient
  logic [1:0]  comp_r, tq_r;
  logic        dc_r, ac_r, wr_r;
  logic [4:0]  len;                // SLOWV: code length found (9..16)
  logic [8:0]  hv_addr_r;
  logic        th;
  logic        have;               // >= 31 bits in the window: any code + magnitude fits
  assign th   = phase_ac ? ac_r : dc_r;
  assign idle = (state == IDLE);

  // ---------------------------------------------------------------- symbol in hand (SYM / SLOWV)
  logic        hit;
  logic [4:0]  L;                  // code length
  logic [7:0]  sym;
  logic [3:0]  s, r;
  logic [5:0]  need;               // L + SSSS bits
  always_comb begin
    hit  = lut_rdata[11];
    if (state == SLOWV) begin L = len; sym = hv_rdata; end
    else begin L = {2'b00, lut_rdata[10:8]} + 5'd1; sym = lut_rdata[7:0]; end
    s    = sym[3:0];
    r    = phase_ac ? sym[7:4] : 4'd0;
    need = {1'b0, L} + {2'b00, s};
  end
  logic sym_go;                    // the symbol is processed this clock
  assign sym_go  = ((state == SYM && hit) || state == SLOWV) && have;
  assign consume = sym_go;
  assign n       = need[4:0];

  // one shifter for both windows: accx[15:0] = acc[wcnt-1 -: 16] (the next 16 bits of the scan,
  // zero-filled below bit 0) and accx[31:16] = acc[wcnt+15 : wcnt] (E1's magnitude bits, below)
  logic [63:0] accx;
  logic [15:0] view16;
  assign accx   = {acc, 16'd0} >> wcnt;
  assign view16 = accx[15:0];

  logic [6:0] k_run;
  assign k_run = {1'b0, k} + {3'd0, r};

  // ---------------------------------------------------------------- SLOW: codes longer than 8 bits
  // The next 16 bits are captured when the table misses (the window keeps them: nothing is consumed
  // until the symbol is known, and refills only add bits below).  Length la is requested from the
  // MAXCODE table each clock; its entry and the matching code prefix meet two clocks later (q2).
  logic [15:0] slow_view;
  logic [4:0]  la;                 // length requested this clock (9..16, 17: none)
  logic        q1_v, q2_v;
  logic [4:0]  q1_l, q2_l;
  logic [15:0] q1_pre, q2_pre;     // first L bits of the view, right-aligned
  logic        match;
  logic [7:0]  hv_idx;
  assign match   = q2_v && hc_rdata[24] && (q2_pre < hc_rdata[23:8]);      // entry = MAXCODE+1
  assign hv_idx  = q2_pre[7:0] + hc_rdata[7:0];

  // ---------------------------------------------------------------- RAM addresses
  assign lut_raddr = {phase_ac, th, view16[15:8]};
  always_comb begin
    hc_raddr = {phase_ac, th, la[3:0] - 4'd1};
    hv_raddr = (state == SLOW && match) ? {th, phase_ac ? hv_idx : {4'hF, hv_idx[3:0]}} : hv_addr_r;
  end

  // ---------------------------------------------------------------- coefficient pipeline
  //   sym_go -> E1 (magnitude bits) -> E2 (EXTEND) -> E3 (DC prediction) -> M (x Qk) -> S (saturate) -> write
  logic        e_valid, e_dc, e_wr;           // E1
  logic [3:0]  e_s;
  logic [5:0]  e_k;
  logic [1:0]  e_comp, e_tq;
  logic        f_valid, f_dc, f_wr;           // E2
  logic [15:0] f_raw, f_c;                    // 16 bits starting with the magnitude, 2^SSSS - 1
  logic [3:0]  f_s;
  logic [5:0]  f_k;
  logic [1:0]  f_comp, f_tq;
  logic        g_valid, g_dc, g_wr;           // E3
  logic signed [15:0] g_v, g_pred;
  logic [5:0]  g_k;
  logic [1:0]  g_comp;
  logic        m_valid, m_wr;                 // M
  logic signed [15:0] m_coef;
  logic        p_valid, p_wr;                 // S
  logic signed [24:0] p_prod;
  logic [5:0]  p_addr;
  logic [15:0] pred [0:3];
  // E1: the SSSS magnitude bits consumed by the last symbol are now acc[wcnt+SSSS-1 : wcnt]
  // = accx[16 +: SSSS] (a refill in between shifted acc and wcnt by the same 8)
  // E2: EXTEND (F.2.2.1): a value whose top bit is 0 is negative, v - (2^s - 1)  (s = 0: v = 0)
  logic [15:0] f_mag;
  logic        f_msb;
  logic signed [15:0] v_ext;
  assign f_mag = f_raw & f_c;
  assign f_msb = (f_s == 4'd0) | f_raw[f_s - 4'd1];
  assign v_ext = f_msb ? f_mag : f_mag - f_c;
  // E3: DC prediction (predictor picked in E2); Qk (block RAM with output register) addressed in
  // E2 arrives in M
  logic signed [15:0] coef_e;
  assign coef_e    = g_dc ? (g_pred + g_v) : g_v;
  assign dqt_raddr = {f_tq, f_k};
  (* romstyle = "M4K" *) logic [5:0] zz_nat;             // natural position, arrives in M
  always_ff @(posedge clk) zz_nat <= zigzag_to_natural(g_k);
  (* multstyle = "dsp" *) logic signed [24:0] prod;
  logic signed [15:0] prod_sat;
  assign prod = m_coef * $signed({1'b0, dqt_rdata});
  always_comb begin
    if (p_prod > 25'sd32767)       prod_sat = 16'sd32767;
    else if (p_prod < -25'sd32768) prod_sat = 16'sh8000;
    else                           prod_sat = p_prod[15:0];
  end

  logic fin_pipe_empty;
  assign fin_pipe_empty = !e_valid && !f_valid && !g_valid && !m_valid && !p_valid;

  always_ff @(posedge clk) begin
    done <= 1'b0; err_huff <= 1'b0; cw_we <= 1'b0;
    e_valid <= 1'b0; f_valid <= 1'b0; g_valid <= 1'b0; m_valid <= 1'b0; p_valid <= 1'b0;
    have <= (wcnt >= 6'd31);       // (wcnt only grows until the next consumption)
    if (rst) begin
      state <= IDLE; phase_ac <= 1'b0; k <= '0; comp_r <= '0; tq_r <= '0; dc_r <= 1'b0; ac_r <= 1'b0; wr_r <= 1'b0;
      len <= '0; hv_addr_r <= '0; slow_view <= '0; la <= 5'd17; q1_v <= 1'b0; q2_v <= 1'b0; q1_l <= '0; q2_l <= '0;
      q1_pre <= '0; q2_pre <= '0;
      e_dc <= 1'b0; e_wr <= 1'b0; e_s <= '0; e_k <= '0; e_comp <= '0; e_tq <= '0;
      f_dc <= 1'b0; f_wr <= 1'b0; f_raw <= '0; f_c <= '0; f_s <= '0; f_k <= '0; f_comp <= '0; f_tq <= '0;
      g_dc <= 1'b0; g_wr <= 1'b0; g_v <= '0; g_pred <= '0; g_k <= '0; g_comp <= '0;
      m_wr <= 1'b0; m_coef <= '0; p_wr <= 1'b0; p_prod <= '0; p_addr <= '0;
      cw_addr <= '0; cw_data <= '0;
      pred[0] <= '0; pred[1] <= '0; pred[2] <= '0; pred[3] <= '0;
    end else begin
      if (pred_clear) begin pred[0] <= '0; pred[1] <= '0; pred[2] <= '0; pred[3] <= '0; end

      // E1: magnitude bits
      if (e_valid) begin
        f_valid <= 1'b1; f_dc <= e_dc; f_wr <= e_wr; f_raw <= accx[31:16]; f_s <= e_s; f_k <= e_k; f_comp <= e_comp; f_tq <= e_tq;
        f_c   <= ~(16'hFFFF << e_s);                              // 2^s - 1 (the magnitude mask)
      end
      // E2: EXTEND
      if (f_valid) begin
        g_valid <= 1'b1; g_dc <= f_dc; g_wr <= f_wr; g_v <= v_ext; g_k <= f_k; g_comp <= f_comp; g_pred <= pred[f_comp];
      end
      // E3: DC prediction.  The multiplier operand m_coef and the product p_prod are loaded every
      // clock (used the next clock) so they fit the DSP block's input and output registers.
      m_coef <= coef_e;
      if (g_valid) begin
        m_valid <= 1'b1; m_wr <= g_wr;
        if (g_dc) pred[g_comp] <= coef_e;
      end
      // M: dequantise
      p_prod <= prod;
      if (m_valid) begin
        p_valid <= 1'b1; p_wr <= m_wr; p_addr <= zz_nat;
      end
      // S: saturate and write
      if (p_valid) begin
        cw_we <= p_wr; cw_addr <= p_addr; cw_data <= prod_sat;
      end

      case (state)
        IDLE: if (start) begin
          comp_r <= comp; dc_r <= dc_tbl; ac_r <= ac_tbl; tq_r <= tq; wr_r <= wr_en;
          phase_ac <= 1'b0; k <= '0;
          state <= LOOK;
        end
        LOOK: if (wcnt >= 6'd8) state <= LW;             // table address valid, entry arrives in SYM
        LW:   state <= SYM;
        SYM:  if (!hit && have) begin                    // (a hit is handled by sym_go below)
          la <= 5'd9; q1_v <= 1'b0; q2_v <= 1'b0; slow_view <= view16; state <= SLOW;
        end
        SLOW: begin
          q1_v <= (la <= 5'd16); q1_l <= la; q1_pre <= slow_view >> (5'd16 - la);
          if (la <= 5'd16) la <= la + 5'd1;
          q2_v <= q1_v; q2_l <= q1_l; q2_pre <= q1_pre;
          if (match) begin len <= q2_l; hv_addr_r <= hv_raddr; state <= SLOWW; end
          else if (q2_v && q2_l == 5'd16) begin err_huff <= 1'b1; state <= FIN; end
        end
        SLOWW: state <= SLOWV;                            // HUFFVAL through the RAM output register
        SLOWV: ;                                          // symbol in hand, waiting for its bits (sym_go)
        FIN: if (fin_pipe_empty) begin done <= 1'b1; state <= IDLE; end
        default: state <= IDLE;
      endcase

      // symbol processing, shared by SYM (table hit) and SLOWV
      if (sym_go) begin
        e_s <= s; e_comp <= comp_r; e_tq <= tq_r; e_wr <= wr_r;
        if (!phase_ac) begin                                  // DC: DIFF, always written
          e_valid <= 1'b1; e_dc <= 1'b1; e_k <= 6'd0;
          phase_ac <= 1'b1; k <= 6'd1; state <= LOOK;
        end else if (s == 4'd0) begin
          if (r == 4'hF) begin                                // ZRL: sixteen zeros
            if (k > 6'd47) begin err_huff <= 1'b1; state <= FIN; end
            else begin k <= k + 6'd16; state <= LOOK; end
          end else state <= FIN;                              // EOB
        end else if (k_run > 7'd63) begin
          err_huff <= 1'b1; state <= FIN;
        end else begin
          e_valid <= 1'b1; e_dc <= 1'b0; e_k <= k_run[5:0];
          if (k_run == 7'd63) state <= FIN;
          else begin k <= k_run[5:0] + 6'd1; state <= LOOK; end
        end
      end
    end
  end
endmodule
