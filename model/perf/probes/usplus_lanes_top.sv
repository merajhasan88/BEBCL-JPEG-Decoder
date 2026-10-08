// usplus_lanes_top.sv - N decoder lanes (boards/acorn_cle215/bench_lane.sv, as in the batched harness)
// for the crowded case of usplus_timing.tcl, without the harness's UART core (uart_batch_core.sv): with 15
// lanes, that core alone grew past 9 GB in synthesis on the KU5P. Each lane gets its own registered push /
// restart / end-of-file inputs and the shared registered data byte; each lane's results are folded into
// a register next to it and then, in two more register stages, into one output word, so that nothing is
// optimised away. Clocking as usplus_batch_top.sv. A timing probe only (no pins, no bitstream).
module usplus_lanes_top #(
  parameter int N = 15
) (
  input  logic         clk_in,
  input  logic [N-1:0] push,
  input  logic [N-1:0] restart,
  input  logic [N-1:0] eos,
  input  logic [7:0]   push_b,
  output logic [31:0]  q
);
  logic         clk;
  logic [N-1:0] run_en, dclk;
  BUFG u_clk (.I(clk_in), .O(clk));

  // power-on reset for 2^16 clocks
  logic [16:0] por = '0;
  logic        rst;
  always_ff @(posedge clk) begin
    if (!por[16]) por <= por + 17'd1;
    rst <= !por[16];
  end

  logic [N-1:0] push_r, restart_r, eos_r;
  logic [7:0]   push_b_r;
  always_ff @(posedge clk) begin
    push_r <= push; restart_r <= restart; eos_r <= eos; push_b_r <= push_b;
  end

  localparam int G = (N + 3) / 4;               // fold groups of up to 4 lanes
  logic [31:0] lx [0:N-1];
  logic [31:0] gx [0:G-1];
  genvar gi;
  generate
    for (gi = 0; gi < N; gi = gi + 1) begin : g_lane
      logic        res_v, ovf, wdog;
      logic [31:0] cyc, chk, npx;
      logic [12:0] err;
      logic [15:0] w, h;
      BUFGCE #(.SIM_DEVICE("ULTRASCALE_PLUS")) u_gate (.I(clk_in), .CE(run_en[gi]), .O(dclk[gi]));
      bench_lane u_lane (
        .clk(clk), .rst(rst), .dclk(dclk[gi]), .run_en(run_en[gi]),
        .restart(restart_r[gi]), .push(push_r[gi]), .push_b(push_b_r), .eos(eos_r[gi]),
        .res_v(res_v), .ovf(ovf), .wdog_hit(wdog),
        .cyc(cyc), .chk(chk), .npx(npx), .err(err), .w_(w), .h_(h));
      always_ff @(posedge clk)
        lx[gi] <= cyc ^ chk ^ npx ^ {w, h} ^ {res_v, ovf, wdog, 6'd0, err, 10'd0};
    end
    for (gi = 0; gi < G; gi = gi + 1) begin : g_fold
      always_ff @(posedge clk) begin : p_fold
        integer i;
        logic [31:0] x;
        x = '0;
        for (i = 4 * gi; i < 4 * gi + 4; i = i + 1)
          if (i < N) x = x ^ lx[i];
        gx[gi] <= x;
      end
    end
  endgenerate
  always_ff @(posedge clk) begin : p_out
    integer i;
    logic [31:0] x;
    x = '0;
    for (i = 0; i < G; i = i + 1) x = x ^ gx[i];
    q <= x;
  end
endmodule
