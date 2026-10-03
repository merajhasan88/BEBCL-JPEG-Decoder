// tb_gls.sv - gate-level (post-fit, SDF-annotated) testbench for the fpga_top netlist that
// Quartus writes with `quartus_eda --simulation`.  Drives the 50 MHz clock and the reset
// button, samples uart_tx with an 8N1 receiver, writes every received byte to OUT_FILE and
// stops after the frame trailer 'E' 'N' 'D' (or MAX_CYCLES).  scripts/uart_bytes_to_pnm.py
// then rebuilds the image and compares it with the golden PNM.
`timescale 1 ps / 1 ps
module tb_gls;
  parameter integer CLK_DIV    = 4;             // UART clocks per bit of the netlist under test
  parameter integer MAX_CYCLES = 4000000;
  parameter integer STOP_AFTER_BYTES = 0;       // >0: stop after this many UART bytes instead of END
  parameter         OUT_FILE   = "uart_bytes.bin";

  reg  clk_r = 1'b0;
  reg  key_n_r = 1'b0;
  wire clk = clk_r;                             // pads are inout inside the netlist: drive via nets
  wire key_n = key_n_r;
  wire [2:0] led_n;
  wire uart_tx;

  fpga_top dut (.clk(clk), .key_n(key_n), .led_n(led_n), .uart_tx(uart_tx));

  always #10000 clk_r = ~clk_r;                 // 20 ns period

  integer fd, nbytes = 0, cycles = 0, state = 0, cnt = 0, bitno = 0;
  reg [7:0] cur = 8'h00, b1 = 8'h00, b2 = 8'h00, b3 = 8'h00;
  reg prev_tx = 1'b1;
  reg tx_s;

  initial begin
    fd = $fopen(OUT_FILE, "wb");
    #2000000 key_n_r = 1'b1;                    // release the button after 100 clocks
  end

  always @(posedge clk) begin
    cycles <= cycles + 1;
    tx_s = (uart_tx === 1'b1) ? 1'b1 : 1'b0;    // treat X/Z as 0 for the receiver
    case (state)
      0: if (prev_tx == 1'b1 && tx_s == 1'b0) begin state <= 1; cnt <= CLK_DIV / 2; bitno <= 0; cur <= 8'h00; end
      1: begin cnt <= cnt - 1; if (cnt == 1) begin state <= 2; cnt <= CLK_DIV; end end
      2: begin cnt <= cnt - 1;
           if (cnt == 1) begin
             cur[bitno] <= tx_s; bitno <= bitno + 1; cnt <= CLK_DIV;
             if (bitno == 7) state <= 3;
           end
         end
      3: begin cnt <= cnt - 1;
           if (cnt == 1) begin
             state <= 0; nbytes <= nbytes + 1;
             $fwrite(fd, "%c", cur);
             b1 <= b2; b2 <= b3; b3 <= cur;
             if ((b2 == "E" && b3 == "N" && cur == "D") || (STOP_AFTER_BYTES > 0 && nbytes + 1 == STOP_AFTER_BYTES)) begin
               $display("tb_gls: %0d UART bytes received after %0d clocks, led_n=%b", nbytes + 1, cycles, led_n);
               #3000000;                        // 150 clocks: let the LEDs settle
               $display("tb_gls: final led_n=%b (bit1=0 -> checksum LED on)", led_n);
               $fclose(fd); $finish;
             end
           end
         end
    endcase
    prev_tx <= tx_s;
    if (cycles % 100000 == 0 && cycles != 0) $display("tb_gls: %0d clocks, %0d UART bytes so far, led_n=%b", cycles, nbytes, led_n);
    if (cycles == MAX_CYCLES) begin
      $display("tb_gls: TIMEOUT after %0d clocks, %0d bytes, led_n=%b", cycles, nbytes, led_n);
      $fclose(fd); $finish;
    end
  end
endmodule
