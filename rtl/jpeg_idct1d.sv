// jpeg_idct1d.sv - one 8-point 1-D inverse DCT per clock, for the wide IDCT (FAST = 2).
//
// The arithmetic of jpeg_idct_fast (a bit-exact port of libjpeg's jpeg_idct_islow, jidctint.c:
// CONST_BITS = 13, PASS1_BITS = 2), laid out as a pipeline that accepts a new vector every clock
// instead of sharing one core between the passes:
//   P   sums of the inputs, multiplier operands          M   12 products
//   A1  first adder level                                A2  second adder level
//   B   outputs: PASS = 1  (v >> 11) saturated to 16 bits (the 16-bit workspace of jpeg_idct_fast)
//                PASS = 2  range_limit(v >> 18) (pass 2 adds the range centre and rounding,
//                          16384 + 16, to x0 before the shift by 13)
// Five registers from x to y: in_valid / tag come out as out_valid / out_tag five clocks later.
// Based in part on the work of the Independent JPEG Group: the arithmetic reproduces libjpeg /
// libjpeg-turbo so that the output is bit-identical to them (see NOTICE.md).
module jpeg_idct1d #(
  parameter int PASS = 1,             // 1: columns (16-bit results), 2: rows (8-bit samples)
  parameter int TW   = 8              // tag width
) (
  input  logic                clk,
  input  logic                in_valid,
  input  logic [TW-1:0]       in_tag,
  input  logic signed [15:0]  x0, x1, x2, x3, x4, x5, x6, x7,
  output logic                out_valid,
  output logic [TW-1:0]       out_tag,
  output logic [15:0]         y0, y1, y2, y3, y4, y5, y6, y7    // PASS 2: samples in bits 7..0
);
  localparam logic signed [15:0] C_0_541 = 16'sd4433,  C_0_765 = 16'sd6270,  C_1_847 = 16'sd15137;
  localparam logic signed [15:0] C_1_175 = 16'sd9633,  C_0_298 = 16'sd2446,  C_1_501 = 16'sd12299;
  localparam logic signed [15:0] C_2_053 = 16'sd16819, C_3_072 = 16'sd25172;
  localparam logic signed [15:0] CN_1_961 = -16'sd16069, CN_0_390 = -16'sd3196;
  localparam logic signed [15:0] CN_0_899 = -16'sd7373,  CN_2_562 = -16'sd20995;

  function automatic logic signed [17:0] sx18(input logic signed [15:0] v);
    sx18 = {v[15], v[15], v};
  endfunction
  function automatic logic signed [31:0] sh13(input logic signed [17:0] v, input logic fudge);
    sh13 = {v[17], v, 2'b00, fudge, 10'd0};                           // (v << 13) + (fudge ? 1024 : 0)
  endfunction
  function automatic logic signed [15:0] sat16(input logic signed [20:0] v);
    if (v > 21'sd32767)       sat16 = 16'sd32767;
    else if (v < -21'sd32768) sat16 = 16'sh8000;
    else                      sat16 = v[15:0];
  endfunction
  function automatic logic [7:0] range_limit(input logic signed [31:0] v);
    logic [9:0] m;
    m = v[9:0];                                    // (v) & RANGE_MASK
    if (m < 10'd384)      range_limit = 8'd0;
    else if (m < 10'd640) range_limit = m[7:0] - 8'd128;
    else                  range_limit = 8'd255;
  endfunction

  // ---- stage P
  logic                      p_v;  logic [TW-1:0] p_t;
  logic signed [17:0] pa_z1, pa_t2, pa_t3, pa_zz1, pa_zz2, pa_zz3, pa_w1, pa_t0, pa_t3o, pa_w2, pa_t1, pa_t2o;
  logic signed [17:0] pa_e0, pa_e1;
  logic signed [17:0] e_base, s02, s13;
  assign e_base = (PASS == 2) ? sx18(x0) + 18'sd16400 : sx18(x0);
  assign s02    = sx18(x3) + sx18(x7);
  assign s13    = sx18(x1) + sx18(x5);
  // ---- stage M (multiplier operands and products registered every clock: DSP input/output registers)
  logic                      m_v;  logic [TW-1:0] m_t;
  (* multstyle = "dsp" *) logic signed [33:0] p_z1, p_t2, p_t3, p_zz1, p_zz2, p_zz3, p_w1, p_t0, p_t3o, p_w2, p_t1, p_t2o;
  logic signed [31:0] r_z1, r_t2, r_t3, r_zz1, r_zz2, r_zz3, r_w1, r_t0, r_t3o, r_w2, r_t1, r_t2o, r_tmp0, r_tmp1;
  assign p_z1  = pa_z1  * C_0_541;                                    // FIX_0_541196100
  assign p_t2  = pa_t2  * C_0_765;                                    // FIX_0_765366865
  assign p_t3  = pa_t3  * C_1_847;                                    // FIX_1_847759065
  assign p_zz1 = pa_zz1 * C_1_175;                                    //  FIX_1_175875602
  assign p_zz2 = pa_zz2 * CN_1_961;                                   // -FIX_1_961570560
  assign p_zz3 = pa_zz3 * CN_0_390;                                   // -FIX_0_390180644
  assign p_w1  = pa_w1  * CN_0_899;                                   // -FIX_0_899976223
  assign p_t0  = pa_t0  * C_0_298;                                    //  FIX_0_298631336
  assign p_t3o = pa_t3o * C_1_501;                                    //  FIX_1_501321110
  assign p_w2  = pa_w2  * CN_2_562;                                   // -FIX_2_562915447
  assign p_t1  = pa_t1  * C_2_053;                                    //  FIX_2_053119869
  assign p_t2o = pa_t2o * C_3_072;                                    //  FIX_3_072711026
  // ---- stage A1, A2, B
  logic                      a1_v, a2_v;  logic [TW-1:0] a1_t, a2_t;
  logic signed [31:0] b_tmp0, b_tmp1, b_tmp2, b_tmp3, b_zz2m, b_zz3m, b_u0, b_u1, b_u2, b_u3;
  logic signed [31:0] a_tmp10, a_tmp11, a_tmp12, a_tmp13, a_t0, a_t1, a_t2, a_t3;
  logic signed [31:0] yv [0:7];
  always_comb begin
    yv[0] = a_tmp10 + a_t3;  yv[7] = a_tmp10 - a_t3;
    yv[1] = a_tmp11 + a_t2;  yv[6] = a_tmp11 - a_t2;
    yv[2] = a_tmp12 + a_t1;  yv[5] = a_tmp12 - a_t1;
    yv[3] = a_tmp13 + a_t0;  yv[4] = a_tmp13 - a_t0;
  end
  function automatic logic [15:0] outv(input logic signed [31:0] v);
    if (PASS == 2) outv = {8'd0, range_limit(v >>> 18)};               // CONST_BITS + PASS1_BITS + 3
    else           outv = sat16(v[31:11]);                              // >>> (CONST_BITS - PASS1_BITS)
  endfunction

  always_ff @(posedge clk) begin
    // P
    p_v <= in_valid; p_t <= in_tag;
    pa_z1 <= sx18(x2) + sx18(x6);  pa_t2 <= sx18(x2);  pa_t3 <= sx18(x6);
    pa_zz1 <= s02 + s13;           pa_zz2 <= s02;      pa_zz3 <= s13;
    pa_w1 <= sx18(x7) + sx18(x1);  pa_t0 <= sx18(x7); pa_t3o <= sx18(x1);
    pa_w2 <= sx18(x5) + sx18(x3);  pa_t1 <= sx18(x5); pa_t2o <= sx18(x3);
    pa_e0 <= e_base + sx18(x4);    pa_e1 <= e_base - sx18(x4);
    // M
    m_v <= p_v; m_t <= p_t;
    r_z1 <= p_z1[31:0]; r_t2 <= p_t2[31:0]; r_t3 <= p_t3[31:0];
    r_zz1 <= p_zz1[31:0]; r_zz2 <= p_zz2[31:0]; r_zz3 <= p_zz3[31:0];
    r_w1 <= p_w1[31:0]; r_t0 <= p_t0[31:0]; r_t3o <= p_t3o[31:0];
    r_w2 <= p_w2[31:0]; r_t1 <= p_t1[31:0]; r_t2o <= p_t2o[31:0];
    r_tmp0 <= sh13(pa_e0, PASS == 1); r_tmp1 <= sh13(pa_e1, PASS == 1);
    // A1
    a1_v <= m_v; a1_t <= m_t;
    b_tmp0 <= r_tmp0;           b_tmp1 <= r_tmp1;
    b_tmp2 <= r_z1 + r_t2;      b_tmp3 <= r_z1 - r_t3;
    b_zz2m <= r_zz2 + r_zz1;    b_zz3m <= r_zz3 + r_zz1;
    b_u0 <= r_t0 + r_w1;        b_u3 <= r_t3o + r_w1;
    b_u1 <= r_t1 + r_w2;        b_u2 <= r_t2o + r_w2;
    // A2
    a2_v <= a1_v; a2_t <= a1_t;
    a_tmp10 <= b_tmp0 + b_tmp2;  a_tmp13 <= b_tmp0 - b_tmp2;
    a_tmp11 <= b_tmp1 + b_tmp3;  a_tmp12 <= b_tmp1 - b_tmp3;
    a_t0 <= b_u0 + b_zz2m;       a_t3 <= b_u3 + b_zz3m;
    a_t1 <= b_u1 + b_zz3m;       a_t2 <= b_u2 + b_zz2m;
    // B
    out_valid <= a2_v; out_tag <= a2_t;
    y0 <= outv(yv[0]); y1 <= outv(yv[1]); y2 <= outv(yv[2]); y3 <= outv(yv[3]);
    y4 <= outv(yv[4]); y5 <= outv(yv[5]); y6 <= outv(yv[6]); y7 <= outv(yv[7]);
  end
endmodule
